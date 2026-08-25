/// Pre-creation admission gate — the "check before you take money" pass.
///
/// Order creation is refused when fulfilment is already known to be impossible:
/// insufficient ICP float, no burn-cap headroom, this canister's own cycle
/// balance too low to keep running, an amount above the per-purchase ceiling,
/// or a principal holding too many open orders. `Treasury.gate` remains the
/// authoritative money check at *mint* time; this gate exists so the refusal
/// happens before the user pays Stripe rather than after.
///
/// This is an admission gate, not a capacity *reservation*. A reservation would
/// need reserved-but-unpaid accounting plus a release path for abandoned
/// orders, and it still could not guarantee delivery (the operator can withdraw
/// the float, the CMC rate can move). Nothing is escrowed at creation —
/// `lockedCycles` is a *price*, not a hold — so an order that lapses releases
/// nothing. (It pointed at `Retention.mo` until #33 deleted it: an order lapses
/// when Stripe expires its session, and #30 is what will make the release
/// non-trivial by giving the promise something to hold.)
///
/// Every check here is pure arithmetic over values the caller reads, so the
/// whole policy unit-tests without an IC environment.
import Nat "mo:core/Nat";
import Result "mo:core/Result";

module {

  public type Config = {
    /// Cap on simultaneously-`#created` orders per principal. This is the
    /// bound that actually stops unbounded state growth: legitimate order
    /// volume is already bounded by the burn cap, so the only unbounded
    /// vector is *abandoned* orders, which cost an attacker nothing to create
    /// (`canister-security`: allowing unbounded user-controlled storage).
    /// Not a money decision — an abuse bound. Raise it for legitimate power
    /// users; do not set it to 0, which would block the rail entirely.
    maxOpenOrdersPerPrincipal : Nat;
    /// Floor on this canister's OWN cycle balance — its gas, not the ICP
    /// float. Below the freezing threshold the canister stops accepting
    /// updates; at zero it is uninstalled. This is the "should never happen"
    /// guard, and it must be well above the freezing threshold so there is
    /// room to notice and top up. Distinct from `Treasury`'s float checks in
    /// every way: different resource, different failure, different fix.
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
    /// custom-amount-specific limit: two knobs for one rule is how the float gate
    /// and the reserve gate ended up contradicting each other.
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

  /// Deliberately non-zero, unlike the burn cap — that is a *money* decision and
  /// must ship dark. These are *safety limits*: a default of 0 would brick the
  /// canister rather than protect it, which is the wrong direction of fail-closed.
  ///
  /// The card rail's on/off switch is **both Stripe secrets being provisioned**
  /// (#33), not the tier list. An empty tier list now means only "no presets
  /// shown", because a custom amount is orderable without one.
  public func defaultConfig() : Config {
    {
      maxOpenOrdersPerPrincipal = 20;
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
    /// unpayable**: the buyer completes checkout and the webhook files a Type 1,
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
    #burnCapExhausted : { burnedE8s : Nat; capE8s : Nat };
    #floatLow : { observedE8s : ?Nat; thresholdE8s : Nat };
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
      case (#burnCapExhausted({ burnedE8s; capE8s })) "burnCapExhausted(" # burnedE8s.toText() # "/" # capE8s.toText() # ")";
      case (#floatLow({ observedE8s; thresholdE8s })) {
        let observed = switch (observedE8s) { case (?e8s) e8s.toText(); case null "never observed" };
        "floatLow(" # observed # "<" # thresholdE8s.toText() # ")";
      };
      case (#amountAboveMax({ usdCents; maxUsdCents })) "amountAboveMax(" # usdCents.toText() # ">" # maxUsdCents.toText() # ")";
      case (#amountBelowMin({ usdCents; minUsdCents })) "amountBelowMin(" # usdCents.toText() # "<" # minUsdCents.toText() # ")";
    };
  };

  /// Everything the gate needs to decide, read by the caller immediately
  /// before the decision (all synchronous — no awaits, so no TOCTOU window
  /// between reading and deciding).
  public type Observation = {
    /// Count of this principal's `#created` orders.
    openOrders : Nat;
    /// `Cycles.balance()` — this canister's own gas.
    canisterCycles : Nat;
    /// `Treasury.burnedInWindow` for the live rolling window.
    burnedInWindowE8s : Nat;
    /// The operator's rolling ICP burn cap.
    burnCapE8s : Nat;
    /// Last observed ICP float, or null if it has never been read.
    observedFloatE8s : ?Nat;
    /// `Treasury.Config.lowFloatThresholdE8s`. Zero opts out of float gating.
    lowFloatThresholdE8s : Nat;
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
    // Burn-cap headroom: if the window is already spent, a new order could
    // only ever land in #awaitingTreasury and then time out into a manual
    // refund. Refusing to quote is strictly kinder than taking the money.
    // Checked with `>=` because a cap of 0 (the fail-closed default) means
    // "no minting at all" and must refuse every order.
    if (observation.burnedInWindowE8s >= observation.burnCapE8s) {
      return #err(#burnCapExhausted({
        burnedE8s = observation.burnedInWindowE8s;
        capE8s = observation.burnCapE8s;
      }));
    };
    // Float gating is opt-in: a threshold of 0 means the operator has chosen
    // not to gate on it. Once a threshold IS configured, a missing
    // observation is treated as failing it — "I asked for this to be
    // enforced" plus "I have never looked" is not a state to sell into. The
    // go-live checklist calls `refresh_float` after funding for this reason.
    if (observation.lowFloatThresholdE8s > 0) {
      let sufficient = switch (observation.observedFloatE8s) {
        case (?e8s) e8s >= observation.lowFloatThresholdE8s;
        case null false;
      };
      if (not sufficient) {
        return #err(#floatLow({
          observedE8s = observation.observedFloatE8s;
          thresholdE8s = observation.lowFloatThresholdE8s;
        }));
      };
    };
    #ok;
  };

};
