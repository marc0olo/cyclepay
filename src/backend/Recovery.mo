/// §5.2 recovery timer — the pure half: sweep cadence policy and sweep
/// eligibility, unit-testable without an IC env. The timer itself
/// (`recurringTimer` arming, the transient id re-armed on upgrade, the
/// single-flight flag) lives in Main.mo; live timer behavior under
/// PocketIC is task 12's go-live bar.
import Int "mo:core/Int";
import Result "mo:core/Result";
import Types "Types";

module {

  /// Default sweep cadence: **15 min**. Well inside the §5.1 ceiling enforced by
  /// `validateInterval`, and paired with `maxMintRetries` below so an order
  /// survives far more than a day of consecutive retriable failures before the
  /// notify loop escalates.
  public let defaultIntervalNs : Nat = 900_000_000_000; // 15 min

  /// Retry budget for the money-out stages the ledger's own dedup window does
  /// not already bound (`notify_top_up` could otherwise retry forever).
  ///
  /// **Coupled to the cadence, so they live together.** The invariant is
  /// `maxMintRetries × intervalNs > 24 h`: an upstream outage shorter than a day
  /// must never exhaust the budget, because exhausting it escalates an order that
  /// would have completed. `validateInterval` enforces both sides of it, so a
  /// retuned cadence cannot silently break it.
  ///
  /// Sized generously rather than tightly, because the count is a *backstop*, not
  /// the primary bound. What actually stops an endless retry is time: a transfer
  /// intent past the ledger dedup window escalates as `#staleIntent`, and a paid
  /// order alerts at 2 h and terminates at 72 h regardless of retries. A retry
  /// itself costs one journal bump and one call attempt.
  ///
  /// A tight budget would also make the *cadence* nearly unadjustable: at 100
  /// retries the shortest legal interval is 14.4 min, so an operator working an
  /// incident could not speed the sweep up at all. At 2,000 it is ~43 s, which
  /// leaves the useful range open while still bounding the loop.
  public let maxMintRetries : Nat = 2_000;

  public type IntervalError = {
    #zeroInterval;
    /// Cadence too coarse for §5.1 — `maxNs` is the ceiling that was
    /// enforced (a quarter of the ledger dedup window).
    #intervalTooLong : { maxNs : Nat };
    /// Cadence too *fine*: `maxMintRetries × intervalNs` no longer spans the
    /// ledger dedup window, so the retry budget would run out while a replay
    /// could still have succeeded — converting a survivable outage into
    /// terminated, refundable paid orders. `minNs` is the shortest cadence that
    /// keeps the budget wide enough.
    #intervalTooShort : { minNs : Nat };
  };

  /// §5.1: recovery cadence must be ≪ the ledger's ~24 h dedup window — a
  /// stuck `#minting` order needs several replay attempts while its intent
  /// can still deduplicate; one sweep per window would burn the only
  /// chance on a single transient failure. "Several" is pinned to ≥ 4
  /// sweeps per window (interval ≤ window / 4).
  /// Also enforces the *other* side of the same invariant, which
  /// `defaultIntervalNs`/`maxMintRetries` satisfy together but which a retuned
  /// cadence can silently break: the retry budget
  /// (`maxMintRetries × intervalNs`) must outlast the dedup window, or a
  /// multi-hour CMC outage exhausts the retries and terminates orders that would
  /// have completed. A 60 s cadence, for instance, shrinks the budget from
  /// >24 h to ~100 min.
  public func validateInterval(intervalNs : Nat, ledgerDedupWindowNs : Int) : Result.Result<(), IntervalError> {
    let window = Int.abs(ledgerDedupWindowNs);
    let maxNs = window / 4;
    if (intervalNs == 0) return #err(#zeroInterval);
    if (intervalNs > maxNs) return #err(#intervalTooLong({ maxNs }));
    // Ceiling division: the budget must strictly exceed the window.
    let minNs = window / maxMintRetries + 1;
    if (intervalNs < minNs) return #err(#intervalTooShort({ minNs }));
    #ok;
  };

  /// Which orders the §5.2 sweep drives: money has committed (fiat
  /// captured) but money-out hasn't finished. `#created` waits on the user
  /// (expiry is per-rail policy, seam §11.1.4), and the terminal states
  /// plus `#expired` have nothing left to drive.
  /// Is a tally reconcile due? Gated on the last **attempt**, never on the last
  /// success.
  ///
  /// A trap rolls back every state change in its own message, so a reconcile that
  /// traps cannot record that it ran. An earlier version short-circuited on
  /// `lastSuccessNs == null`, which defeated the whole point in the one case where
  /// the bound matters most: a canister whose first-ever reconcile keeps trapping
  /// never records a success, so it stayed due on *every* sweep tick and burned a
  /// full instruction budget each time. The attempt clock alone is correct —
  /// `lastAttemptNs` starts at 0, so the first tick is due through it anyway.
  ///
  /// `lastSuccessNs` is deliberately not a parameter: taking it would invite
  /// exactly that bug back.
  public func reconcileDue(lastAttemptNs : Int, nowNs : Int, intervalNs : Nat) : Bool {
    nowNs - lastAttemptNs >= intervalNs;
  };

  public func isSweepable(status : Types.OrderStatus) : Bool {
    switch (status) {
      case (#paid or #minting or #icpAtCmc or #awaitingTreasury) true;
      // `#needsReview` is NOT sweepable: its whole meaning is that the money
      // position is unknown and a human must look. Re-driving it automatically
      // is the double-spend this status exists to prevent.
      case (#created or #cancelled or #expired or #delivered or #needsReview or #abandoned) false;
    };
  };

};
