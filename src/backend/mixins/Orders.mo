import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Auth "../Auth";
import Delivery "../Delivery";
// `Map` for the receiver `.get()` on the delivery journal's map.
import Map "mo:core/Map";
import Orders "../Orders";
import Receipts "../Receipts";
import Session "../rails/Session";
import Types "../Types";

/// What a buyer can do with their own orders: read them, read the receipt, give up on an
/// unpaid one, and ask for a stalled delivery to be driven again (§2).
///
/// ⚠️ **Owner-scoped, not admin-scoped, and the distinction is the whole point of §2.**
/// Every read here goes through `Orders.getOwned` or the caller's own index, so existence
/// is not revealed to a non-owner. The admin equivalents are separate methods in
/// `mixins/AdminOrders.mo` precisely so that lifting the owner boundary is a visible,
/// audited act rather than a branch inside these.
///
/// ⚠️ **`cancelRequests` is passed as the `Set` itself** — a heap object, so the intent
/// this mixin records is the same intent the webhook reads (`docs/DESIGN.md` §4.3). An
/// accessor pair would have worked too; a copy would have silently broken attribution.
///
/// ⚠️ **The two `async*` helpers stay in the composition root.** `expireStripeSession`
/// makes the Stripe outcall and `processDelivery` drives money out of the reserve; both
/// are actor-bound and both are shared with the timers. Passing them as
/// `async*`-returning closures keeps one implementation for the endpoint and the sweep,
/// which is what stops "cancel" and "the sweep cancelled" from diverging.
mixin (
  orderStore : Orders.Store,
  deliveryJournal : Delivery.Journal,
  cancelRequests : Set.Set<Types.OrderId>,
  ops : {
    audit : (Text, Text) -> ();
    auditAdmin : (Principal, Text, Text) -> ();
    noteStripeApiFailed : (Text) -> ();
    tryTransition : (Types.OrderId, Types.OrderStatus) -> ?Types.Order;
    expireStripeSession : (Text) -> async* Session.ExpireOutcome;
    processDelivery : (Types.OrderId) -> async* ();
    /// Is this principal a granted admin? Passed rather than reimplemented so
    /// `process_order` decides admin-ness by the same predicate `requireAdmin` does.
    isGrantedAdmin : (Principal) -> Bool;
    /// ⚠️ A TRANSIENT set, read through a closure. `deliveriesInFlight` is the
    /// single-flight guard for money-out, rebuilt on every start — a copy taken at
    /// include time would report an empty set forever and let a second kick in.
    deliveryInFlight : (Types.OrderId) -> Bool;
  },
) {

  /// Why a manual delivery kick did nothing (#30 PR-B).
  type ProcessOrderError = { #notFound; #inFlight };

  /// §2 query authz: `caller == order.owner`, null otherwise — existence is
  /// not revealed to non-owners. Anonymous callers own nothing by
  /// construction (create_order rejects them), so they always get null.
  public shared query ({ caller }) func get_order(id : Types.OrderId) : async ?Types.Order {
    Orders.getOwned(orderStore, id, caller);
  };

  /// Order history for the caller (§2, fixes the lost-receipt problem).
  /// The caller's own orders, **paginated** (#38).
  ///
  /// ⚠️ **This was a latent trap on the BUYER path, not an ergonomic wart.** It returned
  /// every order the caller owns, unbounded, and a query response is capped at ~2 MB —
  /// so an oversized read does not degrade, it **traps**. The open-order cap of 1 means
  /// a buyer accumulates them slowly, but nothing bounded it, and nothing drops orders
  /// under #37.
  ///
  /// ⚠️ **Paging bounded the RESPONSE; `Orders.ownerPage` bounds the WORK (#70).** The
  /// admin pager's owner filter walks every principal's orders to find one principal's,
  /// so this used to cost O(all orders ever created) in a single message — a page cap on
  /// a ~2 MB response, against a limit that is actually instructions. `ownerPage` walks
  /// the caller's own index from the cursor instead, and its cost is that buyer's page.
  public shared query ({ caller }) func list_orders(
    afterId : ?Types.OrderId,
    limit : Nat,
  ) : async Orders.Page {
    // ⚠️ The SAME function the unit test's `scanned` bound is asserted on, with the
    // count projected away here (#70). A separate uninstrumented path for production
    // would put that bound on code nobody runs.
    Orders.ownerPage(orderStore, caller, afterId, limit).page;
  };

  /// Manual delivery kick — **admin, or the order's own owner** (#30 PR-B).
  ///
  /// Safe to spam by construction: every step is journalled, deduplicated, idempotent
  /// and single-flighted. A page refresh heals a stuck order in seconds rather than
  /// waiting a sweep interval.
  ///
  /// ⚠️ **Owner-scoped, not public.** `getOwned` is the guard, so a caller can only kick
  /// their OWN order — one order per kick, serialised, on an order they paid real money
  /// to create. *Unauthenticated* traffic triggering a sweep over **every** order is a
  /// different shape and stays refused.
  ///
  /// ⚠️ **This does not replace the recovery sweep and must not be read as making it
  /// optional.** The sweep is the *guarantee* — we took the money, so we deliver whether
  /// or not the buyer comes back; this is the *latency fix*. A retry that only exists in
  /// the UI makes fulfilling an obligation depend on the buyer returning, and whoever
  /// closed the tab is exactly who most needs us to finish.
  ///
  /// ⚠️ **An owner kicking their own order is NOT audited**, because the log drops
  /// nothing (#37) and a refresh loop would be permanent state growth driven by a
  /// caller. An admin kick is audited — it is an ops action on someone else's order.
  public shared ({ caller }) func process_order(id : Types.OrderId) : async Result.Result<Types.Order, ProcessOrderError> {
    let isAdmin = Auth.checkAdmin(caller, Principal.isController, ops.isGrantedAdmin).isOk();
    if (isAdmin) {
      ops.auditAdmin(caller, "delivery.manualKick", id);
    } else {
      // Not an admin, so this must be the owner's own order. `getOwned` answers
      // "not found" for someone else's, which is also the right answer to give:
      // whether an id exists is not a stranger's business. No separate anonymous
      // check is needed — `create_order` refuses the anonymous principal, so it
      // owns no order and every id answers `#notFound` for it.
      if (Orders.getOwned(orderStore, id, caller) == null) return #err(#notFound);
    };
    if (Orders.get(orderStore, id) == null) return #err(#notFound);
    if (ops.deliveryInFlight(id)) return #err(#inFlight);
    await* ops.processDelivery(id);
    switch (Orders.get(orderStore, id)) {
      case (?order) #ok(order);
      case null #err(#notFound);
    };
  };

  /// Let a buyer give up on their own unpaid order (owner-scoped).
  ///
  /// ⚠️ **Load-bearing on the open-order cap**, whose refusal tells the buyer to pay or
  /// abandon one — advice they cannot follow without this, since `abandon_order` is
  /// admin-only and takes *paid* orders. Remove it and a buyer who opened the cap's worth
  /// of checkouts is locked out until their sessions expire.
  ///
  /// ⚠️ **Nothing is stranded, and the reason is the ORDERING**: the session is expired
  /// on Stripe *before* the order moves, so an in-flight payment either wins that race
  /// (and the order is not cancelled at all) or it cannot start. `#cancelled → #paid` is
  /// absent from the matrix, so a cancelled order is unpayable by construction.
  ///
  /// No problem filed: nothing is owed, and filing an obligation for an order where no
  /// money moved is exactly the noise the worklist must not accumulate.
  public shared ({ caller }) func cancel_order(id : Types.OrderId) : async Result.Result<Types.Order, Text> {
    let ?order = Orders.getOwned(orderStore, id, caller) else return #err("no order " # id);
    // WHICH answer is `Orders.cancelShape`'s decision, over the whole status space and
    // unit-tested there; how it READS stays here, because a buyer sees these words
    // verbatim (§4.3 / #118).
    switch (Orders.cancelShape(order.status)) {
      case (#proceed) {};
      case (#alreadyCancelled) return #ok(order);
      case (#alreadyExpired) {
        return #err("order " # id # " has already expired, so there is nothing to cancel");
      };
      case (#notCancellable(status)) {
        return #err(
          "order " # id # " is " # Types.statusToText(status)
          # "; a paid order cannot be cancelled — it will deliver, or contact support"
        );
      };
    };
    // `#cancelled`, not `#expired`: the buyer's own decision is a distinct state,
    // so a reload shows them "Cancelled" rather than telling them their order
    // expired (#34). And `#cancelled → #paid` is absent from the matrix, which is
    // what makes a cancelled order unpayable by construction rather than by a
    // runtime check somebody has to remember.
    //
    // ── Atomic with Stripe (#33, option B) ──────────────────────────────────
    // Expire the session FIRST, then mark the order. Nothing is ever *half*
    // cancelled: if the session is still live on Stripe, the order is not
    // cancelled. That ordering is the whole reason `#cancelled → #paid` never
    // needs to be legal — Stripe guarantees a session ends in exactly one of
    // completed/expired, so a successful expire proves no payment completed.
    //
    // An earlier draft made this outcall non-fatal (audit and return success
    // anyway). Rejected: it recreates the half-cancelled state — order says
    // cancelled, session still charges the buyer — that `#cancelled` exists to
    // eliminate.
    switch (order.stripeSessionId) {
      case null {
        // No session ever existed, so no URL left the canister and the order is
        // provably unpayable. This is the residue case: a trap or upgrade landed
        // between the order commit and the outcall response, so the in-call
        // failure handler never ran. Cancel with no outcall.
        ops.audit("order.cancelledSessionless", id # " had no session; cancelled without an outcall");
      };
      case (?sessionId) {
        // ⚠️ Recorded BEFORE the await, and deliberately NOT cleared in a `finally`:
        // this is the buyer's intent, not a lock. If this call traps, the intent has to
        // survive, because that is the window in which some other writer settles the
        // order. It is pruned once the order is terminal.
        cancelRequests.add(id);
        switch (await* ops.expireStripeSession(sessionId)) {
          case (#ok) {};
          case (#notOpen(_)) {
            // THREE causes, and this arm cannot tell them apart: the session completed
            // (the payment won the race), it had already expired, or Stripe refused the
            // request itself. The first two settle without us, so the right move is to
            // change nothing and let the incoming `checkout.session.completed` or
            // `checkout.session.expired` resolve it.
            //
            // ⚠️ **The third cause is why this no longer claims a diagnosis.** A
            // malformed request also answers 400, and "already settled or has expired"
            // is then false: the order is still `#created` and payable, so the buyer
            // refreshes onto an order that is still there and clicks again. The wording
            // below is true of all three, and it names what happens next in each case
            // instead of asserting which one it was.
            //
            // ⚠️ **No audit line, and the earlier reason for that was WRONG.** It said
            // the information exists in the resolving event — true of the first two
            // causes, and there is no resolving event for the third. The rule that does
            // apply is `AuditLog.mo`'s, which is explicit about this shape: a buyer can
            // retry, so "a caller decides" how often it fires, and that is a counter
            // with a monitoring row rather than a line. `Gate.RefusalCounts` cannot gain
            // one without an upgrade-incompatible change to the stable shape, so the
            // counter waits for a change entitled to make one.
            //
            // Until then the operator's lever is `expire_order`, which takes this same
            // path, is admin-authenticated — so the same rule admits its line — and
            // audits Stripe's body verbatim as `order.expireRaced`. A malformed request
            // is not per-order: it fails every cancel, so running it once against a live
            // `#created` order surfaces the cause. RUNBOOK §8 carries the row.
            return #err(
              "Stripe would not close the payment session for order " # id
              # ". If it was paid it will deliver; if not it expires on its own. Refresh"
              # " the page to see which"
            );
          };
          case (#failed(detail)) {
            // The order stays payable and uncancelled, which is the safe side:
            // the buyer can retry, or it expires on its own.
            //
            // ⚠️ **And because the buyer CAN retry, this line was caller-bounded** —
            // the comment above invites exactly the loop that made it fail
            // `AuditLog.mo`'s admission rule. It is the same Stripe-API-failing
            // condition `create_order` latches, with the same cause and the same lever,
            // so it routes through the same latch: one line when the API starts
            // refusing us, a counter for the volume.
            ops.noteStripeApiFailed("expire: " # detail);
            // ⚠️ **NOT "could not reach Stripe".** This arm is now only genuine unknowns
            // (a 5xx, or the outcall itself failing), and a 5xx means Stripe was reached
            // and something went wrong at its end. The old wording claimed a diagnosis
            // this arm does not have, and it was the wording a buyer saw for an
            // already-paid order, which took a different branch entirely.
            return #err(
              "could not cancel order " # id # " at Stripe — try again, or it expires on its own"
            );
          };
          case (#unauthorized) {
            // ⚠️ The one expire answer that means "rotate the key", and the only one
            // that should latch. A 400 latched this before, filing a P1 that said the
            // key was refused when the key was fine.
            ops.noteStripeApiFailed(
              "expire REFUSED (401/403): the restricted key needs WRITE on Checkout Sessions — rotate it"
            );
            return #err(
              "could not cancel order " # id # ": Stripe refused our credentials. An operator has been notified; the order expires on its own if it is not paid"
            );
          };
        };
      };
    };
    let ?cancelled = ops.tryTransition(id, #cancelled) else {
      // ⚠️ **Reaching here now means the race was WON by someone else and settled
      // correctly**, which is the normal path rather than a failure: the
      // `checkout.session.expired` webhook Stripe fires from our own expire call
      // routinely lands first, reads `cancelRequests`, and records `#cancelled`. So
      // report the buyer's own order back to them rather than an error.
      let ?fresh = Orders.get(orderStore, id) else return #err("no order " # id);
      switch (fresh.status) {
        case (#cancelled) {
          cancelRequests.remove(id);
          ops.audit("order.cancelled", id # " cancelled by owner (settled by the expiry event)");
          return #ok(fresh);
        };
        case (_) {
          // Genuinely something else: paid in the window, or an admin ended it. The
          // page re-renders from this response, so it shows what actually happened.
          cancelRequests.remove(id);
          return #err(
            "order " # id # " was already settled while this was in flight — the status above is current"
          );
        };
      };
    };
    cancelRequests.remove(id);
    ops.audit("order.cancelled", id # " cancelled by owner");
    #ok(cancelled);
  };

  /// Everything the **buyer** needs to verify their own purchase (§2 authz:
  /// `caller == order.owner`).
  ///
  /// The buyer can **check** the claim rather than take it: recompute the quote from the
  /// two recorded rate inputs, and look up the block index on the ledger.
  /// ⚠️ **Owner-only, and a `query`, which is why the admin path is a separate method.**
  /// See `admin_receipt`. Auditing writes state, so an audited read cannot be a query —
  /// and folding the admin case in here would have made **every buyer's** receipt read
  /// an update, putting the common path through consensus to serve the rare one.
  public shared query ({ caller }) func receipt(id : Types.OrderId) : async ?Receipts.Receipt {
    let ?order = Orders.getOwned(orderStore, id, caller) else return null;
    let journal = deliveryJournal.get(id);
    ?Receipts.of(order, journal);
  };
};
