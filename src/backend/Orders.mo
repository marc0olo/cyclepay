/// Order store + the §4 state machine.
///
/// The state machine owns *transitions only*. Expiry policy, solvency checks,
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
import Reserve "Reserve";
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

  /// §6.1 — the reference the canister sets on the Checkout Session it creates
  /// (#33); it used to be appended to a Payment Link URL by the frontend:
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
    /// §30 PR-B — cycles promised to orders that exist and are not settled.
    ///
    /// ⚠️ **It lives HERE, in the store, deliberately.** `create`,
    /// `applyTransition` and `markPaid` are the only three functions that write an
    /// order's status, and they are all in this module — so the tally sits next to
    /// every site that can move it, and adding a fourth writer means editing this
    /// file and seeing the tally. Holding it in `Main.mo` instead would put the
    /// state and its adjustment sites in different files, which is how per-status
    /// counters drift.
    ///
    /// The value is `Σ lockedCycles` over orders whose status is **not terminal**
    /// (`Reserve.holdsPromise`). See `Reserve.mo` for why it is a rule rather than
    /// a list, and why there is no fee term.
    var promised : Nat;
    /// How many times `promised` had to saturate at zero — i.e. a release asked to
    /// remove more than was held. **Any non-zero value means the tally diverged**,
    /// and it is surfaced by `reserve_status` so it does not wait for a recount.
    var tallySaturations : Nat;
  };

  public func emptyStore() : Store {
    {
      orders = Map.empty<Types.OrderId, Types.Order>();
      principalsToOrders = Map.empty<Principal, List.List<Types.OrderId>>();
      counts = Map.empty<Text, Nat>();
      var promised = 0;
      var tallySaturations = 0;
    };
  };

  /// Cycles promised to unsettled orders (#30 PR-B). O(1).
  public func promised(store : Store) : Nat {
    store.promised;
  };

  /// Statuses whose live counts are maintained. Keyed by `statusToText` so the
  /// map is a shared type and the key set is self-documenting.
  ///
  /// ⚠️ **A status earns an O(1) tally only when something reads it — and here is the
  /// reader for each, because a justification naming readers that do not exist is how
  /// this list drifts.**
  ///
  ///   - `#paid` → `Main.sweepableCount`, which short-circuits the whole recovery
  ///     sweep when it is 0. The only tally on a money path.
  ///   - `#created`, `#expired` → `reserve_status`'s `openOrders` / `expiredOrders`.
  ///     An **operator metric**, not a decision: `openOrders` climbing while
  ///     deliveries do not is the order-creation abuse signal.
  ///   - `#needsReview` → nothing reads it directly, and it stays tracked on purpose:
  ///     being in `trackedStatuses` is what puts escalated orders under `reconcile`'s
  ///     drift detection. An order whose money position a human is establishing is the
  ///     last one whose bookkeeping should go unchecked.
  ///
  /// ⚠️ **The admission gate reads none of these.** Its open-order cap is per
  /// principal, so it calls `openOrderCount`, which iterates that caller's own order
  /// ids — a global tally cannot answer a per-principal question. Do not "optimise"
  /// the gate onto `countOf`; it would silently change the cap's meaning from
  /// per-buyer to system-wide.
  ///
  /// `#cancelled`, `#delivered` and `#abandoned` are absent because nothing counts
  /// them — `countOf` returns 0 and `reconcile` leaves them alone.
  let trackedStatuses : [Types.OrderStatus] = [#created, #expired, #paid, #needsReview];

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
  /// ⚠️ **A guard mirrors this matrix and the compiler does not check it**:
  /// `Card.handleWebhook`'s status switch, which feeds `markPaid`, so anything it
  /// admits that this refuses is a bug — and on that path a trap, i.e. a 5xx
  /// Stripe retries for ~3 days. Change this and check the guard. It was two
  /// guards until #33 deleted `attach_payment`; #34 shipped the first fix and
  /// missed the second, so the lesson is to grep for `markPaid`'s CALLERS, not
  /// for the trap.
  public func isLegalTransition(from : Types.OrderStatus, to : Types.OrderStatus) : Bool {
    switch (from, to) {
      case (#created, #cancelled) true; // the buyer gave up before paying (#34)
      case (#created, #expired) true; // never paid (§4)
      case (#created, #paid) true; // webhook verified, deduped, amount honored
      // Delivery is ONE transfer out of the cycles reserve, so this single edge is
      // the whole money-out path. ⚠️ **Deleting it fails silently in the worst
      // direction:** `tryTransition` returns null *after* the transfer has landed, so
      // the buyer holds their cycles and the order sits `#paid` forever, looking
      // undelivered to every sweep that comes past.
      case (#paid, #delivered) true;
      case (#paid, #needsReview) true; // paid, undelivered past max wait (§5)
      // The operator read the ledger and the transfer HAD landed.
      //
      // ⚠️ **Added because its absence made the operator record a lie.** Until this
      // edge existed, `#needsReview`'s only exit was `#abandoned`, so an escalated
      // order whose cycles the buyer demonstrably has could only be filed as
      // abandoned — auditing a refund that never happened. Money-correct,
      // record-wrong, and the record is what this codebase trusts to keep illegal
      // states unrepresentable.
      //
      // Not a routine path: `#needsReview` means the money position is unknown, and
      // reaching it at all takes a ~24 h cycles-ledger outage. Only `record_delivered`
      // drives it, admin-only, and it demands the ledger block as evidence — no
      // automatic route to `#delivered` from an unknown position exists, because that
      // is the double-delivery this status prevents.
      case (#needsReview, #delivered) true;
      // `abandon_order` — the operator ends it, having refunded by hand. The
      // #needsReview edge is what the #errorQueue split made possible: an
      // escalated order could not previously be abandoned, because one status
      // meant both "promise held" and "promise released".
      case (#paid, #abandoned) true;
      case (#needsReview, #abandoned) true;
      case _ false;
    };
  };

  /// Pure transition: legal → updated copy, illegal → error. Callers decide
  /// *when* to ask (expiry timers, solvency checks); this decides *whether*.
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
      delayedAtNs = null;
      createdAtNs = nowNs;
      updatedAtNs = nowNs;
    };
    store.orders.add(id, order);
    bump(store, #created, 1);
    // #30 PR-B: the hold at creation. ⚠️ **Not a transition** — an order appears in
    // the counted set rather than moving into it — so it lives outside the
    // transition machinery entirely, which is why #30 calls `create` an adjustment
    // site in its own right. Missing this is the one leak the recount could not
    // attribute to a status change.
    store.promised += lockedCycles;
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
  /// ⚠️ **The ONLY way a status reaches the store.** Writes the record, both
  /// per-status counters, and the #30 promise tally, in one place.
  ///
  /// This exists because the alternative failed immediately. The tally was first
  /// wired into the three writers a comment claimed were the only ones —
  /// `create`, `applyTransition`, `markPaid` — and that comment was **false in the
  /// very file it was written in**: `expireWithCause` and `expireBySession` (#47)
  /// also write status, each with its own hand-rolled `add` plus two `bump`s.
  ///
  /// They are release points 1 and 4 of #30's five, and Stripe's
  /// `checkout.session.expired` is the most common release in the whole design —
  /// **every unpaid order ends there.** So every expired order would have left its
  /// `lockedCycles` in `promised` forever: `available` ratchets down, the gate
  /// starts refusing sales the reserve can cover, and the rail eventually closes
  /// on a full reserve. Safe in direction (over-refusal, never a double-sell), and
  /// a slow self-inflicted outage.
  ///
  /// Proximity was not enough, so the invariant is structural now: a sixth writer
  /// cannot forget the tally, because writing a status *is* calling this.
  /// (`attachSession` is the one writer that legitimately does not — it changes no
  /// status, and says so at its own `add`.)
  func commitTransition(store : Store, before : Types.Order, after : Types.Order) {
    store.orders.add(after.id, after);
    bump(store, before.status, -1);
    bump(store, after.status, 1);
    // Zero when the transition stays inside the counted set — `#created → #paid`
    // is the live example — and called anyway, so no writer is a special case.
    let moved = Reserve.applyDelta(
      store.promised,
      Reserve.tallyDelta(before.status, after.status),
      before.lockedCycles,
    );
    store.promised := moved.total;
    // ⚠️ Surfaced, not swallowed. Saturation means the tally was ALREADY wrong
    // before this order reached here, and a silent zero is indistinguishable from
    // an exact release — the first evidence would otherwise be the daily recount,
    // up to 24 h of a wrong tally gating real sales. `Main` audits this.
    if (moved.saturated) store.tallySaturations += 1;
  };

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
            // The tally moves only when a transition ACTUALLY succeeds.
            // That is where idempotency comes from and why no extra guard is
            // needed anywhere — `transition` refuses an illegal edge, so a
            // redelivered `checkout.session.expired` for an already-cancelled
            // order, a sweep racing a webhook, or a delivery retry answering
            // `#Duplicate` after the transition already committed all no-op here
            // rather than double-releasing.
            commitTransition(store, order, updated);
            #ok(updated);
          };
          case (#err(e)) #err(e);
        };
      };
    };
  };

  /// Attach a created Checkout Session to an order (#33).
  ///
  /// ⚠️ **Refuses unless the order is still `#created`, and that refusal is the
  /// point.** `create_order` commits the order and *then* awaits the outcall, so
  /// another ingress message can interleave — specifically `cancel_order` from a
  /// second tab, whose sessionless branch fires because no session id exists yet.
  /// Storing the URL anyway would hand the buyer a **payable link for an order
  /// they were told was cancelled**. Money-safe (the matrix rejects
  /// `#cancelled → #paid`, so a payment lands as a refundable obligation) but it
  /// recreates the exact "told cancelled, tab still charges" wart that making
  /// cancellation atomic exists to eliminate.
  ///
  /// `expiresAtNs` is Stripe's own deadline and is stamped **once** — there is no
  /// session retry, so nothing ever re-stamps it.
  public func attachSession(
    store : Store,
    id : Types.OrderId,
    sessionId : Text,
    sessionUrl : Text,
    expiresAtNs : Int,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        if (order.status != #created) {
          // Not a transition failure in the matrix sense — the order is fine, it
          // just is not the order this session was created for any more. Reported
          // as an illegal `#created` transition so the caller has one shape to
          // handle and the audit line names the status it actually found.
          return #err(#illegalTransition({ from = order.status; to = #created }));
        };
        let attached = {
          order with
          stripeSessionId = ?sessionId;
          stripeSessionUrl = ?sessionUrl;
          expiresAtNs = ?expiresAtNs;
          updatedAtNs = nowNs;
        };
        store.orders.add(id, attached);
        // No `bump`: the status did not change, so the tallies are untouched.
        #ok(attached);
      };
    };
  };

  /// `#created → #expired` because **Stripe closed the session** (#33), with the
  /// session id backfilled if the order did not have one.
  ///
  /// The backfill is what lets a residue order heal: if the session-create
  /// response was lost (a trap or upgrade between the order commit and the
  /// continuation), the order holds no session id — and this event, arriving ~30
  /// minutes later, is the thing that tells it which session it had.
  public func expireBySession(
    store : Store,
    id : Types.OrderId,
    sessionId : Text,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        switch (transition(order, #expired, nowNs)) {
          case (#ok(updated)) {
            let expired = {
              updated with
              expiredBy = ?(#sessionExpired : Types.ExpiredBy);
              stripeSessionId = ?sessionId;
            };
            // Release point 1 (#30), and the most common one: Stripe says the
            // session died unpaid, so every unpaid order releases here.
            commitTransition(store, order, expired);
            #ok(expired);
          };
          case (#err(e)) #err(e);
        };
      };
    };
  };

  /// `#created → #expired` **with a recorded cause** (#34's `expiredBy`).
  ///
  /// Routed through `transition`, never a direct status write, for two protections
  /// at once: the matrix no-ops `#cancelled → #expired` (a second tab may have
  /// cancelled while the outcall was in flight), and the tallies stay coupled to
  /// the status change. A direct write would bypass both — and on the reserve path
  /// (#30) it would release an already-released promise.
  /// Record that this order has crossed `alertAfterNs` while waiting to deliver.
  ///
  /// Returns true only on the **first** crossing, so the caller can announce once
  /// without keeping any state of its own — which is what retires the
  /// `delayedAlerts` map rather than relocating it.
  ///
  /// ⚠️ **`updatedAtNs` is deliberately left alone.** It is the held-since clock
  /// `Delivery.waitStage` reads; moving it here would reset the wait being recorded,
  /// and an order that keeps resetting its own clock can never reach `maxHoldNs` —
  /// it would be alerted about forever and escalated never.
  public func markDelayed(store : Store, id : Types.OrderId, nowNs : Int) : Bool {
    let ?order = store.orders.get(id) else return false;
    switch (order.delayedAtNs) {
      case (?_) false; // already recorded; idempotent by construction
      case null {
        store.orders.add(id, { order with delayedAtNs = ?nowNs });
        true;
      };
    };
  };

  public func expireWithCause(
    store : Store,
    id : Types.OrderId,
    cause : Types.ExpiredBy,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        switch (transition(order, #expired, nowNs)) {
          case (#ok(updated)) {
            let expired = { updated with expiredBy = ?cause };
            // Release point 4 (#30): in-call session-creation failure.
            commitTransition(store, order, expired);
            #ok(expired);
          };
          case (#err(e)) #err(e);
        };
      };
    };
  };

  /// Webhook money-in (§6.1): `#created → #paid`, and only that. #34 deleted the
  /// `#expired` edge, so this REFUSES an order that stopped being payable.
  ///
  /// ⚠️ `Card.handleWebhook` guards the status before reaching here and `-Werror`
  /// does not check that guard against the matrix. It **traps** on this error
  /// rather than swallowing it, so a guard that drifts open is a 5xx Stripe
  /// retries for ~3 days rather than a silent delivery. One caller is not a reason
  /// to relax the trap.
  ///
  /// **`lockedCycles` is not written here.** The webhook honours only the quoted
  /// amount, so the quantity locked at creation is the quantity delivered —
  /// immutable for the order's whole life, which is what makes the outstanding-promise
  /// tally exact rather than conservative. `paidUsdCents` records what arrived,
  /// and it can only equal `pricing.usdCents`; it is stored because "what Stripe
  /// said" and "what we asked for" being the same is worth being able to check.
  public func markPaid(
    store : Store,
    id : Types.OrderId,
    paidUsdCents : Nat,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        switch (transition(order, #paid, nowNs)) {
          case (#ok(updated)) {
            let paid = { updated with paidUsdCents = ?paidUsdCents };
            // ⚠️ Release is at DELIVERY, never at payment, so this delta is ZERO.
            // `Reserve.tallyDelta` carries the two-orders-one-reserve argument.
            commitTransition(store, order, paid);
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

  /// Count of this principal's still-open orders — the input to the `Gate` admission cap.
  ///
  /// `#created` **and not past its own deadline**. Anything past `#paid` is a record of
  /// money rather than an open slot, and an `#expired` or `#cancelled` order is finished.
  ///
  /// ⚠️ **The deadline check is what makes a cap of 1 safe, and the reason it needs no
  /// Stripe call is the whole distinction.** A slot is **our** resource: we may grant it
  /// on our own clock, because being generous with it cannot lose money — at worst a
  /// buyer gets a second slot a little early, and the order they abandoned is unpayable
  /// anyway once Stripe expires its session. Reserve *capacity* is money, so releasing it
  /// needs Stripe's authority (#52 PR-A's sweep, and the reason option 3 was rejected).
  /// Same input, two resources, two standards of proof.
  ///
  /// Without it, one missed `checkout.session.expired` locks a buyer out **permanently**
  /// at a cap of 1 — not for the 35 minutes the session lasts, because nothing else moves
  /// a `#created` order. That is why the cap and this check land together and why
  /// shipping the cap alone would have been the harmful half.
  ///
  /// ⚠️ **`expiresAtNs` is null until the session-create response lands**, and a null
  /// deadline counts as open: an order with no session is one whose fate we do not know
  /// yet, and the residue case (a lost create response) is a canister-level fault whose
  /// lever is `expire_order`. Counting it as free would hand out a slot on the strength
  /// of an order we cannot even expire.
  public func openOrderCount(store : Store, caller : Principal, nowNs : Int) : Nat {
    switch (store.principalsToOrders.get(caller)) {
      case null 0;
      case (?ids) {
        var open = 0;
        for (id in ids.values()) {
          switch (store.orders.get(id)) {
            case (?order) {
              if (order.status == #created and not pastDeadline(order, nowNs)) open += 1;
            };
            case null {}; // id indexed without a record — cannot happen
          };
        };
        open;
      };
    };
  };

  /// Is this order past the deadline Stripe set for its own session?
  ///
  /// Null answers **false** — see `openOrderCount`. Separate and named so the one
  /// comparison has one home and one test, the way `Session.secondsToNs` does.
  public func pastDeadline(order : Types.Order, nowNs : Int) : Bool {
    switch (order.expiresAtNs) {
      case (?deadline) nowNs > deadline;
      case null false;
    };
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
  /// Every order, for the #30 promise recount.
  ///
  /// ⚠️ Deliberately NOT paged: the recount has to see all of them or its answer
  /// is wrong in the dangerous direction — a partial scan under-counts what is
  /// owed, which reports a leak that is not there and hides one that is. O(n) over
  /// orders that are never deleted, so it belongs on the daily reconcile and the
  /// admin recount, never on a hot path. #37 adds a status index.
  public func all(store : Store) : [Types.Order] {
    store.orders.values().toArray();
  };

  public func ordersFor(store : Store, caller : Principal) : [Types.Order] {
    switch (store.principalsToOrders.get(caller)) {
      case null [];
      case (?ids) {
        ids.values().filterMap<Types.OrderId, Types.Order>(func(id) = store.orders.get(id)).toArray();
      };
    };
  };

};
