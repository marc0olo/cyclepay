import { test; suite } "mo:test";
import Int "mo:core/Int";
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

  test("rejects a cadence so fine the retry budget stops spanning the window", func() {
    // A 1 ns interval is "positive" but useless: maxMintRetries sweeps would
    // elapse instantly, so the first transient CMC failure would burn the whole
    // budget and escalate an order that had ~24 h of replay left. The validator
    // owns BOTH sides of the retries × cadence > window invariant, because a
    // retuned cadence is exactly how an operator breaks it by accident.
    let minNs = Int.abs(dayNs) / Recovery.maxMintRetries + 1;
    assert Recovery.validateInterval(1, dayNs) == #err(#intervalTooShort({ minNs }));
    assert Recovery.validateInterval(minNs / 2, dayNs) == #err(#intervalTooShort({ minNs }));
  });

  test("a cadence an operator would actually reach for during an incident is legal", func() {
    // The invariant must not make the cadence unadjustable. With a tight retry
    // budget the shortest legal interval would be over 14 min, so nobody could
    // speed the sweep up while working an outage — the budget is sized to keep
    // this range open.
    assert Recovery.validateInterval(60_000_000_000, dayNs) == #ok; // 1 min
    assert Recovery.validateInterval(300_000_000_000, dayNs) == #ok; // 5 min
  });

  test("boundary: the shortest legal cadence keeps the budget wider than the window", func() {
    let minNs = Int.abs(dayNs) / Recovery.maxMintRetries + 1;
    assert Recovery.validateInterval(minNs, dayNs) == #ok;
    assert Recovery.validateInterval(minNs - 1, dayNs) == #err(#intervalTooShort({ minNs }));
    // And the accepted boundary really does satisfy the invariant it guards.
    assert Recovery.maxMintRetries * minNs > Int.abs(dayNs);
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
    // THE coupling invariant. Shortening the cadence without raising the retry
    // budget converts a survivable outage into a stuck order — an outage shorter
    // than a day must never exhaust the budget, because exhausting it escalates
    // an order that would have completed.
    assert Recovery.maxMintRetries * Recovery.defaultIntervalNs > 86_400_000_000_000;
  });

  test("the cadence leaves real margin under the §5.1 ledger dedup window", func() {
    // Replay safety needs the cadence well inside the 24 h window, not merely
    // legal at the boundary.
    assert Recovery.defaultIntervalNs * 4 <= Int.abs(Cmc.ledgerDedupWindowNs);
  });
});

suite("isSweepable", func() {
  test("exactly the four money-committed states sweep", func() {
    assert Recovery.isSweepable(#paid);
    assert Recovery.isSweepable(#minting);
    assert Recovery.isSweepable(#icpAtCmc);
    assert Recovery.isSweepable(#awaitingTreasury);
  });

  test("user-pending, expired, and terminal states never sweep", func() {
    assert not Recovery.isSweepable(#created);
    assert not Recovery.isSweepable(#expired);
    assert not Recovery.isSweepable(#delivered);
    assert not Recovery.isSweepable(#errorQueue);
  });

  test("the matrix is exhaustive: 4 of all 8 states sweep", func() {
    let all : [Types.OrderStatus] = [
      #created, #expired, #paid, #minting,
      #icpAtCmc, #delivered, #awaitingTreasury, #errorQueue,
    ];
    var sweepable = 0;
    for (status in all.values()) {
      if (Recovery.isSweepable(status)) sweepable += 1;
    };
    assert all.size() == 8;
    assert sweepable == 4;
  });
});
