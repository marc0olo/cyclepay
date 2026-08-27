/// §5.2 recovery timer — the pure half: sweep cadence policy and sweep
/// eligibility, unit-testable without an IC env. The timer itself
/// (`recurringTimer` arming, the transient id re-armed on upgrade, the
/// single-flight flag) lives in Main.mo; live timer behavior under
/// PocketIC is task 12's go-live bar.
import Int "mo:core/Int";
import Result "mo:core/Result";
import Types "Types";

module {

  /// Default sweep cadence: **15 min**, well inside the §5.1 ceiling `validateInterval`
  /// enforces.
  ///
  /// ⚠️ **There is no retry budget to pair it with.** A delivery replay is provably
  /// safe, so what bounds retrying is time — the ledger's dedup window and §5.3's 72 h
  /// max-wait — and this cadence only has to be fast enough to use that window well
  /// (see `validateInterval`).
  public let defaultIntervalNs : Nat = 900_000_000_000; // 15 min

  public type IntervalError = {
    #zeroInterval;
    /// Cadence too coarse for §5.1 — `maxNs` is the ceiling that was
    /// enforced (a quarter of the ledger dedup window).
    #intervalTooLong : { maxNs : Nat };
  };

  /// §5.1: recovery cadence must be ≪ the ledger's ~24 h dedup window — a
  /// stuck `#paid` order needs several replay attempts while its intent
  /// can still deduplicate; one sweep per window would burn the only
  /// chance on a single transient failure. "Several" is pinned to ≥ 4
  /// sweeps per window (interval ≤ window / 4).
  ///
  /// ⚠️ **An upper bound only — a fast cadence is simply a fast cadence.** There is
  /// nothing a too-short interval can break: with no retry budget to exhaust, extra
  /// sweeps cost gas and find nothing to do. Do not add a lower bound without a
  /// failure it prevents.
  public func validateInterval(intervalNs : Nat, ledgerDedupWindowNs : Int) : Result.Result<(), IntervalError> {
    let window = Int.abs(ledgerDedupWindowNs);
    let maxNs = window / 4;
    if (intervalNs == 0) return #err(#zeroInterval);
    if (intervalNs > maxNs) return #err(#intervalTooLong({ maxNs }));
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
      // ⚠️ **Exactly one sweepable status, and that is the design.** Money-out is a
      // single transfer out of `#paid`, so there is one status the sweep can drive.
      // Adding a second means a second way an order can owe cycles, which is the
      // thing this shape exists to prevent.
      case (#paid) true;
      // `#needsReview` is NOT sweepable: its whole meaning is that the money
      // position is unknown and a human must look. Re-driving it automatically
      // is the double-spend this status exists to prevent.
      case (#created or #cancelled or #expired or #delivered or #needsReview or #abandoned) false;
    };
  };

};
