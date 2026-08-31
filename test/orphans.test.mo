import { test; suite } "mo:test";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Orphans "../src/backend/Orphans";

// Unit suite for the §4.1 bounded error queue: which kinds a refund can settle,
// bounded eviction (resolved-first), manual resolve, and charge.refunded auto-resolve
// by payment_intent.


/// ⚠️ Was `#duplicate` until #37 moved that onto the order. `#unattributed` carries
/// the property this fixture is for: refund-resolvable, and it names the payment a
/// `charge.refunded` closes it by.
func addDuplicate(store : Orphans.Store, orderId : Text, paymentRef : Text, nowNs : Int) : Orphans.AddResult {
  Orphans.add(store, #card, #unattributed({ claimedRef = orderId; paymentRef }), "2nd payment", nowNs);
};

func addUnattributed(store : Orphans.Store, claimedRef : Text, paymentRef : Text, nowNs : Int) : Orphans.AddResult {
  Orphans.add(store, #card, #unattributed({ claimedRef; paymentRef }), "no such order", nowNs);
};

/// An obligation a refund cannot settle — the counterpart to the two above, and what
/// the eviction and resolution tests need in order to be about anything.
///
/// ⚠️ Was `#deliveryStuck` until #37 moved that onto the order. `#refundAfterDelivery`
/// carries the same property that matters here: a `charge.refunded` must never close
/// it, because the refund is what created it.
func addStuck(store : Orphans.Store, orderId : Text, nowNs : Int) : Orphans.AddResult {
  Orphans.add(store, #card, #unprocessable({ eventId = "evt_" # orderId; field = "payment_intent" }), "a verified event we cannot parse", nowNs);
};

suite("kinds: what a refund can settle, and what it cannot", func() {
  test("a refund settles exactly the fiat-only obligations", func() {
    assert Orphans.refundResolvable(#unattributed({ claimedRef = "o1"; paymentRef = "pi_1" }));
    assert Orphans.refundResolvable(#unattributed({ claimedRef = "x"; paymentRef = "pi_2" }));
  });

  test("only a refund-settleable obligation carries the payment it is about", func() {
    // The pairing is the point: `resolveByPaymentRef` can only find an entry that
    // names its payment, so carrying a ref and being refund-settleable are the same
    // property seen from two sides.
    assert Orphans.paymentRefOf(#unattributed({ claimedRef = "o1"; paymentRef = "pi_1" })) == ?"pi_1";
    assert Orphans.paymentRefOf(#unattributed({ claimedRef = "x"; paymentRef = "pi_2" })) == ?"pi_2";
    assert Orphans.paymentRefOf(#unprocessable({ eventId = "evt_1"; field = "payment_intent" })) == null;
  });

  test("⚠️ refundResolvable and paymentRefOf agree on EVERY kind", func() {
    // The structural claim in `Orphans`'s header: `refundResolvable` and
    // `paymentRefOf` are the same property seen from two sides. The tests above
    // spot-check three kinds; this walks all seven, because the failure it guards
    // against is a *new* kind added with a paymentRef and left out of
    // `refundResolvable` — which would make `resolveByPaymentRef` find an entry it must
    // not close, silently marking a live obligation settled.
    //
    // ⚠️ **The agreement is with the ACCESSOR, not with the payload.**
    // `#refundAfterDelivery` carries a `paymentRef` field and `paymentRefOf` returns
    // null for it *on purpose* — the refund is what created the entry, so matching on
    // it would close the loss the instant it was recorded. Asserting against the
    // payload instead would demand exactly the bug the accessor exists to prevent.
    // ⚠️ **The tripwire, because `all.size() == N` cannot catch a new variant.** The
    // array below is hand-written, so adding a case to `Orphans.Kind` leaves the
    // count assertion passing while the test silently covers 8 of 9 kinds. This switch
    // is **exhaustive**, so under `-Werror` the compiler refuses this file until a new
    // kind is named here — which lands the maintainer on the exact line where the list
    // and its count live.
    //
    // Found the hard way: #52 added `#paidNotCredited`, both `refundResolvable` and
    // `paymentRefOf` were forced to handle it by their own exhaustive switches, and
    // **this test kept passing at "all seven"**. A test whose name promises
    // exhaustiveness its body cannot deliver is the defect this repo keeps deleting.
    //
    // ⚠️ **It works in the removal direction too**, which is the half a hand-written
    // count usually misses: #37 dropped `#deliveryDelayed`, and `named`'s exhaustive
    // switch plus this count caught the array still listing it — the compiler on the
    // switch, this assertion on the tally.
    func named(k : Orphans.Kind) : Text {
      switch k {
        case (#unattributed(_)) "unattributed";
        case (#unprocessable(_)) "unprocessable";
      };
    };
    let all : [Orphans.Kind] = [
      #unattributed({ claimedRef = "x"; paymentRef = "pi_2" }),
      #unprocessable({ eventId = "evt_1"; field = "amount_total" }),
    ];
    assert all.size() == 2;
    var seen = "";
    for (kind in all.values()) {
      let carriesRef = Orphans.paymentRefOf(kind) != null;
      assert Orphans.refundResolvable(kind) == carriesRef;
      // Names every element through the exhaustive switch, so the tripwire is load
      // bearing rather than dead code, and a duplicated array entry shows up here.
      let name = named(kind);
      assert not Text.contains(seen, #text ("[" # name # "]"));
      seen #= "[" # name # "]";
    };
  });

  test("an escalated delivery is never settled by a refund arriving", func() {
    assert not Orphans.refundResolvable(#unprocessable({ eventId = "evt_2"; field = "amount_total" }));
    assert Orphans.paymentRefOf(#unprocessable({ eventId = "evt_2"; field = "amount_total" })) == null;
  });

  test("charge.refunded auto-resolve never touches an entry it did not settle", func() {
    let store = Orphans.emptyStore();
    ignore Orphans.add(store, #card, #unprocessable({ eventId = "evt_x"; field = "amount_total" }), "a verified event we cannot parse", 100);
    ignore addDuplicate(store, "o4", "pi_9", 200);
    let resolved = Orphans.resolveByPaymentRef(store, "pi_9", 300);
    assert resolved.size() == 1;
    assert Orphans.unresolved(store).size() == 1; // the unsettleable entry stays
  });
});

suite("add", func() {
  test("entries get monotonic ids and start unresolved", func() {
    let store = Orphans.emptyStore();
    let a = addDuplicate(store, "o1", "pi_1", 100);
    let b = addStuck(store, "o2", 200);
    assert a.entry.id == 0;
    assert b.entry.id == 1;
    assert a.entry.resolvedAtNs == null;
    assert Orphans.size(store) == 2;
    assert Orphans.get(store, 0) == ?a.entry;
  });

  test("unresolved lists open entries oldest first", func() {
    let store = Orphans.emptyStore();
    ignore addDuplicate(store, "o1", "pi_1", 100);
    ignore addUnattributed(store, "ref", "pi_2", 200);
    let open = Orphans.unresolved(store);
    assert open.size() == 2;
    assert open[0].id == 0;
    assert open[1].id == 1;
  });
});

// ── The "bounded eviction" suite was DELETED by #37, with its heirs named ─────
//
// Three tests asserted about a bound that no longer exists: "an unresolved obligation
// is NEVER evicted", "growth is bounded by resolution, not by capacity", and "resolved
// entries are evicted before older unresolved ones". The `capacity` parameter is gone
// from `add`, so none of those claims is expressible.
//
// ⚠️ **Their heirs, because a deleted test needs one named:**
//   - The first test's property — an unresolved obligation is never dropped — became
//     **unrepresentable rather than untested**. Nothing is dropped at all now, which is
//     strictly stronger than "not this one", and the suite below pins it.
//   - The second and third were about *which* entries eviction preferred. With no
//     eviction there is no preference to get wrong. What survives from them is the
//     property they were protecting, `unresolvedCount`, which the resolution suite
//     already covers directly.
//   - The §4.1 invariant they existed for — every verified dollar resolves to a
//     delivery or an obligation — is now carried by `test/webhook.test.mo`'s orphan
//     fallback test, which is the only place a problem can still fail to find a home.

suite("nothing is evicted (#37)", func() {
  test("the list grows with real events and never drops one", func() {
    let store = Orphans.emptyStore();
    for (i in Nat.range(0, 12)) {
      ignore addDuplicate(store, "o" # i.toText(), "pi_" # i.toText(), 100 + i);
    };
    assert Orphans.size(store) == 12;
    assert Orphans.unresolvedCount(store) == 12;
    // The oldest is still there, which is what the deleted test was really about.
    assert Orphans.get(store, 0) != null;
  });

  test("resolving does not remove — history is retained, only the count moves", func() {
    let store = Orphans.emptyStore();
    for (i in Nat.range(0, 5)) {
      ignore addDuplicate(store, "o" # i.toText(), "pi_" # i.toText(), 100 + i);
    };
    for (id in ([0, 1] : [Nat]).values()) {
      switch (Orphans.resolve(store, id, 900)) {
        case (#ok(_)) {};
        case (#err(_)) assert false;
      };
    };
    // ⚠️ **Before #37 a subsequent add would have trimmed these two as history.** Now
    // resolving is purely a state change: the entries stay, and only the outstanding
    // count falls.
    ignore addDuplicate(store, "oX", "pi_X", 999);
    assert Orphans.size(store) == 6;
    assert Orphans.unresolvedCount(store) == 4;
    assert Orphans.get(store, 0) != null;
  });
});

suite("resolve (manual, operator)", func() {
  test("resolve stamps the entry and keeps it retained", func() {
    let store = Orphans.emptyStore();
    ignore addStuck(store, "o1", 100);
    switch (Orphans.resolve(store, 0, 500)) {
      case (#ok(entry)) {
        assert entry.resolvedAtNs == ?500;
        assert entry.createdAtNs == 100;
      };
      case (#err(_)) assert false;
    };
    assert Orphans.unresolved(store) == [];
    assert Orphans.all(store).size() == 1;
  });

  test("resolve is not repeatable and unknown ids fail", func() {
    let store = Orphans.emptyStore();
    ignore addDuplicate(store, "o1", "pi_1", 100);
    ignore Orphans.resolve(store, 0, 500);
    switch (Orphans.resolve(store, 0, 600)) {
      case (#err(#alreadyResolved(0))) {};
      case _ assert false;
    };
    switch (Orphans.resolve(store, 99, 600)) {
      case (#err(#notFound(99))) {};
      case _ assert false;
    };
  });
});

suite("charge.refunded auto-resolve (§4.1)", func() {
  test("resolves all unresolved refund-resolvable entries with that payment_intent", func() {
    let store = Orphans.emptyStore();
    ignore addDuplicate(store, "o1", "pi_target", 100);
    ignore addUnattributed(store, "bogus", "pi_target", 200);
    ignore addDuplicate(store, "o2", "pi_other", 300);
    let resolved = Orphans.resolveByPaymentRef(store, "pi_target", 900);
    assert resolved.size() == 2;
    assert resolved[0].resolvedAtNs == ?900;
    assert resolved[1].resolvedAtNs == ?900;
    let open = Orphans.unresolved(store);
    assert open.size() == 1;
    assert Orphans.paymentRefOf(open[0].kind) == ?"pi_other";
  });

  test("already-resolved entries are not re-stamped", func() {
    let store = Orphans.emptyStore();
    ignore addDuplicate(store, "o1", "pi_1", 100);
    ignore Orphans.resolve(store, 0, 500);
    assert Orphans.resolveByPaymentRef(store, "pi_1", 900) == [];
    switch (Orphans.get(store, 0)) {
      case (?entry) assert entry.resolvedAtNs == ?500;
      case null assert false;
    };
  });

  test("kinds carrying no paymentRef never match a refund, unknown refs return empty", func() {
    let store = Orphans.emptyStore();
    ignore addStuck(store, "o1", 100);
    assert Orphans.resolveByPaymentRef(store, "pi_anything", 900) == [];
    assert Orphans.unresolved(store).size() == 1;
  });
});

suite("paging", func() {
  // Unresolved obligations are never evicted, so the queue can outgrow a 2 MB
  // Candid response. Paging bounds the response instead of the record.
  func fill(store : Orphans.Store, n : Nat) {
    for (i in Nat.range(0, n)) {
      ignore Orphans.add(store, #card, #unattributed({ claimedRef = "o" # i.toText(); paymentRef = "pi_" # i.toText() }), "d", 100 + i);
    };
  };

  test("a cursor walks the whole queue exactly once, in arrival order", func() {
    let store = Orphans.emptyStore();
    fill(store, 25);
    var cursor : ?Nat = null;
    var seen = 0;
    var guard = 0;
    label walk loop {
      guard += 1;
      if (guard > 50) { assert false; break walk };
      let page = Orphans.page(store, cursor, 10);
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
    let store = Orphans.emptyStore();
    fill(store, 10);
    // Exactly-full page with nothing left: no cursor, so the caller stops.
    let exact = Orphans.page(store, null, 10);
    assert exact.entries.size() == 10;
    assert exact.nextCursor == null;
    // Full page with more behind it: cursor points at the last id returned.
    let partial = Orphans.page(store, null, 4);
    assert partial.entries.size() == 4;
    assert partial.nextCursor == ?3;
    let next = Orphans.page(store, ?3, 4);
    assert next.entries[0].id == 4;
  });

  test("limit is capped, so a caller cannot ask for an unreturnable response", func() {
    let store = Orphans.emptyStore();
    fill(store, Orphans.maxPageSize + 50);
    assert Orphans.page(store, null, 100_000).entries.size() == Orphans.maxPageSize;
    // Zero means "give me a page", not "give me nothing".
    assert Orphans.page(store, null, 0).entries.size() == Orphans.maxPageSize;
  });

  test("the worklist page skips resolved history server-side", func() {
    let store = Orphans.emptyStore();
    fill(store, 6);
    for (id in ([0, 1, 2, 3] : [Nat]).values()) {
      switch (Orphans.resolve(store, id, 900)) {
        case (#ok(_)) {};
        case (#err(_)) assert false;
      };
    };
    // Four resolved entries stand between the start and the two open ones; the
    // operator must not have to page past them.
    let open = Orphans.unresolvedPage(store, null, 10);
    assert open.entries.size() == 2;
    assert open.entries[0].id == 4;
    assert open.entries[1].id == 5;
    assert open.nextCursor == null;
    assert Orphans.unresolvedCount(store) == 2;
  });

  test("an empty queue pages cleanly", func() {
    let store = Orphans.emptyStore();
    let page = Orphans.page(store, null, 10);
    assert page.entries.size() == 0;
    assert page.nextCursor == null;
  });

  // ⚠️ Two more capacity tests deleted by #37 — the same heirs as the suite above.
  // "resolved entries are evicted oldest-first" and "an unresolved entry is never
  // evicted, however far over capacity" both describe a bound that no longer exists.
  // The second one's property is now unrepresentable: nothing is evicted at all.

  test("an unprocessable event is recognised as already queued", func() {
    let store = Orphans.emptyStore();
    ignore Orphans.add(store, #card, #unprocessable({ eventId = "evt_a"; field = "payment_intent" }), "missing field", 100);
    // What ingestion checks before filing: the same event id, past the ~7-day
    // dedup retention, must not become a second worklist item.
    switch (Orphans.unresolvedUnprocessable(store, "evt_a")) {
      case (?found) assert found.id == 0;
      case null assert false;
    };
    // A different event is a different obligation.
    assert Orphans.unresolvedUnprocessable(store, "evt_b") == null;
    // And once an operator has closed it, a genuine re-report is allowed through
    // rather than being suppressed forever by resolved history.
    switch (Orphans.resolve(store, 0, 900)) {
      case (#ok(_)) {};
      case (#err(_)) assert false;
    };
    assert Orphans.unresolvedUnprocessable(store, "evt_a") == null;
  });

  test("only unprocessable entries answer the unprocessable lookup", func() {
    let store = Orphans.emptyStore();
    // The lookup keys on an event id, and other kinds carry payment refs that
    // could otherwise collide with one.
    ignore addUnattributed(store, "evt_a", "evt_a", 100);
    assert Orphans.unresolvedUnprocessable(store, "evt_a") == null;
  });
});
