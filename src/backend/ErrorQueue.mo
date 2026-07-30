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
import Text "mo:core/Text";
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
    /// §5.1/§5.3/§6.2 escalation — a money pipeline stopped where it cannot
    /// continue automatically (stale mint intent whose transfer fate is
    /// unknowable, a CMC rejection/refund, an ambiguous forward, a treasury
    /// hold past its max wait — there the position is certain: fiat in,
    /// nothing minted — or a ck-USDC pull intent aged past the ledger dedup
    /// window). Neither Type 1 nor Type 2: the operator inspects the
    /// ledger/CMC/destination, then refunds or re-delivers manually.
    /// `stage` = Cmc.EscalateReason text, "treasuryWaitExceeded", or
    /// "stalePullIntent".
    #stuckMint : { orderId : Types.OrderId; stage : Text };
    /// Neither Type 1 nor Type 2 — the money moved *both* ways. A
    /// `charge.refunded` arrived for a payment that had already been delivered
    /// as cycles, so the fiat went back to the payer and the cycles are
    /// irreversibly gone to an arbitrary destination. **Not automatically
    /// resolvable and not automatically preventable**: the canister cannot claw
    /// cycles back, so this records a loss for the operator to reconcile rather
    /// than starting a recovery flow.
    ///
    /// Chargeback *prevention* belongs in Stripe (Radar rules, 3DS) and in the
    /// `Gate` per-purchase ceiling, not in Motoko.
    #refundAfterDelivery : { orderId : Types.OrderId; paymentRef : Text; cycles : Nat };
  };

  public func isType1(kind : Kind) : Bool {
    switch (kind) {
      case (#duplicate(_) or #unattributed(_)) true;
      case (#undeliverable(_) or #stuckMint(_) or #refundAfterDelivery(_)) false;
    };
  };

  /// Bound on attacker-supplied text stored in an entry. `claimedRef` comes
  /// straight off a URL parameter, so without a cap an attacker could stuff
  /// arbitrary data into admin-visible stable state one webhook at a time
  /// (`canister-security`: validate input sizes). Long enough for a legitimate
  /// `<principal>_<orderId>` (≈ 63 + 1 + 32) with room to show what was sent.
  public let maxClaimedRefBytes : Nat = 128;

  public func truncateClaimedRef(claimedRef : Text) : Text {
    if (claimedRef.size() <= maxClaimedRefBytes) return claimedRef;
    Text.fromIter(claimedRef.chars().take(maxClaimedRefBytes)) # "…(truncated)";
  };

  /// The payment reference a `charge.refunded` resolves — Type 1 only.
  /// (`#stuckMint` carries no paymentRef: the order store doesn't retain the
  /// payment_intent, and a refund alone doesn't settle an uncertain mint.)
  public func paymentRefOf(kind : Kind) : ?Text {
    switch (kind) {
      case (#duplicate({ paymentRef; orderId = _ })) ?paymentRef;
      case (#unattributed({ paymentRef; claimedRef = _ })) ?paymentRef;
      // #refundAfterDelivery carries a paymentRef but must NOT be reachable
      // from `resolveByPaymentRef`: the refund is what created the entry, so
      // auto-resolving on it would close the loss the instant it was recorded.
      // Only a human closes this one.
      case (#undeliverable(_) or #stuckMint(_) or #refundAfterDelivery(_)) null;
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
    /// Evicted to honour the bound. **Only resolved entries are ever evicted.**
    ///
    /// An unresolved entry is a live money obligation: a dollar arrived and has
    /// not yet been dealt with. Dropping one breaks the §4.1 invariant that
    /// every verified dollar resolves to delivery, Type 1, or Type 2 — and it
    /// breaks it silently, because the only trace would be an audit line in a
    /// ring buffer that itself drops.
    ///
    /// So the queue grows past `capacity` rather than forgetting an obligation.
    /// That is safe in a way unbounded *order* growth is not: every unresolved
    /// entry requires a real payment to exist, so growth costs an attacker
    /// actual money per entry. `unresolvedCount` is the number to watch.
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
    // Trim only *resolved* history. If nothing resolved is left to drop, the
    // queue exceeds capacity and stays that way until the operator works it
    // down — a visibly growing worklist is strictly better than a forgotten
    // obligation.
    label trim while (store.entries.size() > capacity) {
      switch (oldestResolved(store)) {
        case (?victim) {
          store.entries.remove(victim.id);
          evicted.add(victim);
        };
        case null break trim;
      };
    };
    { entry; evicted = evicted.toArray() };
  };

  /// Oldest *resolved* entry, or null when none is resolved. Scans oldest-first
  /// (ids are monotonic, so the map iterates in arrival order).
  func oldestResolved(store : Store) : ?Entry {
    for ((_, entry) in store.entries.entries()) {
      if (entry.resolvedAtNs != null) return ?entry;
    };
    null;
  };

  /// Live obligations. The operator's worklist depth, and the number that must
  /// not be allowed to grow unbounded — not because state is precious, but
  /// because each one is money someone is owed an answer about.
  public func unresolvedCount(store : Store) : Nat {
    var open = 0;
    for ((_, entry) in store.entries.entries()) {
      if (entry.resolvedAtNs == null) open += 1;
    };
    open;
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
