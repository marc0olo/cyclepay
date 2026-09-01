import { test; suite } "mo:test";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Cmc "../src/backend/Cmc";
import Delivery "../src/backend/Delivery";
import Recovery "../src/backend/Recovery";
import Types "../src/backend/Types";

// Unit suite for §5.2's pure half: the sweep-cadence bound against the
// ledger dedup window and the sweep-eligibility predicate. The live timer
// (arming, postupgrade re-arm, single-flight under fire) is PocketIC
// coverage (task 12).

let dayNs : Int = 86_400_000_000_000;

suite("validateInterval", func() {
  test("rejects a zero interval", func() {
    assert Recovery.validateInterval(0, dayNs) == #err(#zeroInterval);
  });

  test("a cadence an operator would actually reach for during an incident is legal", func() {
    // The invariant must not make the cadence unadjustable. With a tight retry
    // budget the shortest legal interval would be over 14 min, so nobody could
    // speed the sweep up while working an outage — the budget is sized to keep
    // this range open.
    assert Recovery.validateInterval(60_000_000_000, dayNs) == #ok; // 1 min
    assert Recovery.validateInterval(300_000_000_000, dayNs) == #ok; // 5 min
  });


  test("boundary: exactly window/4 passes, one ns more fails", func() {
    let maxNs = 21_600_000_000_000; // 6 h, a quarter of the 24 h window
    assert Recovery.validateInterval(maxNs, dayNs) == #ok;
    assert Recovery.validateInterval(maxNs + 1, dayNs) == #err(#intervalTooLong({ maxNs }));
  });

  test("default cadence is legal against the real ledger window", func() {
    assert Recovery.validateInterval(Recovery.defaultIntervalNs, Delivery.ledgerDedupWindowNs) == #ok;
  });

  test("the cadence leaves real margin under the §5.1 ledger dedup window", func() {
    // Replay safety needs the cadence well inside the 24 h window, not merely
    // legal at the boundary.
    //
    // ⚠️ **This is the ONLY coupling left between the cadence and the window, and it
    // is a one-sided bound.** There is no retry-budget invariant to assert on the
    // other side: nothing breaks when the cadence is fast, so a test asserting a
    // lower bound would have nothing to check and would pass on any positive value.
    assert Recovery.defaultIntervalNs * 4 <= Int.abs(Delivery.ledgerDedupWindowNs);
  });
});

