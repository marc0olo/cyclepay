import { test; suite } "mo:test";
import Problems "../src/backend/Problems";
import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Recovery "../src/backend/Recovery";
import Reserve "../src/backend/Reserve";
import Types "../src/backend/Types";
import Map "mo:core/Map";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Orders "../src/backend/Orders";

// Unit suite for the §4 order state machine and the Orders store.
// Exhaustive: every (from, to) pair of the 8 statuses is checked against the
// spec's legal-transition table.

let allStatuses : [Types.OrderStatus] = [
  #created,
  #cancelled,
  #expired,
  #paid,
  #delivered,
  #needsReview,
  #abandoned,
];

// The legal-transition table straight from spec §4 (+ the escalation edges from
// §4.1/§5.1 and the #34 statuses). Kept as data here so the test is the spec
// table, independent of the implementation's switch.
let legalTransitions : [(Types.OrderStatus, Types.OrderStatus)] = [
  (#created, #cancelled),
  (#created, #expired),
  (#created, #paid),
  // #30 PR-A: the whole money-out path is now one transfer from the reserve.
  // ⚠️ **Deleting this edge fails in the worst direction**: the transfer lands and
  // the order sits `#paid` forever, with the buyer already holding their cycles.
  (#paid, #delivered),
  (#paid, #needsReview),
  // abandon_order: the operator ends it, having refunded by hand.
  (#paid, #abandoned),
  (#needsReview, #abandoned),
  // #30 PR-B — `record_delivered`: the operator checked the cycles ledger and the
  // transfer HAD landed. Its absence forced them to file a delivered order as
  // abandoned, auditing a refund that never happened.
  (#needsReview, #delivered),
];

func isExpectedLegal(from : Types.OrderStatus, to : Types.OrderStatus) : Bool {
  for ((f, t) in legalTransitions.values()) {
    if (f == from and t == to) return true;
  };
  false;
};

let alice = Principal.fromText("aaaaa-aa");
let bob = Principal.fromText("2vxsx-fae");

// §6.1 pricing snapshot used across the store tests — the shared §3 vector
// (500¢ gross at $4.55/ICP and 3.5 XDR/ICP; see pricing.test.mo).
let pricing : Types.Pricing = {
  usdCents = 500;
  usdPerIcpMicros = 4_550_000; // $4.55 per ICP
  xdrPermyriadPerIcp = 35_000; // 3.5 XDR per ICP
  rateStandardDeviation = 0;
  rateReceivedRates = 5;
  rateQueriedSources = 5;
  feeBps = 290;
  feeFixedCents = 30;
  // Deliberately EARLIER than any order's createdAtNs in these fixtures: the
  // rate pair is read before the order exists, which is the whole reason #34
  // records it separately.
  ratesFetchedAtNs = 1;
};

func newOrder(store : Orders.Store, id : Types.OrderId, owner : Principal) : Types.Order {
  switch (
    Orders.create(
      store,
      id,
      #ii(owner),
      #card,
      #cyclesLedgerAccount({ owner = alice; subaccount = null }),
      1_000_000_000_000, // 1T cycles locked at creation (§3)
      pricing,
      100,
    )
  ) {
    case (#ok(order)) order;
    case (#err(_)) { assert false; loop {} };
  };
};

// Drive a stored order along a path of statuses, asserting each hop is legal.
func drive(store : Orders.Store, id : Types.OrderId, path : [Types.OrderStatus]) {
  for (status in path.values()) {
    switch (Orders.applyTransition(store, id, status, 200)) {
      case (#ok(_)) {};
      case (#err(e)) {
        assert false;
        ignore e;
      };
    };
  };
};

suite("the promise tally (#30 PR-B) — every writer moves it", func() {
  // ⚠️ **These exist because of a real bug in this PR.** The tally was first wired
  // into the three writers a comment claimed were the only ones (`create`,
  // `applyTransition`, `markPaid`), and that comment was false in the file it was
  // written in: `expireWithCause` and `expireBySession` (#47) also write status.
  // They are #30's release points 4 and 1 — and point 1 is where EVERY unpaid
  // order ends — so every expired order would have left its `lockedCycles` in
  // `promised` forever, ratcheting `available` down until the gate refused sales
  // against a full reserve.
  //
  // The structural fix is `commitTransition`: one private function does the write,
  // both counters and the tally, so a sixth writer cannot forget. These tests are
  // what keep a hand-rolled writer from reopening the hole.

  test("create takes the hold", func() {
    let store = Orders.emptyStore();
    assert Orders.promised(store) == 0;
    let order = newOrder(store, "ord-1", alice);
    assert Orders.promised(store) == order.lockedCycles;
  });

  test("⚠️ expireBySession returns the hold to zero — release point 1, the common one", func() {
    // Stripe says the session died unpaid. This is the path every abandoned
    // checkout takes, and the one that leaked.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    switch (Orders.expireBySession(store, "ord-1", "cs_test", 300)) {
      case (#ok(_)) {};
      case (#err(_)) assert false;
    };
    assert Orders.promised(store) == 0;
  });

  test("⚠️ expireWithCause returns the hold to zero — release point 4", func() {
    // In-call session-creation failure: no session ever existed.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    switch (Orders.expireWithCause(store, "ord-1", #sessionFailed, 300)) {
      case (#ok(_)) {};
      case (#err(_)) assert false;
    };
    assert Orders.promised(store) == 0;
  });

  test("payment does NOT release; delivery does", func() {
    // Release at `#paid` would let a second order claim capacity the first still
    // needs — the two-orders-one-reserve failure in `Reserve.tallyDelta`.
    let store = Orders.emptyStore();
    let order = newOrder(store, "ord-1", alice);
    switch (Orders.markPaid(store, "ord-1", 500, 300)) {
      case (#ok(_)) {};
      case (#err(_)) assert false;
    };
    assert Orders.promised(store) == order.lockedCycles;
    ignore Orders.applyTransition(store, "ord-1", #delivered, 400);
    assert Orders.promised(store) == 0;
  });

  test("cancel releases — release point 3", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.applyTransition(store, "ord-1", #cancelled, 300);
    assert Orders.promised(store) == 0;
  });

  test("an escalated order KEEPS its promise; abandoning releases it — point 5", func() {
    // `#needsReview` means "we do not know whether the cycles left", so releasing
    // it would free cycles that may still have to be delivered. Only the
    // operator's explicit give-up ends it.
    let store = Orders.emptyStore();
    let order = newOrder(store, "ord-1", alice);
    ignore Orders.applyTransition(store, "ord-1", #paid, 300);
    ignore Orders.applyTransition(store, "ord-1", #needsReview, 400);
    assert Orders.promised(store) == order.lockedCycles;
    ignore Orders.applyTransition(store, "ord-1", #abandoned, 500);
    assert Orders.promised(store) == 0;
  });

  test("an illegal transition moves nothing — idempotency comes from the matrix", func() {
    // A redelivered `checkout.session.expired` for an already-cancelled order is
    // the live example: the transition is refused, so the tally cannot
    // double-release. No extra guard anywhere.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.applyTransition(store, "ord-1", #cancelled, 300);
    assert Orders.promised(store) == 0;
    switch (Orders.expireBySession(store, "ord-1", "cs_test", 400)) {
      case (#err(#illegalTransition(_))) {};
      case (_) assert false;
    };
    assert Orders.promised(store) == 0;
  });

  test("the maintained tally agrees with the independent recount", func() {
    // Two derivations of one quantity: incremental at the write sites, and
    // recomputed from statuses. This is the drift check the daily reconcile runs.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore newOrder(store, "ord-2", alice);
    ignore newOrder(store, "ord-3", bob);
    ignore Orders.applyTransition(store, "ord-1", #paid, 300);
    ignore Orders.applyTransition(store, "ord-2", #cancelled, 300);
    ignore Orders.applyTransition(store, "ord-3", #paid, 300);
    ignore Orders.applyTransition(store, "ord-3", #delivered, 400);
    assert Orders.promised(store) == Reserve.recount(Orders.all(store));
  });
});

suite("legal-transition matrix (exhaustive, 8×8)", func() {
  for (from in allStatuses.values()) {
    for (to in allStatuses.values()) {
      let expected = isExpectedLegal(from, to);
      let name = Types.statusToText(from) # " -> " # Types.statusToText(to) # (if (expected) " is legal" else " is illegal");
      test(name, func() {
        assert Orders.isLegalTransition(from, to) == expected;
      });
    };
  };

  test("exactly 8 legal transitions exist", func() {
    var count = 0;
    for (from in allStatuses.values()) {
      for (to in allStatuses.values()) {
        if (Orders.isLegalTransition(from, to)) count += 1;
      };
    };
    assert count == 8;
  });

  test("the terminal statuses have no outgoing edge at all", func() {
    // `#expired` joined this list in #34, when `#expired → #paid` was deleted:
    // an expired order is a record of an attempt, not something still payable.
    for (from in ([#delivered, #cancelled, #expired, #abandoned] : [Types.OrderStatus]).values()) {
      for (to in allStatuses.values()) {
        assert not Orders.isLegalTransition(from, to);
      };
    };
  });

  test("a cancelled order can NEVER be paid (#34's whole point)", func() {
    // Asserted on its own rather than only as part of the table, because this
    // absence is the guarantee `cancel_order` rests on. If `#cancelled → #paid`
    // is ever added, the buyer-cancellation state stops meaning anything.
    assert not Orders.isLegalTransition(#cancelled, #paid);
    // And the same for an expired one, which used to be legal.
    assert not Orders.isLegalTransition(#expired, #paid);
  });

  test("needsReview has exactly TWO exits, and both need a human's finding", func() {
    // It is NOT re-drivable and NOT terminal. `#abandoned` is "the operator
    // refunded"; `#delivered` is "the operator read the cycles ledger and the
    // transfer had landed" (#30 PR-B). Both are decisions, neither is automatic —
    // `Recovery.isSweepable(#needsReview)` is false and stays false, because
    // re-driving an unknown money position is the double-spend this status prevents.
    //
    // ⚠️ The exhaustive loop is the point: an escalated order must not acquire a
    // third exit, or a *known* position becomes reachable from an unknown one.
    for (to in allStatuses.values()) {
      assert Orders.isLegalTransition(#needsReview, to) == (to == #abandoned or to == #delivered);
    };
    assert not Recovery.isSweepable(#needsReview);
  });
});

suite("transition function", func() {
  test("legal transition returns updated copy with new status and timestamp", func() {
    let store = Orders.emptyStore();
    let order = newOrder(store, "ord-1", alice);
    switch (Orders.transition(order, #paid, 555)) {
      case (#ok(updated)) {
        assert updated.status == #paid;
        assert updated.updatedAtNs == 555;
        // everything else is untouched
        assert updated.id == order.id;
        assert updated.owner == order.owner;
        assert updated.lockedCycles == order.lockedCycles;
        assert updated.createdAtNs == order.createdAtNs;
      };
      case (#err(_)) assert false;
    };
  });

  test("illegal transition reports from/to", func() {
    let store = Orders.emptyStore();
    let order = newOrder(store, "ord-1", alice);
    switch (Orders.transition(order, #delivered, 555)) {
      case (#err(#illegalTransition({ from; to }))) {
        assert from == #created;
        assert to == #delivered;
      };
      case _ assert false;
    };
  });
});

suite("store: create", func() {
  test("create locks the cycle quantity and starts in Created", func() {
    let store = Orders.emptyStore();
    let order = newOrder(store, "ord-1", alice);
    assert order.status == #created;
    assert order.lockedCycles == 1_000_000_000_000;
    assert order.createdAtNs == 100;
    assert Orders.get(store, "ord-1") == ?order;
  });

  test("duplicate id is rejected, original order untouched", func() {
    let store = Orders.emptyStore();
    let original = newOrder(store, "ord-1", alice);
    switch (Orders.create(store, "ord-1", #ii(bob), #card, #cyclesLedgerAccount({ owner = bob; subaccount = null }), 7, pricing, 999)) {
      case (#err(#duplicateId("ord-1"))) {};
      case _ assert false;
    };
    assert Orders.get(store, "ord-1") == ?original;
  });

  test("owner is the parameter, not any ambient caller (seam §11.1.3)", func() {
    let store = Orders.emptyStore();
    let order = newOrder(store, "ord-1", bob);
    assert order.owner == #ii(bob);
  });
});

suite("store: applyTransition", func() {
  test("happy path Created -> Paid -> Delivered", func() {
    // Three states, and that is the whole happy path: money-out is one transfer.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    drive(store, "ord-1", [#paid, #delivered]);
    switch (Orders.get(store, "ord-1")) {
      case (?order) assert order.status == #delivered;
      case null assert false;
    };
  });

  test("buyer cancellation path Created -> Cancelled, and it stops there", func() {
    // Replaces "Created -> Expired -> Paid". #34 deleted `#expired → #paid`, so
    // there is no late-payment path left to drive: an order that stopped being
    // payable stays that way, and `Card.handleWebhook` files a payment against
    // one as a refundable obligation instead.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    drive(store, "ord-1", [#cancelled]);
    switch (Orders.applyTransition(store, "ord-1", #paid, 300)) {
      case (#err(#illegalTransition({ from = #cancelled; to = #paid }))) {};
      case (_) assert false;
    };
  });

  test("illegal transition leaves stored order unchanged", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    switch (Orders.applyTransition(store, "ord-1", #delivered, 200)) {
      case (#err(#illegalTransition(_))) {};
      case _ assert false;
    };
    switch (Orders.get(store, "ord-1")) {
      case (?order) {
        assert order.status == #created;
        assert order.updatedAtNs == 100;
      };
      case null assert false;
    };
  });

  test("unknown order id returns notFound", func() {
    let store = Orders.emptyStore();
    switch (Orders.applyTransition(store, "missing", #paid, 200)) {
      case (#err(#notFound("missing"))) {};
      case _ assert false;
    };
  });
});

suite("store: ownership and history", func() {
  test("getOwned enforces caller == order.owner (§2)", func() {
    let store = Orders.emptyStore();
    let order = newOrder(store, "ord-1", alice);
    assert Orders.getOwned(store, "ord-1", alice) == ?order;
    assert Orders.getOwned(store, "ord-1", bob) == null;
    assert Orders.getOwned(store, "missing", alice) == null;
  });

  test("ordersFor returns only the caller's orders, insertion order", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "a-1", alice);
    ignore newOrder(store, "b-1", bob);
    ignore newOrder(store, "a-2", alice);
    let mine = Orders.ordersFor(store, alice);
    assert mine.size() == 2;
    assert mine[0].id == "a-1";
    assert mine[1].id == "a-2";
    assert Orders.ordersFor(store, bob).size() == 1;
  });

  test("isOwnedBy pattern-matches the Owner variant (seam §11.1.1)", func() {
    assert Types.isOwnedBy(#ii(alice), alice);
    assert not Types.isOwnedBy(#ii(alice), bob);
  });

  test("isOwnDestination accepts only the caller's default subaccount (#29)", func() {
    assert Types.isOwnDestination(#cyclesLedgerAccount({ owner = alice; subaccount = null }), alice);
    // Someone else's account — the case `create_order` used to accept.
    assert not Types.isOwnDestination(#cyclesLedgerAccount({ owner = bob; subaccount = null }), alice);
    // The caller's own account, but not the one the app and the CLI read.
    let sub : Blob = "\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\01";
    assert not Types.isOwnDestination(#cyclesLedgerAccount({ owner = alice; subaccount = ?sub }), alice);
    // The all-zero subaccount is the SAME account as `null` under ICRC-1 —
    // verified against the cycles ledger, both spellings report one balance — and
    // it is refused anyway. `null` is the one accepted representation; see
    // `Types.isOwnDestination` for why equivalent forms are not normalised.
    let zeros : Blob = "\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00";
    assert not Types.isOwnDestination(#cyclesLedgerAccount({ owner = alice; subaccount = ?zeros }), alice);
  });
});

suite("order ids from raw_rand entropy (task 6, §2)", func() {
  // 32 bytes, the shape raw_rand actually returns.
  let rawRandShaped : Blob = "\00\01\02\03\04\05\06\07\08\09\0A\0B\0C\0D\0E\0F\10\11\12\13\14\15\16\17\18\19\1A\1B\1C\1D\1E\1F";

  test("derives 32 lowercase hex chars from the first 16 bytes", func() {
    assert Orders.idFromEntropy(rawRandShaped) == ?"000102030405060708090a0b0c0d0e0f";
  });

  test("exactly idEntropyBytes is enough", func() {
    let atMin : Blob = "\FF\FE\FD\FC\FB\FA\F9\F8\F7\F6\F5\F4\F3\F2\F1\F0";
    assert atMin.size() == Orders.idEntropyBytes;
    assert Orders.idFromEntropy(atMin) == ?"fffefdfcfbfaf9f8f7f6f5f4f3f2f1f0";
  });

  test("one byte under the minimum is refused (broken entropy source)", func() {
    let short : Blob = "\00\01\02\03\04\05\06\07\08\09\0A\0B\0C\0D\0E";
    assert short.size() + 1 == Orders.idEntropyBytes;
    assert Orders.idFromEntropy(short) == null;
    assert Orders.idFromEntropy("" : Blob) == null;
  });

  test("distinct entropy yields distinct ids", func() {
    let other : Blob = "\10\01\02\03\04\05\06\07\08\09\0A\0B\0C\0D\0E\0F";
    assert Orders.idFromEntropy(rawRandShaped) != Orders.idFromEntropy(other);
  });

  test("a collision is reported, then a fresh draw succeeds (re-draw path)", func() {
    let store = Orders.emptyStore();
    let ?id = Orders.idFromEntropy(rawRandShaped) else Runtime.trap("entropy too short");
    ignore newOrder(store, id, alice);
    // Same entropy again: duplicate id, order untouched.
    switch (Orders.create(store, id, #ii(alice), #card, #cyclesLedgerAccount({ owner = alice; subaccount = null }), 1, pricing, 200)) {
      case (#err(#duplicateId(dup))) assert dup == id;
      case (#ok(_)) assert false;
    };
    // Fresh entropy: succeeds.
    let ?id2 = Orders.idFromEntropy("\AA\01\02\03\04\05\06\07\08\09\0A\0B\0C\0D\0E\0F" : Blob) else Runtime.trap("entropy too short");
    switch (Orders.create(store, id2, #ii(alice), #card, #cyclesLedgerAccount({ owner = alice; subaccount = null }), 1, pricing, 200)) {
      case (#ok(order)) assert order.id == id2;
      case (#err(_)) assert false;
    };
    assert Orders.ordersFor(store, alice).size() == 2;
  });
});

suite("client_reference_id (§6.1)", func() {
  test("format is <principal>_<orderId>", func() {
    assert Orders.clientReferenceId(#ii(alice), "00ff") == "aaaaa-aa_00ff";
    assert Orders.clientReferenceId(#ii(bob), "000102030405060708090a0b0c0d0e0f") == "2vxsx-fae_000102030405060708090a0b0c0d0e0f";
  });
});

suite("parseClientReferenceId (§4.1 claimed-not-trusted)", func() {
  let id = "000102030405060708090a0b0c0d0e0f"; // 32 hex chars = idEntropyBytes * 2

  test("round-trips what clientReferenceId produces", func() {
    assert Orders.parseClientReferenceId(Orders.clientReferenceId(#ii(bob), id)) == ?("2vxsx-fae", id);
  });

  test("returns the claimed parts verbatim — no Principal parsing (a garbage principal must not trap)", func() {
    assert Orders.parseClientReferenceId("not!a@principal_" # id) == ?("not!a@principal", id);
  });

  test("wrong underscore count is rejected", func() {
    assert Orders.parseClientReferenceId("") == null;
    assert Orders.parseClientReferenceId("no-underscore") == null;
    assert Orders.parseClientReferenceId("a_b_" # id) == null;
  });

  test("empty principal half is rejected", func() {
    assert Orders.parseClientReferenceId("_" # id) == null;
  });

  test("order-id half must be exactly 32 lowercase hex chars", func() {
    assert Orders.parseClientReferenceId("aaaaa-aa_" # id # "00") == null; // too long
    assert Orders.parseClientReferenceId("aaaaa-aa_00ff") == null; // too short
    assert Orders.parseClientReferenceId("aaaaa-aa_000102030405060708090A0B0C0D0E0F") == null; // uppercase
    assert Orders.parseClientReferenceId("aaaaa-aa_g00102030405060708090a0b0c0d0e0f") == null; // non-hex
  });
});

suite("markPaid (§6.1 amount honoring)", func() {
  test("created -> paid, and the LOCKED quantity is what survives", func() {
    // Inverted by #33. `markPaid` used to take an honored quantity and overwrite
    // `lockedCycles` with it, because a Payment Link could be paid for a
    // different amount. Per-order sessions carry our own figure, so the webhook
    // honours only the quoted amount and this argument is gone: what was locked
    // at creation is what is delivered, for the order's whole life. #30's tally
    // is exact rather than conservative because of that.
    let store = Orders.emptyStore();
    let created = newOrder(store, "ord-1", alice);
    switch (Orders.markPaid(store, "ord-1", 500, 300)) {
      case (#ok(paid)) {
        assert paid.status == #paid;
        assert paid.lockedCycles == created.lockedCycles;
        assert paid.paidUsdCents == ?500;
        assert paid.updatedAtNs == 300;
        assert paid.pricing == pricing; // snapshot untouched
      };
      case (#err(_)) assert false;
    };
    switch (Orders.get(store, "ord-1")) {
      case (?stored) assert stored.lockedCycles == created.lockedCycles and stored.status == #paid;
      case null assert false;
    };
  });

  test("markPaid refuses an order that is no longer payable", func() {
    // `markPaid` is the second line of defence behind `Card.handleWebhook`'s status
    // guard: the guard files a refundable obligation, and this refuses rather than moving
    // the status if the guard is ever wrong.
    //
    // ⚠️ `Card.mo` TRAPS on this error, deliberately, so a mismatch between the guard
    // and the matrix cannot silently deliver. Which is exactly why the guard must
    // never let one of these through — see the webhook suite.
    for (unpayable in ([#cancelled, #expired] : [Types.OrderStatus]).values()) {
      let store = Orders.emptyStore();
      ignore newOrder(store, "ord-1", alice);
      drive(store, "ord-1", [unpayable]);
      switch (Orders.markPaid(store, "ord-1", 500, 300)) {
        case (#err(#illegalTransition({ from; to = #paid }))) assert from == unpayable;
        case (_) assert false;
      };
      // And the store is untouched.
      switch (Orders.get(store, "ord-1")) {
        case (?stored) assert stored.status == unpayable and stored.paidUsdCents == null;
        case null assert false;
      };
    };
  });

  test("already-paid order refuses a second markPaid, store unchanged", func() {
    let store = Orders.emptyStore();
    let created = newOrder(store, "ord-1", alice);
    switch (Orders.markPaid(store, "ord-1", 500, 300)) {
      case (#ok(_)) {};
      case (#err(_)) assert false;
    };
    switch (Orders.markPaid(store, "ord-1", 500, 400)) {
      case (#err(#illegalTransition({ from = #paid; to = #paid }))) {};
      case _ assert false;
    };
    switch (Orders.get(store, "ord-1")) {
      case (?stored) assert stored.lockedCycles == created.lockedCycles and stored.updatedAtNs == 300;
      case null assert false;
    };
  });

  test("unknown order id returns notFound", func() {
    let store = Orders.emptyStore();
    switch (Orders.markPaid(store, "missing", 500, 100)) {
      case (#err(#notFound("missing"))) {};
      case _ assert false;
    };
  });
});

suite("openOrderCount — the Gate admission input", func() {
  test("counts only #created orders for the given principal", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore newOrder(store, "ord-2", alice);
    ignore newOrder(store, "ord-3", bob);
    assert Orders.openOrderCount(store, alice, 200) == 2;
    assert Orders.openOrderCount(store, bob, 200) == 1;
  });

  test("a principal with no orders counts zero", func() {
    assert Orders.openOrderCount(Orders.emptyStore(), alice, 200) == 0;
  });

  test("an expired order no longer occupies a slot", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.applyTransition(store, "ord-1", #expired, 200);
    assert Orders.openOrderCount(store, alice, 200) == 0;
  });

  test("⚠️ a #created order PAST ITS DEADLINE frees the slot without any Stripe call", func() {
    // The half that makes a cap of 1 safe. Without it, one missed
    // `checkout.session.expired` locks the buyer out **permanently** — not for the 35
    // minutes the session lasts, because nothing else moves a `#created` order.
    //
    // ⚠️ And it needs no outcall, which is the asymmetry worth remembering: a slot is
    // OUR resource, so we may grant it on our own clock — being early costs nothing,
    // because the order it frees is unpayable anyway once Stripe expires its session.
    // Reserve capacity is money, so releasing THAT needs Stripe's authority (#52 PR-A).
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.attachSession(store, "ord-1", "cs_1", "https://pay.example/1", 5_000, 120);
    // One ns before the deadline it still holds the slot; one ns after, it does not.
    assert Orders.openOrderCount(store, alice, 5_000) == 1;
    assert Orders.openOrderCount(store, alice, 5_001) == 0;
    // The order itself is untouched — this frees a slot, it does not expire anything.
    switch (Orders.get(store, "ord-1")) {
      case (?order) assert order.status == #created;
      case null assert false;
    };
  });

  test("⚠️ a null deadline still occupies the slot", func() {
    // `expiresAtNs` is null until the session-create response lands. Counting that as
    // free would hand out a slot on the strength of an order whose fate we do not know —
    // and the residue case (a lost create response) is a canister-level fault whose only
    // lever is `expire_order`, not a slot we should be optimistic about.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    assert Orders.openOrderCount(store, alice, 9_999_999_999) == 1;
  });

  test("pastDeadline: both sides of the boundary, and null is never past", func() {
    let store = Orders.emptyStore();
    let fresh = newOrder(store, "ord-1", alice);
    assert not Orders.pastDeadline(fresh, 9_999_999_999); // null deadline
    ignore Orders.attachSession(store, "ord-1", "cs_1", "https://pay.example/1", 5_000, 120);
    switch (Orders.get(store, "ord-1")) {
      case (?dated) {
        assert not Orders.pastDeadline(dated, 4_999);
        assert not Orders.pastDeadline(dated, 5_000); // AT the deadline is not past it
        assert Orders.pastDeadline(dated, 5_001);
      };
      case null assert false;
    };
  });

  test("anything past #created no longer occupies a slot", func() {
    // Money in play is a record, not an open slot — otherwise a busy buyer
    // would lock themselves out permanently.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.markPaid(store, "ord-1", 500, 200);
    assert Orders.openOrderCount(store, alice, 200) == 0;
  });
});

suite("status counts — the O(1) query inputs", func() {
  // The public status queries read these instead of scanning the store, so a
  // drift here silently misreports operational state. Every write path that
  // touches a status is covered.
  test("create increments #created", func() {
    let store = Orders.emptyStore();
    assert Orders.countOf(store, #created) == 0;
    ignore newOrder(store, "ord-1", alice);
    ignore newOrder(store, "ord-2", bob);
    assert Orders.countOf(store, #created) == 2;
  });

  test("applyTransition moves the count between tracked statuses", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.applyTransition(store, "ord-1", #expired, 200);
    assert Orders.countOf(store, #created) == 0;
    assert Orders.countOf(store, #expired) == 1;
  });

  test("markPaid decrements without going through applyTransition", func() {
    // markPaid writes status directly, so it maintains the counts itself —
    // this is the path most likely to be forgotten.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.markPaid(store, "ord-1", 500, 200);
    assert Orders.countOf(store, #created) == 0;
    // #paid is untracked, so nothing else moved.
    assert Orders.countOf(store, #expired) == 0;
  });

  test("a paid order is tracked in both directions", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.markPaid(store, "ord-1", 500, 200);
    assert Orders.countOf(store, #paid) == 1;
    ignore Orders.applyTransition(store, "ord-1", #delivered, 400);
    assert Orders.countOf(store, #paid) == 0;
  });

  test("a refused transition leaves the counts alone", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    // #created → #delivered is illegal.
    switch (Orders.applyTransition(store, "ord-1", #delivered, 200)) {
      case (#err(_)) {};
      case (#ok(_)) assert false;
    };
    assert Orders.countOf(store, #created) == 1;
  });

  test("the bounded pass recounts from the non-terminal index and is idempotent", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore newOrder(store, "ord-2", alice);
    ignore newOrder(store, "ord-3", bob);
    ignore Orders.applyTransition(store, "ord-3", #expired, 200);

    let first = Orders.reconcileBounded(store).counts;
    assert Orders.countOf(store, #created) == 2;
    // ⚠️ **Maintained by `bump`, NOT recounted** — `#expired` is terminal, so the
    // non-terminal index cannot see it and the pass checks it by monotonicity instead.
    assert Orders.countOf(store, #expired) == 1;
    // Running it again must not double-count.
    assert Orders.reconcileBounded(store).counts == first;
  });

  test("the bounded pass lands an order in exactly one bucket after a transition chain", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    // A real chain rather than a contrived one: paid, then escalated. (It used to be
    // created → expired → paid, which #34 made illegal, and then paid → held short of
    // float, which #36 deleted with the float.)
    ignore Orders.applyTransition(store, "ord-1", #paid, 200);
    ignore Orders.applyTransition(store, "ord-1", #needsReview, 300);
    ignore Orders.reconcileBounded(store);
    // One order, one bucket: the statuses it passed through must be vacated.
    assert Orders.countOf(store, #created) == 0;
    assert Orders.countOf(store, #expired) == 0;
    assert Orders.countOf(store, #paid) == 0;
    assert Orders.countOf(store, #needsReview) == 1;
  });

  test("the bounded pass reports nothing while the incremental counts are correct", func() {
    // What the daily sweep asserts. Drift can only come from a bug in `bump`, so
    // it cannot be manufactured through the public API — which is exactly why the
    // useful direction to pin is the negative one: a representative chain of
    // transitions must leave the tallies agreeing with the store, so a future
    // `bump` that forgets a status makes this fail.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore newOrder(store, "ord-2", alice);
    ignore newOrder(store, "ord-3", bob);
    ignore Orders.applyTransition(store, "ord-1", #paid, 200);
    ignore Orders.applyTransition(store, "ord-1", #delivered, 300);
    ignore Orders.applyTransition(store, "ord-2", #expired, 300);
    ignore Orders.applyTransition(store, "ord-3", #paid, 300);

    let result = Orders.reconcileBounded(store);
    assert result.adopted.size() == 0;
    assert result.refused.size() == 0;
    assert result.staleHolders.size() == 0;
    assert result.promisedWas == result.promisedIs;
    assert not result.expiredOverflow;
    // And the tallies it reports are the ones the queries serve. ⚠️ **Four keys, and
    // a delivered order lands in none of them**: `#delivered` is terminal and
    // untracked, so `ord-1` (paid → delivered) is counted nowhere. That is correct —
    // the counters exist for the gate and the sweep, and neither asks about
    // deliveries that finished.
    for ((status, n) in result.counts.values()) {
      assert n == (switch (status) {
        case ("Expired") 1; // ord-2
        case ("Paid") 1; // ord-3
        case (_) 0;
      });
    };
  });

  test("⚠️ a tally that reads TOO HIGH is refused, not repaired", func() {
    // ⚠️ **The one-directional rule, in the direction that must not be adopted.** A
    // recount below the maintained tally is indistinguishable from an index missing a
    // member, so adopting it is the only way an index bug could lower `promised` and
    // oversell the reserve. The old full-scan pass adopted it, because a full scan was
    // authoritative; the bounded pass is not, and this is the difference.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore newOrder(store, "ord-2", alice);
    Map.add(store.counts, Text.compare, "Created", 99);

    let result = Orders.reconcileBounded(store);
    assert result.adopted.size() == 0;
    assert result.refused.size() == 1;
    assert result.refused[0].status == "Created";
    assert result.refused[0].was == 99;
    assert result.refused[0].is == 2;
    // NOT repaired: the maintained value stands, which over-refuses rather than
    // overselling.
    assert Orders.countOf(store, #created) == 99;
    // ⚠️ And it keeps reporting, because the condition is unfixed and the report is
    // the only signal. This is a *state* being re-reported, unlike the `#expired`
    // high-water mark — the difference is that this one is repairable by a human
    // reading the tag, so silence would be the wrong default.
    assert Orders.reconcileBounded(store).refused.size() == 1;
  });

  test("⚠️ a tally that reads TOO LOW is raised, because an under-count stops the sweeps", func() {
    // The other half of the same rule. An under-counted `#paid` reads as zero to
    // `sweepableCount`, which short-circuits the recovery sweep — so money-out stops
    // while orders sit paid and undelivered. Raising is the safe direction and it is
    // the one the pass adopts.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore newOrder(store, "ord-2", alice);
    ignore Orders.applyTransition(store, "ord-1", #paid, 200);
    ignore Orders.applyTransition(store, "ord-2", #paid, 200);
    Map.add(store.counts, Text.compare, "Paid", 0);

    let result = Orders.reconcileBounded(store);
    assert result.refused.size() == 0;
    assert result.adopted.size() == 1;
    assert result.adopted[0].status == "Paid";
    assert result.adopted[0].was == 0;
    assert result.adopted[0].is == 2;
    assert Orders.countOf(store, #paid) == 2;
    // Repaired, so a second pass is clean and the sweep does not re-audit it.
    assert Orders.reconcileBounded(store).adopted.size() == 0;
  });

  test("a status no order is in reads zero", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    // #delivered and the terminal #34 statuses are untracked by design (terminal or worklist-
    // owned); the rest are tracked but empty here.
    for (status in ([#paid, #delivered, #cancelled, #needsReview, #abandoned] : [Types.OrderStatus]).values()) {
      assert Orders.countOf(store, status) == 0;
    };
  });
});


suite("#37 — markDelayed records the first crossing, and only the first", func() {
  test("first call records, later calls do not, and updatedAtNs never moves", func() {
    let store = Orders.emptyStore();
    let order = switch (
      Orders.create(store, "o-delay", #ii(alice), #card, #cyclesLedgerAccount({ owner = alice; subaccount = null }), 1_000, pricing, 1_000)
    ) {
      case (#ok(o)) o;
      case (#err(e)) { assert false; loop {} };
    };
    assert order.delayedAtNs == null;
    let heldSince = order.updatedAtNs;

    assert Orders.markDelayed(store, order.id, 5_000);
    let marked = switch (Orders.get(store, order.id)) { case (?o) o; case null { assert false; loop {} } };
    assert marked.delayedAtNs == ?5_000;
    // ⚠️ **The clock must not move.** `Delivery.waitStage` reads `updatedAtNs` as
    // held-since, so bumping it here would reset the very wait being recorded and
    // the order could never reach `maxHoldNs` — alerted forever, escalated never.
    assert marked.updatedAtNs == heldSince;

    // Idempotent by construction: this is what retires the `delayedAlerts` map
    // rather than relocating it, so there is no second structure to fall out of
    // step with the order.
    assert not Orders.markDelayed(store, order.id, 9_999);
    let again = switch (Orders.get(store, order.id)) { case (?o) o; case null { assert false; loop {} } };
    assert again.delayedAtNs == ?5_000;
    assert again.updatedAtNs == heldSince;
  });

  test("an unknown order records nothing and reports false", func() {
    let store = Orders.emptyStore();
    assert not Orders.markDelayed(store, "no-such-order", 1);
  });
});

suite("#37 — the unresolved-problems index", func() {
  func freshOrder(store : Orders.Store, id : Text) : Types.Order {
    switch (Orders.create(store, id, #ii(alice), #card, #cyclesLedgerAccount({ owner = alice; subaccount = null }), 1_000, pricing, 100)) {
      case (#ok(o)) o;
      case (#err(_)) { assert false; loop {} };
    };
  };

  test("filing enters the index, resolving the last problem leaves it", func() {
    let store = Orders.emptyStore();
    let o = freshOrder(store, "idx-1");
    assert Orders.unresolvedProblemCount(store) == 0;
    assert Orders.withUnresolvedProblems(store).size() == 0;

    assert Orders.fileProblem(store, o.id, #duplicate({ paymentRef = "pi_1" }), "second payment", 200);
    assert Orders.unresolvedProblemCount(store) == 1;
    assert Orders.withUnresolvedProblems(store).size() == 1;

    // Two problems, one order: the order is in the index once and stays until BOTH
    // are closed.
    assert Orders.fileProblem(store, o.id, #deliveryStuck({ stage = "staleIntent" }), "ledger", 210);
    assert Orders.unresolvedProblemCount(store) == 2;
    assert Orders.withUnresolvedProblems(store).size() == 1;

    assert Orders.resolveProblems(store, o.id, func(k) { Problems.refundResolvable(k) }, 300) == 1;
    assert Orders.withUnresolvedProblems(store).size() == 1;
    assert Orders.resolveProblems(store, o.id, func(_) { true }, 310) == 1;
    assert Orders.withUnresolvedProblems(store).size() == 0;
    assert Orders.unresolvedProblemCount(store) == 0;

    // ⚠️ **Nothing dropped.** The resolved problems are still on the order; only the
    // worklist shrank.
    let after = switch (Orders.get(store, o.id)) { case (?x) x; case null { assert false; loop {} } };
    assert after.problems.size() == 2;
  });

  test("resolveByPaymentRef closes only the matching refund-resolvable problem", func() {
    let store = Orders.emptyStore();
    let a = freshOrder(store, "idx-a");
    let b = freshOrder(store, "idx-b");
    assert Orders.fileProblem(store, a.id, #duplicate({ paymentRef = "pi_match" }), "dup", 200);
    assert Orders.fileProblem(store, b.id, #duplicate({ paymentRef = "pi_other" }), "dup", 200);
    // Carries a paymentRef and must NOT be closed by a refund: the refund is what
    // created it.
    assert Orders.fileProblem(store, b.id, #refundAfterDelivery({ paymentRef = "pi_match"; cycles = 1; refundedCents = 1; fullRefund = true }), "loss", 200);

    assert Orders.resolveByPaymentRef(store, "pi_match", 300) == 1;
    assert Orders.withUnresolvedProblems(store).size() == 1; // b still has two open
    assert Orders.unresolvedProblemCount(store) == 2;
  });

  test("⚠️ the index agrees with a full scan — the tripwire that makes derived state safe", func() {
    // Without this the index is the `delayedAlerts` mistake again: a second structure
    // that can disagree with the orders it points at and no way to tell which is
    // right. A disagreement means a writer bypassed fileProblem/resolveProblems.
    //
    // ⚠️ **Both directions, because #63 split them across two mechanisms** and a test
    // that only ran one would pass while the other was broken. The inside direction
    // (nothing in the index lacks a problem) is `reconcileBounded`, daily; the outside
    // direction (nothing outside the index has one) is `scanChunk`, on a coverage
    // window. The full scan below is the independent oracle both are checked against.
    let store = Orders.emptyStore();
    let a = freshOrder(store, "drift-a");
    let b = freshOrder(store, "drift-b");
    let c = freshOrder(store, "drift-c");
    assert Orders.fileProblem(store, a.id, #duplicate({ paymentRef = "p1" }), "d", 200);
    assert Orders.fileProblem(store, b.id, #deliveryStuck({ stage = "s" }), "d", 200);
    assert Orders.fileProblem(store, c.id, #paidNotCredited({ paymentRef = "p3"; sessionId = "cs" }), "d", 200);
    ignore Orders.resolveProblems(store, b.id, func(_) { true }, 300);

    assert Orders.reconcileBounded(store).staleProblemIds.size() == 0;
    let chunk = Orders.scanChunk(store, null, Orders.scanChunkSize);
    assert chunk.unindexedProblems.size() == 0;
    assert chunk.nextCursor == null; // the cycle completed, so this speaks for all of them
    assert Orders.withUnresolvedProblems(store).size() == 2;

    // And the oracle: the index is exactly the set a full scan would build.
    var byScan = 0;
    for (order in Orders.all(store).values()) {
      if (Problems.unresolvedCount(order.problems) > 0) byScan += 1;
    };
    assert byScan == Orders.withUnresolvedProblems(store).size();
  });

  test("filing on an unknown order changes nothing", func() {
    let store = Orders.emptyStore();
    assert not Orders.fileProblem(store, "no-such-order", #duplicate({ paymentRef = "p" }), "d", 1);
    assert Orders.withUnresolvedProblems(store).size() == 0;
  });
});

suite("#37 — the pay link is dropped on the way into a terminal state", func() {
  func withUrl(store : Orders.Store, id : Text) : Types.Order {
    let o = switch (Orders.create(store, id, #ii(alice), #card, #cyclesLedgerAccount({ owner = alice; subaccount = null }), 1_000, pricing, 100)) {
      case (#ok(x)) x;
      case (#err(_)) { assert false; loop {} };
    };
    switch (Orders.attachSession(store, id, "cs_" # id, "https://checkout.stripe.com/c/pay/cs_" # id, 999, 200)) {
      case (#ok(x)) x;
      case (#err(_)) { assert false; loop {} };
    };
  };

  test("every terminal status clears it; the non-terminal ones keep it", func() {
    // ⚠️ Terminality comes from `Reserve.holdsPromise`, which is the single authority
    // — a second list in `commitTransition` would be a place for the two to disagree.
    for (terminal in [#cancelled, #expired].vals()) {
      let store = Orders.emptyStore();
      let o = withUrl(store, "t-" # Types.statusToText(terminal));
      assert o.stripeSessionUrl != null;
      switch (Orders.applyTransition(store, o.id, terminal, 300)) {
        case (#ok(after)) assert after.stripeSessionUrl == null;
        case (#err(_)) assert false;
      };
    };
  });

  test("#paid keeps the link — the order is still payable-adjacent and not terminal", func() {
    let store = Orders.emptyStore();
    let o = withUrl(store, "keeps");
    switch (Orders.markPaid(store, o.id, 500, 300)) {
      case (#ok(after)) assert after.stripeSessionUrl != null;
      case (#err(_)) assert false;
    };
  });

  test("the stored order agrees with what the transition returned", func() {
    // The clearing happens inside `commitTransition`, so the returned value and the
    // stored value must be the same object — a version that only patched the return
    // would leave the big field on disk forever.
    let store = Orders.emptyStore();
    let o = withUrl(store, "stored");
    ignore Orders.applyTransition(store, o.id, #cancelled, 300);
    let fromStore = switch (Orders.get(store, o.id)) { case (?x) x; case null { assert false; loop {} } };
    assert fromStore.stripeSessionUrl == null;
    // The session ID is NOT dropped: the recovery sweep reads it.
    assert fromStore.stripeSessionId != null;
  });
});

suite("#37 — resolving a problem is precise, and refuses when it cannot be", func() {
  func orderWith(store : Orders.Store, id : Text) : Types.Order {
    switch (Orders.create(store, id, #ii(alice), #card, #cyclesLedgerAccount({ owner = alice; subaccount = null }), 1_000, pricing, 100)) {
      case (#ok(o)) o;
      case (#err(_)) { assert false; loop {} };
    };
  };

  test("⚠️ two #duplicate problems with different refs are BOTH kept", func() {
    // This is the state that made a tag-only resolver dangerous: the dedup key is
    // (kind, paymentRef), so a buyer paying three times files three problems.
    let store = Orders.emptyStore();
    let o = orderWith(store, "multi");
    assert Orders.fileProblem(store, o.id, #duplicate({ paymentRef = "pi_a" }), "2nd", 200);
    assert Orders.fileProblem(store, o.id, #duplicate({ paymentRef = "pi_b" }), "3rd", 210);
    assert Orders.unresolvedOfKind(store, o.id, "duplicate").size() == 2;
  });

  test("resolving by ref closes exactly one, leaving the other outstanding", func() {
    let store = Orders.emptyStore();
    let o = orderWith(store, "precise");
    assert Orders.fileProblem(store, o.id, #duplicate({ paymentRef = "pi_a" }), "2nd", 200);
    assert Orders.fileProblem(store, o.id, #duplicate({ paymentRef = "pi_b" }), "3rd", 210);
    let closed = Orders.resolveProblems(
      store, o.id,
      func(k) { Problems.identifyingRef(k) == ?"pi_a" },
      300,
    );
    assert closed == 1;
    let left = Orders.unresolvedOfKind(store, o.id, "duplicate");
    assert left.size() == 1;
    assert left[0].ref == ?"pi_b";
    // The order is still on the worklist, because one problem is still open.
    assert Orders.withUnresolvedProblems(store).size() == 1;
  });

  test("#deliveryStuck can only ever have one, so a ref is never needed", func() {
    // `sameShape` matches it on the discriminator alone, which makes a second
    // unresolved one unrepresentable rather than merely unlikely.
    let store = Orders.emptyStore();
    let o = orderWith(store, "stuck-once");
    assert Orders.fileProblem(store, o.id, #deliveryStuck({ stage = "staleIntent" }), "a", 200);
    assert not Orders.fileProblem(store, o.id, #deliveryStuck({ stage = "transferRejected" }), "b", 210);
    assert Orders.unresolvedOfKind(store, o.id, "deliveryStuck").size() == 1;
    assert Problems.identifyingRef(#deliveryStuck({ stage = "x" })) == null;
  });

  test("sameShape and the operator's selector are the same key", func() {
    // They were separate definitions, and that is precisely what let the resolver be
    // coarser than the dedup. One definition now, both users.
    let a : Types.ProblemKind = #duplicate({ paymentRef = "pi_1" });
    let b : Types.ProblemKind = #duplicate({ paymentRef = "pi_2" });
    assert not Problems.sameShape(a, b);
    assert Problems.identifyingRef(a) != Problems.identifyingRef(b);
    assert Problems.sameShape(a, #duplicate({ paymentRef = "pi_1" }));
  });
});

suite("#38 — filtered, cursor-paginated reads", func() {
  func mk(store : Orders.Store, id : Text, who : Principal, createdAtNs : Int) : Types.Order {
    switch (Orders.create(store, id, #ii(who), #card, #cyclesLedgerAccount({ owner = who; subaccount = null }), 1_000, pricing, createdAtNs)) {
      case (#ok(o)) o;
      case (#err(_)) { assert false; loop {} };
    };
  };

  test("a cursor walk visits every match exactly once", func() {
    // ⚠️ The property that matters for a cursor: complete AND no duplicates. An
    // offset would have both failure modes the moment the set changes under a client.
    let store = Orders.emptyStore();
    for (i in Nat.range(0, 25)) {
      ignore mk(store, "id-" # (if (i < 10) "0" else "") # i.toText(), alice, 100 + i);
    };
    var seen : [Text] = [];
    var cursor : ?Types.OrderId = null;
    var pages = 0;
    label walk loop {
      let p = Orders.page(store, Orders.noFilter(), cursor, 7);
      pages += 1;
      for (o in p.orders.vals()) seen := seen.concat([o.id]);
      switch (p.nextCursor) {
        case (?c) cursor := ?c;
        case null break walk;
      };
      if (pages > 10) { assert false; break walk };  // no infinite walk
    };
    assert seen.size() == 25;
    // No duplicates: every id appears once.
    for (id in seen.vals()) {
      var n = 0;
      for (other in seen.vals()) { if (other == id) n += 1 };
      assert n == 1;
    };
  });

  test("nextCursor is null only when nothing remains, so a full page can be the last", func() {
    let store = Orders.emptyStore();
    for (i in Nat.range(0, 3)) ignore mk(store, "p-" # i.toText(), alice, 100);
    // Exactly three, page size three: full page, and no wasted follow-up request.
    let p = Orders.page(store, Orders.noFilter(), null, 3);
    assert p.orders.size() == 3;
    assert p.nextCursor == null;
  });

  test("limit 0 and an oversized limit both clamp to maxPageSize", func() {
    let store = Orders.emptyStore();
    for (i in Nat.range(0, 5)) ignore mk(store, "c-" # i.toText(), alice, 100);
    assert Orders.page(store, Orders.noFilter(), null, 0).orders.size() == 5;
    assert Orders.page(store, Orders.noFilter(), null, 1_000_000).orders.size() == 5;
  });

  test("filters AND together", func() {
    let store = Orders.emptyStore();
    let a = mk(store, "f-1", alice, 100);
    let b = mk(store, "f-2", bob, 200);
    ignore Orders.applyTransition(store, b.id, #cancelled, 300);

    // owner alone
    assert Orders.page(store, { Orders.noFilter() with owner = ?alice }, null, 50).orders.size() == 1;
    // status alone
    assert Orders.page(store, { Orders.noFilter() with status = ?(#cancelled : Types.OrderStatus) }, null, 50).orders.size() == 1;
    // both, contradicting: alice's order is not cancelled
    assert Orders.page(store, { Orders.noFilter() with owner = ?alice; status = ?(#cancelled : Types.OrderStatus) }, null, 50).orders.size() == 0;
    // time range is inclusive at both ends
    assert Orders.page(store, { Orders.noFilter() with createdFromNs = ?100; createdToNs = ?100 }, null, 50).orders.size() == 1;
    assert Orders.page(store, { Orders.noFilter() with createdFromNs = ?101 }, null, 50).orders.size() == 1;
    assert a.createdAtNs == 100;
  });

  test("withUnresolvedProblems composes with the other filters (#37's thesis)", func() {
    // The worklist is a FILTER, not a parallel query — which is why it has to compose.
    let store = Orders.emptyStore();
    let a = mk(store, "w-1", alice, 100);
    let b = mk(store, "w-2", bob, 100);
    assert Orders.fileProblem(store, a.id, #duplicate({ paymentRef = "pi_a" }), "d", 200);
    assert Orders.fileProblem(store, b.id, #duplicate({ paymentRef = "pi_b" }), "d", 200);

    let worklist = { Orders.noFilter() with withUnresolvedProblems = true };
    assert Orders.page(store, worklist, null, 50).orders.size() == 2;
    // Narrowed to one owner: still a filter, so it intersects.
    assert Orders.page(store, { worklist with owner = ?alice }, null, 50).orders.size() == 1;
    // Resolving removes it from the worklist while the order stays in the unfiltered set.
    ignore Orders.resolveProblems(store, a.id, func(_) { true }, 300);
    assert Orders.page(store, worklist, null, 50).orders.size() == 1;
    assert Orders.page(store, Orders.noFilter(), null, 50).orders.size() == 2;
  });
});

suite("#63 — the reconcile is bounded by flow, not by lifetime sales", func() {
  func mk(store : Orders.Store, id : Text) : Types.Order {
    switch (Orders.create(store, id, #ii(alice), #card, #cyclesLedgerAccount({ owner = alice; subaccount = null }), 1_000, pricing, 100)) {
      case (#ok(o)) o;
      case (#err(_)) { assert false; loop {} };
    };
  };

  /// Drive an order all the way to `#delivered` — a terminal status, so it leaves the
  /// non-terminal index and must stop costing the reconcile anything.
  func deliver(store : Orders.Store, id : Text) {
    ignore mk(store, id);
    ignore Orders.applyTransition(store, id, #paid, 200);
    ignore Orders.applyTransition(store, id, #delivered, 300);
  };

  test("⚠️ the promise recount does not read terminal orders — the acceptance criterion", func() {
    // ⚠️ **Two assertions, and neither alone is worth anything.** "It reads few orders"
    // passes trivially for a pass that reads none and answers wrong; "it answers
    // correctly" passes for the O(every order) pass this replaced. What has to hold is
    // *both at once*: the answer matches an independent full scan **while** the work
    // stays flat as terminal history piles up.
    let store = Orders.emptyStore();
    ignore mk(store, "open-1");
    ignore mk(store, "open-2");
    ignore Orders.applyTransition(store, "open-2", #paid, 200);

    let lean = Orders.reconcileBounded(store);
    assert lean.ordersRead == 2;
    assert lean.promisedIs == Reserve.recount(Orders.all(store));

    // Now bury them in history. Fifty delivered orders is fifty the old pass summed
    // every single day, forever.
    for (i in Nat.range(0, 50)) deliver(store, "done-" # i.toText());
    assert Orders.storedCount(store) == 52;

    let heavy = Orders.reconcileBounded(store);
    // ⚠️ The work did not move. This is the whole issue in one assertion.
    assert heavy.ordersRead == 2;
    // And it is still the right answer, checked against the full-scan oracle.
    assert heavy.promisedIs == Reserve.recount(Orders.all(store));
    assert heavy.promisedIs == 2_000;
    assert heavy.promisedWas == heavy.promisedIs;
  });

  test("a terminal order left in the index is dropped on sight, and reported", func() {
    // Stands in for a status writer that bypassed `commitTransition`: the order is
    // terminal but its id is still indexed. Reading the order is authoritative, so the
    // drop is a sound repair — and the recount must exclude it rather than counting a
    // promise that was released.
    let store = Orders.emptyStore();
    deliver(store, "gone-1");
    ignore mk(store, "live-1");
    Set.add(store.promiseHolders, Text.compare, "gone-1");

    let result = Orders.reconcileBounded(store);
    assert result.staleHolders == ["gone-1"];
    assert not store.promiseHolders.contains("gone-1");
    // The delivered order's cycles are not in the recount.
    assert result.promisedIs == 1_000;
    // Reported once: a second pass has nothing left to drop.
    assert Orders.reconcileBounded(store).staleHolders.size() == 0;
  });

  test("⚠️ `#expired` is checked by monotonicity, and a decrease is a breach", func() {
    // `#expired` is the ONE tracked status that is terminal, so the index cannot recount
    // it. Its inbound edge is `#created → #expired` and the matrix has no outbound one,
    // so the tally can only rise — which is what makes a cheap check sound here and
    // nowhere else.
    let store = Orders.emptyStore();
    ignore mk(store, "exp-1");
    ignore mk(store, "exp-2");
    ignore Orders.applyTransition(store, "exp-1", #expired, 200);
    ignore Orders.applyTransition(store, "exp-2", #expired, 200);

    let first = Orders.reconcileBounded(store);
    assert first.expiredWas == 0 and first.expiredIs == 2; // 0 → 2 is a rise, not a breach
    assert Orders.reconcileBounded(store).expiredIs == 2;

    // A `bump` bug is the only way this happens, so write the wrong value directly.
    Map.add(store.counts, Text.compare, "Expired", 1);
    let breach = Orders.reconcileBounded(store);
    assert breach.expiredWas == 2 and breach.expiredIs == 1;

    // ⚠️ **Reported once, not daily.** The high-water mark follows the tally down, so an
    // unfixed decrease does not re-fire on every pass — our own cadence bounding a rate
    // against a persistent state is the fault #37 §2c removed from the audit log.
    let after = Orders.reconcileBounded(store);
    assert after.expiredWas == 1 and after.expiredIs == 1;
  });

  test("`#expired` over-counting past the store size is caught by disjointness", func() {
    // The bound monotonicity cannot give: `#expired` orders and the non-terminal set are
    // disjoint subsets of the store, so their sizes cannot exceed it. Two O(1) reads.
    let store = Orders.emptyStore();
    ignore mk(store, "live-1");
    assert not Orders.reconcileBounded(store).expiredOverflow;
    Map.add(store.counts, Text.compare, "Expired", 5);
    assert Orders.reconcileBounded(store).expiredOverflow;
  });

  test("⚠️ the rotating scan never claims coverage it did not achieve", func() {
    // ⚠️ **The three-state requirement, at its mechanical root.** A chunk that stopped
    // early must return a cursor; only exhaustion returns null. If it ever returned null
    // early, a partial pass would read as a completed one and `no drift` would mean
    // `not looked at yet` — two readings with opposite responses.
    let store = Orders.emptyStore();
    for (i in Nat.range(0, 5)) ignore mk(store, "scan-" # i.toText());

    let first = Orders.scanChunk(store, null, 2);
    assert first.visited == 2;
    let ?cursor1 = first.nextCursor else Runtime.trap("a partial chunk must return a cursor");

    let second = Orders.scanChunk(store, ?cursor1, 2);
    assert second.visited == 2;
    let ?cursor2 = second.nextCursor else Runtime.trap("still partial");
    // The cursor advanced, so the pass makes progress rather than re-reading a prefix.
    assert cursor2 > cursor1;

    let third = Orders.scanChunk(store, ?cursor2, 2);
    assert third.visited == 1; // the store is exhausted, not the chunk
    assert third.nextCursor == null; // and only now is the cycle complete

    // 2 + 2 + 1 = every order exactly once. No overlap, no gap: the cursor is inclusive
    // in `entriesFrom` and the scan skips it explicitly, which is the off-by-one that
    // would otherwise re-read one order per chunk forever or skip one per chunk.
    assert first.visited + second.visited + third.visited == Orders.storedCount(store);
  });

  test("⚠️ the scan finds the one error the daily pass cannot see, and the tally follows", func() {
    // The money-critical case. A non-terminal order missing from the index while
    // `promised` is missing its cycles too: the two agree with each other, so the daily
    // recount reports nothing, and the reserve reads as MORE available than it is.
    let store = Orders.emptyStore();
    ignore mk(store, "hidden-1");
    ignore mk(store, "seen-1");
    // Stand in for a writer that entered an order without either bookkeeping step.
    store.promiseHolders.remove("hidden-1");
    store.promised -= 1_000;

    // ⚠️ The daily pass is blind to it — index and tally agree at the wrong value. This
    // assertion is why the rotating scan exists at all; if it ever fails, the scan is
    // redundant and should go.
    let blind = Orders.reconcileBounded(store);
    assert blind.promisedWas == blind.promisedIs;
    assert blind.promisedIs == 1_000;
    assert blind.promisedIs != Reserve.recount(Orders.all(store));

    // The scan reads the order itself, so it sees the truth and repairs the index.
    let chunk = Orders.scanChunk(store, null, Orders.scanChunkSize);
    assert chunk.unindexedHolders == ["hidden-1"];
    assert store.promiseHolders.contains("hidden-1");

    // And the repair feeds through to the tally without the scan touching it: the next
    // recount is larger, and a larger recount is exactly what the pass adopts.
    let fixed = Orders.reconcileBounded(store);
    assert fixed.promisedAdopted;
    assert fixed.promisedIs == 2_000;
    assert Orders.promised(store) == Reserve.recount(Orders.all(store));
  });

  test("the scan repairs on a chunk that stopped early, not only on the last one", func() {
    // ⚠️ **A draft returned from inside the loop when the chunk filled and skipped the
    // two lines that apply the repair** — so the one thing the scan exists to do was
    // dropped on every chunk except the last of a cycle, and every test that scanned a
    // small store in one chunk passed.
    let store = Orders.emptyStore();
    for (i in Nat.range(0, 4)) ignore mk(store, "part-" # i.toText());
    for (i in Nat.range(0, 4)) store.promiseHolders.remove("part-" # i.toText());

    let chunk = Orders.scanChunk(store, null, 2);
    assert chunk.nextCursor != null; // it stopped early
    assert chunk.unindexedHolders.size() == 2;
    // Repaired, despite the early stop.
    assert Orders.promiseHolderCount(store) == 2;
  });

  test("a scan over an empty store completes immediately rather than stalling", func() {
    let store = Orders.emptyStore();
    let chunk = Orders.scanChunk(store, null, Orders.scanChunkSize);
    assert chunk.visited == 0;
    // ⚠️ Null, so the cycle is recorded as complete. A stalled cursor on an empty store
    // would leave `lastCompletedCycle` null forever and make every clean scan read as
    // unverified.
    assert chunk.nextCursor == null;
  });
});

suite("#39 — cumulative delivery figures", func() {
  func mk(store : Orders.Store, id : Text, cycles : Nat) : Types.Order {
    switch (Orders.create(store, id, #ii(alice), #card, #cyclesLedgerAccount({ owner = alice; subaccount = null }), cycles, pricing, 100)) {
      case (#ok(o)) o;
      case (#err(_)) { assert false; loop {} };
    };
  };
  /// Pay at `cents`, then deliver — the ordinary route.
  func payAndDeliver(store : Orders.Store, id : Text, cycles : Nat, cents : Nat) {
    ignore mk(store, id, cycles);
    switch (Orders.markPaid(store, id, cents, 200)) {
      case (#ok(_)) {};
      case (#err(_)) assert false;
    };
    ignore Orders.applyTransition(store, id, #delivered, 300);
  };

  test("delivered orders, cycles and USD accumulate", func() {
    let store = Orders.emptyStore();
    payAndDeliver(store, "d-1", 1_000, 1_000);
    payAndDeliver(store, "d-2", 2_500, 2_000);
    let t = Orders.deliveryTotals(store);
    assert t.orders == 2;
    assert t.cycles == 3_500;
    assert t.usdCents == 3_000;
    assert t.nullPaid == 0;
  });

  test("nothing that is not delivered is counted", func() {
    let store = Orders.emptyStore();
    ignore mk(store, "open", 1_000);
    ignore mk(store, "gone", 2_000);
    ignore Orders.applyTransition(store, "gone", #expired, 200);
    ignore mk(store, "esc", 4_000);
    switch (Orders.markPaid(store, "esc", 500, 200)) { case (#ok(_)) {}; case (#err(_)) assert false };
    ignore Orders.applyTransition(store, "esc", #needsReview, 300);
    let t = Orders.deliveryTotals(store);
    assert t.orders == 0 and t.cycles == 0 and t.usdCents == 0;
  });

  test("⚠️ the OPERATOR path counts too — the undercount this would otherwise ship", func() {
    // `record_delivered` drives `#needsReview → #delivered` and writes the journal's
    // `cyclesDelivered` as **null**, so a counter maintained at the sites that write that
    // field would miss exactly these — the rare, high-touch orders most likely to be
    // asked about. Counting in `commitTransition` covers the route for free.
    let store = Orders.emptyStore();
    ignore mk(store, "esc-1", 9_000);
    switch (Orders.markPaid(store, "esc-1", 7_500, 200)) { case (#ok(_)) {}; case (#err(_)) assert false };
    ignore Orders.applyTransition(store, "esc-1", #needsReview, 300);
    assert Orders.deliveryTotals(store).orders == 0;
    ignore Orders.applyTransition(store, "esc-1", #delivered, 400);
    let t = Orders.deliveryTotals(store);
    assert t.orders == 1;
    assert t.cycles == 9_000;
    assert t.usdCents == 7_500;
  });

  test("⚠️ double-counting is unrepresentable, not merely guarded", func() {
    // `#delivered` has no outbound edge, so `commitTransition` cannot run twice for a
    // delivered order. Pinned by trying every status as a follow-on transition: all must
    // be refused, and the totals must not move.
    let store = Orders.emptyStore();
    payAndDeliver(store, "once", 1_000, 900);
    assert Orders.deliveryTotals(store).orders == 1;
    for (to in allStatuses.values()) {
      switch (Orders.applyTransition(store, "once", to, 500)) {
        case (#err(_)) {};
        case (#ok(_)) assert false; // any legal exit from #delivered breaks the counter
      };
    };
    let t = Orders.deliveryTotals(store);
    assert t.orders == 1 and t.cycles == 1_000 and t.usdCents == 900;
  });

  test("the figures survive the bounded reconcile untouched", func() {
    // They are cumulative, not derived from live state, so nothing may rebuild them —
    // a reconcile that "repaired" them would erase history.
    let store = Orders.emptyStore();
    payAndDeliver(store, "keep", 5_000, 4_200);
    ignore Orders.reconcileBounded(store);
    let t = Orders.deliveryTotals(store);
    assert t.orders == 1 and t.cycles == 5_000 and t.usdCents == 4_200;
  });
});
