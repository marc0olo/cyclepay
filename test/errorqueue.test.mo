import { test; suite } "mo:test";
import Nat "mo:core/Nat";
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

/// An obligation a refund cannot settle — the counterpart to the two above, and what
/// the eviction and resolution tests need in order to be about anything.
func addStuck(store : ErrorQueue.Store, orderId : Text, nowNs : Int) : ErrorQueue.AddResult {
  ErrorQueue.add(store, cap, #card, #deliveryStuck({ orderId; stage = "staleIntent"; blockIndex = null }), "transfer unconfirmed", nowNs);
};

suite("kinds: what a refund can settle, and what it cannot", func() {
  test("a refund settles exactly the fiat-only obligations", func() {
    assert ErrorQueue.refundResolvable(#duplicate({ orderId = "o1"; paymentRef = "pi_1" }));
    assert ErrorQueue.refundResolvable(#unattributed({ claimedRef = "x"; paymentRef = "pi_2" }));
  });

  test("only a refund-settleable obligation carries the payment it is about", func() {
    // The pairing is the point: `resolveByPaymentRef` can only find an entry that
    // names its payment, so carrying a ref and being refund-settleable are the same
    // property seen from two sides.
    assert ErrorQueue.paymentRefOf(#duplicate({ orderId = "o1"; paymentRef = "pi_1" })) == ?"pi_1";
    assert ErrorQueue.paymentRefOf(#unattributed({ claimedRef = "x"; paymentRef = "pi_2" })) == ?"pi_2";
    assert ErrorQueue.paymentRefOf(#deliveryStuck({ orderId = "o3"; stage = "staleIntent"; blockIndex = null })) == null;
  });

  test("an escalated delivery is never settled by a refund arriving", func() {
    assert not ErrorQueue.refundResolvable(#deliveryStuck({ orderId = "o3"; stage = "staleIntent"; blockIndex = null }));
    assert ErrorQueue.paymentRefOf(#deliveryStuck({ orderId = "o3"; stage = "staleIntent"; blockIndex = null })) == null;
  });

  test("charge.refunded auto-resolve never touches a deliveryStuck entry", func() {
    let store = ErrorQueue.emptyStore();
    ignore ErrorQueue.add(store, cap, #card, #deliveryStuck({ orderId = "o3"; stage = "ambiguousForward"; blockIndex = null }), "upgrade mid-forward", 100);
    ignore addDuplicate(store, "o4", "pi_9", 200);
    let resolved = ErrorQueue.resolveByPaymentRef(store, "pi_9", 300);
    assert resolved.size() == 1;
    assert ErrorQueue.unresolved(store).size() == 1; // the deliveryStuck entry stays
  });
});

suite("add", func() {
  test("entries get monotonic ids and start unresolved", func() {
    let store = ErrorQueue.emptyStore();
    let a = addDuplicate(store, "o1", "pi_1", 100);
    let b = addStuck(store, "o2", 200);
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
  test("an unresolved obligation is NEVER evicted — the queue grows instead", func() {
    // Each unresolved entry is a dollar that arrived and has not been dealt
    // with. Dropping one would break the §4.1 invariant silently, since the only
    // trace would be an audit line in a ring buffer that also drops. So the
    // queue is allowed to exceed capacity rather than forget.
    let store = ErrorQueue.emptyStore();
    ignore addDuplicate(store, "o1", "pi_1", 100);
    ignore addDuplicate(store, "o2", "pi_2", 200);
    ignore addDuplicate(store, "o3", "pi_3", 300);
    let r = addDuplicate(store, "o4", "pi_4", 400);
    assert r.evicted.size() == 0;
    assert ErrorQueue.size(store) == cap + 1;
    assert ErrorQueue.get(store, 0) != null; // the oldest obligation survives
    assert ErrorQueue.unresolvedCount(store) == cap + 1;
  });

  test("growth is bounded by resolution, not by capacity", func() {
    // The operator working the queue down is what shrinks it — and once an
    // entry is resolved it becomes evictable history.
    let store = ErrorQueue.emptyStore();
    for (i in Nat.range(0, cap + 3)) {
      ignore addDuplicate(store, "o" # i.toText(), "pi_" # i.toText(), 100 + i);
    };
    assert ErrorQueue.size(store) == cap + 3;
    assert ErrorQueue.unresolvedCount(store) == cap + 3;
    // Resolve the two oldest; the next add can now trim them as history.
    for (id in ([0, 1] : [Nat]).values()) {
      switch (ErrorQueue.resolve(store, id, 900)) {
        case (#ok(_)) {};
        case (#err(_)) assert false;
      };
    };
    let r = addDuplicate(store, "oX", "pi_X", 999);
    assert r.evicted.size() == 2;
    assert r.evicted[0].id == 0;
    assert r.evicted[1].id == 1;
    assert ErrorQueue.unresolvedCount(store) == cap + 2;
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

  test("ids are never reused, whether or not anything was evicted", func() {
    let store = ErrorQueue.emptyStore();
    for (i in [1, 2, 3, 4, 5].values()) {
      ignore addDuplicate(store, "o", "pi", 100 * i);
    };
    let r = addDuplicate(store, "last", "pi_last", 600);
    assert r.entry.id == 5;
    // All six are unresolved obligations, so none were dropped.
    assert ErrorQueue.size(store) == 6;
  });
});

suite("resolve (manual, operator)", func() {
  test("resolve stamps the entry and keeps it retained", func() {
    let store = ErrorQueue.emptyStore();
    ignore addStuck(store, "o1", 100);
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
    ignore addStuck(store, "o1", 100);
    assert ErrorQueue.resolveByPaymentRef(store, "pi_anything", 900) == [];
    assert ErrorQueue.unresolved(store).size() == 1;
  });
});

suite("paging", func() {
  // Unresolved obligations are never evicted, so the queue can outgrow a 2 MB
  // Candid response. Paging bounds the response instead of the record.
  func fill(store : ErrorQueue.Store, n : Nat) {
    for (i in Nat.range(0, n)) {
      ignore ErrorQueue.add(store, 1_000_000, #card, #duplicate({ orderId = "o" # i.toText(); paymentRef = "pi_" # i.toText() }), "d", 100 + i);
    };
  };

  test("a cursor walks the whole queue exactly once, in arrival order", func() {
    let store = ErrorQueue.emptyStore();
    fill(store, 25);
    var cursor : ?Nat = null;
    var seen = 0;
    var guard = 0;
    label walk loop {
      guard += 1;
      if (guard > 50) { assert false; break walk };
      let page = ErrorQueue.page(store, cursor, 10);
      // Ids strictly ascend, so nothing is revisited or skipped.
      for (entry in page.entries.values()) {
        assert entry.id == seen;
        seen += 1;
      };
      switch (page.nextCursor) {
        case (?next) cursor := ?next;
        case null break walk;
      };
    };
    assert seen == 25;
  });

  test("a cursor appears only when more remains — no wasted final request", func() {
    let store = ErrorQueue.emptyStore();
    fill(store, 10);
    // Exactly-full page with nothing left: no cursor, so the caller stops.
    let exact = ErrorQueue.page(store, null, 10);
    assert exact.entries.size() == 10;
    assert exact.nextCursor == null;
    // Full page with more behind it: cursor points at the last id returned.
    let partial = ErrorQueue.page(store, null, 4);
    assert partial.entries.size() == 4;
    assert partial.nextCursor == ?3;
    let next = ErrorQueue.page(store, ?3, 4);
    assert next.entries[0].id == 4;
  });

  test("limit is capped, so a caller cannot ask for an unreturnable response", func() {
    let store = ErrorQueue.emptyStore();
    fill(store, ErrorQueue.maxPageSize + 50);
    assert ErrorQueue.page(store, null, 100_000).entries.size() == ErrorQueue.maxPageSize;
    // Zero means "give me a page", not "give me nothing".
    assert ErrorQueue.page(store, null, 0).entries.size() == ErrorQueue.maxPageSize;
  });

  test("the worklist page skips resolved history server-side", func() {
    let store = ErrorQueue.emptyStore();
    fill(store, 6);
    for (id in ([0, 1, 2, 3] : [Nat]).values()) {
      switch (ErrorQueue.resolve(store, id, 900)) {
        case (#ok(_)) {};
        case (#err(_)) assert false;
      };
    };
    // Four resolved entries stand between the start and the two open ones; the
    // operator must not have to page past them.
    let open = ErrorQueue.unresolvedPage(store, null, 10);
    assert open.entries.size() == 2;
    assert open.entries[0].id == 4;
    assert open.entries[1].id == 5;
    assert open.nextCursor == null;
    assert ErrorQueue.unresolvedCount(store) == 2;
  });

  test("an empty queue pages cleanly", func() {
    let store = ErrorQueue.emptyStore();
    let page = ErrorQueue.page(store, null, 10);
    assert page.entries.size() == 0;
    assert page.nextCursor == null;
  });

  test("one add evicts every entry it needs to, not just one", func() {
    let store = ErrorQueue.emptyStore();
    // Five resolved entries, then a capacity of 2: the single add below has to
    // shed four at once. A trim that dropped one victim per add would leave the
    // queue over capacity and only converge after three more arrivals.
    fill(store, 5);
    for (id in ([0, 1, 2, 3, 4] : [Nat]).values()) {
      switch (ErrorQueue.resolve(store, id, 900)) {
        case (#ok(_)) {};
        case (#err(_)) assert false;
      };
    };
    let result = ErrorQueue.add(store, 2, #card, #duplicate({ orderId = "o"; paymentRef = "pi" }), "2nd payment", 1_000);
    assert result.evicted.size() == 4;
    // Oldest-first: the survivors are the newest resolved entry and the new one.
    assert result.evicted[0].id == 0;
    assert result.evicted[3].id == 3;
    assert ErrorQueue.size(store) == 2;
  });

  test("an unresolved entry is never evicted, however far over capacity", func() {
    let store = ErrorQueue.emptyStore();
    // Nothing resolved: capacity 1 cannot be honoured without dropping a live
    // obligation, so the queue is allowed to exceed it instead.
    ignore addDuplicate(store, "o1", "pi_1", 100);
    ignore addDuplicate(store, "o2", "pi_2", 200);
    let result = ErrorQueue.add(store, 1, #card, #duplicate({ orderId = "o3"; paymentRef = "pi_3" }), "2nd payment", 300);
    assert result.evicted.size() == 0;
    assert ErrorQueue.size(store) == 3;
  });

  test("an unprocessable event is recognised as already queued", func() {
    let store = ErrorQueue.emptyStore();
    ignore ErrorQueue.add(store, 10, #card, #unprocessable({ eventId = "evt_a"; field = "payment_intent" }), "missing field", 100);
    // What ingestion checks before filing: the same event id, past the ~7-day
    // dedup retention, must not become a second worklist item.
    switch (ErrorQueue.unresolvedUnprocessable(store, "evt_a")) {
      case (?found) assert found.id == 0;
      case null assert false;
    };
    // A different event is a different obligation.
    assert ErrorQueue.unresolvedUnprocessable(store, "evt_b") == null;
    // And once an operator has closed it, a genuine re-report is allowed through
    // rather than being suppressed forever by resolved history.
    switch (ErrorQueue.resolve(store, 0, 900)) {
      case (#ok(_)) {};
      case (#err(_)) assert false;
    };
    assert ErrorQueue.unresolvedUnprocessable(store, "evt_a") == null;
  });

  test("only unprocessable entries answer the unprocessable lookup", func() {
    let store = ErrorQueue.emptyStore();
    // The lookup keys on an event id, and other kinds carry payment refs that
    // could otherwise collide with one.
    ignore addUnattributed(store, "evt_a", "evt_a", 100);
    assert ErrorQueue.unresolvedUnprocessable(store, "evt_a") == null;
  });
});
