/// Pre-creation admission gate — the "check before you take money" pass.
///
/// Order creation is refused when fulfilment is already known to be impossible:
/// too few cycles in the reserve to cover the order, this canister's own cycle
/// balance too low to keep running, an amount outside the per-purchase bounds,
/// or a principal holding too many open orders.
///
/// ⚠️ **Advisory about money, authoritative about abuse.** The binding money check is
/// at delivery, when the transfer lands or does not. This gate exists so a refusal
/// reaches the buyer *before* they pay Stripe — a user-experience guarantee, not a
/// solvency one.
///
/// An admission gate, **not** a capacity reservation: nothing is escrowed at creation,
/// and `lockedCycles` is a price rather than a hold. A reservation would need
/// reserved-but-unpaid accounting plus a release path, and still could not guarantee
/// delivery.
///
/// Every check is pure arithmetic over values the caller supplies, so the whole policy
/// unit-tests with no IC environment.
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Reserve "Reserve";

module {

  public type Config = {
    /// Cap on simultaneously-`#created` orders per principal. This is the
    /// bound that actually stops unbounded state growth: paid volume is
    /// self-limiting, because every delivery spends a reserve someone had to
    /// fund, so the only unbounded vector is *unpaid* orders — free to create
    /// (`canister-security`: allowing unbounded user-controlled storage).
    /// Not a money decision — an abuse bound. Raise it for legitimate power
    /// users; do not set it to 0, which would block the rail entirely.
    ///
    /// One, as a product call rather than a safety control: a buyer who wants another
    /// slot cancels the one they have, which is what makes `cancel_order` load-bearing.
    /// **Do not harden this against identity flooding.** A per-principal cap cannot
    /// bound an attacker who rotates self-authenticating principals, so the honest bound
    /// is the cycles cost of the calls plus `minCanisterCycles` failing the rail closed.
    ///
    /// ⚠️ **Only safe because `Orders.openOrderCount` skips past-deadline orders.** At a
    /// cap of 1 without that check, one missed expiry webhook locks a buyer out forever.
    maxOpenOrdersPerPrincipal : Nat;
    /// Floor on this canister's OWN cycle balance — its gas, not the cycles it
    /// sells. Below the freezing threshold the canister stops accepting updates;
    /// at zero it is uninstalled. This is the "should never happen" guard, and it
    /// must be well above the freezing threshold so there is room to notice and
    /// top up.
    ///
    /// ⚠️ **THREE balances, and confusing them is the classic operational error.**
    ///   - **gas** — this canister's own balance, spent by running. `icp canister status`.
    ///   - **stock** — the reserve: the gateway's cycles-ledger *account*, spent by
    ///     delivering, topped up by a plain `icp cycles transfer <amt> <backend-id>`.
    ///     `reserve_status`, or `icp cycles balance --of-principal <backend-id>`.
    ///   - **the operator's own cycles-ledger account**, which funds both. `icp cycles
    ///     balance`. ⚠️ A failed top-up reports *this* balance, under a message about the
    ///     reserve — so read "insufficient funds. balance: N" as the sender's, not the
    ///     reserve's.
    minCanisterCycles : Nat;
    /// Per-purchase ceiling on the gross USD amount.
    ///
    /// It stopped being defence in depth when custom amounts arrived (#33): the
    /// buyer names the amount now, so this is the **only** upper bound, and it is
    /// the real lever on the reserve-availability vector in #30 — the ceiling IS
    /// the per-order reserve exposure. At $1,000 one unpaid order ties up ~720 T
    /// of reserve for a few hundred million cycles of our gas; at $100 it is
    /// ~72 T, a 10× improvement for one config value and no new machinery.
    ///
    /// **One ceiling governs presets AND custom amounts.** Do not add a
    /// custom-amount-specific limit. Two knobs for one rule drift apart, and then
    /// which one binds depends on the path the amount arrived by — an amount a
    /// preset may be sold at but a custom order may not, or the reverse.
    maxPurchaseUsdCents : Nat;
    /// Floor on the gross USD amount, for the same two cases.
    ///
    /// Below it the §3 fee formula swallows too much of the payment to be worth
    /// the outcall and the reserve hold: a $1 purchase pays ~33¢ in card fees
    /// before it buys a cycle. Nothing enforced a floor before #33 —
    /// `Tiers.validate` checked non-zero and the ceiling only.
    ///
    /// Enforced in **two** places, and both are needed: here, for every order;
    /// and in `set_card_tiers`, or a registered tier becomes unsellable — the
    /// mirror of `#tierAboveCeiling`.
    minPurchaseUsdCents : Nat;
  };

  /// Deliberately non-zero. These are *safety limits*, not money decisions: a
  /// default of 0 would brick the canister rather than protect it, which is the
  /// wrong direction of fail-closed. The one value that does gate money — how many
  /// cycles are available to sell — has no default at all, because it is whatever
  /// the operator actually funded the reserve with.
  ///
  /// The card rail's on/off switch is **both Stripe secrets being provisioned**
  /// (#33), not the tier list. An empty tier list now means only "no presets
  /// shown", because a custom amount is orderable without one.
  public func defaultConfig() : Config {
    {
      maxOpenOrdersPerPrincipal = 1;
      minCanisterCycles = 5_000_000_000_000; // 5T
      // $100, down from $1,000 (#33). The ceiling IS the per-order reserve
      // exposure, so this is the main lever on #30's reserve-griefing vector.
      maxPurchaseUsdCents = 10_000;
      // $10. Below this the card fee eats too much of the payment to be worth an
      // outcall and a reserve hold.
      minPurchaseUsdCents = 1_000;
    };
  };

  public type ConfigError = {
    #zeroOpenOrderCap;
    #zeroPurchaseCeiling;
    /// A registered card tier costs more than the new per-purchase ceiling.
    ///
    /// `set_card_tiers` already refuses a tier above the ceiling; without the
    /// inverse check, lowering the ceiling leaves that tier **sellable but
    /// unpayable**: the buyer completes checkout and the webhook files a refundable
    /// obligation,
    /// because the honoured amount exceeds the ceiling. Since #33 deleted
    /// `attach_payment` there is no rescue at all — the only remedy is a refund,
    /// so the money is taken and given back for a config change made earlier.
    #tierAboveCeiling : { tierId : Text; usdCents : Nat; maxUsdCents : Nat };
    /// The mirror: a registered tier costs less than the new floor.
    #tierBelowFloor : { tierId : Text; usdCents : Nat; minUsdCents : Nat };
    /// A floor above the ceiling admits nothing at all — the rail would refuse
    /// every amount, which is a config typo rather than a policy.
    #floorAboveCeiling : { minUsdCents : Nat; maxUsdCents : Nat };
    /// ⚠️ **The mirror of `Pricing.ConfigError.divisorUndeliverable`, and it exists
    /// because the divisor's ceiling is a function of the FLOOR** (#99).
    ///
    /// `set_pricing_config` refuses a divisor that scales the current minimum
    /// purchase below what the cycles-ledger deposit fee eats. Without this check,
    /// lowering the floor afterwards reaches the same configuration from the other
    /// direction: accept divisor 1,000 at a $10 floor, then drop the floor to $1,
    /// and every minimum-amount purchase starts refusing with a message about the
    /// simulation scale rather than about the change the operator just made.
    ///
    /// Not unsafe — `Pricing.quote` still refuses at creation, so no money moves
    /// and nothing stalls. It is the *learns at set time rather than through a
    /// buyer's refusal* property that goes missing, in the one direction that is
    /// reachable. Mutual, like the livemode guard, so neither order of operations
    /// gets there.
    #floorUndeliverableAtDivisor : {
      minUsdCents : Nat;
      divisor : Nat;
      scaledCycles : Nat;
      ledgerFee : Nat;
    };
  };

  /// `tierPrices` is every registered card tier, so the ceiling cannot be lowered
  /// underneath one. Pass an empty array when there are no tiers to consider.
  public func validateConfig(
    config : Config,
    tierPrices : [(Text, Nat)],
  ) : Result.Result<(), ConfigError> {
    if (config.maxOpenOrdersPerPrincipal == 0) return #err(#zeroOpenOrderCap);
    if (config.maxPurchaseUsdCents == 0) return #err(#zeroPurchaseCeiling);
    if (config.minPurchaseUsdCents > config.maxPurchaseUsdCents) {
      return #err(#floorAboveCeiling({
        minUsdCents = config.minPurchaseUsdCents;
        maxUsdCents = config.maxPurchaseUsdCents;
      }));
    };
    for ((tierId, usdCents) in tierPrices.values()) {
      if (usdCents > config.maxPurchaseUsdCents) {
        return #err(#tierAboveCeiling({ tierId; usdCents; maxUsdCents = config.maxPurchaseUsdCents }));
      };
      // The mirror, for the same reason: raising the floor over a registered tier
      // would leave it sellable but unpayable, and the operator would have to
      // connect a refused order to a config change made earlier.
      if (usdCents < config.minPurchaseUsdCents) {
        return #err(#tierBelowFloor({ tierId; usdCents; minUsdCents = config.minPurchaseUsdCents }));
      };
    };
    // minCanisterCycles = 0 is permitted: it means "do not gate on my own
    // balance", which is a coherent (if unwise) operator choice and is the
    // only way to keep serving while deliberately running the canister down.
    #ok;
  };

  /// Why admission was refused. Each case carries the observed value and the
  /// bound so the frontend can explain the refusal rather than showing a
  /// generic failure, and so the operator can see which lever to move.
  public type Reason = {
    #tooManyOpenOrders : { open : Nat; max : Nat };
    #canisterCyclesLow : { balance : Nat; min : Nat };
    /// The reserve cannot cover this order on top of what is already owed.
    /// Carries both figures so the frontend can offer a smaller amount instead of
    /// a bare failure, and an operator reading a ticket knows whether to top the
    /// reserve up or hunt a leak.
    #reserveShort : { requested : Nat; available : Nat };
    #amountAboveMax : { usdCents : Nat; maxUsdCents : Nat };
    /// Below the floor. Distinguishable from `#amountAboveMax` because the buyer
    /// acts on them differently — one means "ask for less", the other "ask for
    /// more" — and with custom amounts both are reachable by typing.
    #amountBelowMin : { usdCents : Nat; minUsdCents : Nat };
    /// ⚠️ **The gateway is a faucet: it accepts free test payments, has an empty
    /// buyer allow-list, and has a funded reserve** (#99 2b). Stripe test
    /// payments are free and unlimited — `4242 4242 4242 4242` pays any session,
    /// for anyone who reaches the page — so this combination gives cycles away to
    /// the internet. Refused rather than warned about.
    ///
    /// ⚠️ **A fact about the GATEWAY, not about this buyer**, which is why it is
    /// a separate reason from `#buyerNotAllowed` and why it is checked first. With
    /// an empty list, a per-principal check would refuse every buyer with "not on
    /// the allow-list" — and populating the list genuinely does fix it, so the
    /// lever is right and the *diagnosis* is wrong. It reads as "this buyer is not
    /// authorized" when the state is "we are unbounded and refusing everyone",
    /// sending an operator to the list rather than to the order in which they
    /// funded the reserve.
    #unboundedGiveaway : { reserveFloor : Nat };
    /// This principal is not on the buyer allow-list, which is enforced while the
    /// gateway accepts free test payments (#99 2b).
    ///
    /// Per-*principal*, so it never latches and never announces — nothing about
    /// the gateway changed, exactly like `#tooManyOpenOrders`.
    #buyerNotAllowed;
  };

  /// Renderable config-validation failure.
  ///
  /// `#tierAboveCeiling` names the offending tier and both numbers, because "your
  /// ceiling is too low" without saying which tier collides is a message an operator
  /// has to go and investigate.
  public func configErrorToText(error : ConfigError) : Text {
    switch (error) {
      case (#zeroOpenOrderCap) "zeroOpenOrderCap";
      case (#zeroPurchaseCeiling) "zeroPurchaseCeiling";
      case (#tierAboveCeiling({ tierId; usdCents; maxUsdCents })) {
        "tierAboveCeiling(tier " # tierId # " costs " # usdCents.toText()
        # " cents, ceiling would be " # maxUsdCents.toText() # ")";
      };
      case (#tierBelowFloor({ tierId; usdCents; minUsdCents })) {
        "tierBelowFloor(tier " # tierId # " costs " # usdCents.toText()
        # " cents, floor would be " # minUsdCents.toText() # ")";
      };
      case (#floorAboveCeiling({ minUsdCents; maxUsdCents })) {
        "floorAboveCeiling(" # minUsdCents.toText() # ">" # maxUsdCents.toText() # ")";
      };
      case (#floorUndeliverableAtDivisor({ minUsdCents; divisor; scaledCycles; ledgerFee })) {
        // Names the divisor as well as the floor, because the operator changed the
        // floor and the constraint comes from the other setting.
        "floorUndeliverableAtDivisor(a " # minUsdCents.toText() # "-cent floor at divisor "
        # divisor.toText() # " scales to " # scaledCycles.toText()
        # " cycles, which does not clear the " # ledgerFee.toText() # " ledger fee with headroom)";
      };
    };
  };

  public func reasonToText(reason : Reason) : Text {
    switch (reason) {
      case (#tooManyOpenOrders({ open; max })) "tooManyOpenOrders(" # open.toText() # "/" # max.toText() # ")";
      case (#canisterCyclesLow({ balance; min })) "canisterCyclesLow(" # balance.toText() # "<" # min.toText() # ")";
      case (#unboundedGiveaway({ reserveFloor })) "unboundedGiveaway(floor " # reserveFloor.toText() # ", empty allow-list, test payments accepted)";
      case (#buyerNotAllowed) "buyerNotAllowed";
      case (#reserveShort({ requested; available })) "reserveShort(need " # requested.toText() # ", have " # available.toText() # ")";
      case (#amountAboveMax({ usdCents; maxUsdCents })) "amountAboveMax(" # usdCents.toText() # ">" # maxUsdCents.toText() # ")";
      case (#amountBelowMin({ usdCents; minUsdCents })) "amountBelowMin(" # usdCents.toText() # "<" # minUsdCents.toText() # ")";
    };
  };

  /// Running tally of refusals, one counter per `Reason` (#61).
  ///
  /// ⚠️ **A counter and not an audit line, because refusals are free to attempt.**
  /// `#amountBelowMin` needs no prior state — one cent from any fresh principal
  /// reaches it with no order, no payment and no setup — and principals are free. The
  /// audit log drops nothing, so a line per attempt is permanent stable-state growth at
  /// zero attacker cost. Every other structure here is attacker-priced: orders by the
  /// open-order cap and the reserve, orphans by needing a real payment to exist.
  ///
  /// **A record rather than a map, so a new `Reason` cannot be silently untallied** —
  /// `countRefusal` switches exhaustively, so adding a variant is a compile error here
  /// rather than a counter that reads zero in production.
  public type RefusalCounts = {
    amountAboveMax : Nat;
    amountBelowMin : Nat;
    tooManyOpenOrders : Nat;
    canisterCyclesLow : Nat;
    reserveShort : Nat;
    /// ⚠️ **Not a `Reason`, and that is why it is easy to miss.** The rail being
    /// unprovisioned is refused *before* the gate — `create_order` checks caller,
    /// destination, then the RAIL, then tier and admission — so while the rail is
    /// closed **100% of attempts never reach `admit` at all**. A counter set that
    /// only covered `Reason` would record nothing during exactly the window the
    /// gateway spends freshly deployed, because RUNBOOK §1 prescribes
    /// provisioning the secrets last.
    railClosed : Nat;
    /// The session outcall failed. Separate from `railClosed` because a present
    /// but invalid key is a different incident from an absent one.
    stripeApiFailed : Nat;
    /// The faucet refusal (#99 2b) — see `Reason.unboundedGiveaway`.
    unboundedGiveaway : Nat;
    /// A non-allow-listed buyer against a POPULATED list. Counted separately from
    /// `unboundedGiveaway` because the two mean opposite things: this one is the
    /// allow-list working, that one is the allow-list missing.
    buyerNotAllowed : Nat;
  };

  public func noRefusals() : RefusalCounts {
    ({
      amountAboveMax = 0;
      amountBelowMin = 0;
      tooManyOpenOrders = 0;
      canisterCyclesLow = 0;
      reserveShort = 0;
      railClosed = 0;
      stripeApiFailed = 0;
      unboundedGiveaway = 0;
      buyerNotAllowed = 0;
    });
  };

  /// Rail closure is counted through its own entry point, because it is not a
  /// `Reason` — see `RefusalCounts.railClosed`.
  public func countRailClosed(counts : RefusalCounts) : RefusalCounts {
    ({ counts with railClosed = counts.railClosed + 1 });
  };

  public func countStripeApiFailed(counts : RefusalCounts) : RefusalCounts {
    ({ counts with stripeApiFailed = counts.stripeApiFailed + 1 });
  };

  public func countRefusal(counts : RefusalCounts, reason : Reason) : RefusalCounts {
    switch (reason) {
      case (#amountAboveMax(_)) ({ counts with amountAboveMax = counts.amountAboveMax + 1 });
      case (#amountBelowMin(_)) ({ counts with amountBelowMin = counts.amountBelowMin + 1 });
      case (#tooManyOpenOrders(_)) ({ counts with tooManyOpenOrders = counts.tooManyOpenOrders + 1 });
      case (#canisterCyclesLow(_)) ({ counts with canisterCyclesLow = counts.canisterCyclesLow + 1 });
      case (#reserveShort(_)) ({ counts with reserveShort = counts.reserveShort + 1 });
      case (#unboundedGiveaway(_)) ({ counts with unboundedGiveaway = counts.unboundedGiveaway + 1 });
      case (#buyerNotAllowed) ({ counts with buyerNotAllowed = counts.buyerNotAllowed + 1 });
    };
  };

  /// Does this refusal describe the **gateway's** state, or **one request's**?
  ///
  /// Only the two rail-state conditions get an audit line, and the split is the
  /// whole point of #61: `#reserveShort` and `#canisterCyclesLow` are global facts
  /// about this gateway, so *"it started refusing at T"* is a real event an
  /// operator wants. The other three have **no meaningful transition** — nothing
  /// about the gateway changed, one request was malformed (`#amountBelowMin`,
  /// `#amountAboveMax`) or one principal used its own slot
  /// (`#tooManyOpenOrders`).
  /// A condition that is a fact about the **gateway**, so entering it is worth
  /// exactly one audit line and every later refusal under it is noise.
  ///
  /// **Three, not two.** `#railClosed` belongs here for the same reason the
  /// other two do — either the API key and origin are provisioned or they are not
  /// — and it is refused on a path that never reaches `admit`, so it cannot be
  /// expressed as a `Reason`.
  public type RailCondition = {
    #reserveShort;
    #canisterCyclesLow;
    #railClosed;
    /// A Stripe session **outcall** is failing, as distinct from `#railClosed`'s "no
    /// key at all". Its clearest cause is a key that is present but **invalid** —
    /// rotated or revoked at Stripe without updating the canister — which
    /// `sessionConfig` cannot detect, because the secret exists.
    ///
    /// **One condition for BOTH session outcalls — create and expire — because they
    /// share one diagnosis and one lever.** A revoked key fails both, and "rotate the
    /// key" is the answer to either. Splitting them would file two incidents for one
    /// cause and leave an operator wondering which to act on. Named for the API rather
    /// than for `create`, so the next outcall added here does not need a third
    /// condition.
    ///
    /// **Different diagnosis, different lever, so not folded into `#railClosed`:**
    /// that one says *provision the key*, this one says *rotate it*. Folding them
    /// would file the wrong instruction.
    #stripeApiFailing;
    /// The gateway is a faucet — see `Reason.unboundedGiveaway` (#99 2b).
    ///
    /// **A rail condition rather than a per-request reason** because it is a fact
    /// about this gateway: it started refusing at a definite T, which is the
    /// transition an operator wants exactly one audit line for. The lever is
    /// "populate the allow-list", or "go live", or "do not fund the reserve yet".
    #unboundedGiveaway;
  };

  /// Which refusals describe the gateway rather than one request. Exhaustive, so
  /// a new `Reason` has to decide rather than defaulting to "not rail state".
  public func railConditionOf(reason : Reason) : ?RailCondition {
    switch (reason) {
      case (#reserveShort(_)) ?#reserveShort;
      case (#canisterCyclesLow(_)) ?#canisterCyclesLow;
      case (#unboundedGiveaway(_)) ?#unboundedGiveaway;
      // Nothing about the gateway changed: one request was malformed
      // (`#amountBelowMin`, `#amountAboveMax`), or one principal used its own slot
      // (`#tooManyOpenOrders`), or one principal is not on a list that IS doing its
      // job (`#buyerNotAllowed` — the gateway is correctly bounded, so there is no
      // gateway-level transition to announce).
      case (
        #amountAboveMax(_) or #amountBelowMin(_) or #tooManyOpenOrders(_)
        or #buyerNotAllowed
      ) null;
    };
  };

  public func isRailState(reason : Reason) : Bool {
    railConditionOf(reason) != null;
  };

  /// Which rail-state conditions are **currently** refusing, latched per
  /// condition so that entering the state writes exactly one audit line.
  ///
  /// ⚠️ **Per condition, NOT one global "was admitting, now refusing" flag** —
  /// that naive version reintroduces a smaller copy of the leak this exists to
  /// close. A single flag is reset by *any* legitimate success, so the next
  /// refusal announces again: bounded by real traffic rather than free, but
  /// avoidable entirely by latching only the conditions that actually **have**
  /// states.
  public type RailStateLatch = {
    reserveShort : Bool;
    canisterCyclesLow : Bool;
    railClosed : Bool;
    stripeApiFailing : Bool;
    unboundedGiveaway : Bool;
  };

  public func admitting() : RailStateLatch {
    ({
      reserveShort = false;
      canisterCyclesLow = false;
      railClosed = false;
      stripeApiFailing = false;
      unboundedGiveaway = false;
    });
  };

  /// Enter a rail-state condition. `announce` is true only on the **transition
  /// in** — the caller writes its audit line exactly then.
  ///
  /// This is the single place the announce-once semantics live, so every refusal
  /// path gets them by routing here rather than by reimplementing them.
  public func latchCondition(latch : RailStateLatch, condition : RailCondition) : {
    latch : RailStateLatch;
    announce : Bool;
  } {
    switch (condition) {
      case (#reserveShort) {
        ({ latch = { latch with reserveShort = true }; announce = not latch.reserveShort });
      };
      case (#canisterCyclesLow) {
        ({ latch = { latch with canisterCyclesLow = true }; announce = not latch.canisterCyclesLow });
      };
      case (#railClosed) {
        ({ latch = { latch with railClosed = true }; announce = not latch.railClosed });
      };
      case (#stripeApiFailing) {
        ({
          latch = { latch with stripeApiFailing = true };
          announce = not latch.stripeApiFailing;
        });
      };
      case (#unboundedGiveaway) {
        ({
          latch = { latch with unboundedGiveaway = true };
          announce = not latch.unboundedGiveaway;
        });
      };
    };
  };

  /// Observe a refusal. `announce` is true only on the **transition into** a
  /// rail-state condition — the caller writes its audit line exactly then.
  public func latchRefusal(latch : RailStateLatch, reason : Reason) : {
    latch : RailStateLatch;
    announce : Bool;
  } {
    switch (railConditionOf(reason)) {
      case (?condition) latchCondition(latch, condition);
      // Per-request and per-principal reasons never announce and never latch:
      // they say nothing about whether the gateway is refusing.
      case null ({ latch; announce = false });
    };
  };

  /// Observe a **successful** admission, which is the only thing that clears the
  /// latches.
  ///
  /// ⚠️ **Only a full admission clears them, and that is deliberate.** `admit`
  /// returns on the first failure, so a request refused for being below the
  /// minimum never reaches the reserve check and tells us nothing about whether
  /// the reserve recovered. Clearing on any refusal would drop the latch on
  /// evidence that does not bear on it — and then re-announce on the next
  /// genuine refusal. Reaching a full admission means neither condition fired,
  /// which is exactly the evidence the latch needs.
  /// ⚠️ **`#unboundedGiveaway` IS cleared here, and `#stripeApiFailing` is not —
  /// the difference is what a synchronous admission proves.** A successful admit
  /// says nothing about whether a Stripe *outcall* works, so clearing
  /// `#stripeApiFailing` on it would drop the latch on evidence that does not bear
  /// on it. The faucet condition is the opposite: it is a predicate over state the
  /// admission just evaluated, so **if a buyer was admitted the predicate was
  /// false at that moment** — the list is non-empty, or we are live, or the floor
  /// is zero. Admission is direct proof.
  ///
  /// ⚠️ Decided rather than left to symmetry, because the other way round it
  /// latches when the reserve is funded against an empty list and **never
  /// clears**: `refusingNow` would report the faucet forever after the operator
  /// populated the list and buyers started succeeding — a condition become
  /// permanently unsatisfiable, making the console lie.
  public func latchAdmission(latch : RailStateLatch) : RailStateLatch {
    ({
      latch with
      reserveShort = false;
      canisterCyclesLow = false;
      railClosed = false;
      unboundedGiveaway = false;
    });
  };

  /// A session was created successfully — the only evidence that bears on
  /// `#stripeApiFailing`.
  ///
  /// ⚠️ **Deliberately NOT cleared by `latchAdmission`, and this is the trap.** The
  /// session outcall runs *after* admission, so a successful admission says nothing
  /// about it. If admission cleared it, the sequence "admit ok → session fails →
  /// admit ok → session fails" would announce **every time** — the naive global-flag
  /// bug reappearing one level down. Each condition is cleared only by the evidence
  /// that actually bears on it, which is why `latchAdmission` now names the three it
  /// covers instead of resetting everything.
  public func latchStripeApiOk(latch : RailStateLatch) : RailStateLatch {
    ({ latch with stripeApiFailing = false });
  };

  /// Everything the gate needs to decide, read by the caller immediately
  /// before the decision (all synchronous — no awaits, so no TOCTOU window
  /// between reading and deciding).
  public type Observation = {
    /// Count of this principal's `#created` orders.
    openOrders : Nat;
    /// `Cycles.balance()` — this canister's own gas.
    canisterCycles : Nat;
    /// The maintained reserve **floor**, used only as "is there anything to sell
    /// at all" by the faucet check (#99 2b).
    ///
    /// ⚠️ **This is NOT a solvency input, and the distinction is load-bearing** —
    /// see the warning at the end of `admit`. Solvency asks "can the reserve cover
    /// *this order*", which must be paired with the hold in one synchronous block
    /// or it is a TOCTOU window. This asks `> 0`, a question no interleaving can
    /// make wrong in a harmful direction: if the floor is zero here and funded a
    /// moment later, `solvent` still governs the actual sale and the next order
    /// gets the faucet refusal.
    ///
    /// The **floor** rather than a ledger balance, and not merely because it is
    /// synchronous: `solvent` derives availability from the floor too, so a
    /// funded-but-unobserved reserve cannot sell and need not trigger the
    /// condition (#82).
    reserveFloor : Nat;
    /// Whether free Stripe **test** payments would be accepted — the rail's
    /// `expectLivemode` is anything other than `?true`.
    ///
    /// Passed as a plain Bool rather than the `?Bool` itself so this module stays
    /// ignorant of Stripe: the gate's question is "are payments here free and
    /// unlimited", not "which mode is the key in".
    acceptsTestPayments : Bool;
    /// Whether the buyer allow-list has no entries at all.
    buyerAllowlistEmpty : Bool;
    /// Whether THIS caller is on the buyer allow-list.
    buyerAllowed : Bool;
  };

  /// Admission decision. Cheapest checks first so a spammed principal is
  /// rejected before anything expensive happens.
  ///
  /// `usdCents` is the *gross* tier/order amount, checked against the
  /// per-purchase ceiling before any quote is computed.
  public func admit(config : Config, observation : Observation, usdCents : Nat) : Result.Result<(), Reason> {
    // ── The faucet, before anything about this request ───────────────────────
    //
    // ⚠️ **First, and the order is the point.** This is a fact about the gateway,
    // so it must not be shadowed by a refusal about the request: a below-minimum
    // amount arriving while we are a faucet would report `#amountBelowMin`, the
    // condition would never latch, and `refusingNow` would say we are admitting.
    if (
      observation.acceptsTestPayments and observation.buyerAllowlistEmpty
      and observation.reserveFloor > 0
    ) {
      return #err(#unboundedGiveaway({ reserveFloor = observation.reserveFloor }));
    };
    if (usdCents > config.maxPurchaseUsdCents) {
      return #err(#amountAboveMax({ usdCents; maxUsdCents = config.maxPurchaseUsdCents }));
    };
    // Checked HERE rather than only in the frontend, because a frontend-only
    // bound is not a bound — and with custom amounts the buyer supplies this
    // number directly.
    if (usdCents < config.minPurchaseUsdCents) {
      return #err(#amountBelowMin({ usdCents; minUsdCents = config.minPurchaseUsdCents }));
    };
    if (observation.openOrders >= config.maxOpenOrdersPerPrincipal) {
      return #err(#tooManyOpenOrders({
        open = observation.openOrders;
        max = config.maxOpenOrdersPerPrincipal;
      }));
    };
    if (observation.canisterCycles < config.minCanisterCycles) {
      return #err(#canisterCyclesLow({
        balance = observation.canisterCycles;
        min = config.minCanisterCycles;
      }));
    };
    // ── This caller against a list that is doing its job ─────────────────────
    //
    // ⚠️ **LAST, and the faucet check is FIRST, and the two positions are the same
    // argument.** `#unboundedGiveaway` is a fact about the gateway, so it must not
    // be shadowed by anything about one request. `#buyerNotAllowed` is a fact about
    // one *principal*, so it must not shadow anything about the gateway — and it
    // would: `can_purchase` is a query the frontend calls to ask "can anyone buy
    // right now", and every suite in this repo probes it **anonymously**. Checked
    // early, an unlisted caller answered `#buyerNotAllowed` to that probe and hid
    // the gas floor, the short reserve and the faucet behind it. 50 integration
    // assertions failed that way.
    //
    // ⚠️ **Two conditions before the caller is even considered, and both are
    // load-bearing.** At go-live the list must have no effect whatsoever, because
    // one that keeps filtering afterwards is an outage nobody would look for. And
    // an EMPTY list must not filter either: that is the state a sandbox gateway is
    // configured in before the list is populated, so filtering on it would refuse
    // every buyer during exactly the window the deployment is being explored in.
    // The empty case is bounded by `#unboundedGiveaway` instead, which fires only
    // once there is something to sell.
    if (
      observation.acceptsTestPayments and not observation.buyerAllowlistEmpty
      and not observation.buyerAllowed
    ) {
      return #err(#buyerNotAllowed);
    };
    // ⚠️ **Solvency is NOT decided here — see `solvent` below.** Everything above
    // is arithmetic over values the caller already holds; the money question needs
    // a ledger read, so it cannot live in a synchronous function. Do not add a
    // balance check here to save a call: that is what reintroduces the TOCTOU
    // window this split exists to close.
    //
    // ⚠️ **The faucet check above reads `reserveFloor` and is NOT that mistake.**
    // It asks `> 0` — is there anything to sell — not "does the reserve cover this
    // order". A stale `> 0` cannot over-promise: `solvent` still decides every
    // sale, paired with its hold. See `Observation.reserveFloor`.
    #ok;
  };

  /// Can the reserve cover this order, on top of everything already owed?
  ///
  /// **Kept separate from `admit`, structurally.** `admit` is synchronous so there
  /// is no TOCTOU window between observing and deciding; folding solvency in would force
  /// every caller to supply a balance, including `can_purchase`, which is a **query**
  /// and cannot await one.
  ///
  /// ⚠️ **The caller must hold `lockedCycles` in the SAME synchronous block as this
  /// check.** Two concurrent creates that both pass here against one `promisedTotal` and
  /// only then hold will together promise more than the balance they checked — two
  /// honest buyers, no attacker.
  public func solvent(reserveBalance : Nat, promisedTotal : Nat, lockedCycles : Nat) : Result.Result<(), Reason> {
    if (Reserve.canCover(reserveBalance, promisedTotal, lockedCycles)) return #ok;
    #err(#reserveShort({
      requested = lockedCycles;
      available = Reserve.available(reserveBalance, promisedTotal);
    }));
  };

};
