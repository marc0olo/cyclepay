// Unit suite for the delivery timeline (#36).
//
// ⚠️ **This suite MOVED here from `treasury.test.mo` with the bound it tests.** It is
// the one part of `Treasury` that is not dead code: `Delivery.waitStage` drives the
// 2 h alert / 72 h terminate timeline for `#paid`, the live delivery path, and #30
// PR-B made it load-bearing for the `#needsReview` route census and for
// `abandon_order`'s unsettled-delivery guard. The assertions are unchanged, which is
// the point — the move is a re-home, not a behaviour change.
import { suite; test } "mo:test";
import Delivery "../src/backend/Delivery";

let hour : Int = 3_600_000_000_000;

/// The same two thresholds the shared fixture used: alert at 2 h, terminate at 72 h.
let waitConfig : Delivery.Config = {
  alertAfterNs = 2 * hour;
  maxHoldNs = 72 * hour;
};

suite("waitStage — the §5.3 timeline for money in, nothing delivered", func() {
  // Three outcomes, not two. Splitting the alert from the terminal bound is what
  // lets the operator be told early WITHOUT giving up on the sale early.
  test("quiet retry before the alert threshold", func() {
    assert Delivery.waitStage(0, 1 * hour, waitConfig) == #retry;
    assert Delivery.waitStage(0, 2 * hour - 1, waitConfig) == #retry;
  });

  test("alert from alertAfterNs, and keep retrying — not terminal", func() {
    assert Delivery.waitStage(0, 2 * hour, waitConfig) == #alert;
    assert Delivery.waitStage(0, 71 * hour, waitConfig) == #alert;
  });

  test("terminate at maxHoldNs — the spec's max-wait bound", func() {
    // A buyer left waiting files a chargeback, which costs the operator more
    // than a refund; and by 72h the cause is structural, not transient.
    assert Delivery.waitStage(0, 72 * hour, waitConfig) == #terminate;
    assert Delivery.waitStage(0, 1_000 * hour, waitConfig) == #terminate;
  });

  test("a clock that has not advanced never alerts", func() {
    assert Delivery.waitStage(5 * hour, 5 * hour, waitConfig) == #retry;
  });
});
