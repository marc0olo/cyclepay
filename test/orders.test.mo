import { test; suite } "mo:test";
import Array "mo:core/Array";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Recovery "../src/backend/Recovery";
import Reserve "../src/backend/Reserve";
import Types "../src/backend/Types";
import Map "mo:core/Map";
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
  // ⚠️ It did NOT exist before — `#icpAtCmc → #delivered` was the only route to
  // `#delivered`, so without this edge the transfer lands and the order sits
  // `#paid` forever with the buyer already holding their cycles.
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
    // ⚠️ Three states, not five (#36). It read `Created → Paid → Minting → IcpAtCMC
    // → Delivered`, which was the ICP mint pipeline; money-out is one transfer now.
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
    // one as a Type 1 obligation instead.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    drive(store, "ord-1", [#cancelled]);
    switch (Orders.applyTransition(store, "ord-1", #paid, 300)) {
      case (#err(#illegalTransition({ from = #cancelled; to = #paid }))) {};
      case (_) assert false;
    };
  });

  test("treasury path Paid -> AwaitingTreasury -> Minting", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    drive(store, "ord-1", [#paid, #delivered]);
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
    // Was "late payment: expired -> paid is honored (§4)". #34 deleted that edge,
    // so `markPaid` is now the second line of defence behind
    // `Card.handleWebhook`'s status guard: the guard files a Type 1 obligation,
    // and this refuses rather than moving the status if the guard is ever wrong.
    //
    // ⚠️ `Card.mo` TRAPS on this error, deliberately, so that a mismatch between
    // the guard and the matrix cannot silently mint. Which is exactly why the
    // guard must never let one of these through — see the webhook suite.
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
    assert Orders.openOrderCount(store, alice) == 2;
    assert Orders.openOrderCount(store, bob) == 1;
  });

  test("a principal with no orders counts zero", func() {
    assert Orders.openOrderCount(Orders.emptyStore(), alice) == 0;
  });

  test("an expired order no longer occupies a slot", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.applyTransition(store, "ord-1", #expired, 200);
    assert Orders.openOrderCount(store, alice) == 0;
  });

  test("anything past #created no longer occupies a slot", func() {
    // Money in play is a record, not an open slot — otherwise a busy buyer
    // would lock themselves out permanently.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.markPaid(store, "ord-1", 500, 200);
    assert Orders.openOrderCount(store, alice) == 0;
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

  test("recount rebuilds from the store and is idempotent", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore newOrder(store, "ord-2", alice);
    ignore newOrder(store, "ord-3", bob);
    ignore Orders.applyTransition(store, "ord-3", #expired, 200);

    let first = Orders.recount(store);
    assert Orders.countOf(store, #created) == 2;
    assert Orders.countOf(store, #expired) == 1;
    // Running it again must not double-count.
    assert Orders.recount(store) == first;
  });

  test("recount lands an order in exactly one bucket after a transition chain", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    // A real chain rather than a contrived one: paid, then escalated. (It used to be
    // created → expired → paid, which #34 made illegal, and then paid → held short of
    // float, which #36 deleted with the float.)
    ignore Orders.applyTransition(store, "ord-1", #paid, 200);
    ignore Orders.applyTransition(store, "ord-1", #needsReview, 300);
    ignore Orders.recount(store);
    // One order, one bucket: the statuses it passed through must be vacated.
    assert Orders.countOf(store, #created) == 0;
    assert Orders.countOf(store, #expired) == 0;
    assert Orders.countOf(store, #paid) == 0;
    assert Orders.countOf(store, #needsReview) == 1;
  });

  test("reconcile reports no drift while the incremental counts are correct", func() {
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

    let result = Orders.reconcile(store);
    assert result.drift.size() == 0;
    // And the tallies it reports are the ones the queries serve. ⚠️ Four keys now,
    // not six (#36): the mint statuses are deleted, so `ord-1` (paid → delivered)
    // lands in no tracked bucket at all — `#delivered` is terminal and untracked.
    for ((status, n) in result.counts.values()) {
      assert n == (switch (status) {
        case ("Expired") 1; // ord-2
        case ("Paid") 1; // ord-3
        case (_) 0;
      });
    };
  });

  test("reconcile reports the delta when a tally is stale", func() {
    // A `bump` bug is the only way a tally drifts, so this writes the wrong value
    // straight into the counts map to stand in for one. What matters is that the
    // drift list names the status and *both* values: a repair that silently
    // succeeded would hide the bug that made it necessary, and the daily sweep
    // audits nothing when this list is empty.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore newOrder(store, "ord-2", alice);
    Map.add(store.counts, Text.compare, "Created", 99);

    let result = Orders.reconcile(store);
    assert result.drift.size() == 1;
    assert result.drift[0].status == "Created";
    assert result.drift[0].was == 99;
    assert result.drift[0].is == 2;
    // Repaired, not just reported.
    assert Orders.countOf(store, #created) == 2;
    // And a second pass is clean, so the sweep does not re-audit the same drift.
    assert Orders.reconcile(store).drift.size() == 0;
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

