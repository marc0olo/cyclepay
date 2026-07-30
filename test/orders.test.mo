import { test; suite } "mo:test";
import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Types "../src/backend/Types";
import Orders "../src/backend/Orders";

// Unit suite for the §4 order state machine and the Orders store.
// Exhaustive: every (from, to) pair of the 8 statuses is checked against the
// spec's legal-transition table.

let allStatuses : [Types.OrderStatus] = [
  #created,
  #expired,
  #paid,
  #minting,
  #icpAtCmc,
  #delivered,
  #awaitingTreasury,
  #errorQueue,
];

// The legal-transition table straight from spec §4 (+ the two error-queue
// edges from §4.1/§5.1). Kept as data here so the test is the spec table,
// independent of the implementation's switch.
let legalTransitions : [(Types.OrderStatus, Types.OrderStatus)] = [
  (#created, #expired),
  (#created, #paid),
  (#expired, #paid),
  (#paid, #minting),
  (#paid, #awaitingTreasury),
  (#paid, #errorQueue),
  (#awaitingTreasury, #minting),
  (#awaitingTreasury, #errorQueue),
  (#minting, #icpAtCmc),
  (#minting, #errorQueue),
  (#icpAtCmc, #delivered),
  (#icpAtCmc, #errorQueue),
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
};

func newOrder(store : Orders.Store, id : Types.OrderId, owner : Principal) : Types.Order {
  switch (
    Orders.create(
      store,
      id,
      #ii(owner),
      #card,
      #canister(alice),
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

  test("exactly 12 legal transitions exist", func() {
    var count = 0;
    for (from in allStatuses.values()) {
      for (to in allStatuses.values()) {
        if (Orders.isLegalTransition(from, to)) count += 1;
      };
    };
    assert count == 12;
  });

  test("delivered and errorQueue are terminal", func() {
    for (to in allStatuses.values()) {
      assert not Orders.isLegalTransition(#delivered, to);
      assert not Orders.isLegalTransition(#errorQueue, to);
    };
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
    switch (Orders.create(store, "ord-1", #ii(bob), #ckUsdc, #canister(bob), 7, pricing, 999)) {
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
  test("happy path Created -> Paid -> Minting -> IcpAtCMC -> Delivered", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    drive(store, "ord-1", [#paid, #minting, #icpAtCmc, #delivered]);
    switch (Orders.get(store, "ord-1")) {
      case (?order) assert order.status == #delivered;
      case null assert false;
    };
  });

  test("late payment path Created -> Expired -> Paid", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    drive(store, "ord-1", [#expired, #paid]);
  });

  test("treasury path Paid -> AwaitingTreasury -> Minting", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    drive(store, "ord-1", [#paid, #awaitingTreasury, #minting]);
  });

  test("illegal transition leaves stored order unchanged", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    switch (Orders.applyTransition(store, "ord-1", #minting, 200)) {
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
    switch (Orders.create(store, id, #ii(alice), #card, #canister(alice), 1, pricing, 200)) {
      case (#err(#duplicateId(dup))) assert dup == id;
      case (#ok(_)) assert false;
    };
    // Fresh entropy: succeeds.
    let ?id2 = Orders.idFromEntropy("\AA\01\02\03\04\05\06\07\08\09\0A\0B\0C\0D\0E\0F" : Blob) else Runtime.trap("entropy too short");
    switch (Orders.create(store, id2, #ii(alice), #card, #canister(alice), 1, pricing, 200)) {
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
  test("created -> paid, lockedCycles replaced by the honored quantity", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    switch (Orders.markPaid(store, "ord-1", 42, 500, 300)) {
      case (#ok(paid)) {
        assert paid.status == #paid;
        assert paid.lockedCycles == 42;
        assert paid.updatedAtNs == 300;
        assert paid.pricing == pricing; // snapshot untouched
      };
      case (#err(_)) assert false;
    };
    switch (Orders.get(store, "ord-1")) {
      case (?stored) assert stored.lockedCycles == 42 and stored.status == #paid;
      case null assert false;
    };
  });

  test("late payment: expired -> paid is honored (§4)", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    drive(store, "ord-1", [#expired]);
    switch (Orders.markPaid(store, "ord-1", 7, 500, 300)) {
      case (#ok(paid)) assert paid.status == #paid;
      case (#err(_)) assert false;
    };
  });

  test("already-paid order refuses a second markPaid, store unchanged", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    switch (Orders.markPaid(store, "ord-1", 42, 500, 300)) {
      case (#ok(_)) {};
      case (#err(_)) assert false;
    };
    switch (Orders.markPaid(store, "ord-1", 99, 500, 400)) {
      case (#err(#illegalTransition({ from = #paid; to = #paid }))) {};
      case _ assert false;
    };
    switch (Orders.get(store, "ord-1")) {
      case (?stored) assert stored.lockedCycles == 42 and stored.updatedAtNs == 300;
      case null assert false;
    };
  });

  test("unknown order id returns notFound", func() {
    let store = Orders.emptyStore();
    switch (Orders.markPaid(store, "missing", 1, 500, 100)) {
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
    ignore Orders.markPaid(store, "ord-1", 1, 500, 200);
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
    ignore Orders.markPaid(store, "ord-1", 1, 500, 200);
    assert Orders.countOf(store, #created) == 0;
    // #paid is untracked, so nothing else moved.
    assert Orders.countOf(store, #expired) == 0;
    assert Orders.countOf(store, #awaitingTreasury) == 0;
  });

  test("the awaitingTreasury hold is tracked in both directions", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.markPaid(store, "ord-1", 1, 500, 200);
    ignore Orders.applyTransition(store, "ord-1", #awaitingTreasury, 300);
    assert Orders.countOf(store, #awaitingTreasury) == 1;
    ignore Orders.applyTransition(store, "ord-1", #minting, 400);
    assert Orders.countOf(store, #awaitingTreasury) == 0;
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

  test("recount repairs a drifted count", func() {
    // The reconciliation lever exists precisely because incremental
    // maintenance can be wrong; prove it actually converges.
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    ignore Orders.applyTransition(store, "ord-1", #expired, 200);
    ignore Orders.applyTransition(store, "ord-1", #paid, 300);
    // #paid is untracked, so nothing should remain counted.
    ignore Orders.recount(store);
    assert Orders.countOf(store, #created) == 0;
    assert Orders.countOf(store, #expired) == 0;
    assert Orders.countOf(store, #awaitingTreasury) == 0;
  });

  test("untracked statuses always read zero", func() {
    let store = Orders.emptyStore();
    ignore newOrder(store, "ord-1", alice);
    for (status in ([#paid, #minting, #icpAtCmc, #delivered, #errorQueue] : [Types.OrderStatus]).values()) {
      assert Orders.countOf(store, status) == 0;
    };
  });
});
