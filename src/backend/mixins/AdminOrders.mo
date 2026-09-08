// `Array` for the receiver `.map()` on a candidate list.
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Time "mo:core/Time";
import AuditLog "../AuditLog";
import Idempotency "../Idempotency";
import Delivery "../Delivery";
import Orders "../Orders";
import Orphans "../Orphans";
import Problems "../Problems";
import Receipts "../Receipts";
import Session "../rails/Session";
import Types "../Types";

/// The operator's worklist: read any order, settle an obligation, end a purchase, and
/// the paged views the runbook triages from (§4.1, §7).
///
/// ⚠️ **Every read here lifts §2's owner boundary, and every one is audited for exactly
/// that reason.** `admin_order`, `admin_orders` and `admin_receipt` answer about orders
/// the caller does not own, which is what §2 withholds from everyone else — so the audit
/// line is the price of the exception rather than decoration, and it fires on a miss as
/// well as a hit, because a probe for existence is the thing being permitted.
///
/// ⚠️ **That is also why `admin_receipt` is an update while `receipt` is a query.**
/// Auditing writes state. Folding the admin case into the buyer's method would put every
/// buyer's receipt read through consensus to serve the rare one — which is why the two
/// live in different mixins and share one builder, `Receipts.of`.
mixin (
  orderStore : Orders.Store,
  dedup : Idempotency.Store,
  orphanStore : Orphans.Store,
  auditLog : AuditLog.Log,
  deliveryJournal : Delivery.Journal,
  paidIntents : Map.Map<Text, Types.OrderId>,
  cancelRequests : Set.Set<Types.OrderId>,
  ops : {
    audit : (Text, Text) -> ();
    auditAdmin : (Principal, Text, Text) -> ();
    requireAdmin : (Principal) -> ();
    isGrantedAdmin : (Principal) -> Bool;
    noteStripeApiFailed : (Text) -> ();
    tryTransition : (Types.OrderId, Types.OrderStatus) -> ?Types.Order;
    expireStripeSession : (Text) -> async* Session.ExpireOutcome;
    /// The delivery-stage predicates these paged views share with the sweep that
    /// maintains them. Shared rather than reimplemented so "is this delayed" has one
    /// definition — a second copy is how a worklist starts disagreeing with the timer
    /// that feeds it.
    deliveryStage : (Types.Order, Int) -> ?{ #retry; #alert; #terminate };
    stageIsDelayed : ({ #retry; #alert; #terminate }) -> Bool;
    openTransfer : (Types.JournalEntry) -> Bool;
    forEachPromisedDelivery : ((Types.Order, Types.JournalEntry) -> ()) -> ();
  },
) {

  /// Deliveries outstanding past `alertAfterNs` — a **reading**, not an obligation, which
  /// is why it is a query rather than a filed problem.
  ///
  /// ⚠️ **`alertAfterNs` is this predicate's THRESHOLD, not a trigger.** Lowering a
  /// filter costs nothing; lowering a trigger would file worklist entries for orders that
  /// deliver themselves.
  /// One delayed delivery, as `delayed_deliveries` reports it (#37, paginated by #38).
  ///
  /// ⚠️ **`pastMaxHold` is a transient window, at most one sweep interval wide** — past
  /// `maxHoldNs` the next sweep escalates the order out of `#paid` and out of this set.
  /// Useful to read; **do not assert it in an integration scenario**, because pinning
  /// that window without ticking the clock is the shape that produces a flaky test. The
  /// boundary is unit-pinned on `Delivery.waitStage`, which is where it belongs.
  type DelayedDelivery = {
    orderId : Types.OrderId;
    status : Types.OrderStatus;
    /// `order.updatedAtNs` — retries deliberately do not move it, so the clock is
    /// pinned to the moment the order entered its current state.
    heldSinceNs : Int;
    waitedNs : Int;
    /// How many times delivery has already failed. `0` is an order simply waiting.
    retries : Nat;
    pastMaxHold : Bool;
    /// When it FIRST crossed the threshold, read off the order — the permanent record,
    /// where every other field here is a live reading.
    delayedAtNs : ?Int;
  };

  /// "Is MY principal granted?" — public and caller-scoped.
  ///
  /// ⚠️ **Deliberately ungated.** An admin who is NOT yet granted has to be able to read
  /// their own principal and see that it is not granted; a guarded version would reject
  /// exactly the caller who needs the answer, and the UI could not tell "not granted" from
  /// "not reachable". It discloses nothing about anyone else: the answer is about `caller`.
  public shared query ({ caller }) func admin_status() : async {
    caller : Principal;
    granted : Bool;
    isController : Bool;
  } {
    {
      caller;
      granted = ops.isGrantedAdmin(caller);
      isController = caller.isController();
    };
  };

  /// Read **any** order by id (admin, #38).
  ///
  /// ⚠️ **A deliberate exception to §2's "existence is not revealed to non-owners", so it
  /// audits itself on every use.** `get_order` is owner-scoped with no admin bypass, so
  /// without this an operator could identify *which* order a Stripe receipt named and
  /// then not look at it.
  ///
  /// ⚠️ **The audit line is the price of the exception, not decoration.** It is an
  /// `auditAdmin` write, so it names *who* looked, and it fires on the read whether or
  /// not the order exists — a probe for existence is exactly what §2 withholds from
  /// everyone else, so a miss has to be as visible as a hit.
  public shared ({ caller }) func admin_order(id : Types.OrderId) : async ?Types.Order {
    ops.requireAdmin(caller);
    let found = Orders.get(orderStore, id);
    ops.auditAdmin(
      caller,
      "order.adminRead",
      id # (switch (found) { case (?_) ""; case null " (no such order)" }),
    );
    found;
  };

  /// Filtered, cursor-paginated order list (admin, #38).
  ///
  /// ⚠️ **Do not sort by `createdAtNs`.** Ordering is by order id, which is arbitrary
  /// because ids are random — and time-ordering would mean materialising the filtered set
  /// first, which is the unbounded scan #63 removed. Narrow with `createdFromNs` instead.
  ///
  /// ⚠️ **Deliberately NOT audited, unlike `admin_order` and `admin_receipt` — do not
  /// "fix" the inconsistency.** Their line records *"an operator looked at THIS person's
  /// order"*, and that targeted act is the accountable one; a line per page would record
  /// the work rather than the intrusion and bury the targeted reads. It would also make
  /// this an update, since audits write state, on the call an operator makes repeatedly.
  /// Same reasoning keeps `orphans`, `orphan_depth` and `problem_depth` unaudited.
  ///
  /// ⚠️ **What would change that:** a filter narrowing to a *single named principal* as
  /// the normal way to drive this. `owner : ?Principal` makes it possible today; it is not
  /// the intended use, and if it becomes one the list inherits the audit.
  public shared query ({ caller }) func admin_orders(
    filter : Orders.Filter,
    afterId : ?Types.OrderId,
    limit : Nat,
  ) : async Orders.Page {
    ops.requireAdmin(caller);
    Orders.page(orderStore, filter, afterId, limit);
  };

  /// §4.1 retained history, oldest first, **paged**. Admin: entries carry
  /// payment references and claimed-but-bogus URL params.
  ///
  /// Paged because unresolved obligations are never evicted, so the queue can
  /// grow — and an unpaginated read would eventually exceed Candid's 2 MB
  /// message limit, i.e. the record would become unreadable exactly when it
  /// mattered most. Pass `null` to start; feed `nextCursor` back until it is
  /// null. `limit` is capped at `Orphans.maxPageSize`.
  public shared query ({ caller }) func orphans(
    afterId : ?Nat,
    limit : Nat,
  ) : async Orphans.Page {
    ops.requireAdmin(caller);
    Orphans.page(orphanStore, afterId, limit);
  };

  /// Manual resolution (§4.1/§7) — the operator marking an obligation settled after
  /// acting off-chain: a refund issued in the Stripe Dashboard, or a delivery whose
  /// fate they established on the cycles ledger.
  ///
  /// ⚠️ **This closes ORPHAN entries only — `#unattributed` and `#unprocessable`.**
  /// Everything order-bound moved onto the orders in #37 and is closed by
  /// `resolve_problem`; pointing an operator here for those would be pointing them at the
  /// wrong method. Resolving an entry never transitions the order — see `Orphans`'s
  /// header.
  /// Close **one** order-bound problem an operator has dealt with (#37).
  ///
  /// ⚠️ **`paymentRef` is the selector, and dropping it over-resolves.** `sameShape`
  /// deliberately allows two unresolved `#duplicate` problems on one order with different
  /// payment references (a buyer who pays three times), so closing by tag alone marks an
  /// obligation settled that nobody has settled.
  ///
  /// ⚠️ **Problems in an array have no stable handle, so the dedup key IS the handle** —
  /// `(kindTag, identifyingRef)`, the same pair `sameShape` uses. One definition, both
  /// users.
  ///
  /// ⚠️ **And it refuses rather than guesses when the selector is ambiguous**, which is
  /// this codebase's posture wherever a lever might act on the wrong thing — the
  /// abandon guard and `cancel_order`'s `#notOpen` do the same. The refusal lists the
  /// references so the operator can disambiguate, because declining without a way
  /// through is a dead end rather than a safeguard.
  public shared ({ caller }) func resolve_problem(
    orderId : Types.OrderId,
    tag : Types.ProblemKindTag,
    /// Which one, when the kind can have several. `#deliveryStuck` never can — it is
    /// matched on the discriminator alone — so null is always right for it.
    paymentRef : ?Text,
  ) : async Result.Result<Nat, Problems.ResolveProblemError> {
    ops.requireAdmin(caller);
    // Separated from "nothing to resolve" (#123): an unknown id used to answer the same
    // way as a known order with nothing open, so a mistyped id read as "already done".
    if (Orders.get(orderStore, orderId) == null) return #err(#noSuchOrder({ orderId }));
    let candidates = Orders.unresolvedOfKind(orderStore, orderId, tag);
    if (candidates.size() == 0) return #err(#noSuchProblem({ tag }));
    switch (paymentRef) {
      case null {
        if (candidates.size() > 1) {
          // ⚠️ The candidate list travels as DATA now, not inside a sentence. It is what
          // the operator disambiguates with, and a caller had to parse it back out of
          // the prose to offer a choice.
          let refs = candidates.map(
            func(c) = switch (c.ref) { case (?r) r; case null "(none)" }
          );
          return #err(#ambiguous({ tag; candidates = refs }));
        };
      };
      case (?_) {};
    };
    let closed = Orders.resolveProblems(
      orderStore,
      orderId,
      func(k) {
        Problems.tagOf(k) == tag
        and (
          switch (paymentRef) {
            case null true; // exactly one candidate, checked above
            case (?want) Problems.identifyingRef(k) == ?want;
          }
        );
      },
      Time.now(),
    );
    if (closed == 0) {
      // Reachable only with a reference given: the no-reference path either found one
      // candidate or refused as ambiguous above.
      // Passed as the option it is, so the error cannot report an empty string as
      // though a reference had been supplied.
      return #err(#referenceNotFound({ tag; reference = paymentRef }));
    };
    ops.auditAdmin(
      caller,
      "order.problemResolved",
      orderId # ": " # Problems.tagToText(tag)
      # (switch (paymentRef) { case (?r) " (" # r # ")"; case null "" })
      # " — " # closed.toText() # " closed",
    );
    #ok(closed);
  };

  /// Mark one orphaned payment settled off-chain (admin, §4.1).
  ///
  /// The operator has dealt with it in Stripe; this records that they did. Audited with
  /// the entry's own detail, because nothing else in the system can tell afterwards that
  /// the obligation was met rather than forgotten. Nothing re-opens it.
  public shared ({ caller }) func resolve_orphan(id : Nat) : async Result.Result<Orphans.Entry, Orphans.ResolveError> {
    ops.requireAdmin(caller);
    let resolved = Orphans.resolve(orphanStore, id, Time.now());
    switch (resolved) {
      case (#ok(entry)) ops.auditAdmin(caller, "orphanStore.resolved", "entry " # id.toText() # ": " # entry.detail);
      case (#err(_)) {};
    };
    resolved;
  };

  /// The operational trail, **paginated** (#38).
  ///
  /// ⚠️ **Pagination became necessary the moment #37 removed the ring.** The bound used
  /// to be the 4,096-entry ring, so the response size took care of itself; retention is
  /// now total. Removing the cap moved the problem from *"history is lossy"* to *"the
  /// query cannot answer"* — both real, and removing the ring only fixed the first.
  ///
  /// Cursor on `seq`, which now has **no gaps**: gaps used to be how a reader detected
  /// drops, and there are no drops.
  public shared query ({ caller }) func audit_log(
    afterSeq : ?Nat,
    limit : Nat,
  ) : async AuditLog.Page {
    ops.requireAdmin(caller);
    AuditLog.page(auditLog, afterSeq, limit);
  };

  /// Orders past `alertAfterNs` and still undelivered (admin, paged by #38).
  ///
  /// The worklist behind `operator_summary.deliveriesDelayed`: one entry per order,
  /// with the journal figures a human needs to decide whether it is stuck or slow.
  public shared query ({ caller }) func delayed_deliveries(
    afterId : ?Types.OrderId,
    limit : Nat,
  ) : async {
    entries : [DelayedDelivery];
    nextCursor : ?Types.OrderId;
  } {
    ops.requireAdmin(caller);
    // ⚠️ **Bounded by the non-terminal index, not by lifetime sales (#63).** `#paid`
    // holds its promise, so the index is a superset of the population and the filter is
    // exact — and the index is capped by the reserve rather than growing with sales.
    //
    // ⚠️ **The page bounds the RESPONSE; the index bounds the WORK. Both are needed
    // and they are different limits** — ~2 MB for the response, instructions per
    // message for the walk — which is why paginating this in #38 did not make it
    // bounded and the comment here said so until now.
    let capped = if (limit == 0 or limit > Orders.maxPageSize) Orders.maxPageSize else limit;
    let now = Time.now();
    let collected = List.empty<DelayedDelivery>();
    var last : ?Types.OrderId = null;
    // Seek in O(log n); `valuesFrom` is inclusive, so the `id > cursor` test below is
    // what skips the cursor itself.
    let ids = switch (afterId) {
      case (?cursor) Orders.promiseHolderIdsFrom(orderStore, cursor);
      case null Orders.promiseHolderIds(orderStore);
    };
    label scan for (id in ids) {
      let ?order = Orders.get(orderStore, id) else continue scan;
      let past = switch (afterId) { case (?cursor) id > cursor; case null true };
      // ⚠️ `deliveryDelayed` is the ONLY status gate here. An outer `order.status == #paid`
      // survived alongside it and made the claim of one shared definition false: widening
      // the predicate changed this page and the summary's count differently, so the two
      // could disagree while both were "using the predicate".
      if (not past) continue scan;
      let ?stage = ops.deliveryStage(order, now) else continue scan;
      if (ops.stageIsDelayed(stage)) {
        if (collected.size() == capped) {
          return { entries = collected.toArray(); nextCursor = last };
        };
        collected.add({
          orderId = order.id;
          status = order.status;
          heldSinceNs = order.updatedAtNs;
          waitedNs = now - order.updatedAtNs;
          retries = switch (deliveryJournal.get(order.id)) {
            case (?entry) entry.retries;
            case null 0;
          };
          pastMaxHold = stage == #terminate;
          delayedAtNs = order.delayedAtNs;
        });
        last := ?order.id;
      };
    };
    { entries = collected.toArray(); nextCursor = null };
  };

  /// Every delivery with money-out work outstanding, right now (admin).
  ///
  /// The immediate answer to "is a delivery failing?", and it **self-clears by
  /// construction** — an entry leaves the moment delivery lands, because landing records
  /// the block and moves the status. No resolve step to forget. Read `retries` as "how
  /// many times this has already failed"; `0` is a first attempt, not a problem.
  ///
  /// ⚠️ **Admin even now that it is bounded.** A public version would hand an
  /// unauthenticated caller the operator's in-flight worklist; `reserve_status` is the
  /// public answer, and O(1) on purpose.
  ///
  /// ⚠️ The `#paid` subset is **exactly** the reconcile's quiet-window predicate, so this
  /// is also how "the reserve reconcile keeps skipping" gets diagnosed. `#needsReview`
  /// orders are included because an operator asking "what is wrong right now" wants them,
  /// and they are deliberately NOT in that predicate — see `unsettledDeliveries`.
  public shared query ({ caller }) func pending_deliveries() : async [Types.JournalEntry] {
    ops.requireAdmin(caller);
    let out = List.empty<Types.JournalEntry>();
    ops.forEachPromisedDelivery(
      func(order, entry) {
        switch (order.status) {
          case (#paid) { if (ops.openTransfer(entry)) out.add(entry) };
          case (#needsReview) { if (entry.blockIndex == null) out.add(entry) };
          case (_) {};
        };
      }
    );
    out.toArray();
  };

  /// Which order did this Stripe `payment_intent` pay for (admin, §4.2)? The
  /// reconciliation lookup: given a charge in the Stripe Dashboard, find the
  /// order it funded. Null means the payment was never attributed to an order
  /// here — check the order's problems and the orphan list for an obligation carrying it.
  public shared query ({ caller }) func order_for_payment(paymentRef : Text) : async ?Types.OrderId {
    ops.requireAdmin(caller);
    paidIntents.get(paymentRef);
  };

  /// **Admin: expire one `#created` order, releasing its reserve capacity** (#52).
  ///
  /// ⚠️ **The lever for the class the sweep structurally CANNOT see**, so do not delete it
  /// as redundant with the sweep: an order whose session-create response was lost carries
  /// neither `expiresAtNs` (nothing to trigger on) nor `stripeSessionId` (nothing to query
  /// with), and Stripe's session list cannot be filtered by `client_reference_id`.
  ///
  /// ⚠️ **Expire-first, exactly as `cancel_order` does, and for exactly that reason.**
  /// Nothing is ever half-expired: if the session is still live on Stripe, the order does
  /// not move. A successful expire is what makes "expired" mean *provably unpayable*
  /// rather than assumed, because Stripe guarantees a session ends in exactly one of
  /// completed/expired.
  ///
  /// ⚠️ **`#notOpen` changes nothing, and that is not timidity.** It means the session
  /// completed or already expired, and those demand opposite actions — expiring an order
  /// whose buyer just paid would strand a real payment. Let the webhook (or the sweep)
  /// settle it on Stripe's answer.
  public shared ({ caller }) func expire_order(id : Types.OrderId) : async Result.Result<Types.Order, Orders.ExpireError> {
    ops.requireAdmin(caller);
    let ?order = Orders.get(orderStore, id) else return #err(#notFound(id));
    switch (order.status) {
      case (#created) {};
      case (#expired) return #ok(order); // idempotent
      case (status) {
        return #err(#notCreated({ id; status }));
      };
    };
    switch (order.stripeSessionId) {
      case (?sessionId) {
        switch (await* ops.expireStripeSession(sessionId)) {
          case (#ok) {};
          case (#notOpen(detail)) {
            // The body travels into the audit line because this module deliberately
            // does not guess Stripe's wording: recording what it actually said is how
            // the next reader learns it. See `Session.expireOutcome`.
            ops.audit("order.expireRaced", id # ": session " # sessionId # " is no longer open. Stripe said: " # detail);
            return #err(#sessionNotOpen(id));
          };
          case (#unauthorized) {
            // ⚠️ 401/403 is the ONE expire answer that means "rotate the key", so it is
            // the only one that latches. A 400 latched it before, which filed a P1
            // saying the key was refused for a key that was fine.
            ops.noteStripeApiFailed(
              "expire REFUSED (401/403): the restricted key needs WRITE on Checkout Sessions — rotate it"
            );
            return #err(#stripeUnauthorized(id));
          };
          case (#failed(detail)) {
            ops.audit("order.expireFailed", id # ": " # detail);
            return #err(#stripeFailed({ id; detail }));
          };
        };
      };
      case null {
        // The residue class this method exists for. No session id means no URL ever left
        // the canister, so the order is provably unpayable with no outcall needed.
        ops.audit("order.expiredSessionless", id # " had no session; expired without an outcall");
      };
    };
    // Through the machinery, never a status write: a second tab may have cancelled this
    // order while the outcall was in flight, and the matrix no-ops `#cancelled → #expired`
    // for free — which is what keeps the buyer's own decision, and its `expiredBy`
    // provenance, from being overwritten.
    switch (Orders.settleUnpayable(orderStore, cancelRequests, id, #sessionExpired, Time.now())) {
      case (#ok(updated)) {
        ops.auditAdmin(caller, "order.expiredByAdmin", id # ": reserve capacity released");
        #ok(updated);
      };
      case (#err(_)) {
        let ?fresh = Orders.get(orderStore, id) else return #err(#notFound(id));
        #err(#movedInFlight({ id; status = fresh.status }));
      };
    };
  };

  /// Stop trying to deliver an order (admin, §7) — **the only path to a
  /// terminal non-delivered state.**
  ///
  /// Nothing in the system gives up on a purchase automatically: a delay raises
  /// `delayed_deliveries` and keeps retrying, because its causes are all
  /// operator-fixable. This is the deliberate human decision that a purchase
  /// will not be completed, and it demands a reason so the trail records *why*
  /// alongside *who*.
  ///
  /// Only reachable from a pre-delivery money-bearing state. A `#created` order
  /// has taken no money and needs no decision; a `#delivered` one is done.
  public shared ({ caller }) func abandon_order(
    id : Types.OrderId,
    reason : Text,
  ) : async Result.Result<Types.Order, Orders.AbandonError> {
    ops.requireAdmin(caller);
    let ?order = Orders.get(orderStore, id) else return #err(#notFound(id));
    switch (order.status) {
      case (#paid or #needsReview) {};
      case (status) {
        return #err(#notAbandonable({ id; status }));
      };
    };
    // ── ⚠️ A PAID order with an unsettled delivery cannot be abandoned ────────
    //
    // **Otherwise this lever pays the buyer twice.** The order is `#paid` with a
    // transfer issued and no block recorded, so the money position is UNKNOWN.
    // Abandoning releases the promise and files a refund-by-hand obligation, while
    // the transfer either lands afterwards or has already landed with its reply
    // lost — and after `#abandoned` nothing sweeps the order, so nothing ever
    // discovers which. The buyer keeps the cycles and gets the refund.
    //
    // ⚠️ It is not only a race with a call in flight. The wider case is the one that
    // needs no timing at all: an intent whose transfer executed and whose reply was
    // lost looks exactly like one that never executed, and this lever would decide
    // between them by guessing. **Deciding an unknown money position is precisely
    // what `#needsReview` exists to prevent**, and without this guard
    // `abandon_order` reached the same outcome directly from `#paid`, skipping it.
    //
    // Second symptom, worth knowing for the post-mortem: the late reply patches the
    // journal to `#delivered` while `tryTransition` no-ops against `#abandoned`, so
    // the journal and the order end up contradicting each other.
    //
    // **Bounded, so this is a wait and not a refusal:** the ~24 h dedup fuse moves
    // such an order to `#needsReview` on its own, where abandonment is allowed and
    // the documented procedure is establish-the-fate-first. `#needsReview` is
    // therefore untouched by this guard — escalation implies no outstanding call.
    //
    // ⚠️ **`unsettledDeliveries` now depends on this refusal for its completeness**, so
    // this guard holds up more than the double-payout it was added for (#69). It is what
    // keeps a transfer-in-flight order inside `promiseHolders`; relaxing it for operator
    // ergonomics would let the quiet window read quiet across an in-flight transfer,
    // which is the oversell direction. Integration scenario 78 owns it.
    if (order.status == #paid) {
      switch (deliveryJournal.get(id)) {
        case (?entry) {
          if (ops.openTransfer(entry)) {
            return #err(#deliveryOutstanding(id));
          };
        };
        case null {};
      };
    };
    if (reason.size() == 0) return #err(#reasonRequired);
    // Status and reason in one step, so they cannot diverge — an `#abandoned` order
    // with no explanation is the gap the dropped queue entry used to paper over.
    let abandoned = switch (Orders.abandonWithReason(orderStore, id, reason, Time.now())) {
      case (#ok(o)) o;
      case (#err(_)) return #err(#transitionRefused(id));
    };
    Delivery.patch(deliveryJournal, id, { status = ?#abandoned; blockIndex = null; cyclesDelivered = null; bumpRetries = false; lastError = null }, Time.now());
    // ⚠️ **No queue entry.** It was the fourth copy of one decision — the status, the
    // journal patch and this audit line already carry it, and nothing about it was
    // outstanding. Review established the refund is tracked separately, via
    // `stripe.refundOfEscalated` on the `charge.refunded` for the intent.
    ops.auditAdmin(caller, "order.abandoned", id # ": " # reason);
    #ok(abandoned);
  };

  /// Record that an escalated order's cycles **did** reach the buyer (admin, §7).
  ///
  /// The counterpart to `abandon_order`, and the reason #30 PR-B added the
  /// `#needsReview → #delivered` edge. `#needsReview` means "we could not establish
  /// whether the transfer landed"; when the operator establishes on the cycles
  /// ledger that it did, this is how they say so. Without it their only lever was
  /// `abandon_order`, which files a delivered order as abandoned and audits a refund
  /// that never happened.
  ///
  /// ⚠️ **The block index is required, and it is not decoration.** It is the evidence
  /// that this call is a *finding* rather than a guess, it goes into the journal so
  /// the receipt shows the same proof any other delivered order shows, and demanding
  /// it means the operator has actually looked. The order id is in the transfer's
  /// memo, so the lookup is a search on the ledger, not a reconstruction.
  ///
  /// ⚠️ It moves no money and must not: the cycles are already gone. It also does not
  /// credit the reserve floor back — the floor already assumed the debit when the
  /// transfer was issued (rule 2), and this call is the confirmation that the
  /// assumption was right.
  public shared ({ caller }) func record_delivered(
    id : Types.OrderId,
    blockIndex : Nat,
  ) : async Result.Result<Types.Order, Orders.RecordDeliveredError> {
    ops.requireAdmin(caller);
    let ?order = Orders.get(orderStore, id) else return #err(#notFound(id));
    switch (order.status) {
      case (#needsReview) {};
      case (#delivered) return #ok(order); // idempotent: already recorded
      case (status) {
        return #err(#notUnderReview({ id; status }));
      };
    };
    let ?delivered = ops.tryTransition(id, #delivered) else {
      return #err(#transitionRefused(id));
    };
    Delivery.patch(deliveryJournal, id, { status = ?#delivered; blockIndex = ?blockIndex; cyclesDelivered = null; bumpRetries = false; lastError = null }, Time.now());
    ops.auditAdmin(caller, "order.recordedDelivered", id # ": operator confirmed cycles-ledger block " # blockIndex.toText());
    #ok(delivered);
  };

  /// The same receipt, for **any** order (admin, #38) — and **audited**, which is the
  /// whole reason it is a separate method.
  ///
  /// ⚠️ **The audit is not about existence disclosure; it is about an operator leaving a
  /// record of having looked.** `Receipt` embeds the whole `Order`, so an *unaudited*
  /// admin path returns exactly what `admin_order` returns with no trace — which makes
  /// `admin_order`'s audit **bypassable by calling the other method**. Reading an operator
  /// read as harmless because the data is reachable elsewhere is the mistake to avoid.
  ///
  /// ⚠️ **A separate method rather than a branch, because auditing writes state.** An
  /// audited read cannot be a `query`, and folding this into `receipt` would make **every
  /// buyer's** receipt read an update — the common path through consensus to serve the
  /// rare one.
  ///
  /// ⚠️ **Auditing is the mitigation for lifting the owner boundary at all.** A path that
  /// lifts it without the audit is not a smaller version of the change; it is the change
  /// without its safeguard.
  public shared ({ caller }) func admin_receipt(id : Types.OrderId) : async ?Receipts.Receipt {
    ops.requireAdmin(caller);
    let ?order = Orders.get(orderStore, id) else {
      // Audited on a miss too, like `admin_order`: an id probe by an operator is exactly
      // what §2 withholds from everyone else, so a miss must be as visible as a hit.
      ops.auditAdmin(caller, "order.adminRead", id # " (receipt; no such order)");
      return null;
    };
    ops.auditAdmin(caller, "order.adminRead", order.id # " (receipt)");
    let journal = deliveryJournal.get(id);
    ?Receipts.of(order, journal);
  };

  /// Money-out journal for one order (admin, §4.2) — intent, block_index, cycles
  /// delivered, retries.
  public shared query ({ caller }) func delivery_journal(id : Types.OrderId) : async ?Types.JournalEntry {
    ops.requireAdmin(caller);
    deliveryJournal.get(id);
  };
};
