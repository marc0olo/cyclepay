import { test; suite } "mo:test";
import Principal "mo:core/Principal";
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

func newOrder(store : Orders.Store, id : Types.OrderId, owner : Principal) : Types.Order {
  switch (
    Orders.create(
      store,
      id,
      #ii(owner),
      #card,
      #canister(alice),
      1_000_000_000_000, // 1T cycles locked at creation (§3)
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

  test("exactly 11 legal transitions exist", func() {
    var count = 0;
    for (from in allStatuses.values()) {
      for (to in allStatuses.values()) {
        if (Orders.isLegalTransition(from, to)) count += 1;
      };
    };
    assert count == 11;
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
    switch (Orders.create(store, "ord-1", #ii(bob), #ckUsdc, #canister(bob), 7, 999)) {
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
