/// Bounded error queue (§4.1).
///
/// Every dollar that arrives resolves to delivery, or to an obligation on this
/// worklist. There is no third outcome and no silent one.
///
/// ⚠️ **Only fiat can be stranded, never cycles.** Delivery is one transfer out of a
/// reserve the gateway already holds, so a failed delivery leaves the cycles exactly
/// where they were and the order retries. That is what makes the taxonomy one-sided:
/// every obligation here is *money we took and have not delivered against*, and the
/// remedy is always either finishing the delivery or refunding in Stripe.
///
/// Two shapes, and `refundResolvable` is the predicate that separates them:
///
///   - **Fiat with no order to credit** (`#duplicate`, `#unattributed`) — the remedy
///     is a Stripe refund, and the `charge.refunded` webhook auto-resolves the entry
///     through `resolveByPaymentRef`. Nothing on-chain is owed.
///   - **Everything else** — a delivery a human must look at (`#deliveryStuck`), a
///     refund that arrived after delivery (`#refundAfterDelivery`), an alert
///     (`#deliveryDelayed`), an operator's decision (`#abandoned`), or an event that
///     could not be parsed (`#unprocessable`). A refund cannot resolve these: either
///     the position is unknown, or money moved both ways, or nothing is owed yet.
///
/// ⚠️ **Resolution lives on the queue entry, never on the order.** Resolving here does
/// not transition anything: an order's status says where the *order* got to, and a
/// queue entry says what the *operator* still owes. One order can outlive several
/// entries, and an entry can name no order at all (`#unattributed`). The two exits
/// that do move an order are `abandon_order` and `record_delivered`, both explicit.
import Map "mo:core/Map";
import Int "mo:core/Int";
import List "mo:core/List";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Types "Types";

