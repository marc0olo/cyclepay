/// Bounded error queue — exactly two types (§4.1).
///
/// Every dollar that arrives must resolve to delivery, Type 1, or Type 2.
/// Type 1 (`#duplicate` | `#unattributed`): fiat exists, nothing was minted
/// (dedup gates the mint). Resolution is the operator refunding in the Stripe
/// Dashboard; the `charge.refunded` webhook auto-resolves via
/// `resolveByPaymentRef`. Type 2 (`#undeliverable`): cycles were minted but
/// delivery failed — they sit in the app canister's own balance until the
/// operator refunds or re-delivers.
///
/// Resolution lives on the queue entry, not the order: `#errorQueue` is a
/// terminal order status (§4), and resolving here never transitions an order.
import Map "mo:core/Map";
import List "mo:core/List";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Types "Types";

module {

  /// §4.1 — the payloads make the two types structural: Type 1 always carries
  /// the Stripe `payment_intent` (`paymentRef`) that a refund resolves;
  /// Type 2 always carries the stranded cycle quantity.
  public type Kind = {
    /// Type 1 — genuine 2nd/distinct payment for an already-handled order.
    #duplicate : { orderId : Types.OrderId; paymentRef : Text };
    /// Type 1 — `client_reference_id` resolved to no order (claimed, not
    /// trusted: it is an attacker-editable URL param).
    #unattributed : { claimedRef : Text; paymentRef : Text };
    /// Type 2 — minted, but forward failed (e.g. target canister deleted).
    #undeliverable : { orderId : Types.OrderId; cycles : Nat };
  };

  public func isType1(kind : Kind) : Bool {
    switch (kind) {
      case (#duplicate(_) or #unattributed(_)) true;
      case (#undeliverable(_)) false;
    };
  };

  /// The payment reference a `charge.refunded` resolves — Type 1 only.
  public func paymentRefOf(kind : Kind) : ?Text {
    switch (kind) {
      case (#duplicate({ paymentRef; orderId = _ })) ?paymentRef;
      case (#unattributed({ paymentRef; claimedRef = _ })) ?paymentRef;
      case (#undeliverable(_)) null;
    };
  };

  public type Entry = {
    /// Monotonic — doubles as arrival order for bounded eviction.
    id : Nat;
    rail : Types.Rail;
    kind : Kind;
    detail : Text;
    createdAtNs : Int;
    resolvedAtNs : ?Int;
  };

  public type Store = {
    /// Keyed by monotonic id → `entries()` iterates oldest-first.
    entries : Map.Map<Nat, Entry>;
    var nextId : Nat;
  };

  public func emptyStore() : Store {
    { entries = Map.empty<Nat, Entry>(); var nextId = 0 };
  };

  public type AddResult = {
    entry : Entry;
    /// Evicted to honor the bound — oldest resolved first; only when nothing
    /// is resolved does the oldest *unresolved* entry go (the bound exists so
    /// spammed unattributed payments can't grow state without limit). The
    /// caller must audit-log unresolved evictions: each is a live money
    /// obligation dropped from on-chain state.
    evicted : [Entry];
  };

  /// Append an entry, evicting past `capacity` (see `AddResult.evicted`).
  public func add(
    store : Store,
    capacity : Nat,
    rail : Types.Rail,
    kind : Kind,
    detail : Text,
    nowNs : Int,
  ) : AddResult {
    let entry : Entry = {
      id = store.nextId;
      rail;
      kind;
      detail;
      createdAtNs = nowNs;
      resolvedAtNs = null;
    };
    store.nextId += 1;
    store.entries.add(entry.id, entry);
    let evicted = List.empty<Entry>();
    while (store.entries.size() > capacity) {
      switch (oldestPreferResolved(store)) {
        case (?victim) {
          store.entries.remove(victim.id);
          evicted.add(victim);
        };
        case null {}; // unreachable: size > capacity ≥ 0 means non-empty
      };
    };
    { entry; evicted = evicted.toArray() };
  };

  /// Eviction victim: oldest resolved entry, else oldest entry outright.
  /// Scans oldest-first (ids are monotonic, the map iterates in key order).
  func oldestPreferResolved(store : Store) : ?Entry {
    var oldest : ?Entry = null;
    for ((_, entry) in store.entries.entries()) {
      switch (entry.resolvedAtNs) {
        case (?_) return ?entry;
        case null { if (oldest == null) oldest := ?entry };
      };
    };
    oldest;
  };

  public type ResolveError = { #notFound : Nat; #alreadyResolved : Nat };

  /// Manual operator resolution (refund issued / cycles re-delivered).
  public func resolve(store : Store, id : Nat, nowNs : Int) : Result.Result<Entry, ResolveError> {
    switch (store.entries.get(id)) {
      case null #err(#notFound(id));
      case (?entry) {
        switch (entry.resolvedAtNs) {
          case (?_) #err(#alreadyResolved(id));
          case null {
            let updated = { entry with resolvedAtNs = ?nowNs };
            store.entries.add(id, updated);
            #ok(updated);
          };
        };
      };
    };
  };

  /// `charge.refunded` auto-resolve (§4.1): marks every unresolved Type 1
  /// entry carrying this `payment_intent` resolved; returns them. Type 2
  /// entries never match (no paymentRef) — minted cycles are not a refund's
  /// business. Empty result = refund for something not in the queue (fine:
  /// operators may refund proactively).
  public func resolveByPaymentRef(store : Store, paymentRef : Text, nowNs : Int) : [Entry] {
    let matches = store.entries.values().filter(
      func(e) = e.resolvedAtNs == null and paymentRefOf(e.kind) == ?paymentRef
    ).toArray();
    let resolved = List.empty<Entry>();
    for (entry in matches.values()) {
      let updated = { entry with resolvedAtNs = ?nowNs };
      store.entries.add(entry.id, updated);
      resolved.add(updated);
    };
    resolved.toArray();
  };

  public func get(store : Store, id : Nat) : ?Entry {
    store.entries.get(id);
  };

  /// Open obligations, oldest first — the operator's worklist.
  public func unresolved(store : Store) : [Entry] {
    store.entries.values().filter(func(e) = e.resolvedAtNs == null).toArray();
  };

  /// Everything still retained (resolved entries stay until evicted), oldest
  /// first.
  public func all(store : Store) : [Entry] {
    store.entries.values().toArray();
  };

  public func size(store : Store) : Nat {
    store.entries.size();
  };

};
