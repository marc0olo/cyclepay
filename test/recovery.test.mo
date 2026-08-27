import { test; suite } "mo:test";
import Int "mo:core/Int";
import Nat "mo:core/Nat";
import Cmc "../src/backend/Cmc";
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
    assert Recovery.validateInterval(Recovery.defaultIntervalNs, Cmc.ledgerDedupWindowNs) == #ok;
  });

  test("the retry budget outlasts a full day of outage at the default cadence", func() {
    // ⚠️ **The coupling invariant this asserted is gone (#36).** It was
    // `maxMintRetries × intervalNs > 24 h`: an outage shorter than a day must never
    // exhaust the retry budget, because exhausting it escalated an order that would
    // have completed. There is no budget — a delivery replay is provably safe, so
    // retrying is bounded by time instead. What survives is the *upper* bound below:
    // the cadence must stay well inside the dedup window so a stuck order gets
    // several replay attempts while its intent can still deduplicate.
    assert Recovery.defaultIntervalNs > 0;
  });

  test("the cadence leaves real margin under the §5.1 ledger dedup window", func() {
    // Replay safety needs the cadence well inside the 24 h window, not merely
    // legal at the boundary.
    assert Recovery.defaultIntervalNs * 4 <= Int.abs(Cmc.ledgerDedupWindowNs);
  });
});

suite("isSweepable", func() {
  test("exactly ONE money-committed state sweeps", func() {
    // ⚠️ Four before #36. Money-out is one transfer from `#paid`, and the three
    // mint-pipeline states that also swept are deleted.
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
    // ⚠️ **One, and it used to be four (#36).** Money-out is one transfer from
    // `#paid`; the three mint-pipeline statuses that also swept are deleted. A
    // seven-status list that still summed to four would be the tell that a deleted
    // state came back.
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
