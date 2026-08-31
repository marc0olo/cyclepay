/// Pre-creation admission gate — the "check before you take money" pass.
///
/// Order creation is refused when fulfilment is already known to be impossible:
/// too few cycles in the reserve to cover the order, this canister's own cycle
/// balance too low to keep running, an amount outside the per-purchase bounds,
/// or a principal holding too many open orders.
///
/// ⚠️ **This gate is advisory about money and authoritative about abuse.** The
/// binding money check happens at delivery, when the transfer either lands or
/// does not; `solvent` is split out from `admit` precisely because a *query*
/// cannot await a balance, so `can_purchase` answers from the last observation.
/// The gate exists so a refusal reaches the buyer before they pay Stripe rather
/// than after, which is a user-experience guarantee, not a solvency one.
///
/// This is an admission gate, not a capacity *reservation*. A reservation would
/// need reserved-but-unpaid accounting plus a release path for abandoned orders,
/// and it still could not guarantee delivery: the operator can move cycles out
/// of the reserve account by hand, and the CMC rate can move between quote and
/// delivery. Nothing is escrowed at creation — `lockedCycles` is a *price*, not
/// a hold — so an order that lapses releases nothing, and an order that lapses
/// is one whose Stripe session expired.
///
/// Every check here is pure arithmetic over values the caller reads, so the
/// whole policy unit-tests without an IC environment.
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
    /// ⚠️ **One, decided as a product call rather than a safety control.** A buyer who
    /// wants another slot cancels the one they have, which is what makes `cancel_order`
    /// load-bearing rather than a nicety. Abuse (trolling, a flood of identities) is
    /// deliberately **not** pre-built for: a per-principal cap cannot bound an attacker
    /// who rotates self-authenticating principals anyway, so the honest bound is the
    /// cycles cost of the update calls plus `minCanisterCycles` failing the rail closed.
    /// Mitigate if it happens; do not harden against it now.
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
    /// ⚠️ **Two pots, and confusing them is the classic operational error.** Gas
    /// lives in the canister's own balance and is spent by running; stock lives in
    /// the gateway's cycles-ledger account and is spent by delivering. Different
    /// resource, different failure, different fix — `icp canister status` reads the
    /// first, `reserve_status` the second.
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
    };
  };

  public func reasonToText(reason : Reason) : Text {
    switch (reason) {
      case (#tooManyOpenOrders({ open; max })) "tooManyOpenOrders(" # open.toText() # "/" # max.toText() # ")";
      case (#canisterCyclesLow({ balance; min })) "canisterCyclesLow(" # balance.toText() # "<" # min.toText() # ")";
      case (#reserveShort({ requested; available })) "reserveShort(need " # requested.toText() # ", have " # available.toText() # ")";
      case (#amountAboveMax({ usdCents; maxUsdCents })) "amountAboveMax(" # usdCents.toText() # ">" # maxUsdCents.toText() # ")";
      case (#amountBelowMin({ usdCents; minUsdCents })) "amountBelowMin(" # usdCents.toText() # "<" # minUsdCents.toText() # ")";
    };
  };

  /// Running tally of refusals, one counter per `Reason` (#61).
  ///
  /// ⚠️ **This replaces a per-attempt audit line, and it replaces it without
  /// losing anything.** The line it replaces was
  /// `audit("order.notAdmitted", reasonToText(reason))` — no principal, no
  /// amount. It could not attribute abuse to anyone and never could; its whole
  /// content was *"a refusal of this kind happened at time T"*. A counter keeps
  /// the kind and the volume; `RailStateLatch` below keeps the timestamp anyone
  /// actually wants.
  ///
  /// ⚠️ **Why a counter and not a log line at all: refusals are free to
  /// attempt.** `#amountBelowMin` needs no prior state — `create_order` with one
  /// cent from any fresh principal reaches it, with no order, no payment and no
  /// setup. Principals are free and there is no rate limit by decision. While the
  /// audit log was a 4,096-entry ring that was harmless churn; #37 removes the
  /// ring, and an unbounded log fed by a free caller is permanent stable-state
  /// growth at zero attacker cost. Every other structure here is attacker-priced
  /// — orders by the open-order cap and the reserve, error-queue entries by
  /// needing a real payment to exist. Audit lines were the exception.
  ///
  /// **A record rather than a map, so a new `Reason` cannot be silently
  /// untallied**: `countRefusal` switches exhaustively, so adding a variant is a
  /// compile error here rather than a counter that stays at zero in production.
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
  /// ⚠️ **Three, not two.** `#railClosed` belongs here for the same reason the
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
    /// ⚠️ **One condition for BOTH session outcalls — create and expire — because they
    /// share one diagnosis and one lever.** A revoked key fails both, and "rotate the
    /// key" is the answer to either. Splitting them would file two incidents for one
    /// cause and leave an operator wondering which to act on. Named for the API rather
    /// than for `create`, so the next outcall added here does not need a third
    /// condition.
    ///
    /// ⚠️ **Different diagnosis, different lever, so not folded into `#railClosed`:**
    /// that one says *provision the key*, this one says *rotate it*. Folding them
    /// would file the wrong instruction.
    #stripeApiFailing;
  };

  /// Which refusals describe the gateway rather than one request. Exhaustive, so
  /// a new `Reason` has to decide rather than defaulting to "not rail state".
  public func railConditionOf(reason : Reason) : ?RailCondition {
    switch (reason) {
      case (#reserveShort(_)) ?#reserveShort;
      case (#canisterCyclesLow(_)) ?#canisterCyclesLow;
      // Nothing about the gateway changed: one request was malformed
      // (`#amountBelowMin`, `#amountAboveMax`) or one principal used its own slot
      // (`#tooManyOpenOrders`).
      case (#amountAboveMax(_) or #amountBelowMin(_) or #tooManyOpenOrders(_)) null;
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
  };

  public func admitting() : RailStateLatch {
    ({
      reserveShort = false;
      canisterCyclesLow = false;
      railClosed = false;
      stripeApiFailing = false;
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
  public func latchAdmission(latch : RailStateLatch) : RailStateLatch {
    ({ latch with reserveShort = false; canisterCyclesLow = false; railClosed = false });
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

  };

  /// Admission decision. Cheapest checks first so a spammed principal is
  /// rejected before anything expensive happens.
  ///
  /// `usdCents` is the *gross* tier/order amount, checked against the
  /// per-purchase ceiling before any quote is computed.
  public func admit(config : Config, observation : Observation, usdCents : Nat) : Result.Result<(), Reason> {
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
    // ⚠️ **Solvency is NOT decided here — see `solvent` below.** Everything above
    // is arithmetic over values the caller already holds; the money question needs
    // a ledger read, so it cannot live in a synchronous function. Do not add a
    // balance check here to save a call: that is what reintroduces the TOCTOU
    // window this split exists to close.
    #ok;
  };

  /// Can the reserve cover this order, on top of everything already owed?
  ///
  /// ⚠️ **Separate from `admit`, and that separation is structural rather than
  /// stylistic.** Reading the reserve means awaiting the cycles ledger, and
  /// `admit` is synchronous precisely so there is no TOCTOU window between
  /// observing and deciding. Folding solvency into it would force every caller to
  /// supply a balance — including `can_purchase`, which is a **query** and cannot
  /// await one. #30 asks for `can_purchase`'s contract to be narrowed to "gas,
  /// open-order cap, ceiling, floor"; splitting the functions makes that narrowing
  /// a fact about the code rather than a sentence in a doc comment.
  ///
  /// ⚠️ **The caller must hold `lockedCycles` in the SAME synchronous block as
  /// this check.** Two concurrent `create_order` calls that both pass here against
  /// one `promisedTotal` and only then hold will together promise more than the
  /// balance they checked — two honest buyers, no attacker. #30's own earlier
  /// draft claimed interleaved creates were safe because "each resumes after the
  /// other has recorded its promise", which is true only if the check and the hold
  /// cannot be separated by an await.
  public func solvent(reserveBalance : Nat, promisedTotal : Nat, lockedCycles : Nat) : Result.Result<(), Reason> {
    if (Reserve.canCover(reserveBalance, promisedTotal, lockedCycles)) return #ok;
    #err(#reserveShort({
      requested = lockedCycles;
      available = Reserve.available(reserveBalance, promisedTotal);
    }));
  };

};
