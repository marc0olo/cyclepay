/// Treasury management + ICP burn cap (§5.3) — the pure half.
///
/// Money-out is funded from one operator-refilled ICP float. This module
/// owns the policy around that float: the **per-period rolling burn cap**
/// (the primary blast-radius bound if the webhook secret leaks — forged
/// "paid" webhooks can't drain more ICP than the cap per window before
/// detection + rotation; it doubles as a safety limit against any mint-path
/// bug), the **pre-gate decision** that sends a Paid order to
/// `#awaitingTreasury` instead of minting when the cap is consumed or the
/// float is short, the **max-wait** that escalates a held order to the error
/// queue, and the **low-float soft-gate signal** the frontend uses to
/// disable tiers. Main.mo owns the impure half — the `icrc1_balance_of`
/// call, the persistent ledger/config, and the driver wiring.
///
/// Cap accounting is conservative by construction: a mint consumes window
/// budget when its transfer intent commits (before the ledger await), and a
/// later failure never refunds it — over-counting pauses mints early, which
/// is the fail-safe direction for a blast-radius bound. The window "resets"
/// by burns aging out (rolling), or by the operator's manual override.
import Queue "mo:core/Queue";
import Result "mo:core/Result";
import Nat "mo:core/Nat";

module {

  /// §5.3 treasury policy (§7: controllers may adjust).
  public type Config = {
    /// Hard ceiling on ICP (e8s of transfer amount) converted to cycles per
    /// rolling window. **0 = all mints hold** — the fail-closed default and
    /// an explicit operator pause lever.
    burnCapE8s : Nat;
    /// Rolling window length for the cap.
    burnWindowNs : Int;
    /// Max time a held order may sit in `#awaitingTreasury` before it
    /// escalates to the error queue (operator refunds).
    /// How long an order may sit with money in and nothing delivered before it
    /// is **terminated** and the operator refunds (§5.3 max-wait bound).
    ///
    /// Terminating matters, and not only for tidiness: a buyer left waiting
    /// indefinitely files a chargeback, which is strictly worse for the operator
    /// than a refund — dispute fees, a dispute process, and damage to Stripe
    /// account health. Refunding proactively is the *protective* action.
    ///
    /// By the time this elapses the cause is not transient either: a float
    /// unrefilled for days, or a multi-day CMC outage, is structural. Waiting
    /// longer helps nobody.
    ///
    /// ⚠️ **This is a per-state bound, not an end-to-end one.** The age it is
    /// compared against is `order.updatedAtNs`, which every transition resets, so
    /// an order that lingers in `#paid`, then `#minting`, then `#icpAtCmc` can
    /// take materially longer than `maxHoldNs` from payment to resolution —
    /// worst case on the order of a week and a half at the default.
    ///
    /// That is deliberate: each state is a distinct failure mode with a distinct
    /// recovery, and an order that *just* progressed should not be terminated on
    /// a clock started before its current problem existed. But it means this
    /// bounds "stuck in one place", and `alertAfterNs` is what an operator
    /// actually works against. RUNBOOK §5 spells out the cumulative timeline.
    maxHoldNs : Int;
    /// How long before the operator is **alerted** that an order is delayed.
    ///
    /// Complementary to `maxHoldNs`, not a substitute: this fires while the
    /// problem is still fixable, so most incidents end with the order
    /// *delivering* rather than reaching the terminal bound at all. Must be
    /// shorter than `maxHoldNs` — alerting after the decision has already been
    /// taken is useless.
    alertAfterNs : Int;
    /// Soft-gate / balance-alert threshold on the observed float.
    /// 0 = signal disarmed.
    lowFloatThresholdE8s : Nat;
  };

  /// burnCapE8s = 0: mints pause until the operator consciously sizes the
  /// blast-radius bound — same no-invented-numbers stance as the empty tier
  /// list (a default cap in ICP would be a money decision made up here).
  /// 24 h window; 72 h max hold (a weekend refill outage recovers, a forgotten
  /// order still reaches the operator's worklist); alert disarmed until set.
  public func defaultConfig() : Config {
    {
      burnCapE8s = 0;
      burnWindowNs = 86_400_000_000_000;
      maxHoldNs = 259_200_000_000_000; // 72 h — terminate, operator refunds
      alertAfterNs = 7_200_000_000_000; // 2 h — tell someone while it is fixable
      lowFloatThresholdE8s = 0;
    };
  };

  public type ConfigError = {
    /// A zero/negative window makes the cap meaningless (nothing ever counts).
    #nonPositiveBurnWindow;
    /// A zero/negative max hold would escalate every held order instantly.
    #nonPositiveMaxHold;
    #nonPositiveAlertAfter;
    /// An alert at or after the terminal bound would never be actionable.
    #alertNotBeforeMaxHold : { alertAfterNs : Int; maxHoldNs : Int };
  };

  public func validateConfig(config : Config) : Result.Result<(), ConfigError> {
    if (config.burnWindowNs <= 0) return #err(#nonPositiveBurnWindow);
    if (config.maxHoldNs <= 0) return #err(#nonPositiveMaxHold);
    if (config.alertAfterNs <= 0) return #err(#nonPositiveAlertAfter);
    if (config.alertAfterNs >= config.maxHoldNs) {
      return #err(#alertNotBeforeMaxHold({ alertAfterNs = config.alertAfterNs; maxHoldNs = config.maxHoldNs }));
    };
    #ok;
  };

  /// One cap-consuming mint commitment.
  public type Burn = { atNs : Int; e8s : Nat };

  /// Rolling-window accounting, time-ordered (burns append as they commit).
  /// Persistent in Main — an upgrade must not reset the blast-radius bound.
  public type Ledger = { burns : Queue.Queue<Burn> };

  public func emptyLedger() : Ledger {
    { burns = Queue.empty<Burn>() };
  };

  /// Window consumption: burns younger than the window (age ≥ window = out,
  /// the house staleness convention) — so consumption "resets next window"
  /// (§5.3) by aging out, no timer needed.
  public func burnedInWindow(ledger : Ledger, windowNs : Int, nowNs : Int) : Nat {
    var total = 0;
    for (burn in ledger.burns.values()) {
      if (nowNs - burn.atNs < windowNs) total += burn.e8s;
    };
    total;
  };

  /// Record a cap consumption; prunes aged-out burns from the front (the
  /// queue is time-ordered, so pruning stops at the first in-window entry).
  public func recordBurn(ledger : Ledger, windowNs : Int, e8s : Nat, nowNs : Int) {
    ledger.burns.pushBack({ atNs = nowNs; e8s });
    label prune loop {
      switch (ledger.burns.peekFront()) {
        case (?burn) {
          if (nowNs - burn.atNs >= windowNs) { ignore ledger.burns.popFront() } else break prune;
        };
        case null break prune;
      };
    };
  };

  /// §5.3 manual override: the operator confirms the window's traffic was
  /// legitimate (or has rotated a leaked secret) and clears the consumption.
  public func reset(ledger : Ledger) {
    ledger.burns.clear();
  };

  public func size(ledger : Ledger) : Nat {
    ledger.burns.size();
  };

  /// Why a mint was held instead of proceeding (§5.3).
  public type HoldReason = {
    /// The rolling cap can't absorb this mint. Mints pause until the window
    /// rolls or the operator overrides — the §5.3 "pause + alert" state.
    #burnCapReached : { burnedE8s : Nat; capE8s : Nat };
    /// The float can't fund the transfer (amount + ledger fee). Clears when
    /// the operator refills.
    #floatShort : { floatE8s : Nat; neededE8s : Nat };
  };

  public func holdReasonToText(reason : HoldReason) : Text {
    switch (reason) {
      case (#burnCapReached({ burnedE8s; capE8s })) {
        "burn cap reached: " # burnedE8s.toText() # " of " # capE8s.toText() # " e8s consumed this window";
      };
      case (#floatShort({ floatE8s; neededE8s })) {
        "float short: " # floatE8s.toText() # " e8s available, " # neededE8s.toText() # " needed";
      };
    };
  };

  /// §5.3 pre-gate, decided in one synchronous read. The burn cap is checked
  /// **first**: it is the blast-radius bound, so it must hold mints even when
  /// the float could fund them (a leaked-secret drain has a full float).
  /// Proceed iff the cap absorbs the mint amount (reaching the cap exactly is
  /// allowed) AND the float covers amount + transfer fee.
  public func gate(
    ledger : Ledger,
    config : Config,
    floatE8s : Nat,
    mintE8s : Nat,
    transferFeeE8s : Nat,
    nowNs : Int,
  ) : { #proceed; #hold : HoldReason } {
    let burned = burnedInWindow(ledger, config.burnWindowNs, nowNs);
    if (burned + mintE8s > config.burnCapE8s) {
      return #hold(#burnCapReached({ burnedE8s = burned; capE8s = config.burnCapE8s }));
    };
    let needed = mintE8s + transferFeeE8s;
    if (floatE8s < needed) {
      return #hold(#floatShort({ floatE8s; neededE8s = needed }));
    };
    #proceed;
  };

  /// What the driver does with an `#awaitingTreasury` order (§5.3): retry
  /// the pre-gate (refill/window-roll may have cleared it), or — at/after
  /// the max wait (age ≥ bound, house convention) — escalate to the error
  /// queue. `heldSinceNs` is the order's `updatedAtNs`: the hold transition
  /// is the last one it took.
  public func holdStage(heldSinceNs : Int, nowNs : Int, maxHoldNs : Int) : { #retry; #escalate } {
    if (nowNs - heldSinceNs >= maxHoldNs) #escalate else #retry;
  };

  /// The §5.3 timeline for an order with money in and nothing delivered.
  ///
  /// Three outcomes, not two: quiet retry while it is probably transient, then
  /// an alert while it is still fixable, then termination once it plainly is not.
  /// Splitting these is what lets the alert be early *without* making the
  /// give-up early too.
  public func waitStage(
    heldSinceNs : Int,
    nowNs : Int,
    config : Config,
  ) : { #retry; #alert; #terminate } {
    let waited = nowNs - heldSinceNs;
    if (waited >= config.maxHoldNs) return #terminate;
    if (waited >= config.alertAfterNs) return #alert;
    #retry;
  };

  /// Float observation cache shape — queries can't call the ledger, so the
  /// balance-alert query reads the last value the mint path (or an admin
  /// refresh) saw.
  public type FloatObservation = { e8s : Nat; atNs : Int };

  public func isLowFloat(config : Config, floatE8s : Nat) : Bool {
    config.lowFloatThresholdE8s > 0 and floatE8s < config.lowFloatThresholdE8s;
  };

  /// §5.3 soft-gate signal for the frontend (disable tiers when low). An
  /// armed threshold with no observation yet reads as low — conservative
  /// until the first balance fetch proves otherwise.
  public func lowFloatSignal(config : Config, observation : ?FloatObservation) : Bool {
    if (config.lowFloatThresholdE8s == 0) return false;
    switch (observation) {
      case (?seen) isLowFloat(config, seen.e8s);
      case null true;
    };
  };

  /// §5.3 balance-alert / soft-gate query payload, assembled by Main.
  public type Status = {
    config : Config;
    burnedInWindowE8s : Nat;
    lastObservedFloat : ?FloatObservation;
    lowFloat : Bool;
    /// Orders currently sitting in `#awaitingTreasury`.
    heldOrders : Nat;
    /// Orders that are `#paid` but not yet minted (§5). Transient in normal
    /// operation; a persistent count means money-out is blocked.
    paidOrders : Nat;
  };

};
