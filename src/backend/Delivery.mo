/// Delivery's timeline: how long an order may sit with money in and nothing
/// delivered before an operator is told, and before the sale is given up on.
///
/// ⚠️ **This bound is load-bearing for money safety, not just for tidiness.** Three
/// things rest on it:
///
///   - it is one of the two routes to `#needsReview`, and the only one that fires
///     with a **certain** money position ("fiat in, nothing was ever sent — refund");
///   - it is why `abandon_order` can refuse an order with an unsettled delivery and
///     still be a *wait* rather than a block — the refused order reaches a human here;
///   - without it, a wedged delivery retries forever while holding its reserve
///     promise, on nobody's worklist. That is a silent reserve leak, and it is the
///     failure this module exists to prevent.
///
import Result "mo:core/Result";

module {

  /// The two thresholds. This is the Candid type `set_delivery_config` takes.
  public type Config = {
    /// How long an order may sit with money in and nothing delivered before it is
    /// **terminated** and the operator refunds.
    ///
    /// Terminating matters, and not for tidiness: a buyer left waiting indefinitely
    /// files a chargeback, which is strictly worse for the operator than a refund —
    /// dispute fees, a dispute process, and damage to Stripe account health.
    /// Refunding proactively is the *protective* action. By the time this elapses
    /// the cause is not transient either.
    maxHoldNs : Int;
    /// When to raise the alert, which is **not** when to give up. Complementary to
    /// `maxHoldNs`: the alert fires while the cause is still fixable, so the
    /// operator gets a chance to fix it and the sale completes.
    alertAfterNs : Int;
  };

  public func defaultConfig() : Config {
    {
      maxHoldNs = 259_200_000_000_000; // 72 h — terminate, operator refunds
      alertAfterNs = 7_200_000_000_000; // 2 h — tell someone while it is fixable
    };
  };

  public type ConfigError = {
    /// A zero/negative max hold would escalate every order instantly.
    #nonPositiveMaxHold;
    #nonPositiveAlertAfter;
    /// An alert at or after the terminal bound would never be actionable: the
    /// operator would be told at the moment the decision was already taken.
    #alertNotBeforeMaxHold : { alertAfterNs : Int; maxHoldNs : Int };
  };

  public func validateConfig(config : Config) : Result.Result<(), ConfigError> {
    if (config.maxHoldNs <= 0) return #err(#nonPositiveMaxHold);
    if (config.alertAfterNs <= 0) return #err(#nonPositiveAlertAfter);
    if (config.alertAfterNs >= config.maxHoldNs) {
      return #err(#alertNotBeforeMaxHold({ alertAfterNs = config.alertAfterNs; maxHoldNs = config.maxHoldNs }));
    };
    #ok;
  };

  /// The timeline for an order with money in and nothing delivered.
  ///
  /// Three outcomes, not two: quiet retry while it is probably transient, then an
  /// alert while it is still fixable, then termination once it plainly is not.
  /// Splitting these is what lets the alert be early *without* making the give-up
  /// early too.
  ///
  /// ⚠️ **A per-state bound, not end-to-end.** The age it reads is
  /// `order.updatedAtNs`, which retries deliberately do not move — a retry is not a
  /// transition, so the clock stays pinned to the moment the order entered its
  /// current state.
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

};
