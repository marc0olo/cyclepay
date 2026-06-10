/// §5.2 recovery timer — the pure half: sweep cadence policy and sweep
/// eligibility, unit-testable without an IC env. The timer itself
/// (`recurringTimer` arming, the transient id re-armed on upgrade, the
/// single-flight flag) lives in Main.mo; live timer behavior under
/// PocketIC is task 12's go-live bar.
import Int "mo:core/Int";
import Result "mo:core/Result";
import Types "Types";

module {

  /// Default sweep cadence: 1 h. Well inside the §5.1 bound enforced by
  /// `validateInterval`, and it sizes the retry budget: with
  /// `maxMintRetries = 25` (Main.mo) an order survives more than a full
  /// day of consecutive retriable failures before the notify loop
  /// escalates — an outage shorter than a day never strands an order.
  public let defaultIntervalNs : Nat = 3_600_000_000_000;

  public type IntervalError = {
    #zeroInterval;
    /// Cadence too coarse for §5.1 — `maxNs` is the ceiling that was
    /// enforced (a quarter of the ledger dedup window).
    #intervalTooLong : { maxNs : Nat };
  };

  /// §5.1: recovery cadence must be ≪ the ledger's ~24 h dedup window — a
  /// stuck `#minting` order needs several replay attempts while its intent
  /// can still deduplicate; one sweep per window would burn the only
  /// chance on a single transient failure. "Several" is pinned to ≥ 4
  /// sweeps per window (interval ≤ window / 4).
  public func validateInterval(intervalNs : Nat, ledgerDedupWindowNs : Int) : Result.Result<(), IntervalError> {
    let maxNs = Int.abs(ledgerDedupWindowNs) / 4;
    if (intervalNs == 0) return #err(#zeroInterval);
    if (intervalNs > maxNs) return #err(#intervalTooLong({ maxNs }));
    #ok;
  };

  /// Which orders the §5.2 sweep drives: money has committed (fiat
  /// captured) but money-out hasn't finished. `#created` waits on the user
  /// (expiry is per-rail policy, seam §11.1.4), and the terminal states
  /// plus `#expired` have nothing left to drive.
  public func isSweepable(status : Types.OrderStatus) : Bool {
    switch (status) {
      case (#paid or #minting or #icpAtCmc or #awaitingTreasury) true;
      case (#created or #expired or #delivered or #errorQueue) false;
    };
  };

};
