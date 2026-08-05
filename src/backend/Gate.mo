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
/// nothing (see Retention.mo).
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
    /// Per-purchase ceiling on the gross USD amount. On the card rail the
    /// amount is already structurally pinned by which tier's Payment Link was
    /// used, so this is defence in depth against an operator typo (a tier
    /// registered at 100× its intended price) and against the webhook's
    /// amount-honouring path repricing an implausible payment upward. Retune
    /// to just above your largest tier; do not disable.
    maxPurchaseUsdCents : Nat;
  };

  /// Deliberately non-zero, unlike the burn cap and the ck-USDC bound. Those
  /// are *money* decisions that must ship dark. These three are *safety
  /// limits*: a default of 0 would brick the canister rather than protect it,
  /// which is the wrong direction of fail-closed. The card rail's real on/off
  /// switch remains the tier list, which does ship empty.
  public func defaultConfig() : Config {
    {
      maxOpenOrdersPerPrincipal = 20;
      minCanisterCycles = 5_000_000_000_000; // 5T
      maxPurchaseUsdCents = 100_000; // $1,000
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
    /// because the honoured amount exceeds the ceiling. Worse, `attach_payment`
    /// refuses to rescue it until the ceiling is raised back — so the operator has
    /// to work out the connection between a refused rescue and a config change
    /// made earlier.
    #tierAboveCeiling : { tierId : Text; usdCents : Nat; maxUsdCents : Nat };
  };

  /// `tierPrices` is every registered card tier, so the ceiling cannot be lowered
  /// underneath one. Pass an empty array when there are no tiers to consider.
  public func validateConfig(
    config : Config,
    tierPrices : [(Text, Nat)],
  ) : Result.Result<(), ConfigError> {
    if (config.maxOpenOrdersPerPrincipal == 0) return #err(#zeroOpenOrderCap);
    if (config.maxPurchaseUsdCents == 0) return #err(#zeroPurchaseCeiling);
    for ((tierId, usdCents) in tierPrices.values()) {
      if (usdCents > config.maxPurchaseUsdCents) {
        return #err(#tierAboveCeiling({ tierId; usdCents; maxUsdCents = config.maxPurchaseUsdCents }));
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
