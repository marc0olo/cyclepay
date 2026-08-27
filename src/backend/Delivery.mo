/// Delivery's own timeline: how long an order may sit with money in and nothing
/// delivered before an operator is told, and before it is given up on.
///
/// ⚠️ **This moved out of `Treasury.mo`, and the move is a safety fix rather than
/// tidying (#36).** That module is deleted with the ICP machinery, and its Delete
/// list said "`Treasury.mo` (249 lines) — burn ledger, burn cap, float observation,
/// `isLowFloat`, `lowFloatSignal`, `Treasury.gate`, **`waitStage`**". Every item on
/// that list is dead except the last one: `waitStage` drives the timeline for
/// **`#paid`** — the live delivery path — and #30 PR-B made it load-bearing three
/// ways:
///
///   - it is one of the two *reachable* routes to `#needsReview`, and the only one
///     that fires with a **certain** money position ("fiat in, nothing was ever
///     sent — refund");
///   - it is why `abandon_order`'s unsettled-delivery guard is "a wait, not a
///     block": an order that guard refuses reaches a human by this bound;
///   - deleting it would turn "a wedged delivery reaches a human in 72 h" into "a
///     wedged delivery retries forever, holding its reserve promise, on nobody's
///     worklist" — the silent-leak shape that #33's retention deletion was argued
///     against, reintroduced from the other end.
///
/// So it moves before anything is deleted, alone, and with no behaviour change: the
/// two thresholds, the three outcomes and the escalation's instruction are identical
/// on both sides of the move. A deletion commit that also relocates a bound is the
/// shape that hides a behaviour change.
module {

  /// The two thresholds, split out of `Treasury.Config`.
  ///
  /// ⚠️ Deliberately **not** yet the Candid type. `set_treasury_config` still carries
  /// all five fields, three of which (`burnCapE8s`, `burnWindowNs`,
  /// `lowFloatThresholdE8s`) are already dead config — `Treasury.gate` lost its only
  /// entrance in #30 PR-A. Trimming the public record is the deletion commit's job;
  /// doing it here would force `Treasury.mo`'s burn half to be deleted in the same
  /// change, which is exactly the merge this ordering avoids.
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
