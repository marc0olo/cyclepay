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
    // ⚠️ **The invariant with two sides**, carried over from `ErrorQueue`: a refund
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
  test("filing the same shape twice adds nothing", func() {
    let once = Problems.file([], dup, "second payment", 100);
    assert once.size() == 1;
    let twice = Problems.file(once, dup, "second payment again", 200);
    assert twice.size() == 1;
    // The original detail and timestamp stand: this is not a new problem.
    assert twice[0].detail == "second payment";
    assert twice[0].filedAtNs == 100;
  });

  test("a DIFFERENT payment is a different problem", func() {
    let first = Problems.file([], dup, "d1", 100);
    let other = Problems.file(first, #duplicate({ paymentRef = "pi_other" }), "d2", 200);
    assert other.size() == 2;
  });

  test("detail is excluded from the comparison", func() {
    // The ledger's wording can change between attempts without the problem being new
    // — otherwise a retry with a reworded error files a second one.
    let first = Problems.file([], stuck, "ledger said A", 100);
    let again = Problems.file(first, stuck, "ledger said B", 200);
    assert again.size() == 1;
  });

  test("a cumulative refund figure does NOT file a second problem", func() {
    // ⚠️ `refundedCents` is cumulative, so a second partial arrives with a larger
    // number. Comparing it would file one problem per partial refund.
    let first = Problems.file([], refunded, "partial", 100);
    let bigger : Types.ProblemKind = #refundAfterDelivery({
      paymentRef = "pi_ref"; cycles = 1_000; refundedCents = 1_000; fullRefund = true;
    });
    let after = Problems.file(first, bigger, "now full", 200);
    assert after.size() == 1;
  });

  test("a RESOLVED problem does not block a new one of the same shape", func() {
    // The same trouble recurring after it was dealt with is a new obligation.
    let filed = Problems.file([], dup, "d1", 100);
    let closed = Problems.resolveWhere(filed, func(_) { true }, 150);
    assert closed.closed == 1;
    let refiled = Problems.file(closed.problems, dup, "d1 again", 200);
    assert refiled.size() == 2;
    assert Problems.unresolvedCount(refiled) == 1;
  });
});

suite("resolving", func() {
  test("resolveWhere closes only matching unresolved problems", func() {
    var ps = Problems.file([], dup, "d", 100);
    ps := Problems.file(ps, stuck, "s", 100);
    let r = Problems.resolveWhere(ps, func(k) { Problems.refundResolvable(k) }, 200);
    assert r.closed == 1;
    assert Problems.unresolvedCount(r.problems) == 1;
    // Idempotent: nothing left to close on a second pass.
    assert Problems.resolveWhere(r.problems, func(k) { Problems.refundResolvable(k) }, 300).closed == 0;
  });

  test("unresolvedCount ignores resolved history, which is retained", func() {
    var ps = Problems.file([], dup, "d", 100);
    ps := Problems.resolveWhere(ps, func(_) { true }, 200).problems;
    assert Problems.unresolvedCount(ps) == 0;
    // ⚠️ **Nothing drops**: the resolved problem is still there, which is the whole
    // point of retention. Only the COUNT of outstanding work goes to zero.
    assert ps.size() == 1;
    assert ps[0].resolvedAtNs == ?200;
  });
});
