import { test; suite } "mo:test";
import Problems "../src/backend/Problems";
import Types "../src/backend/Types";

// Unit suite for order-bound problems (#37). All pure over an array, so the whole
// admission and resolution policy is pinned without an IC environment.

let dup : Types.ProblemKind = #duplicate({ paymentRef = "pi_dup" });
let stuck : Types.ProblemKind = #deliveryStuck({ stage = "staleIntent" });
let refunded : Types.ProblemKind = #refundAfterDelivery({
  paymentRef = "pi_ref"; cycles = 1_000; refundedCents = 500; fullRefund = false;
});
let uncredited : Types.ProblemKind = #paidNotCredited({ paymentRef = "pi_unc"; sessionId = "cs_1" });

suite("resolution semantics", func() {
  test("refundResolvable and paymentRefOf agree on every kind", func() {
    // ⚠️ **The invariant with two sides**, shared with `Orphans`: a refund
    // can settle a problem exactly when `paymentRefOf` gives the closer something to
    // match on. If these ever disagree, either a refund closes a problem it cannot
    // settle, or a settleable one is never closed.
    for (k in [dup, stuck, refunded, uncredited].vals()) {
      assert Problems.refundResolvable(k) == (Problems.paymentRefOf(k) != null);
    };
  });

  test("only #duplicate is refund-resolvable", func() {
    assert Problems.refundResolvable(dup);
    assert not Problems.refundResolvable(stuck);
    // ⚠️ Both of these CARRY a paymentRef and still return null, for different
    // reasons: the refund is what created `#refundAfterDelivery`, and refunding
    // `#paidNotCredited` leaves the order stranded holding reserve capacity with no
    // event left to release it. The remedy there is a resend.
    assert not Problems.refundResolvable(refunded);
    assert not Problems.refundResolvable(uncredited);
    assert Problems.paymentRefOf(refunded) == null;
    assert Problems.paymentRefOf(uncredited) == null;
  });
});

suite("filing and dedup", func() {
  test("filing the same shape twice adds no PROBLEM, and refreshes what it says", func() {
    let once = Problems.file([], dup, "second payment", 100);
    assert once.filed;
    assert once.problems.size() == 1;
    let twice = Problems.file(once.problems, dup, "second payment again", 200);
    // Not a new problem, so `filed` is false and the caller must not re-audit.
    assert not twice.filed;
    assert twice.problems.size() == 1;
    // ⚠️ **But the detail REFRESHES**, because an operator acts on what the problem
    // currently says. Suppressing the update was the first version of this and it
    // would have shown a stale figure for a cumulative refund.
    assert twice.problems[0].detail == "second payment again";
    // `filedAtNs` is preserved: first seen, not last seen.
    assert twice.problems[0].filedAtNs == 100;
  });

  test("a DIFFERENT payment is a different problem", func() {
    let first = Problems.file([], dup, "d1", 100);
    let other = Problems.file(first.problems, #duplicate({ paymentRef = "pi_other" }), "d2", 200);
    assert other.filed;
    assert other.problems.size() == 2;
  });

  test("detail is excluded from the comparison, but not from the refresh", func() {
    // The ledger's wording can change between attempts without the problem being new
    // — otherwise a retry with a reworded error files a second one.
    let first = Problems.file([], stuck, "ledger said A", 100);
    let again = Problems.file(first.problems, stuck, "ledger said B", 200);
    assert again.problems.size() == 1;
    assert again.problems[0].detail == "ledger said B";
  });

  test("⚠️ #deliveryStuck's STAGE refreshes — it is the money position", func() {
    // The stage is what an operator acts on, and it can move between attempts
    // (staleIntent -> transferRejected). A stale stage sends them to the wrong row of
    // the triage table, which is worse than no problem at all.
    let first = Problems.file([], stuck, "unknown", 100);
    let moved = Problems.file(first.problems, #deliveryStuck({ stage = "transferRejected" }), "definitive", 200);
    assert moved.problems.size() == 1;
    assert not moved.filed;
    switch (moved.problems[0].kind) {
      case (#deliveryStuck({ stage })) assert stage == "transferRejected";
      case (_) assert false;
    };
  });

  test("⚠️ a cumulative refund files no second problem AND shows the current total", func() {
    // `refundedCents` is cumulative, so a second partial arrives with a larger number.
    // Comparing it would file one problem per partial refund; IGNORING it would leave
    // the operator reading the stale, smaller figure — and reconciling against Stripe
    // by amount is the whole reason the field is sized. Both halves are asserted here
    // because getting either one alone is a real defect.
    let first = Problems.file([], refunded, "partial", 100);
    let bigger : Types.ProblemKind = #refundAfterDelivery({
      paymentRef = "pi_ref"; cycles = 1_000; refundedCents = 1_000; fullRefund = true;
    });
    let after = Problems.file(first.problems, bigger, "now full", 200);
    assert after.problems.size() == 1;
    assert not after.filed;
    switch (after.problems[0].kind) {
      case (#refundAfterDelivery({ refundedCents; fullRefund })) {
        assert refundedCents == 1_000;
        assert fullRefund;
      };
      case (_) assert false;
    };
  });

  test("a RESOLVED problem does not block a new one of the same shape", func() {
    // The same trouble recurring after it was dealt with is a new obligation.
    let filed = Problems.file([], dup, "d1", 100);
    let closed = Problems.resolveWhere(filed.problems, func(_) { true }, 150);
    assert closed.closed == 1;
    let refiled = Problems.file(closed.problems, dup, "d1 again", 200);
    assert refiled.filed;
    assert refiled.problems.size() == 2;
    assert Problems.unresolvedCount(refiled.problems) == 1;
  });
});

suite("resolving", func() {
  test("resolveWhere closes only matching unresolved problems", func() {
    var ps = Problems.file([], dup, "d", 100).problems;
    ps := Problems.file(ps, stuck, "s", 100).problems;
    let r = Problems.resolveWhere(ps, func(k) { Problems.refundResolvable(k) }, 200);
    assert r.closed == 1;
    assert Problems.unresolvedCount(r.problems) == 1;
    // Idempotent: nothing left to close on a second pass.
    assert Problems.resolveWhere(r.problems, func(k) { Problems.refundResolvable(k) }, 300).closed == 0;
  });

  test("unresolvedCount ignores resolved history, which is retained", func() {
    var ps = Problems.file([], dup, "d", 100).problems;
    ps := Problems.resolveWhere(ps, func(_) { true }, 200).problems;
    assert Problems.unresolvedCount(ps) == 0;
    // ⚠️ **Nothing drops**: the resolved problem is still there, which is the whole
    // point of retention. Only the COUNT of outstanding work goes to zero.
    assert ps.size() == 1;
    assert ps[0].resolvedAtNs == ?200;
  });
});