module {

  /// §4.1 — **`refundResolvable` and `paymentRefOf` are one property seen from two
  /// sides**, and `test/errorqueue.test.mo` pins their agreement across all seven
  /// kinds: a refund can settle an entry exactly when `paymentRefOf` gives
  /// `resolveByPaymentRef` something to match on.
  ///
  /// ⚠️ **That is the accessor, not the payload.** `#refundAfterDelivery` carries a
  /// `paymentRef` field and `paymentRefOf` returns null for it deliberately — the
  /// refund is what created the entry, so matching on it would close the recorded loss
  /// the instant it was recorded.
  ///
  /// ⚠️ **No kind carries a stranded cycle quantity, because cycles cannot strand.**
  /// `#refundAfterDelivery.cycles` is the opposite case — cycles that *were*
  /// delivered, recorded as an operator loss.
  public type Kind = {
    /// Refund-resolvable — a genuine 2nd/distinct payment for an already-handled
    /// order.
    #duplicate : { orderId : Types.OrderId; paymentRef : Text };
    /// Refund-resolvable — the payment could not be attributed to an order that can accept
    /// it: `client_reference_id` resolved to no order (claimed, not trusted — it
    /// is an attacker-editable URL param), or it resolved to an order that is
    /// `#cancelled` or `#expired`, neither of which is payable.
    #unattributed : { claimedRef : Text; paymentRef : Text };
    /// **A delivery stopped somewhere it cannot continue automatically.** Not
    /// refund-resolvable: the fiat is in, and what happens next depends on the money
    /// position rather than on the reason it stopped.
    ///
    /// ⚠️ **`stage` IS the money position, and it is what the operator acts on.**
    /// `Delivery.terminationFor` derives it from the **journal**, not the status, because
    /// one status covers several positions:
    ///
    ///   - `staleIntent` — a transfer was issued, no block was recorded, and the
    ///     intent is past the ledger's ~24 h dedup window. **Unknown**: the question
    ///     is *"did this transfer land?"*, answerable on the cycles ledger by the
    ///     order id in the transfer's memo. Never "should we refund?" — refunding a
    ///     buyer who already holds the cycles pays twice.
    ///   - `deliveryWaitExceeded` — the 72 h bound on an order where **nothing was
    ///     ever sent**. **Certain**: fiat in, nothing moved, refund in the Stripe
    ///     Dashboard.
    ///   - `transferRejected` / `journalInconsistent` — the ledger refused this call
    ///     definitively, or the intent contradicts the order. Establish the fate
    ///     before re-sending.
    ///
    /// ⚠️ **`stage` is a stringly-typed discriminator, and it must stay advisory.**
    /// It is safe only because the **journal is the authority** — `terminationFor`
    /// reads it to *produce* this string, and the operator's triage table is the only
    /// consumer. **Never branch a money decision on comparing it.** If code ever needs
    /// to distinguish the positions, it should ask the journal the same way
    /// `terminationFor` does, or the string should become a variant first.
    ///
    /// ⚠️ **One kind, not two.** Splitting "did it land?" from "nothing was sent" into
    /// separate kinds puts one operator question behind two names, and leaves whichever
    /// kind is narrower unable to carry the other position. `blockIndex` is present
    /// only in the should-be-unreachable case where the transfer is known to have
    /// landed and the order never moved — it arrives with the entry so the operator
    /// does not have to fetch the journal to start looking.
    #deliveryStuck : { orderId : Types.OrderId; stage : Text; blockIndex : ?Nat };
    /// Not refund-resolvable — the money moved *both* ways. A
    /// `charge.refunded` arrived for a payment that had already been delivered
    /// as cycles, so the fiat went back to the payer and the cycles are
    /// irreversibly gone to an arbitrary destination. **Not automatically
    /// resolvable and not automatically preventable**: the canister cannot claw
    /// cycles back, so this records a loss for the operator to reconcile rather
    /// than starting a recovery flow.
    ///
    /// Chargeback *prevention* belongs in Stripe (Radar rules, 3DS) and in the
    /// `Gate` per-purchase ceiling, not in Motoko.
    #refundAfterDelivery : {
      orderId : Types.OrderId;
      paymentRef : Text;
      cycles : Nat;
      /// Cumulative cents returned to the payer. Sized, because a partial
      /// refund is a partial loss and the operator reconciles against Stripe by
      /// amount, not by the existence of an entry.
      refundedCents : Nat;
      /// Whether that settled the whole charge.
      fullRefund : Bool;
    };
    /// **An alert, not a failure.** Money is in and delivery has not happened yet
    /// for a reason that is always operator-fixable: the reserve is short, or the
    /// cycles ledger is unreachable. The order stays `#paid` and keeps being swept,
    /// so fixing the *cause* delivers it with no further intervention.
    ///
    /// ⚠️ **An alert, deliberately, and not a termination.** Terminating on these
    /// causes would give up on a purchase that is going to succeed once the cause is
    /// fixed. Delivery is the product; a refund is what happens when we cannot
    /// identify a buyer, not when we are merely busy.
    ///
    /// Raised once per order. Resolve it when the cause is fixed, or convert it
    /// to `#abandoned` if you decide to stop.
    #deliveryDelayed : { orderId : Types.OrderId; stage : Text; sinceNs : Int };
    /// A human decided to stop trying. The **only** path to a terminal
    /// non-delivered state — nothing automatic ends here.
    #abandoned : { orderId : Types.OrderId; reason : Text };
    /// A **verified** Stripe event the canister cannot process — a required
    /// field is absent (e.g. a checkout session with no `payment_intent`, which
    /// a subscription-mode link or a 100%-off promo code produces).
    ///
    /// Queued rather than refused: parsing is deterministic, so answering non-2xx
    /// would fail identically on every retry for Stripe's full retry horizon and
    /// risk the endpoint being disabled — which would then lose every legitimate
    /// webhook. Money position is unknown from here; the event id is what the
    /// operator looks up in the Dashboard.
    ///
    /// Growth is bounded by Stripe, not by a caller: reaching this requires a body
    /// that passes HMAC verification, so only the holder of the signing secret can
    /// produce one, and `unresolvedUnprocessable` keeps a resend of the same event
    /// from filing twice. Like every unresolved entry it is never evicted — the
    /// event id is the only pointer the canister keeps to a dollar it could not
    /// account for.
    #unprocessable : { eventId : Text; field : Text };
    /// **Stripe says this session was paid and we never credited it** (#52). Found by
    /// the recovery sweep asking Stripe about a `#created` order whose expiry event
    /// never arrived, past the point where Stripe would still be retrying the
    /// `completed` event it owed us.
    ///
    /// The order stays `#created`, and that is deliberate: `#created → #paid` is the
    /// only edge a resent event can travel, so **keeping the order here is what
    /// preserves the remedy that delivers to the buyer.** Route it anywhere else and
    /// the operator's only exit becomes a refund.
    ///
    /// ⚠️ **Carries `paymentRef`, and `paymentRefOf` returns null for it anyway.** Same
    /// shape as `#refundAfterDelivery`, different reason: a `charge.refunded` settles
    /// the *money* here and leaves the *order* broken, so letting `resolveByPaymentRef`
    /// match this would close the worklist item pointing at capacity that is still
    /// stranded — and nothing would ever release it, because a complete session never
    /// fires `expired`. The id is carried because it is the first thing an operator
    /// looks up in Stripe; it is withheld from the accessor because the accessor is
    /// wired to a closer that must not fire here.
    #paidNotCredited : {
      orderId : Types.OrderId;
      paymentRef : Text;
      sessionId : Text;
    };
  };

  /// Can a `charge.refunded` for the same payment settle this on its own?
  ///
  /// ⚠️ **True only where the remedy is exactly "refund the fiat".** Anything else
  /// needs a decision a webhook cannot make: `#deliveryStuck` may be an unknown money
  /// position (refunding blind pays a buyer who already holds their cycles),
  /// `#refundAfterDelivery` is money that moved both ways, and `#deliveryDelayed` is
  /// not an obligation at all.
  public func refundResolvable(kind : Kind) : Bool {
    switch (kind) {
      case (#duplicate(_) or #unattributed(_)) true;
      case (#deliveryStuck(_) or #refundAfterDelivery(_)) false;
      case (#deliveryDelayed(_) or #abandoned(_) or #unprocessable(_)) false;
      // ⚠️ **False even though a refund is a legal thing for the operator to do here.**
      // The question this answers is "does a `charge.refunded` settle this entry *on its
      // own*", and it does not: refunding returns the buyer's money and leaves the order
      // stranded in `#created` holding reserve capacity, with no event left that can
      // release it. Answering true would auto-close the only worklist item pointing at
      // that. The remedy that settles it whole is a resend.
      case (#paidNotCredited(_)) false;
      // NOT refund-resolvable. That answer means "fiat in, nothing delivered" — a
      // *settled* position the operator refunds. Here whether the cycles moved is
      // unknown, so answering true would tell them to refund a buyer who may already
      // hold their cycles.
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

  /// The payment reference a `charge.refunded` resolves — refund-resolvable kinds only.
  /// (`#deliveryStuck` carries no paymentRef: the order store doesn't retain the
  /// payment_intent, and a refund alone doesn't settle an uncertain delivery.)
  public func paymentRefOf(kind : Kind) : ?Text {
    switch (kind) {
      case (#duplicate({ paymentRef; orderId = _ })) ?paymentRef;
      case (#unattributed({ paymentRef; claimedRef = _ })) ?paymentRef;
      // #refundAfterDelivery carries a paymentRef but must NOT be reachable
      // from `resolveByPaymentRef`: the refund is what created the entry, so
      // auto-resolving on it would close the loss the instant it was recorded.
      // Only a human closes this one.
      case (#deliveryStuck(_) or #refundAfterDelivery(_) or #paidNotCredited(_)) null;
      // None of these is settled by a refund landing: a delay wants its cause
      // fixed, an abandonment was already a conscious decision, and an
      // unprocessable event has no established money position to settle.
      case (#deliveryDelayed(_) or #abandoned(_) or #unprocessable(_)) null;
      // Same reasoning as #deliveryStuck, and sharper: a refund arriving does not
      // tell us whether the cycles left the reserve, which is the only open
      // question. Auto-resolving on it would close an entry whose answer nobody
      // has looked up.
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
    /// every verified dollar resolves to a delivery or to an entry here — and it
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
    // Trim only *resolved* history, oldest first. If nothing resolved is left to
    // drop, the queue exceeds capacity and stays that way until the operator works
    // it down — a visibly growing worklist is strictly better than a forgotten
    // obligation.
    //
    // One pass, collecting victims before removing any: repeatedly re-scanning for
    // the next-oldest resolved entry costs O(size) per eviction, and removing while
    // iterating mutates the map under the iterator.
    let evicted = List.empty<Entry>();
    let size = store.entries.size();
    if (size > capacity) {
      // Int-subtract: the `if` above makes this non-negative, but that is the
      // guard talking and not the type (M0155).
      var over = Int.abs(size.toInt() - capacity.toInt());
      let victims = List.empty<Nat>();
      label scan for ((id, existing) in store.entries.entries()) {
        if (over == 0) break scan;
        if (existing.resolvedAtNs != null) {
          victims.add(id);
          evicted.add(existing);
          over -= 1;
        };
      };
      for (id in victims.values()) store.entries.remove(id);
    };
    { entry; evicted = evicted.toArray() };
  };

  /// The unresolved `#unprocessable` entry for this Stripe event, if one is
  /// already on the worklist.
  ///
  /// Webhook ingestion dedups on the event id, but that dedup set is pruned at
  /// ~7 days (§4.2). A Dashboard resend after that window is a *new* event to the
  /// dedup set and would file a second entry for one event — two worklist items
  /// an operator has to recognise as the same thing and resolve twice.
  ///
  /// Scans the queue: `#unprocessable` is reached only from a signature-verified
  /// event that failed to parse, which is rare and not attacker-drivable, so this
  /// is not on any hot path.
  public func unresolvedUnprocessable(store : Store, eventId : Text) : ?Entry {
    for ((_, entry) in store.entries.entries()) {
      if (entry.resolvedAtNs == null) {
        switch (entry.kind) {
          case (#unprocessable({ eventId = existing; field = _ })) {
            if (existing == eventId) return ?entry;
          };
          case (_) {};
        };
      };
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

  /// `charge.refunded` auto-resolve (§4.1): marks every unresolved refund-resolvable
  /// entry carrying this `payment_intent` resolved; returns them. The other kinds never
  /// match, because they carry no paymentRef — which is the structural half of
  /// `refundResolvable` doing the work.
  /// Empty result = refund for something not in the queue (fine: operators may
  /// refund proactively).
  /// Unresolved entries carrying this `payment_intent`, without touching them.
  /// Used by the partial-refund path, which must report what is still owed
  /// rather than settle it.
  public func unresolvedByPaymentRef(store : Store, paymentRef : Text) : [Entry] {
    store.entries.values().filter(
      func(e) = e.resolvedAtNs == null and paymentRefOf(e.kind) == ?paymentRef
    ).toArray();
  };

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

  /// Hard cap on a page. Entries are a few hundred bytes, and a Candid message
  /// is capped at 2 MB — so an unpaginated read of a queue that is allowed to
  /// grow (see `AddResult.evicted`) would eventually become unreturnable. This
  /// bounds the response instead of bounding the record.
  public let maxPageSize : Nat = 200;

  /// One page of entries, oldest first.
  ///
  /// Cursor-based rather than offset-based on purpose: resolved history is
  /// trimmed as new entries arrive, so positional offsets shift under a client
  /// mid-scan and would silently skip entries. Ids are monotonic and never
  /// reused, so a cursor is stable.
  ///
  /// `nextCursor` is set **only when further matching entries remain**, so a
  /// caller stops the moment it is null and never makes a wasted final request.
  /// A page can therefore come back exactly full with no cursor.
  public type Page = { entries : [Entry]; nextCursor : ?Nat };

  func pageWhere(
    store : Store,
    afterId : ?Nat,
    limit : Nat,
    matches : Entry -> Bool,
  ) : Page {
    let capped = if (limit == 0 or limit > maxPageSize) maxPageSize else limit;
    let collected = List.empty<Entry>();
    var last : ?Nat = null;
    for ((id, entry) in store.entries.entries()) {
      let past = switch (afterId) { case (?cursor) id > cursor; case null true };
      if (past and matches(entry)) {
        if (collected.size() == capped) return { entries = collected.toArray(); nextCursor = last };
        collected.add(entry);
        last := ?id;
      };
    };
    // Ran out of entries, so this is the last page regardless of how full it is.
    { entries = collected.toArray(); nextCursor = null };
  };

  /// Everything still retained, paged (resolved entries included — they are the
  /// audit history).
  public func page(store : Store, afterId : ?Nat, limit : Nat) : Page {
    pageWhere(store, afterId, limit, func(_) = true);
  };

  /// Open obligations only, paged. This is the operator's worklist: filtering
  /// server-side means they never page through resolved history to find the
  /// dollars that still need an answer.
  public func unresolvedPage(store : Store, afterId : ?Nat, limit : Nat) : Page {
    pageWhere(store, afterId, limit, func(entry) = entry.resolvedAtNs == null);
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


  /// Is there already an unresolved `#paidNotCredited` for this order?
  ///
  /// ⚠️ **The sweep's do-not-re-file guard, and it is only safe because of a coupling
  /// elsewhere.** This kind's closer is *the order being credited*, not the money
  /// moving, so an unresolved entry means the problem is still live and suppressing a
  /// duplicate hides nothing. **Move that closer onto money state and this guard becomes
  /// a hider** — an auto-closed entry would stop the sweep from ever filing again while
  /// the capacity stayed stranded. Delete this guard before moving the closer.
  public func hasUnresolvedPaidNotCredited(store : Store, orderId : Types.OrderId) : Bool {
    for (entry in store.entries.values()) {
      if (entry.resolvedAtNs == null) {
        switch (entry.kind) {
          case (#paidNotCredited({ orderId = id; paymentRef = _; sessionId = _ })) {
            if (id == orderId) return true;
          };
          case (_) {};
        };
      };
    };
    false;
  };


  /// Close every unresolved `#paidNotCredited` for an order that has just been credited.
  ///
  /// The mirror of `Card`'s `clearDelayed`: the obligation was "this order is paid and
  /// uncredited", so it ends when the order stops being that — **not** when the money
  /// moves. Returns what it closed, for the audit line.
  public func resolveCreditedOrder(store : Store, orderId : Types.OrderId, nowNs : Int) : [Entry] {
    let closed = List.empty<Entry>();
    for (entry in store.entries.values()) {
      if (entry.resolvedAtNs == null) {
        switch (entry.kind) {
          case (#paidNotCredited({ orderId = id; paymentRef = _; sessionId = _ })) {
            if (id == orderId) {
              let updated = { entry with resolvedAtNs = ?nowNs };
              store.entries.add(entry.id, updated);
              closed.add(updated);
            };
          };
          case (_) {};
        };
      };
    };
    closed.toArray();
  };

};
