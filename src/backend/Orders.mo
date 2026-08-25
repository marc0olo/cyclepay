/// Order store + the §4 state machine.
///
/// The state machine owns *transitions only*. Expiry policy, float checks,
/// dedup, and delivery are the callers' business (per-rail money-in, §5
/// money-out) — they ask for a transition and this module answers whether it
/// is legal. Seam §11.1.3: `create` takes the owner as a parameter and never
/// reads a caller itself; owners come from an II Candid call,
/// a future Base owner from a verified EIP-3009 signature.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import List "mo:core/List";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Result "mo:core/Result";
import Types "Types";
import Util "Util";

module {

  /// 128 bits of raw_rand entropy per order ID (§2: random, not a counter —
  /// the ID is public inside `client_reference_id`, so it must not leak
  /// order volume or be enumerable; it is NOT a bearer secret).
  public let idEntropyBytes : Nat = 16;

  /// Derive an order ID (32 lowercase hex chars) from the first
  /// `idEntropyBytes` of a raw_rand blob; null if the entropy is too short
  /// (raw_rand returns 32 bytes, so null means a broken caller, not bad luck).
  public func idFromEntropy(entropy : Blob) : ?Types.OrderId {
    if (entropy.size() < idEntropyBytes) return null;
    let prefix = entropy.toArray().sliceToArray(0, idEntropyBytes);
    ?Util.hexEncode(Blob.fromArray(prefix));
  };

  /// §6.1 — the value carried on the tier's Payment Link URL:
  /// `<principal>_<orderId>`. Unambiguous to split: principal text is
  /// `[a-z0-9-]`, the ID is hex, so the one `_` is the separator. Claimed,
  /// not trusted — webhook ingestion re-resolves and verifies it.
  public func clientReferenceId(owner : Types.Owner, id : Types.OrderId) : Text {
    switch (owner) {
      case (#ii(p)) p.toText() # "_" # id;
    };
  };

  /// Inverse of `clientReferenceId`, claimed-not-trusted (§4.1: it is an
  /// attacker-editable URL param). Returns the *claimed* owner principal
  /// text and order ID — the caller must verify both against the stored
  /// order; null on any shape deviation. Principal text is compared as
  /// text, never `Principal.fromText`-ed: that traps on garbage, and a
  /// trapped webhook is a 5xx Stripe retries forever.
  public func parseClientReferenceId(ref : Text) : ?(Text, Types.OrderId) {
    let parts = ref.split(#char '_').toArray();
    if (parts.size() != 2) return null;
    if (parts[0] == "") return null;
    if (parts[1].size() != idEntropyBytes * 2) return null;
    for (c in parts[1].chars()) {
      if (not ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return null;
    };
    ?(parts[0], parts[1]);
  };

  public type Store = {
    /// §4.2 — `orders : Map<OrderId, Order>`.
    orders : Map.Map<Types.OrderId, Types.Order>;
    /// §4.2 — order history per principal (fixes the lost-receipt problem).
    principalsToOrders : Map.Map<Principal, List.List<Types.OrderId>>;
    /// Live per-status tallies, maintained by `create` / `applyTransition` /
    /// `markPaid` — the only three functions that write an order's status.
    ///
    /// These exist so the public status queries are O(1). Counting by scanning
    /// `orders` makes an unauthenticated query cost O(total orders), which is
    /// an operation that is free for anyone to invoke and grows more expensive
    /// forever — the shape of DoS the security guidance warns about.
    ///
    /// Only the statuses the queries report are tracked; `countOf` returns 0
    /// for the rest. `recount` rebuilds them if they are ever suspected wrong.
    counts : Map.Map<Text, Nat>;
  };

  public func emptyStore() : Store {
    {
      orders = Map.empty<Types.OrderId, Types.Order>();
      principalsToOrders = Map.empty<Principal, List.List<Types.OrderId>>();
      counts = Map.empty<Text, Nat>();
    };
  };

  /// Statuses whose live counts are maintained. Keyed by `statusToText` so the
  /// map is a shared type and the key set is self-documenting.
  ///
  /// `#cancelled`, `#needsReview` and `#abandoned` are deliberately absent, as
  /// `#delivered` and the old `#errorQueue` were: a status earns an O(1) tally
  /// only when something reads it. Nothing counts these — `countOf` returns 0
  /// and `reconcile` leaves them alone. #30 adds `#needsReview` if its promise
  /// tally needs the count.
  let trackedStatuses : [Types.OrderStatus] = [#created, #expired, #paid, #minting, #icpAtCmc, #awaitingTreasury];

  func isTracked(status : Types.OrderStatus) : Bool {
    for (tracked in trackedStatuses.values()) {
      if (tracked == status) return true;
    };
    false;
  };

  func bump(store : Store, status : Types.OrderStatus, delta : Int) {
    if (not isTracked(status)) return;
    let key = Types.statusToText(status);
    let current = switch (store.counts.get(key)) { case (?n) n; case null 0 };
    let next : Int = current + delta;
    // Clamp at zero rather than trapping: a miscount must never be able to
    // break the money path, and `recount` is the repair lever.
    store.counts.add(key, if (next < 0) 0 else Int.abs(next));
  };

  /// Live count for a tracked status; 0 for anything untracked.
  public func countOf(store : Store, status : Types.OrderStatus) : Nat {
    switch (store.counts.get(Types.statusToText(status))) {
      case (?n) n;
      case null 0;
    };
  };

  /// Every tracked status paired with its current tally, in `trackedStatuses`
  /// order — so two snapshots can be compared index-by-index.
  func snapshotCounts(store : Store) : [(Text, Nat)] {
    let out = List.empty<(Text, Nat)>();
    for (status in trackedStatuses.values()) {
      out.add((Types.statusToText(status), countOf(store, status)));
    };
    out.toArray();
  };

  /// A tracked count that did not match the order store: what it said, and what
  /// the orders actually add up to.
  public type Drift = { status : Text; was : Nat; is : Nat };

  /// Rebuild every tracked count from `orders` — the O(n) reconciliation path.
  ///
  /// Returns the rebuilt counts **and** every count that had to move. The drift
  /// list is the point: `bump` clamps at zero and the counts feed the admission
  /// gate, so a repair that silently succeeded would hide the very bug that made
  /// it necessary. A caller that reports nothing on empty drift and reports the
  /// deltas otherwise turns this from a repair into a detector.
  public func reconcile(store : Store) : { counts : [(Text, Nat)]; drift : [Drift] } {
    let before = snapshotCounts(store);
    for (status in trackedStatuses.values()) {
      store.counts.add(Types.statusToText(status), 0);
    };
    for ((_, order) in store.orders.entries()) {
      bump(store, order.status, 1);
    };
    let counts = snapshotCounts(store);
    let drift = List.empty<Drift>();
    for (i in before.keys()) {
      let (status, was) = before[i];
      let (_, is_) = counts[i];
      if (was != is_) drift.add({ status; was; is = is_ });
    };
    { counts; drift = drift.toArray() };
  };

  /// Counts-only form of `reconcile`, for callers that report the tallies rather
  /// than the drift.
  public func recount(store : Store) : [(Text, Nat)] {
    reconcile(store).counts;
  };

  public type CreateError = {
    /// raw_rand collision (astronomically unlikely) — caller retries with
    /// fresh randomness rather than silently overwriting an order.
    #duplicateId : Types.OrderId;
  };

  public type TransitionError = {
    #notFound : Types.OrderId;
    #illegalTransition : { from : Types.OrderStatus; to : Types.OrderStatus };
  };

  /// The §4 diagram plus the escalation edges it implies, all of which land in
  /// `#needsReview` — the order still owes cycles, so its promise stays held.
  ///
  /// **The terminal set is `#delivered`, `#cancelled`, `#expired`, `#abandoned`.**
  /// Resolving an error-queue *entry* is human and off-chain (§4.1) and never
  /// transitions an order; `abandon_order` is the only thing that ends one, and
  /// `#needsReview → #abandoned` is its single outgoing edge.
  ///
  /// ⚠️ **Two guards mirror this matrix and the compiler checks neither**:
  /// `Card.handleWebhook`'s status switch and `attach_payment`'s. Both feed
  /// `markPaid`, so anything they admit that this refuses is a bug — a trap on the
  /// webhook path, an internal blob on the admin one. Change this and check both.
  public func isLegalTransition(from : Types.OrderStatus, to : Types.OrderStatus) : Bool {
    switch (from, to) {
      case (#created, #cancelled) true; // the buyer gave up before paying (#34)
      case (#created, #expired) true; // never paid (§4)
      case (#created, #paid) true; // webhook verified, deduped, amount honored
      case (#paid, #minting) true; // ICP float sufficient
      case (#paid, #awaitingTreasury) true; // float short (§5.3)
      case (#paid, #needsReview) true; // paid but unable to mint past max wait (§5)
      case (#awaitingTreasury, #minting) true; // float refilled
      case (#awaitingTreasury, #needsReview) true; // max-wait exceeded (§5.3)
      case (#minting, #icpAtCmc) true; // block_index recorded (§5)
      case (#minting, #needsReview) true; // intent aged past dedup window (§5.1)
      case (#icpAtCmc, #delivered) true; // notify + forward succeeded
      case (#icpAtCmc, #needsReview) true; // forward failed → Type 2 (§4.1)
      // `abandon_order` — the operator ends it, having refunded by hand. The
      // #needsReview edge is what the #errorQueue split made possible: an
      // escalated order could not previously be abandoned, because one status
      // meant both "promise held" and "promise released".
      case (#paid, #abandoned) true;
      case (#awaitingTreasury, #abandoned) true;
      case (#needsReview, #abandoned) true;
      case _ false;
    };
  };

  /// Pure transition: legal → updated copy, illegal → error. Callers decide
  /// *when* to ask (expiry timers, float checks); this decides *whether*.
  public func transition(
    order : Types.Order,
    to : Types.OrderStatus,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    if (isLegalTransition(order.status, to)) {
      #ok({ order with status = to; updatedAtNs = nowNs });
    } else {
      #err(#illegalTransition({ from = order.status; to }));
    };
  };

  /// Create an order in `#created`, locking the cycle quantity (§3). Owner is
  /// a parameter, never a caller read (seam §11.1.3).
  public func create(
    store : Store,
    id : Types.OrderId,
    owner : Types.Owner,
    rail : Types.Rail,
    destination : Types.Destination,
    lockedCycles : Nat,
    pricing : Types.Pricing,
    nowNs : Int,
  ) : Result.Result<Types.Order, CreateError> {
    if (store.orders.containsKey(id)) {
      return #err(#duplicateId(id));
    };
    let order : Types.Order = {
      id;
      owner;
      rail;
      destination;
      lockedCycles;
      pricing;
      status = #created;
      paidUsdCents = null;
      // All four are the session's, and no session exists yet: #33 stamps them
      // from the Checkout Session it creates. `expiredBy` stays null unless the
      // order reaches `#expired` with a known cause.
      expiredBy = null;
      expiresAtNs = null;
      stripeSessionId = null;
      stripeSessionUrl = null;
      createdAtNs = nowNs;
      updatedAtNs = nowNs;
    };
    store.orders.add(id, order);
    bump(store, #created, 1);
    let principal = switch (owner) { case (#ii(p)) p };
    switch (store.principalsToOrders.get(principal)) {
      case (?ids) ids.add(id);
      case null {
        let ids = List.empty<Types.OrderId>();
        ids.add(id);
        store.principalsToOrders.add(principal, ids);
      };
    };
    #ok(order);
  };

  /// Look up, validate, and persist a transition in one step.
  public func applyTransition(
    store : Store,
    id : Types.OrderId,
    to : Types.OrderStatus,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        switch (transition(order, to, nowNs)) {
          case (#ok(updated)) {
            store.orders.add(id, updated);
            bump(store, order.status, -1);
            bump(store, updated.status, 1);
            #ok(updated);
          };
          case (#err(e)) #err(e);
        };
      };
    };
  };

  /// Webhook money-in (§6.1): `#created → #paid`, and only that. #34 deleted the
  /// `#expired` edge, so this REFUSES an order that stopped being payable.
  ///
  /// ⚠️ Two callers guard the status before reaching here — `Card.handleWebhook`
  /// and `attach_payment` — and `-Werror` checks neither against the matrix. The
  /// webhook one **traps** on this error rather than swallowing it, so a guard that
  /// drifts open is a 5xx Stripe retries for ~3 days rather than a silent mint.
  ///
  /// `honoredCycles` replaces the locked quantity (equal to it when the paid
  /// amount matches the quote, repriced from the order's own snapshot when it
  /// does not), and `paidUsdCents` records what actually arrived.
  public func markPaid(
    store : Store,
    id : Types.OrderId,
    honoredCycles : Nat,
    paidUsdCents : Nat,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        switch (transition(order, #paid, nowNs)) {
          case (#ok(updated)) {
            let paid = { updated with lockedCycles = honoredCycles; paidUsdCents = ?paidUsdCents };
            store.orders.add(id, paid);
            // markPaid writes status directly rather than going through
            // applyTransition, so it maintains the counts itself.
            bump(store, order.status, -1);
            bump(store, paid.status, 1);
            #ok(paid);
          };
          case (#err(e)) #err(e);
        };
      };
    };
  };

  public func get(store : Store, id : Types.OrderId) : ?Types.Order {
    store.orders.get(id);
  };

  /// Count of this principal's still-open (`#created`) orders — the input to
  /// the `Gate` admission cap. Only `#created` counts: an `#expired` order is
  /// abandoned (it costs the principal nothing to leave lying around, but it is
  /// also on its way to being swept), and anything past `#paid` is a record of
  /// money, not an open slot.
  public func openOrderCount(store : Store, caller : Principal) : Nat {
    switch (store.principalsToOrders.get(caller)) {
      case null 0;
      case (?ids) {
        var open = 0;
        for (id in ids.values()) {
          switch (store.orders.get(id)) {
            case (?order) { if (order.status == #created) open += 1 };
            case null {}; // id indexed without a record — cannot happen
          };
        };
        open;
      };
    };
  };

  /// Every order id in the store, materialised so a caller can mutate the store
  /// while iterating (the retention sweep transitions orders as it goes, which
  /// would otherwise invalidate a live iterator).
  public func allIds(store : Store) : [Types.OrderId] {
    store.orders.keys().toArray();
  };

  /// Up to `limit` ids at or after `afterId` in key order, for a resumable scan.
  ///
  /// Exists so the retention sweep costs O(limit) per tick instead of O(all
  /// orders): `allIds` materialises the whole key set into an array, which grows
  /// forever because orders are never deleted, so a bounded *scan* over an
  /// unbounded *materialisation* still gets more expensive every tick.
  ///
  /// The cursor is an order id rather than an index. An index into a snapshot is
  /// meaningless across ticks — inserts shift everything after them, so a
  /// positional cursor silently skips and re-scans. Keys are stable, so
  /// resuming from one visits every order exactly once per pass.
  public func idsFrom(store : Store, afterId : ?Types.OrderId, limit : Nat) : [Types.OrderId] {
    let out = List.empty<Types.OrderId>();
    let iter = switch (afterId) {
      case (?id) store.orders.entriesFrom(id);
      case null store.orders.entries();
    };
    for ((id, _) in iter) {
      // entriesFrom is inclusive; the cursor is the last id already handled.
      if (afterId == ?id) continue;
      if (out.size() >= limit) return out.toArray();
      out.add(id);
    };
    out.toArray();
  };

  /// Authz-guarded lookup for the user API: `caller == order.owner` (§2).
  public func getOwned(store : Store, id : Types.OrderId, caller : Principal) : ?Types.Order {
    switch (store.orders.get(id)) {
      case (?order) {
        if (Types.isOwnedBy(order.owner, caller)) ?order else null;
      };
      case null null;
    };
  };

  /// Order history for a principal, newest-last (insertion order).
  public func ordersFor(store : Store, caller : Principal) : [Types.Order] {
    switch (store.principalsToOrders.get(caller)) {
      case null [];
      case (?ids) {
        ids.values().filterMap<Types.OrderId, Types.Order>(func(id) = store.orders.get(id)).toArray();
      };
    };
  };

};