suite("isSweepable", func() {
  test("exactly ONE money-committed state sweeps", func() {
    // Money-out is one transfer out of `#paid`, so exactly one status sweeps.
    assert Recovery.isSweepable(#paid);
  });

  test("user-pending, expired, and terminal states never sweep", func() {
    assert not Recovery.isSweepable(#created);
    assert not Recovery.isSweepable(#cancelled);
    assert not Recovery.isSweepable(#expired);
    assert not Recovery.isSweepable(#delivered);
    assert not Recovery.isSweepable(#abandoned);
    // The one worth stating: `#needsReview` means the money position is UNKNOWN,
    // so re-driving it automatically is the double-spend the status prevents.
    assert not Recovery.isSweepable(#needsReview);
  });

  test("the matrix is exhaustive: 1 of all 7 states sweeps", func() {
    // ⚠️ **Exactly one of seven, and the sum is the assertion.** Walking all seven
    // and counting is what catches a status becoming sweepable by accident — a second
    // sweepable status is a second way an order can owe cycles.
    let all : [Types.OrderStatus] = [
      #created, #cancelled, #expired, #paid, #delivered, #needsReview, #abandoned,
    ];
    var sweepable = 0;
    for (status in all.values()) {
      if (Recovery.isSweepable(status)) sweepable += 1;
    };
    assert all.size() == 7;
    assert sweepable == 1;
  });

  test("a reconcile is due on a fresh canister, then not again until the interval", func() {
    let day : Nat = 24 * 3_600 * 1_000_000_000;
    // `lastAttemptNs` starts at 0 and `nowNs` is a real epoch time, so the very
    // first tick is due through the attempt clock alone — which is why the
    // predicate needs no "never succeeded" special case.
    assert Recovery.reconcileDue(0, 1_780_000_000_000_000_000, day);
    // Just attempted: not due, whatever else is true.
    assert not Recovery.reconcileDue(1_780_000_000_000_000_000, 1_780_000_000_000_000_000, day);
    // One nanosecond short of the interval, then exactly on it.
    assert not Recovery.reconcileDue(0, day - 1, day);
    assert Recovery.reconcileDue(0, day, day);
  });

  test("a reconcile that never succeeds still backs off to the interval", func() {
    // THE case the attempt clock exists for. A trap rolls back the reconcile's own
    // state, so it can never record a success — an earlier version short-circuited
    // on "no success yet" and was therefore due on every single sweep tick,
    // burning a full instruction budget each time on a canister that could least
    // afford it. Success is not an input here, so that cannot come back.
    let day : Nat = 24 * 3_600 * 1_000_000_000;
    let attempted = 1_780_000_000_000_000_000;
    // Sweeps run every 15 min; none of them may re-trigger the reconcile.
    var t = attempted;
    for (_ in Nat.range(0, 90)) {
      t += 900_000_000_000;
      assert not Recovery.reconcileDue(attempted, t, day);
    };
    // A full day later it retries — once.
    assert Recovery.reconcileDue(attempted, attempted + day, day);
  });
});

suite("stranded #created capacity (#52)", func() {
  test("only #created with a deadline past the grace is asked about", func() {
    let deadline = 1_000_000_000_000_000;
    let grace = Recovery.expiryGraceNs;
    // Inside the grace: not yet. One ns past it: yes. Both sides pinned, because a
    // one-sided bound passes with the comparison inverted.
    assert not Recovery.expiryCheckDue(#created, ?deadline, deadline + grace - 1, grace);
    assert Recovery.expiryCheckDue(#created, ?deadline, deadline + grace, grace);
  });

  test("a null deadline is never asked about, and that is the residue class", func() {
    // An order whose session-create response was lost has no deadline AND no session
    // id, so there is nothing to trigger on and nothing to query with. `expire_order`
    // is the lever for it; reaching that state means a canister-level fault.
    assert not Recovery.expiryCheckDue(#created, null, 9_999_999_999_999_999, Recovery.expiryGraceNs);
  });

  test("no other status is ever asked about", func() {
    let past = 9_999_999_999_999_999;
    for (status in ([#cancelled, #expired, #paid, #delivered, #needsReview, #abandoned] : [Types.OrderStatus]).values()) {
      assert not Recovery.expiryCheckDue(status, ?0, past, Recovery.expiryGraceNs);
    };
  });

  test("the paid escalation waits out Stripe's retry horizon", func() {
    let created = 5_000_000_000_000_000;
    let horizon = Recovery.paidRetryHorizonNs;
    assert not Recovery.paidEscalationDue(created, created + horizon - 1, horizon);
    assert Recovery.paidEscalationDue(created, created + horizon, horizon);
  });

  test("the horizon outlasts Stripe's ~3 days of redelivery", func() {
    // The whole justification for waiting is that an event is still coming. If the
    // horizon were shorter than Stripe's retry window we would escalate payments that
    // credit themselves — worklist noise in a bounded, evicting queue.
    let threeDaysNs = 3 * 24 * 3_600 * 1_000_000_000;
    assert Recovery.paidRetryHorizonNs > threeDaysNs;
  });

  test("the scan is slower than the sweep, and the grace outlasts one sweep", func() {
    // Hourly rather than per-sweep: `countOf(#created)` is usually non-zero, so putting
    // this on the 15-minute cadence would make the O(n) scan run continuously.
    assert Recovery.expiryScanIntervalNs > Recovery.defaultIntervalNs;
    assert Recovery.expiryGraceNs > Recovery.defaultIntervalNs;
    assert Recovery.maxRetrievesPerPass > 0;
  });

  test("the scan's cadence gate behaves like the reconcile's", func() {
    assert not Recovery.expiryScanDue(100, 100, Recovery.expiryScanIntervalNs);
    assert Recovery.expiryScanDue(100, 100 + Recovery.expiryScanIntervalNs, Recovery.expiryScanIntervalNs);
  });
});

suite("#63 — the rotating scan's coverage window", func() {
  // ⚠️ **The multiplier is what these exist for.** The integration suite pins
  // `expectedFullCycleNs` against the live sweep interval, which is the right coupling
  // to pin — but its store is far smaller than one chunk, so `chunks` is always 1 and a
  // version that dropped the store-size factor entirely would pass. The assertion was
  // right and blind to the part that makes the number mean anything.
  let chunk = 2_000;
  let interval = Recovery.defaultIntervalNs;

  test("an empty store still costs one interval, never zero", func() {
    // Zero would report an instantaneous cycle, which reads as "already verified" at
    // exactly the moment nothing has been. `lastCompletedCycle` is compared against
    // this figure, so a zero window makes every scan look overdue on a fresh install.
    assert Recovery.indexScanCycleNs(0, chunk, interval) == interval;
  });

  test("anything up to one full chunk is one interval", func() {
    assert Recovery.indexScanCycleNs(1, chunk, interval) == interval;
    assert Recovery.indexScanCycleNs(chunk - 1, chunk, interval) == interval;
    // Exactly one chunk is still ONE, not two: the boundary a ceiling-division
    // off-by-one lands on.
    assert Recovery.indexScanCycleNs(chunk, chunk, interval) == interval;
  });

  test("⚠️ one order past a chunk boundary costs a second interval", func() {
    // The multiplier, at the smallest input that exercises it. `chunkSize + 1` is the
    // whole of what the integration assertion cannot see.
    assert Recovery.indexScanCycleNs(chunk + 1, chunk, interval) == 2 * interval;
    assert Recovery.indexScanCycleNs(2 * chunk, chunk, interval) == 2 * interval;
    assert Recovery.indexScanCycleNs(2 * chunk + 1, chunk, interval) == 3 * interval;
  });

  test("⚠️ the window grows linearly in stored orders — the latency #63 traded for", func() {
    // 365k orders at 2,000 per chunk is 183 chunks; at the 15-minute default that is
    // ~1.9 days. Ten times the store is ten times the window, and this is the assertion
    // that makes "grows linearly" a checked claim rather than a comment.
    let day = 24 * 3_600 * 1_000_000_000;
    let small = Recovery.indexScanCycleNs(365_000, chunk, interval);
    let large = Recovery.indexScanCycleNs(3_650_000, chunk, interval);
    assert small > 1 * day and small < 2 * day;
    assert large > 18 * day and large < 20 * day;
    // ⚠️ **Linear to within NINE intervals, not one, and the derivation matters** — a
    // hand-waved tolerance of one interval failed here, which is the useful kind of
    // failure. `ceil(10n/c) ≤ 10·ceil(n/c)`, and it can fall short by up to 9 because
    // ten separately-rounded-up chunks round up ten times while one tenfold store rounds
    // up once. (Concretely: 10 × ⌈365000/2000⌉ = 1830 chunks, while ⌈3650000/2000⌉ =
    // 1825 — five short.) So the bound is one-sided above and 9 below, and a tolerance
    // picked to make the test pass would have hidden which side the error lives on.
    assert large <= 10 * small;
    assert large >= 10 * small - 9 * interval;
  });

  test("⚠️ the operator's cadence knob multiplies the window, and nothing else does", func() {
    // `set_recovery_interval` validates only against the §5.1 ledger-dedup bound, so an
    // operator can legally coarsen the sweep to the 6 h ceiling — 24× the default — and
    // silently multiply the detection latency for `orders.unindexedHolders`, which is P1
    // because it means the reserve was oversellable. That is why the function takes the
    // interval as a parameter instead of reading a constant.
    let ceiling = 6 * 3_600 * 1_000_000_000;
    let atDefault = Recovery.indexScanCycleNs(365_000, chunk, interval);
    let atCeiling = Recovery.indexScanCycleNs(365_000, chunk, ceiling);
    assert atCeiling == 24 * atDefault;
    // And the ceiling is genuinely reachable: `validateInterval` accepts it.
    switch (Recovery.validateInterval(ceiling, 24 * 3_600 * 1_000_000_000)) {
      case (#ok) {};
      case (#err(_)) assert false;
    };
  });

  test("a zero chunk size cannot divide by zero", func() {
    // Unreachable today — the chunk size is a compile-time constant — so this guards a
    // future edit. One interval is the answer that cannot understate the window.
    assert Recovery.indexScanCycleNs(10_000, 0, interval) == interval;
  });
});
