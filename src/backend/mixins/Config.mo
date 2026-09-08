// ⚠️ Several of these carry no `Module.` call and are required anyway: they are what
// make the receiver methods resolve — `.toText()` on the audited figures, `.map()` on a
// tier array, `Time.now()` for the validation clock.
import Array "mo:core/Array";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Delivery "../Delivery";
import Gate "../Gate";
import Orders "../Orders";
import Pricing "../Pricing";
import Recovery "../Recovery";
import Result "mo:core/Result";
import Tiers "../Tiers";

/// The operator's policy levers: pricing, the admission gate, delivery bounds, the price
/// tiles, the Stripe mode, and the sweep cadence — plus the one public read of the
/// bounds a buyer's UI needs (§7).
///
/// ⚠️ **Every setter validates atomically and writes nothing on failure**, which is why
/// they are grouped: the pattern is one `validate` then one assignment, and a setter that
/// half-applied a config would leave a policy nobody chose.
///
/// ⚠️ **Timers are re-armed through `ops`, not here.** Two of these setters change a
/// cadence and must take effect without waiting out the old interval. The composition
/// root owns the `TimerId`s — transient, so a value passed by `include` would be a stale
/// copy — and the `<system>` capability. Keeping the cancel/re-arm there also means a
/// mixin cannot stop the rate refresh or the recovery sweep from an endpoint.
///
/// ⚠️ **State parameters name only the fields these setters touch** (`docs/DESIGN.md`
/// §9.1), so the compiler enforces the slice rather than a comment claiming it.
mixin (
  orderStore : Orders.Store,
  rateCache : Pricing.Cache,
  reserveState : { var cyclesLedgerFee : Nat },
  gateState : { var config : Gate.Config },
  pricingState : { var config : Pricing.Config },
  stripeState : { var expectLivemode : ?Bool },
  tierState : { var cards : [Tiers.Tier] },
  deliveryState : { var config : Delivery.Config },
  recoveryState : { var sweepIntervalNs : Nat },
  ops : {
    requireController : (Principal) -> ();
    auditAdmin : (Principal, Text, Text) -> ();
    expectedIndexScanCycleNs : () -> Nat;
    /// Cancel and re-arm, at the cadence the new config implies.
    ///
    /// ⚠️ **`<system>` is part of the TYPE, not decoration.** Arming a timer needs the
    /// system capability, so the closure carries it and the call site here must be in a
    /// context that has it — which a `shared` function body is. Declaring it as a plain
    /// `() -> ()` fails with M0096, and that is the compiler refusing to let a mixin
    /// smuggle timer control into a context without the capability.
    rearmRateTimer : <system>() -> ();
    /// Cancel and re-arm at exactly this interval, which the caller has validated.
    rearmRecoveryTimer : <system>(Nat) -> ();
  },
) {

    /// Why the expected Stripe mode could not be set (#123).
    ///
    /// ⚠️ **One case, and it stays a variant rather than collapsing to `()`.** The refusal
    /// is not "bad argument" — it is a *conflict with another setting*, and the caller
    /// needs the conflicting value to explain it. A second reason to refuse is plausible
    /// (a live mode with no key provisioned, say), and a variant admits one without
    /// changing the shape callers already match on.
    type LivemodeError = {
      /// A simulation divisor is set, so only `?false` is accepted: taking live or
      /// either-mode payments while scaling cycles down would short a paying buyer.
      /// Clearing the divisor needs a reinstall — see `set_pricing_config`.
      #simulationDivisorSet : { divisor : Nat };
    };

  /// Adjust pricing params (§7): fee formula, staleness window, delta guard.
  /// Validated atomically — a bad config never partially applies.
  /// ⚠️ **Three divisor guards live here rather than in `Pricing.validateConfig`,
  /// because each needs context that module cannot see** (#99). All three are
  /// checked before anything is written, so a bad config never partially applies.
  public shared ({ caller }) func set_pricing_config(config : Pricing.Config) : async Result.Result<(), Pricing.ConfigError> {
    ops.requireController(caller);
    // 1. ⚠️ **`?false` EXACTLY, not `!= ?true`.** `null` means "either mode", so
    // it accepts live payments — and `null` is the default. A guard keyed on
    // `?true` would leave the state every freshly installed canister is in wide
    // open, and that state takes real money and under-delivers.
    if (config.divisor > 1 and stripeState.expectLivemode != ?false) {
      return #err(#divisorNeedsSandbox({ expectLivemode = stripeState.expectLivemode }));
    };
    // 2. The divisor is global, so it must not move under stored orders — every
    // earlier receipt would recompute against the new value and report a
    // mismatch. `storedCount` is `orders.size()`, so this costs one comparison.
    if (config.divisor != pricingState.config.divisor) {
      let stored = Orders.storedCount(orderStore);
      if (stored > 0) return #err(#divisorChangeWithOrders({ stored }));
    };
    // 3. Would the smallest purchase we sell still clear the ledger's flat
    // deposit fee at this divisor? Advisory-at-set-time only: `Pricing.quote`
    // re-checks every order, because this one goes stale as rates move.
    switch (
      Pricing.divisorDeliverable(
        rateCache,
        { feeBps = config.feeBps; feeFixedCents = config.feeFixedCents },
        gateState.config.minPurchaseUsdCents,
        config.divisor,
        reserveState.cyclesLedgerFee,
      )
    ) {
      case (#err(e)) return #err(e);
      case (#ok) {};
    };
    switch (Pricing.validateConfig(config)) {
      case (#ok) {
        pricingState.config := config;
        // The cadence is derived from maxAgeNs, so re-arm rather than waiting
        // for the old interval to elapse under the new window. ⚠️ Re-armed by the
        // composition root: it owns the TimerId (transient) and the `<system>`
        // capability, and a mixin that could cancel timers would be able to stop the
        // rate refresh from an endpoint.
        ops.rearmRateTimer<system>();
        ops.auditAdmin(
          caller,
          "rates.configSet",
          "maxAgeNs=" # config.maxAgeNs.toText()
          # " deltaBps=" # config.maxRateDeltaBps.toText()
          # " divisor=" # config.divisor.toText(),
        );
        #ok;
      };
      case (#err(e)) #err(e);
    };
  };

  /// Replace the card presets (§3/§7 — admin, validated atomically: a bad config
  /// never partially applies).
  ///
  /// ⚠️ **This is no longer the rail's on/off switch.** An empty list used to
  /// pause the rail, and the audit line said "CARD RAIL PAUSED". With custom
  /// amounts (#33) a buyer can order without any preset, so an empty list stops
  /// nothing — it just shows no tiles. The switch is both Stripe secrets being
  /// provisioned; `railsLive` is where that lives.
  public shared ({ caller }) func set_card_tiers(tiers : [Tiers.Tier]) : async Result.Result<(), Tiers.ValidateError> {
    ops.requireController(caller);
    switch (Tiers.validate(tiers, gateState.config.minPurchaseUsdCents, gateState.config.maxPurchaseUsdCents)) {
      case (#ok) {
        tierState.cards := tiers;
        ops.auditAdmin(caller, "tiers.set", tiers.size().toText() # " preset(s)" # (if (tiers.size() == 0) " — no presets shown; the rail is unaffected" else ""));
        #ok;
      };
      case (#err(e)) #err(e);
    };
  };

  /// Declare which Stripe mode this gateway serves (controller only).
  ///
  /// Set it to `?true` before taking real payments and `?false` on a sandbox
  /// deployment. `null` restores "accept either", which only makes sense while
  /// nothing of value is at stake — and it is the default, so a fresh canister
  /// starts there.
  ///
  /// ⚠️ **The other half of the divisor's mutual refusal (#99 2a).** While a
  /// simulation divisor is set, this refuses anything but `?false`: live mode
  /// takes real money and delivers scaled cycles, and `null` accepts live
  /// payments too. Mutual, so **neither order of operations** reaches the state
  /// that shorts a paying buyer — it is unrepresentable rather than discouraged.
  public shared ({ caller }) func set_expected_livemode(expected : ?Bool) : async Result.Result<(), LivemodeError> {
    ops.requireController(caller);
    if (expected != ?false and pricingState.config.divisor > 1) {
      // The divisor travels as DATA (#123): a console can say which value is blocking
      // this without parsing it back out of a sentence, and the remedy is one lever.
      return #err(#simulationDivisorSet({ divisor = pricingState.config.divisor }));
    };
    stripeState.expectLivemode := expected;
    ops.auditAdmin(
      caller,
      "stripe.expectLivemodeSet",
      switch (expected) {
        case (?true) "true — only live-mode payments deliver";
        case (?false) "false — only test-mode payments deliver";
        case null "unset — either mode delivers";
      },
    );
    #ok;
  };

  /// Adjust the admission gate (§7): open-order cap, own-cycles floor,
  /// per-purchase ceiling. Validated atomically — a bad config never partially
  /// applies. Lowering `maxPurchaseUsdCents` below an existing tier does NOT
  /// retroactively invalidate that tier's registration, but the next
  /// `set_card_tiers` will reject it and the webhook will refuse to deliver a
  /// payment above the new ceiling.
  public shared ({ caller }) func set_gate_config(config : Gate.Config) : async Result.Result<(), Gate.ConfigError> {
    ops.requireController(caller);
    // Cross-check against live tiers: lowering the ceiling under a registered tier
    // would leave it sellable but unpayable (see Gate.ConfigError.tierAboveCeiling).
    let tierPrices = tierState.cards.map(func(t) = (t.id, t.usdCents));
    // ⚠️ **The divisor's ceiling is a function of the FLOOR, so lowering the floor
    // has to be checked against the divisor** (#99). `set_pricing_config` refuses a
    // divisor the current minimum purchase cannot survive; without this, the same
    // configuration is reachable from the other direction — set the divisor at a
    // $10 floor, then drop the floor to $1. Mutual, like the livemode guard, so
    // neither order of operations gets there.
    //
    // Checked before anything writes, and only when a divisor is actually set, so a
    // production gateway's gate config is unaffected.
    if (pricingState.config.divisor > 1) {
      switch (
        Pricing.divisorDeliverable(
          rateCache,
          { feeBps = pricingState.config.feeBps; feeFixedCents = pricingState.config.feeFixedCents },
          config.minPurchaseUsdCents,
          pricingState.config.divisor,
          reserveState.cyclesLedgerFee,
        )
      ) {
        case (#err(#divisorUndeliverable({ scaledCycles; ledgerFee }))) {
          return #err(#floorUndeliverableAtDivisor({
            minUsdCents = config.minPurchaseUsdCents;
            divisor = pricingState.config.divisor;
            scaledCycles;
            ledgerFee;
          }));
        };
        // ⚠️ **Every other `Pricing.ConfigError` is DROPPED here, and each by name so
        // the discard is a decision rather than a catch-all.** A bare `case (#err(_))
        // {}` is the shape this repo has removed four times from the seed script,
        // where a swallowed reason was the whole defect.
        //
        // - `#zeroDivisor` — unreachable: the divisor is already stored, and
        //   `set_pricing_config` refused zero before storing it.
        // - `#divisorNeedsSandbox`, `#divisorChangeWithOrders` — not this setter's
        //   questions. Both are about *changing the divisor*, which is not happening.
        // - `#divisorUndeliverable` is handled above; it is the only one that is
        //   about the floor.
        //
        // ⚠️ **And `divisorDeliverable` returns `#ok` when the floor is below the
        // STRIPE fee**, because there is then no net amount to scale and it declines
        // to judge. That is deliberately NOT refused here: a floor that cannot clear
        // the processing fee is not a divisor problem, and `Pricing.quote` refuses
        // such an order at creation with `#unpriceable(#stripeFee)`. Worth knowing,
        // because a test that used a 2-cent floor passed for exactly this reason
        // while looking like it exercised the guard.
        case (#err(#zeroDivisor or #divisorNeedsSandbox(_) or #divisorChangeWithOrders(_))) {};
        // The five fee/rate cases are `validateConfig`'s, and `divisorDeliverable`
        // never returns one — it does not look at the fee formula or the rate bounds.
        // Listed rather than wildcarded so a new `ConfigError` has to decide here too.
        case (
          #err(
            #feeBpsTooHigh or #nonPositiveMaxAge or #maxAgeTooLong(_)
            or #zeroRateDelta or #zeroRateSources
          )
        ) {};
        case (#ok) {};
      };
    };
    switch (Gate.validateConfig(config, tierPrices)) {
      case (#ok) {
        gateState.config := config;
        ops.auditAdmin(caller, "gate.configSet", "openOrderCap=" # config.maxOpenOrdersPerPrincipal.toText()
          # " minCycles=" # config.minCanisterCycles.toText()
          # " maxPurchaseCents=" # config.maxPurchaseUsdCents.toText());
        #ok;
      };
      case (#err(e)) #err(e);
    };
  };

  /// Public: the frontend needs the bounds to size its amount input and to say
  /// what it will accept before the buyer types. Same transparency stance as
  /// `pricing_status` and `reserve_status` — these are the rules users are held
  /// to, not secrets.
  ///
  /// ⚠️ **`delivery` is here because `set_delivery_config` had NO reader at all.**
  /// `maxHoldNs` decides when a paid order escalates to `#needsReview` and `alertAfterNs`
  /// is the delay-alert threshold — both global policy of ours, and both write-only until
  /// now: they appeared in the setter's argument and its error variant and in no return
  /// type anywhere, so an operator could set them and never read them back.
  ///
  /// The comment this replaces said there was "no lifecycle *policy* of ours to add" —
  /// true of an order's DEADLINE, which is the Stripe session's `expires_at` and lives on
  /// the order, and untrue as the general claim it had become. `scripts/check-config-readers.py`
  /// is what stops the next write-only parameter, rather than this comment.
  public query func lifecycle_config() : async {
    gate : Gate.Config;
    delivery : Delivery.Config;
  } {
    { gate = gateState.config; delivery = deliveryState.config };
  };

  /// Tune the delivery timeline (admin, §7).
  ///
  /// ⚠️ Validated rather than trusted: an alert at or after the terminal bound would
  /// tell the operator at the moment the decision was already taken, and a
  /// non-positive bound would escalate every order instantly.
  public shared ({ caller }) func set_delivery_config(config : Delivery.Config) : async Result.Result<(), Delivery.ConfigError> {
    ops.requireController(caller);
    switch (Delivery.validateConfig(config)) {
      case (#err(e)) return #err(e);
      case (#ok) {};
    };
    deliveryState.config := config;
    ops.auditAdmin(caller, "delivery.configSet", "alert after " # config.alertAfterNs.toText() # " ns, terminate after " # config.maxHoldNs.toText() # " ns");
    #ok;
  };

  /// Tune the sweep cadence (admin, §7) — re-arms immediately, no redeploy.
  /// Validated against the §5.1 bound: the cadence must stay well inside
  /// the ledger dedup window or replay loses its safety margin.
  public shared ({ caller }) func set_recovery_interval(intervalNs : Nat) : async Result.Result<(), Recovery.IntervalError> {
    ops.requireController(caller);
    switch (Recovery.validateInterval(intervalNs, Delivery.ledgerDedupWindowNs)) {
      case (#err(e)) #err(e);
      case (#ok) {
        recoveryState.sweepIntervalNs := intervalNs;
        ops.rearmRecoveryTimer<system>(intervalNs);
        // ⚠️ **This knob also sets the index scan's coverage window (#63), which its
        // name does not say.** The rotating scan runs one chunk per sweep, so coarsening
        // the cadence multiplies the detection latency for `orders.unindexedHolders` —
        // a finding that means the reserve was oversellable. Audited with the resulting
        // window so the consequence is in the same line as the cause, rather than
        // something an operator has to go and derive.
        ops.auditAdmin(
          caller,
          "recovery.intervalSet",
          "sweep cadence set to " # intervalNs.toText() # " ns."
          # " The #63 index scan rides this cadence, so a full coverage cycle now takes about "
          # (ops.expectedIndexScanCycleNs() / 1_000_000_000 / 3_600).toText()
          # " h at the current store size — that is the detection latency for orders.unindexedHolders.",
        );
        #ok;
      };
    };
  };
};
