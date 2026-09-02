import { suite; test } "mo:test";
import Map "mo:core/Map";
import Set "mo:core/Set";
import Iter "mo:core/Iter";
import Text "mo:core/Text";

// ⚠️ **A DEPENDENCY-CONTRACT test. It covers no logic this project wrote.** It guards a
// `mo:core` version bump (mops pins 2.5.0) and nothing else — read as coverage of #70's
// cursor correctness it would be three green assertions about someone else's library.
// #70's own properties are pinned in `test/orders.test.mo` under `ownerPage`.
//
// What it pins: `Orders.ownerPage` walks a `Set<OrderId>` with a cursor that
// `Orders.page` produces by walking a `Map<OrderId, Order>`, so the two structures must
// order identically and `valuesFrom` must align with `entriesFrom`.
//
// ⚠️ **The guarantee comes from the type, not from the id format.** Every construction in
// `Orders.mo` is `Map.empty<Types.OrderId, _>()` / `Set.empty<Types.OrderId>()` with no
// explicit comparator, so the ordering is derived from `OrderId` and the two cannot
// disagree; `>` on `Text` is that same order. Ids also happen to be fixed-length
// lowercase hex, which is true and is NOT what makes this safe — recording it as the
// reason would suggest changing the id encoding is dangerous when it is not.
suite("Set and Map agree on OrderId order", func() {
  let ids = [
    "ffffffffffffffffffffffffffffffff",
    "00000000000000000000000000000000",
    "9f3a0000000000000000000000000000",
    "a03b0000000000000000000000000000",
    "0f000000000000000000000000000000",
    "f0000000000000000000000000000000",
  ];

  test("iteration order is identical", func() {
    let m = Map.empty<Text, Nat>();
    let s = Set.empty<Text>();
    for (i in ids.keys()) {
      m.add(ids[i], i);
      s.add(ids[i]);
    };
    let mk = m.keys().toArray();
    let sk = s.values().toArray();
    assert mk.size() == ids.size();
    assert sk.size() == ids.size();
    for (i in mk.keys()) { assert mk[i] == sk[i] };
  });

  test("valuesFrom and entriesFrom seek to the same place, inclusively", func() {
    let m = Map.empty<Text, Nat>();
    let s = Set.empty<Text>();
    for (i in ids.keys()) { m.add(ids[i], i); s.add(ids[i]) };
    let cursor = "9f3a0000000000000000000000000000";
    let mk = m.entriesFrom(cursor).map<(Text, Nat), Text>(func((k, _)) = k).toArray();
    let sk = s.valuesFrom(cursor).toArray();
    assert mk.size() == sk.size();
    for (i in mk.keys()) { assert mk[i] == sk[i] };
    // Inclusive on both, which is why the caller still needs `id > cursor`.
    assert mk[0] == cursor;
    assert sk[0] == cursor;
  });

  test("Motoko's `>` on Text agrees with the collections' order", func() {
    let s = Set.empty<Text>();
    for (i in ids.keys()) { s.add(ids[i]) };
    let sorted = s.values().toArray();
    var i = 1;
    while (i < sorted.size()) {
      assert sorted[i] > sorted[i - 1];
      i += 1;
    };
  });
});
