import { test; suite } "mo:test";
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

  test("accepts the minimum positive interval", func() {
    assert Recovery.validateInterval(1, dayNs) == #ok;
  });

  test("boundary: exactly window/4 passes, one ns more fails", func() {
    let maxNs = 21_600_000_000_000; // 6 h, a quarter of the 24 h window
    assert Recovery.validateInterval(maxNs, dayNs) == #ok;
    assert Recovery.validateInterval(maxNs + 1, dayNs) == #err(#intervalTooLong({ maxNs }));
  });

  test("default cadence is legal against the real ledger window", func() {
    assert Recovery.validateInterval(Recovery.defaultIntervalNs, Cmc.ledgerDedupWindowNs) == #ok;
  });

  test("default cadence gives maxMintRetries more than a day of retries", func() {
    // Pins the Main.mo sizing claim: 25 retries × 1 h cadence > 24 h, so an
    // outage shorter than a day can never exhaust the notify retry budget.
    assert 25 * Recovery.defaultIntervalNs > 86_400_000_000_000;
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
