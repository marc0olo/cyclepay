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
  /// ⚠️ A trap rolls back every state change in its own message, so a reconcile that traps
  /// cannot record that it ran. Gating on success would leave a trapping reconcile due on
  /// *every* tick, burning a full instruction budget each time. `lastSuccessNs` is
  /// deliberately **not a parameter**: taking it invites that bug back.
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


  // ── Stranded `#created` capacity (#52) ───────────────────────────────────────
  //
  // A `#created` order holds its reserve promise from the moment it exists, and two
  // things release it: Stripe's `checkout.session.expired`, and the buyer's own
  // `cancel_order`. If the expiry event never arrives, the promise holds capacity
  // against a session nobody can ever pay — and nothing sweeps `#created`, because
  // #33 deleted retention deliberately. These predicates decide when to ask Stripe.

  /// How long past a session's own deadline to wait before asking Stripe about it.
  ///
  /// ⚠️ **This margin decides when to ASK, never what is TRUE.** A margin that decided the
  /// *outcome* was rejected: releasing capacity on our own copy of the deadline releases
  /// cycles a buyer may still be owed. Here the release comes from Stripe's answer either
  /// way, so being wrong costs a delayed release, never a wrong one.
  ///
  /// 30 min = two sweep intervals at the default cadence. Stripe fires the expiry event
  /// within seconds, so a healthy gateway is already `#expired` first — the grace makes
  /// the outcall count **zero in normal operation** and every firing a real missed event.
  public let expiryGraceNs : Nat = 1_800_000_000_000; // 30 min

  /// Cadence for the stranded-`#created` scan, distinct from the delivery sweep's.
  ///
  /// The delivery sweep is free when idle because `countOf(#paid)` is usually 0 and the
  /// O(total orders) scan is skipped. `#created` is usually **non**-zero, so putting this
  /// on the 15-minute cadence would make that scan run continuously and throw away the
  /// property the delivery sweep was tuned for. A strand needs a sustained failure, so
  /// hourly is ample.
  public let expiryScanIntervalNs : Nat = 3_600_000_000_000; // 1 h

  /// Retrieves per scan pass, resuming on the next pass.
  ///
  /// ⚠️ **The stranded population is CORRELATED, which is why a per-order cost argument
  /// is not enough.** One unprovisioned webhook secret or one frozen canister strands
  /// every order in that window at once, so "rare" describes incidents, not orders per
  /// incident. Without a cap one incident turns into N outcalls an hour for as long as it
  /// lasts. Bounded and resumed, the backlog drains at a known rate instead.
  public let maxRetrievesPerPass : Nat = 10;

  /// How long to let Stripe keep trying before a completed-but-uncredited session becomes
  /// a human's problem. **4 days** — Stripe redelivers for ~3 (§4.2), plus margin.
  ///
  /// ⚠️ **A heuristic about when to bother a human, NOT a claim about money.** Stripe never
  /// tells us it has given up, so this cannot be derived. The asymmetry makes it safe:
  /// wrong-late files an obligation a day later than ideal, while wrong-early buries real
  /// obligations under noise in a worklist that drops nothing. **Tightening it is the wrong
  /// instinct.**
  ///
  /// The delay costs nothing on the capacity axis: capacity held against an order the
  /// buyer genuinely paid for is *correctly committed* and releases at delivery. The leak
  /// is the `expired` case, where capacity is held for a session nobody can ever pay —
  /// which is why the two branches legitimately have different urgencies.
  public let paidRetryHorizonNs : Nat = 345_600_000_000_000; // 4 days

  /// Is the stranded-`#created` scan due?
  public func expiryScanDue(lastAttemptNs : Int, nowNs : Int, intervalNs : Nat) : Bool {
    nowNs - lastAttemptNs >= intervalNs;
  };

  /// Should this order's session be asked about?
  ///
  /// A null `expiresAtNs` answers **false** and that is not an oversight: an order whose
  /// session-create response was lost has no deadline *and* no session id, so there is
  /// nothing to trigger on and nothing to query with. `expire_order` is the lever for
  /// that class, and it is a canister-level fault rather than an operating state.
  public func expiryCheckDue(
    status : Types.OrderStatus,
    expiresAtNs : ?Int,
    nowNs : Int,
    graceNs : Nat,
  ) : Bool {
    switch (status, expiresAtNs) {
      case (#created, ?deadline) nowNs - deadline >= graceNs;
      case _ false;
    };
  };

  /// Has Stripe had long enough that a completed-but-uncredited session is now a
  /// standing obligation rather than an event in flight?
  /// How long one full coverage cycle of the #63 rotating index scan is expected to
  /// take: `⌈stored ÷ chunkSize⌉ × intervalNs`.
  ///
  /// ⚠️ **This is the detection latency for `orders.unindexedHolders`**, which is P1
  /// because it means the reserve was oversellable. #63 converted unbounded *work* into
  /// latency that still grows linearly in stored orders, and this is the number that
  /// says how much — reported on `recovery_status` rather than documented, because a
  /// documented window rots (the RUNBOOK claimed a 1 h sweep default for months while
  /// the code said 15 min).
  ///
  /// ⚠️ **`intervalNs` is operator-tunable and its ceiling is 24× the default**, so this
  /// takes the live cadence as a parameter rather than reading a constant. At 2,000 per
  /// chunk and the 15-minute default a 365k store is one cycle in ~1.9 days; at the
  /// §5.1 ceiling of 6 h the same store takes ~46 days.
  ///
  /// ⚠️ **Pure and in this module so the MULTIPLIER can be tested.** As a private func in
  /// `Main.mo` its only assertion compared the result to the sweep interval, on a store
  /// smaller than one chunk — where the chunk count is always 1, so a version that dropped
  /// the store-size factor entirely passed. `test/recovery.test.mo` pins `chunkSize + 1`.
  ///
  /// The chunk count floors at one: zero would report an instantaneous cycle for an empty
  /// store, which reads as "already verified" at exactly the moment nothing has been.
  public func indexScanCycleNs(stored : Nat, chunkSize : Nat, intervalNs : Nat) : Nat {
    // A zero chunk size would divide by zero; it is a compile-time constant today, so
    // this is a guard against a future edit rather than a reachable state, and one
    // interval is the answer that cannot understate the window.
    if (chunkSize == 0) return intervalNs;
    // Ceiling division written without a subtraction: `a + b - 1` warns under M0155
    // (`operator may trap for inferred type Nat`) and the gate runs -Werror, so the
    // unreachable underflow has to be unwritten rather than argued about.
    let whole = stored / chunkSize;
    let chunks = if (stored % chunkSize == 0) whole else whole + 1;
    if (chunks == 0) intervalNs else chunks * intervalNs;
  };

  public func paidEscalationDue(createdAtNs : Int, nowNs : Int, horizonNs : Nat) : Bool {
    nowNs - createdAtNs >= horizonNs;
  };

};
