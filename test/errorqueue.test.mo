import { test; suite } "mo:test";
import ErrorQueue "../src/backend/ErrorQueue";

// Unit suite for the §4.1 bounded error queue: exactly two types, bounded
// eviction (resolved-first), manual resolve, and charge.refunded auto-resolve
// by payment_intent.

let cap = 3; // small capacity so bounds are easy to exercise

func addDuplicate(store : ErrorQueue.Store, orderId : Text, paymentRef : Text, nowNs : Int) : ErrorQueue.AddResult {
  ErrorQueue.add(store, cap, #card, #duplicate({ orderId; paymentRef }), "2nd payment", nowNs);
};

func addUnattributed(store : ErrorQueue.Store, claimedRef : Text, paymentRef : Text, nowNs : Int) : ErrorQueue.AddResult {
  ErrorQueue.add(store, cap, #card, #unattributed({ claimedRef; paymentRef }), "no such order", nowNs);
};

func addUndeliverable(store : ErrorQueue.Store, orderId : Text, cycles : Nat, nowNs : Int) : ErrorQueue.AddResult {
  ErrorQueue.add(store, cap, #card, #undeliverable({ orderId; cycles }), "target deleted", nowNs);
};

suite("kinds: exactly two types (§4.1)", func() {
  test("duplicate and unattributed are Type 1, undeliverable is Type 2", func() {
    assert ErrorQueue.isType1(#duplicate({ orderId = "o1"; paymentRef = "pi_1" }));
    assert ErrorQueue.isType1(#unattributed({ claimedRef = "x"; paymentRef = "pi_2" }));
    assert not ErrorQueue.isType1(#undeliverable({ orderId = "o2"; cycles = 9 }));
  });

  test("Type 1 carries a paymentRef, Type 2 does not", func() {
    assert ErrorQueue.paymentRefOf(#duplicate({ orderId = "o1"; paymentRef = "pi_1" })) == ?"pi_1";
    assert ErrorQueue.paymentRefOf(#unattributed({ claimedRef = "x"; paymentRef = "pi_2" })) == ?"pi_2";
    assert ErrorQueue.paymentRefOf(#undeliverable({ orderId = "o2"; cycles = 9 })) == null;
  });

  test("stuckMint (§5.1 escalation) is neither Type 1 nor refund-resolvable", func() {
    assert not ErrorQueue.isType1(#stuckMint({ orderId = "o3"; stage = "staleIntent" }));
    assert ErrorQueue.paymentRefOf(#stuckMint({ orderId = "o3"; stage = "staleIntent" })) == null;
  });

  test("charge.refunded auto-resolve never touches a stuckMint entry", func() {
    let store = ErrorQueue.emptyStore();
    ignore ErrorQueue.add(store, cap, #card, #stuckMint({ orderId = "o3"; stage = "ambiguousForward" }), "upgrade mid-forward", 100);
    ignore addDuplicate(store, "o4", "pi_9", 200);
    let resolved = ErrorQueue.resolveByPaymentRef(store, "pi_9", 300);
    assert resolved.size() == 1;
    assert ErrorQueue.unresolved(store).size() == 1; // the stuckMint stays
  });
});

suite("add", func() {
  test("entries get monotonic ids and start unresolved", func() {
    let store = ErrorQueue.emptyStore();
    let a = addDuplicate(store, "o1", "pi_1", 100);
    let b = addUndeliverable(store, "o2", 1_000, 200);
    assert a.entry.id == 0;
    assert b.entry.id == 1;
    assert a.entry.resolvedAtNs == null;
    assert a.evicted == [];
    assert ErrorQueue.size(store) == 2;
    assert ErrorQueue.get(store, 0) == ?a.entry;
  });

  test("unresolved lists open entries oldest first", func() {
    let store = ErrorQueue.emptyStore();
    ignore addDuplicate(store, "o1", "pi_1", 100);
    ignore addUnattributed(store, "ref", "pi_2", 200);
    let open = ErrorQueue.unresolved(store);
    assert open.size() == 2;
    assert open[0].id == 0;
    assert open[1].id == 1;
  });
});

suite("bounded eviction", func() {
  test("over capacity evicts the oldest when nothing is resolved", func() {
    let store = ErrorQueue.emptyStore();
    ignore addDuplicate(store, "o1", "pi_1", 100);
    ignore addDuplicate(store, "o2", "pi_2", 200);
    ignore addDuplicate(store, "o3", "pi_3", 300);
    let r = addDuplicate(store, "o4", "pi_4", 400);
    assert r.evicted.size() == 1;
    assert r.evicted[0].id == 0; // oldest unresolved is the fallback victim
    assert ErrorQueue.size(store) == cap;
    assert ErrorQueue.get(store, 0) == null;
    assert ErrorQueue.get(store, 3) == ?r.entry;
  });

  test("resolved entries are evicted before older unresolved ones", func() {
    let store = ErrorQueue.emptyStore();
    ignore addDuplicate(store, "o1", "pi_1", 100); // id 0, stays unresolved
    ignore addDuplicate(store, "o2", "pi_2", 200); // id 1, resolved below
    ignore addDuplicate(store, "o3", "pi_3", 300); // id 2
    switch (ErrorQueue.resolve(store, 1, 250)) {
      case (#ok(_)) {};
      case (#err(_)) assert false;
    };
    let r = addDuplicate(store, "o4", "pi_4", 400);
    assert r.evicted.size() == 1;
    assert r.evicted[0].id == 1; // the resolved one, not unresolved id 0
    assert r.evicted[0].resolvedAtNs == ?250;
    assert ErrorQueue.get(store, 0) != null;
  });

  test("ids are never reused after eviction", func() {
    let store = ErrorQueue.emptyStore();
    for (i in [1, 2, 3, 4, 5].values()) {
      ignore addDuplicate(store, "o", "pi", 100 * i);
    };
    let r = addDuplicate(store, "last", "pi_last", 600);
    assert r.entry.id == 5;
    assert ErrorQueue.size(store) == cap;
  });
});

suite("resolve (manual, operator)", func() {
  test("resolve stamps the entry and keeps it retained", func() {
    let store = ErrorQueue.emptyStore();
    ignore addUndeliverable(store, "o1", 1_000, 100);
    switch (ErrorQueue.resolve(store, 0, 500)) {
      case (#ok(entry)) {
        assert entry.resolvedAtNs == ?500;
        assert entry.createdAtNs == 100;
      };
      case (#err(_)) assert false;
    };
    assert ErrorQueue.unresolved(store) == [];
    assert ErrorQueue.all(store).size() == 1;
  });

  test("resolve is not repeatable and unknown ids fail", func() {
    let store = ErrorQueue.emptyStore();
    ignore addDuplicate(store, "o1", "pi_1", 100);
    ignore ErrorQueue.resolve(store, 0, 500);
    switch (ErrorQueue.resolve(store, 0, 600)) {
      case (#err(#alreadyResolved(0))) {};
      case _ assert false;
    };
    switch (ErrorQueue.resolve(store, 99, 600)) {
      case (#err(#notFound(99))) {};
      case _ assert false;
    };
  });
});

suite("charge.refunded auto-resolve (§4.1)", func() {
  test("resolves all unresolved Type 1 entries with that payment_intent", func() {
    let store = ErrorQueue.emptyStore();
    ignore addDuplicate(store, "o1", "pi_target", 100);
    ignore addUnattributed(store, "bogus", "pi_target", 200);
    ignore addDuplicate(store, "o2", "pi_other", 300);
    let resolved = ErrorQueue.resolveByPaymentRef(store, "pi_target", 900);
    assert resolved.size() == 2;
    assert resolved[0].resolvedAtNs == ?900;
    assert resolved[1].resolvedAtNs == ?900;
    let open = ErrorQueue.unresolved(store);
    assert open.size() == 1;
    assert ErrorQueue.paymentRefOf(open[0].kind) == ?"pi_other";
  });

  test("already-resolved entries are not re-stamped", func() {
    let store = ErrorQueue.emptyStore();
    ignore addDuplicate(store, "o1", "pi_1", 100);
    ignore ErrorQueue.resolve(store, 0, 500);
    assert ErrorQueue.resolveByPaymentRef(store, "pi_1", 900) == [];
    switch (ErrorQueue.get(store, 0)) {
      case (?entry) assert entry.resolvedAtNs == ?500;
      case null assert false;
    };
  });

  test("Type 2 entries never match a refund, unknown refs return empty", func() {
    let store = ErrorQueue.emptyStore();
    ignore addUndeliverable(store, "o1", 1_000, 100);
    assert ErrorQueue.resolveByPaymentRef(store, "pi_anything", 900) == [];
    assert ErrorQueue.unresolved(store).size() == 1;
  });
});
