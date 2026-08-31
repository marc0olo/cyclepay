/// Card rail (Stripe) — webhook signature verification + event ingestion
/// (§6.1, complete).
///
/// HTTP requests reach the canister as the *anonymous* principal (§6.0), so
/// this route is authenticated purely by payload: HMAC-SHA256 over the
/// Stripe signed payload `"<t>.<raw body>"` under the webhook signing secret,
/// plus a timestamp window as the replay guard. The window bounds how long a
/// captured-and-replayed delivery stays valid; inside the window, replay is
/// the dedup sets' job (Idempotency.mo — `event.id` / `payment_intent`).
///
/// Ingestion invariants (§4.1): dedup gates delivery; every verified dollar
/// resolves to a `#paid` order or an error-queue obligation (§5);
/// `client_reference_id` is claimed, not trusted;
/// the paid amount must EQUAL the quoted one — the session carried our figure,
/// so a difference is a misconfiguration, not a choice. The whole path is
/// synchronous — no awaits, so no interleaving between check and write.
/// State lives in `Deps` (Main.mo's stores, injected) so the path unit-tests
/// without an IC environment.
import Int "mo:core/Int";
import Problems "../Problems";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import AuditLog "../AuditLog";
import Orphans "../Orphans";
import Hmac "../Hmac";
import Http "../Http";
import Idempotency "../Idempotency";
import Json "../Json";
import Orders "../Orders";
import Types "../Types";
import Util "../Util";

module {

  /// Stripe's documented default tolerance for the timestamp window (5 min).
  public let defaultToleranceSeconds : Nat = 300;

  /// Parsed `Stripe-Signature` header.
  public type ParsedSignature = {
    /// `t=` element: when Stripe sent the webhook, unix *seconds*. Signed
    /// into the payload, so it can't be forged to defeat the window check.
    timestampSeconds : Nat;
    /// Decoded 32-byte `v1=` candidates. Stripe sends several while a
    /// rolled secret's predecessor is still live; any one match verifies.
    v1 : [Blob];
  };

  public type VerifyError = {
    /// Header missing `t=`, unparseable `t=`, or no well-formed `v1=`.
    #malformedHeader;
    /// `t=` further than the tolerance from canister time, either direction.
    #timestampOutsideWindow : { timestampSeconds : Nat; nowSeconds : Int };
    /// Well-formed header, but no `v1=` matches the expected MAC.
    #signatureMismatch;
  };

  /// Cap on the `Stripe-Signature` header. A real one is ~100 bytes per `v1=`
  /// plus the timestamp; 4 KiB leaves room for a deep rotation overlap.
  public let maxSignatureHeaderBytes : Nat = 4_096;

  /// Cap on `v1=` candidates actually verified. Stripe documents at most one per
  /// active secret, and only two are active during a rotation.
  public let maxV1Candidates : Nat = 8;

  /// Parse a `Stripe-Signature` header: comma-separated `key=value` elements,
  /// e.g. `t=1492774577,v1=5257a8...,v0=6ffbb5...`. Per Stripe's reference
  /// parsers: unknown schemes (`v0=`...) and unparseable elements are
  /// ignored; only the first `t=` counts. Null when no usable `t=`/`v1=`
  /// remain — the verifier treats that as malformed.
  ///
  /// ⚠️ **Bounded on both header length and candidate count.** The route's 64 KiB
  /// guard covers only the *body*, so a caller could otherwise send a ~2 MB
  /// signature header stuffed with tens of thousands of `v1=` values and make an
  /// unauthenticated update call do orders of magnitude more hashing than any
  /// real delivery — each candidate costs a constant-time compare against a
  /// freshly computed MAC. Stripe sends one `v1=` normally and a handful during a
  /// rotation overlap, so both bounds are far above legitimate traffic.
  public func parseSignatureHeader(header : Text) : ?ParsedSignature {
    if (header.size() > maxSignatureHeaderBytes) return null;
    var timestampSeconds : ?Nat = null;
    var sawTimestamp = false;
    let v1 = List.empty<Blob>();
    for (element in header.split(#char ',')) {
      if (v1.size() >= maxV1Candidates) continue;
      let parts = element.trim(#char ' ').split(#char '=').toArray();
      if (parts.size() != 2) continue;
      if (parts[0] == "t") {
        if (not sawTimestamp) {
          sawTimestamp := true;
          timestampSeconds := Nat.fromText(parts[1]);
        };
      } else if (parts[0] == "v1") {
        switch (Util.hexDecode(parts[1])) {
          case (?mac) { if (mac.size() == 32) v1.add(mac) };
          case (null) {};
        };
      };
    };
    let ?t = timestampSeconds else return null;
    if (v1.isEmpty()) return null;
    ?{ timestampSeconds = t; v1 = v1.toArray() };
  };

  /// MAC over the Stripe signed payload: `"<t>." # raw body bytes`. The body
  /// must be the exact bytes received — re-serialized JSON won't verify.
  public func signedPayloadMac(secret : Blob, timestampSeconds : Nat, body : Blob) : Blob {
    Hmac.sha256(secret, [Text.encodeUtf8(timestampSeconds.toText() # "."), body]);
  };

  /// Full §6.1 check: parse header, enforce the timestamp window against
  /// `nowNs` (canister time), constant-time-compare every `v1=` candidate.
  public func verify(
    secret : Blob,
    header : Text,
    body : Blob,
    nowNs : Int,
    toleranceSeconds : Nat,
  ) : Result.Result<(), VerifyError> {
    let ?parsed = parseSignatureHeader(header) else return #err(#malformedHeader);
    let nowSeconds = nowNs / 1_000_000_000;
    if (Int.abs(nowSeconds - parsed.timestampSeconds) > toleranceSeconds) {
      return #err(#timestampOutsideWindow({ timestampSeconds = parsed.timestampSeconds; nowSeconds }));
    };
    let expected = signedPayloadMac(secret, parsed.timestampSeconds, body);
    for (candidate in parsed.v1.values()) {
      if (Hmac.constantTimeEqual(expected, candidate)) return #ok;
    };
    #err(#signatureMismatch);
  };

  // ── Event parsing (§6.1) ──────────────────────────────────────────────

  public type CheckoutCompleted = {
    eventId : Text;
    /// Stripe `payment_intent` — the per-payment dedup key and the
    /// reference a `charge.refunded` resolves (§4.1).
    paymentIntent : Text;
    /// Attacker-editable URL param — claimed, not trusted (§4.1).
    clientReferenceId : ?Text;
    /// `amount_total` in the currency's smallest unit (cents for usd).
    amountTotalCents : Nat;
    currency : Text;
    /// `payment_status == "paid"`. False = an async payment method has not
    /// settled yet; the money may still arrive, and when it does Stripe sends
    /// `checkout.session.async_payment_succeeded`, which is parsed into this
    /// same shape (see `parseEvent`).
    paid : Bool;
    /// Stripe's `livemode`. A test-mode event carries `false`; accepting one on a
    /// canister with a funded reserve would deliver real cycles for a payment that
    /// never happened.
    livemode : Bool;
  };

  /// `charge.refunded` carries a **charge**, so `amount` is the charge total and
  /// `amount_refunded` is the cumulative amount refunded against it.
  public type ChargeRefunded = {
    eventId : Text;
    paymentIntent : Text;
    /// Cumulative refunded, smallest currency unit.
    amountRefundedCents : Nat;
    /// The charge's own total, for deciding whether the refund is complete.
    chargeAmountCents : Nat;
  };

  /// A refund settles the whole charge only when the cumulative refunded amount
  /// reaches the charge total. A partial refund must never be read as a full one:
  /// auto-resolving an obligation on a $5 courtesy refund of a $500
  /// payment would discard the record of the remaining $495.
  public func isFullRefund(refund : ChargeRefunded) : Bool {
    refund.chargeAmountCents > 0 and refund.amountRefundedCents >= refund.chargeAmountCents;
  };

  public type Event = {
    #checkoutCompleted : CheckoutCompleted;
    #chargeRefunded : ChargeRefunded;
    /// An async payment method failed for good — the session will never pay.
    #asyncPaymentFailed : { eventId : Text; paymentIntent : Text };
    /// Stripe closed the session unpaid (#33). **The only mechanism that expires
    /// an order** — there is no TTL sweep, deliberately: a sweep would flip a
    /// stuck order to `#expired` while its promise stayed held, so a broken order
    /// would look like a correctly expired one and the reserve would leak
    /// silently. Without it, a missed event leaves the order visibly `#created`
    /// past its `expiresAtNs`, which IS the detection signal (#30).
    #sessionExpired : {
      eventId : Text;
      /// The session's own id, so the event can be bound to the order that
      /// stored it rather than trusted on the reference alone.
      sessionId : Text;
      /// `<principal>_<orderId>`. Attribution when the order has no session id
      /// recorded — the residue case whose create-response was lost.
      clientReferenceId : ?Text;
    };
    /// A chargeback. **Audit only** (#33): cycles are delivered and irreversible
    /// and the card network pulls the funds, so there is nothing to react to — but
    /// without the subscription a dispute is invisible to the operator.
    #disputeCreated : { eventId : Text; paymentIntent : Text; amountCents : ?Nat };
    /// Recognized envelope, event type we don't handle — acked and dropped
    /// (an extra subscribed type must not look like a delivery failure).
    #unhandled : { eventId : Text; eventType : Text };
  };

  public type ParseError = {
    #invalidJson;
    /// A handled event type missing a field we require — e.g. a checkout
    /// session without a `payment_intent` (reachable via a subscription-mode
    /// link or a 100%-off promo code).
    ///
    /// `eventId` when the envelope itself parsed, which is what lets the
    /// handler dedup the entry it queues across Stripe's retries.
    #missingField : { field : Text; eventId : ?Text };
  };

  /// Parse a verified webhook body. Only called *after* `verify` — the JSON
  /// is authentic Stripe output, but string values inside it (emails, names)
  /// still carry user-influenced content, which is why this is a tree parse
  /// (Json.mo) and never a substring scan.
  public func parseEvent(body : Blob) : Result.Result<Event, ParseError> {
    let ?text = body.decodeUtf8() else return #err(#invalidJson);
    let ?json = Json.parse(text) else return #err(#invalidJson);
    // The envelope itself: without an id there is nothing to dedup on, so these
    // two carry no eventId of their own.
    let ?eventId = Json.textAt(json, "id") else return #err(#missingField({ field = "id"; eventId = null }));
    let ?eventType = Json.textAt(json, "type") else {
      return #err(#missingField({ field = "type"; eventId = null }));
    };
    func required(path : Text) : Result.Result<Text, ParseError> {
      switch (Json.textAt(json, path)) {
        case (?value) #ok(value);
        case (null) #err(#missingField({ field = path; eventId = ?eventId }));
      };
    };
    // `async_payment_succeeded` carries the same session object as `completed`
    // and is how a delayed payment method reports that money actually arrived.
    // Without it, a session acked as unpaid would settle later with no trace
    // anywhere: fiat in, nothing delivered, nothing on the worklist.
    if (
      eventType == "checkout.session.completed"
      or eventType == "checkout.session.async_payment_succeeded"
    ) {
      let paymentIntent = switch (required("data.object.payment_intent")) {
        case (#ok(v)) v;
        case (#err(e)) return #err(e);
      };
      let currency = switch (required("data.object.currency")) {
        case (#ok(v)) v;
        case (#err(e)) return #err(e);
      };
      let paymentStatus = switch (required("data.object.payment_status")) {
        case (#ok(v)) v;
        case (#err(e)) return #err(e);
      };
      let ?amountTotalCents = Json.natAt(json, "data.object.amount_total") else {
        return #err(#missingField({ field = "data.object.amount_total"; eventId = ?eventId }));
      };
      #ok(#checkoutCompleted({
        eventId;
        paymentIntent;
        livemode = Json.boolAt(json, "livemode") == ?true;
        // Absent and JSON-null both mean "no reference" (Stripe sends null
        // when the link was opened without the param).
        clientReferenceId = Json.textAt(json, "data.object.client_reference_id");
        amountTotalCents;
        currency;
        paid = paymentStatus == "paid";
      }));
    } else if (eventType == "charge.refunded") {
      let paymentIntent = switch (required("data.object.payment_intent")) {
        case (#ok(v)) v;
        case (#err(e)) return #err(e);
      };
      let ?amountRefundedCents = Json.natAt(json, "data.object.amount_refunded") else {
        return #err(#missingField({ field = "data.object.amount_refunded"; eventId = ?eventId }));
      };
      let ?chargeAmountCents = Json.natAt(json, "data.object.amount") else {
        return #err(#missingField({ field = "data.object.amount"; eventId = ?eventId }));
      };
      #ok(#chargeRefunded({ eventId; paymentIntent; amountRefundedCents; chargeAmountCents }));
    } else if (eventType == "checkout.session.async_payment_failed") {
      switch (required("data.object.payment_intent")) {
        case (#ok(paymentIntent)) #ok(#asyncPaymentFailed({ eventId; paymentIntent }));
        case (#err(e)) #err(e);
      };
    } else if (eventType == "checkout.session.expired") {
      // The session id is required — it is what binds the event to an order.
      // `client_reference_id` is optional here because a session can legitimately
      // carry none, and the handler falls back to the id match.
      switch (required("data.object.id")) {
        case (#ok(sessionId)) {
          #ok(#sessionExpired({
            eventId;
            sessionId;
            clientReferenceId = Json.textAt(json, "data.object.client_reference_id");
          }));
        };
        case (#err(e)) #err(e);
      };
    } else if (eventType == "charge.dispute.created") {
      switch (required("data.object.payment_intent")) {
        case (#ok(paymentIntent)) {
          #ok(#disputeCreated({
            eventId;
            paymentIntent;
            amountCents = Json.natAt(json, "data.object.amount");
          }));
        };
        case (#err(e)) #err(e);
      };
    } else {
      #ok(#unhandled({ eventId; eventType }));
    };
  };

  // ── Ingestion (§6.1 complete) ─────────────────────────────────────────

  /// Main.mo's stores, injected so the whole ingestion path unit-tests
  /// without an IC environment (same seam style as Auth.checkAdmin).
  public type Deps = {
    orders : Orders.Store;
    dedup : Idempotency.Store;
    orphanStore : Orphans.Store;
    orphanCapacity : Nat;
    /// Operator's declared Stripe mode; null = unset, which accepts either and
    /// says so in the audit trail. The go-live checklist sets it.
    expectLivemode : ?Bool;
    auditLog : AuditLog.Log;
    auditLogCapacity : Nat;
    /// `payment_intent` → order it paid for. Written when an order is marked
    /// paid; the only way a later `charge.refunded` can tell whether the
    /// refunded payment had already been delivered as cycles. A financial
    /// record — never pruned, and bounded by real volume (every entry corresponds to
    /// a payment that was delivered out of a funded reserve), unlike the
    /// `#unattributed` spam the dedup sets absorb.
    paidIntents : Map.Map<Text, Types.OrderId>;
    /// Per-purchase ceiling (`Gate.Config.maxPurchaseUsdCents`) — defence in
    /// depth now that the webhook honours only the quoted amount: an order
    /// created under a higher ceiling still matches its own quote after the
    /// ceiling is lowered, and this is what refuses it.
    maxPurchaseUsdCents : Nat;
  };

  /// What the webhook path produced: the HTTP response Stripe sees, plus
  /// whether this delivery actually created money-out work.
  ///
  /// `paidOrder` is non-null on exactly one path — a verified, deduped,
  /// attributed payment that transitioned an order to `#paid`. Everything else
  /// (guard rejections, duplicates, queued obligations, refunds, unhandled event
  /// types) leaves it null. The caller uses it to decide whether to kick delivery:
  /// an anonymous request that reaches no order must not be able to trigger a sweep
  /// over every order, which is otherwise an operation that is free to invoke and
  /// expensive to run.
  public type Outcome = {
    response : Http.Response;
    paidOrder : ?Types.OrderId;
  };

  /// Outcome for a delivery that created no money-out work.
  func ack(response : Http.Response) : Outcome {
    { response; paidOrder = null };
  };

  func audit(deps : Deps, nowNs : Int, tag : Text, detail : Text) {
    ignore AuditLog.append(deps.auditLog, deps.auditLogCapacity, nowNs, tag, detail);
  };

  /// Whether a paid amount may be honoured for this order (§3/§6.1) — since
  /// #33 an **equality check, not a computation**.
  ///
  /// Repricing existed because a fixed Payment Link could legitimately be paid
  /// for an amount the order was not created for: the buyer picked the link,
  /// not the order. A per-order Checkout Session carries the amount *we* set,
  /// so `amount_total` can now differ from the quote only if a Stripe feature
  /// that moves the total is enabled — the list is next to `Session.createBody`,
  /// and each entry is one Dashboard toggle away. That is a misconfiguration
  /// for the operator to look at, not a choice the buyer made, so a mismatch
  /// files a refundable obligation and delivers nothing.
  ///
  /// ⚠️ The collapse is what makes `lockedCycles` immutable after creation, and
  /// #30's accounting is exact rather than conservative because of it. Anything
  /// that reintroduces "honour a different amount" reintroduces both problems.
  public type Honored = {
    /// The amount matched the quote, so the locked quantity stands verbatim.
    #asQuoted : Nat;
    /// Stripe reported an amount we never asked for. Refund-resolvable: the operator
    /// refunds and fixes the session configuration.
    #mismatch : { paidUsdCents : Nat; quotedUsdCents : Nat };
    /// Above the per-purchase ceiling, kept as defence in depth even though the
    /// session pins the amount. It is reachable without any tampering: an order
    /// created under a higher ceiling still matches its own quote after the
    /// ceiling is lowered.
    #aboveCeiling : { paidUsdCents : Nat; maxUsdCents : Nat };
  };

  public func honoredCycles(
    order : Types.Order,
    paidUsdCents : Nat,
    maxPurchaseUsdCents : Nat,
  ) : Honored {
    if (paidUsdCents > maxPurchaseUsdCents) {
      return #aboveCeiling({ paidUsdCents; maxUsdCents = maxPurchaseUsdCents });
    };
    if (paidUsdCents != order.pricing.usdCents) {
      return #mismatch({ paidUsdCents; quotedUsdCents = order.pricing.usdCents });
    };
    #asQuoted(order.lockedCycles);
  };

  /// Queue a refund-resolvable entry (§4.1: fiat exists, nothing delivered — operator
  /// refunds in the Stripe Dashboard). Always 200: the payment is handled,
  /// just not by delivery; a non-2xx would make Stripe redeliver an event
  /// we have already routed.
  func queueRefundable(deps : Deps, kind : Orphans.Kind, detail : Text, nowNs : Int) : Http.Response {
    let result = Orphans.add(deps.orphanStore, deps.orphanCapacity, #card, kind, detail, nowNs);
    for (victim in result.evicted.values()) {
      if (victim.resolvedAtNs == null) {
        // §4.1: an unresolved eviction is a live money obligation dropped
        // from on-chain state — the one thing the audit trail must show.
        audit(deps, nowNs, "orphanStore.evictedUnresolved", "entry " # victim.id.toText() # ": " # victim.detail);
      };
    };
    audit(deps, nowNs, "stripe.type1", "entry " # result.entry.id.toText() # ": " # detail);
    Http.text(200, "queued for operator review");
  };

  /// File a refund-resolvable problem **on the order** (#37) and answer 200.
  ///
  /// ⚠️ **The order-bound sibling of `queueRefundable`, and the split is the point.**
  /// That function now serves only `#unattributed`, which by definition has no order
  /// to attach to. Everything with an `orderId` lives on the order, so there is no
  /// eviction to audit here either: orders are never evicted.
  ///
  /// Always 200, for the same reason: the payment is handled, just not by delivery, and
  /// a non-2xx would make Stripe redeliver an event we have already routed.
  func fileOrderProblem(
    deps : Deps,
    orderId : Types.OrderId,
    paymentRef : Text,
    kind : Types.ProblemKind,
    detail : Text,
    nowNs : Int,
  ) : Http.Response {
    switch (deps.orders.orders.get(orderId)) {
      case (?_) {
        let filed = Orders.fileProblem(deps.orders, orderId, kind, detail, nowNs);
        if (filed) {
          audit(deps, nowNs, "stripe.type1", orderId # " [" # Problems.kindToText(kind) # "]: " # detail);
        };
        Http.text(200, "queued for operator review");
      };
      // ⚠️ **No such order, so the problem has no home — and it must NOT be dropped.**
      // §4.1's invariant is that every verified dollar resolves to a delivery or to an
      // obligation. Moving problems onto orders introduced a way to lose one: the
      // queue's `add` filed regardless of whether the order existed, and
      // `Orders.fileProblem` cannot.
      //
      // Money that cannot be attached to an order is money **held for nobody**, which
      // is exactly what `#unattributed` means — so it goes to the orphan list, where
      // it is refund-resolvable and names the payment. Reachable via a corrupted
      // intent-to-order link; a test pins it, which is how it was found.
      case null {
        audit(
          deps,
          nowNs,
          "stripe.problemOrphaned",
          "order " # orderId # " is not in the store, so a " # Problems.kindToText(kind)
          # " problem for intent " # paymentRef # " was filed as unattributed instead",
        );
        queueRefundable(
          deps,
          #unattributed({ claimedRef = orderId; paymentRef }),
          detail # " ⚠️ Filed here rather than on the order because order " # orderId
          # " is not in the store — the reference and our records disagree.",
          nowNs,
        );
      };
    };
  };

  /// `charge.refunded` (§4.1): auto-resolve every unresolved refund-resolvable
  /// obligation carrying this payment_intent — **on both sides now**. No matches is
  /// fine: operators may refund payments that never filed anything.
  func handleRefund(deps : Deps, refund : ChargeRefunded, nowNs : Int) : Outcome {
    if (not Idempotency.recordStripeEvent(deps.dedup, refund.eventId, nowNs)) {
      return ack(Http.text(200, "duplicate event"));
    };
    let full = isFullRefund(refund);
    let amounts =
      refund.amountRefundedCents.toText() # " of " # refund.chargeAmountCents.toText() # " cents";

    // Only a full refund settles the obligation. A partial one leaves the
    // remainder owed, so auto-resolving on it would erase the record of what is
    // still outstanding — the entry stays open and the operator decides.
    if (not full) {
      let open = Orphans.unresolvedByPaymentRef(deps.orphanStore, refund.paymentIntent);
      for (entry in open.values()) {
        audit(
          deps,
          nowNs,
          "stripe.refundPartial",
          "entry " # entry.id.toText() # " left OPEN: partial refund of " # refund.paymentIntent
          # " (" # amounts # ") does not settle it",
        );
      };
      if (open.size() > 0) {
        // Symmetric with the full-refund path: having reported the obligations
        // this refund does NOT settle, stop. Continuing would also audit
        // "matched no queue entry", contradicting the line just written.
        return ack(Http.text(200, "partial refund recorded; obligation left open"));
      };
      audit(deps, nowNs, "stripe.refundPartial", "partial refund of " # refund.paymentIntent # " (" # amounts # ") matched no open entry");
      // Fall through only when nothing was open: a partial refund on a
      // *delivered* order is still a realised loss and must be recorded as one,
      // sized to what went back.
    };

    if (full) {
      // ⚠️ **Two stores to close against since #37**, and forgetting either is a
      // silent failure: an obligation left open after the refund that settles it is
      // exactly the false worklist entry the queue's own rule forbids.
      let resolved = Orphans.resolveByPaymentRef(deps.orphanStore, refund.paymentIntent, nowNs);
      for (entry in resolved.values()) {
        audit(deps, nowNs, "stripe.refundResolved", "entry " # entry.id.toText() # " auto-resolved by full refund of " # refund.paymentIntent # " (" # amounts # ")");
      };
      let closedOnOrders = Orders.resolveByPaymentRef(deps.orders, refund.paymentIntent, nowNs);
      if (closedOnOrders > 0) {
        audit(deps, nowNs, "stripe.refundResolved", closedOnOrders.toText() # " order problem(s) auto-resolved by full refund of " # refund.paymentIntent # " (" # amounts # ")");
      };
      if (resolved.size() > 0 or closedOnOrders > 0) return ack(Http.text(200, "ok"));
    };

    // Nothing resolved. Usually benign — operators may refund a payment that
    // never queued — but it is also how a refund of an already-delivered order
    // arrives, so the two are separated below and each leaves a trace.
    switch (deps.paidIntents.get(refund.paymentIntent)) {
      case null {
        // Genuinely unknown payment — never attributed to an order here.
        audit(deps, nowNs, "stripe.refundUnmatched", "refund of " # refund.paymentIntent # " (" # amounts # ") matched no queue entry and no paid order");
      };
      case (?orderId) {
        switch (Orders.get(deps.orders, orderId)) {
          case null {
            audit(deps, nowNs, "stripe.refundUnmatched", "refund of " # refund.paymentIntent # " maps to order " # orderId # ", which is no longer in the store");
          };
          case (?order) {
            switch (order.status) {
              case (#delivered) {
                // The loss case: fiat returned, cycles irreversibly gone.
                // ⚠️ **A second partial refund REFRESHES this rather than filing
                // again.** `refundedCents` is cumulative, so the figure an operator
                // reconciles by is the latest one — `Problems.file` matches on
                // `paymentRef` and updates the payload, which is why suppressing
                // instead would have frozen the total at the first partial.
                ignore Orders.fileProblem(
                  deps.orders,
                  orderId,
                  #refundAfterDelivery({
                    paymentRef = refund.paymentIntent;
                    cycles = order.lockedCycles;
                    refundedCents = refund.amountRefundedCents;
                    fullRefund = full;
                  }),
                  (if (full) "FULL" else "PARTIAL") # " refund/chargeback on a DELIVERED order: " # amounts
                  # " returned against " # order.lockedCycles.toText()
                  # " cycles already forwarded, which cannot be recovered — reconcile against Stripe and decide whether to restrict the payer",
                  nowNs,
                );
                audit(deps, nowNs, "stripe.refundAfterDelivery", orderId # ": " # refund.paymentIntent # " refunded (" # amounts # ") after " # order.lockedCycles.toText() # " cycles were delivered");
              };
              case (#needsReview or #abandoned) {
                // On the worklist, or already ended by the operator: a refund
                // here is the *expected* resolution, not a race to investigate.
                // Saying "the delivery may still be mid-flight" would send an
                // operator looking for one that cannot exist.
                audit(deps, nowNs, "stripe.refundOfEscalated", orderId # ": " # refund.paymentIntent # " refunded (" # amounts # ") — the expected resolution for an escalated order; resolve its queue entry once reconciled");
              };
              case (status) {
                // Paid but not yet delivered — the money-out pipeline may
                // still be mid-flight, so this is a race the operator must
                // look at rather than a settled loss.
                audit(deps, nowNs, "stripe.refundBeforeDelivery", orderId # ": " # refund.paymentIntent # " refunded (" # amounts # ") while order was " # Types.statusToText(status));
              };
            };
          };
        };
      };
    };
    ack(Http.text(200, "ok"));
  };

  /// An intent that has already funded an order arrived again. Two shapes:
  ///
  /// - **names the same order** → a redelivery past the dedup retention. Ack it.
  /// - **names anything else** → the reference and our record disagree. Since #33
  ///   nothing writes an attribution but the webhook itself and nothing but the
  ///   canister sets `client_reference_id`, so this should be unreachable — which
  ///   is exactly why it stays: an unreachable contradiction that fires means a
  ///   bug in attribution or something odd on Stripe's side, and it used to be
  ///   entirely silent. Never deliver (the money is spent), but surface it.
  ///
  /// Reads the order id straight from `clientReferenceId` rather than taking a
  /// resolved order, so it stays reachable when the reference is unusable. That is
  /// precisely the case that previously filed a false `#unattributed` obligation.
  func alreadyCredited(
    deps : Deps,
    session : CheckoutCompleted,
    credited : Types.OrderId,
    nowNs : Int,
  ) : Http.Response {
    let named = switch (session.clientReferenceId) {
      case (?ref) switch (Orders.parseClientReferenceId(ref)) {
        case (?(_, orderId)) ?orderId;
        case null null;
      };
      case null null;
    };
    if (named == ?credited) {
      audit(
        deps,
        nowNs,
        "stripe.replayedAfterPruning",
        "intent " # session.paymentIntent # " was already credited to order " # credited
        # " and its dedup keys have been pruned — treated as a redelivery, not a second payment",
      );
      return Http.text(200, "already credited");
    };
    let namedText = switch (named) { case (?o) o; case null "(no usable reference)" };
    audit(
      deps,
      nowNs,
      "stripe.creditedElsewhere",
      "intent " # session.paymentIntent # " names " # namedText
      # " but was already credited to order " # credited # " — nothing delivered a second time",
    );
    fileOrderProblem(
      deps,
      credited,
      session.paymentIntent,
      #duplicate({ paymentRef = session.paymentIntent }),
      "intent " # session.paymentIntent # " was credited to order " # credited
      # " but its Stripe session names " # namedText
      # " — the reference and our record disagree, which should not be reachable. Nothing was delivered twice. Decide which order the buyer paid for; there is no way to credit the other one, so settle it by refunding in Stripe.",
      nowNs,
    );
  };

  /// `checkout.session.completed` (§6.1): dedup → attribute (claimed, not
  /// trusted) → honor the actual paid amount → `#paid`, or a refundable obligation.
  func handleCheckout(deps : Deps, session : CheckoutCompleted, nowNs : Int) : Outcome {
    // event.id first: catches Stripe redelivering this exact event.
    if (not Idempotency.recordStripeEvent(deps.dedup, session.eventId, nowNs)) {
      return ack(Http.text(200, "duplicate event"));
    };
    if (not session.paid) {
      // An async payment method has not settled. Money may still arrive, and it
      // is caught then: `checkout.session.async_payment_succeeded` parses into
      // this same shape and runs this same handler.
      //
      // Checked BEFORE the livemode gate: an unsettled session is not money in
      // any Stripe mode, so raising a livemode obligation here would claim a
      // payment that has not happened and may never happen.
      audit(deps, nowNs, "stripe.unpaidSession", "payment_status not paid for intent " # session.paymentIntent # " — awaiting async settlement");
      return ack(Http.text(200, "ignored: payment not completed"));
    };
    // A test-mode event on a canister with a funded reserve would deliver real
    // cycles for a payment that never happened. The secret is the only thing
    // standing between the two, and provisioning the wrong one is a plausible
    // operator slip, so the event says which world it came from and we check.
    switch (deps.expectLivemode) {
      case (?expected) if (session.livemode != expected) {
        audit(
          deps,
          nowNs,
          "stripe.livemodeMismatch",
          "intent " # session.paymentIntent # ": livemode=" # (if (session.livemode) "true" else "false")
          # " but this gateway expects " # (if (expected) "true" else "false") # " — nothing delivered",
        );
        // Queue it only when real money is involved: a live payment reaching a
        // test-configured gateway is an obligation. The reverse is a test event
        // and owes nobody anything.
        if (session.livemode) {
          ignore Orphans.add(
            deps.orphanStore,
            deps.orphanCapacity,
            #card,
            // The real reference, not a placeholder: it is the only field that
            // identifies WHICH order to rescue once the config is fixed, and
            // discarding it would turn a recoverable misconfiguration into a
            // manual hunt through the Stripe Dashboard.
            #unattributed({
              claimedRef = Orphans.truncateClaimedRef(
                switch (session.clientReferenceId) { case (?r) r; case null "(no client_reference_id)" }
              );
              paymentRef = session.paymentIntent;
            }),
            "LIVE payment arrived but this gateway is configured for test mode — money is in the live Stripe account and nothing was delivered; fix set_expected_livemode, then RESEND this event from the Stripe Dashboard so the referenced order is credited, or refund",
            nowNs,
          );
        };
        return ack(Http.text(200, "acknowledged: livemode mismatch logged"));
      };
      case null {
        // Nothing is being refused here — but a gateway taking payments without
        // having declared its Stripe mode has no defence against a test-mode
        // secret spending the reserve, and the operator should see that in the
        // trail rather than discover it later. Self-extinguishing: setting the
        // expectation stops the line.
        audit(
          deps,
          nowNs,
          "stripe.livemodeUnset",
          "intent " # session.paymentIntent # " honoured without a declared Stripe mode — set_expected_livemode is unset",
        );
      };
    };
    // payment_intent second: one delivery per payment even across distinct
    // event deliveries for the same intent (§4.2).
    if (not Idempotency.recordStripeIntent(deps.dedup, session.paymentIntent, nowNs)) {
      return ack(Http.text(200, "duplicate payment intent"));
    };
    // ⚠️ **One intent, one credit — asked before the reference is even read.**
    //
    // `paidIntents` is the permanent record of which intent funded which order, and
    // answering from it needs only the payment_intent. Asking here rather than after
    // attribution matters when BOTH are wrong: an intent already credited elsewhere,
    // arriving with an unusable reference, would otherwise fall through to the
    // unattributed path and file an obligation for money that is already spent.
    //
    // The dedup sets prune at ~7 days, which automatic Stripe retries (~3 days)
    // cannot outlive — but a manual Dashboard resend can, and resending an event to
    // confirm it was processed is an ordinary operator move.
    switch (deps.paidIntents.get(session.paymentIntent)) {
      case (?credited) return ack(alreadyCredited(deps, session, credited, nowNs));
      case null {};
    };
    // ── Attribution (§4.1: claimed, not trusted). Failures are refund-resolvable
    // #unattributed: fiat arrived, nothing will be delivered.
    let claimedRef = Orphans.truncateClaimedRef(
      switch (session.clientReferenceId) { case (?r) r; case (null) "" }
    );
    func unattributed(detail : Text) : Outcome {
      ack(queueRefundable(deps, #unattributed({ claimedRef; paymentRef = session.paymentIntent }), detail, nowNs));
    };
    let ?ref = session.clientReferenceId else return unattributed("missing client_reference_id");
    let ?(claimedOwnerText, orderId) = Orders.parseClientReferenceId(ref) else {
      return unattributed("malformed client_reference_id");
    };
    // Orders are never deleted, so an unresolvable id means the reference was
    // never valid — not that we forgot the order.
    let ?order = Orders.get(deps.orders, orderId) else return unattributed("no order " # orderId);
    // A `switch` rather than a refutable `let #ii(owner) = …`, matching every other
    // authz site. Both forms warn (M0145) and both trap at runtime when a second
    // `Owner` case reaches them, so this buys **consistency, not safety** — the
    // safety would come from making M0145 an error, tracked separately.
    //
    // Why it matters here at all: a trap on this path is a 5xx, which Stripe retries
    // for ~3 days, so whoever takes up the §11.1.1 Base seam must update this site.
    let owner = switch (order.owner) { case (#ii(p)) p };
    if (owner.toText() != claimedOwnerText) return unattributed("claimed owner does not match order " # orderId);
    if (order.rail != #card) return unattributed("order " # orderId # " is not a card order");
    // The already-credited question was answered BEFORE attribution (see the
    // `paidIntents` lookup above), so reaching here means this intent has never
    // funded an order.
    // ⚠️ THIS GUARD IS WHAT KEEPS `markPaid`'s trap unreachable. It must admit
    // exactly the statuses the matrix allows into `#paid`, and nothing else: a
    // status that passes here and is then refused by `isLegalTransition` traps,
    // and a trap on this path is a 5xx that Stripe retries for ~3 days.
    //
    // `-Werror` does NOT protect this. Both arms typecheck whatever the matrix
    // says, so the coupling is a comment and a test, not a compile error. #34
    // deleted `#expired → #paid` and this guard had to lose `#expired` in the
    // same change; #33 and #36 change the matrix again.
    switch (order.status) {
      case (#created) {};
      case (#cancelled or #expired) {
        // Real money against an order that can no longer be paid. Until #33 the
        // Stripe session outlives both states, so this is reachable: a buyer who
        // cancels and pays anyway, or who pays a link after the sweep expired the
        // order.
        //
        // Filed as `#unattributed` rather than `#duplicate`, because nothing was
        // ever paid — there is no first payment for this to be a second of. Both
        // are refund-resolvable and both carry the `paymentRef` a `charge.refunded` resolves,
        // so the operator's lever is the same: refund in Stripe.
        return unattributed(
          "order " # orderId # " is " # Types.statusToText(order.status)
          # " and cannot be paid — refund " # session.paymentIntent # " in Stripe"
        );
      };
      case (status) {
        // A genuinely distinct payment for an already-handled order (§4.1:
        // Stripe dedup is redelivery protection, not double-pay protection).
        // Reaching here means the intent is NOT in paidIntents, so it is new
        // money against an order that has already been paid.
        return ack(fileOrderProblem(
          deps,
          orderId,
          session.paymentIntent,
          #duplicate({ paymentRef = session.paymentIntent }),
          "second payment for order " # orderId # " (status " # Types.statusToText(status) # ")",
          nowNs,
        ));
      };
    };
    if (session.currency != "usd") {
      return unattributed("unexpected currency " # session.currency # " for order " # orderId);
    };
    // ── §3/§6.1: the session carried our amount, so the only thing to decide is
    // whether Stripe reported it back unchanged.
    switch (honoredCycles(order, session.amountTotalCents, deps.maxPurchaseUsdCents)) {
      case (#asQuoted(_)) {};
      case (#mismatch({ paidUsdCents; quotedUsdCents })) {
        return unattributed(
          "paid amount " # paidUsdCents.toText() # " cents is not the " # quotedUsdCents.toText()
          # " cents order " # orderId # " asked Stripe for — a session feature that moves the total is"
          # " enabled (see Session.createBody); nothing delivered, refund and fix the configuration"
        );
      };
      case (#aboveCeiling({ paidUsdCents; maxUsdCents })) {
        return unattributed(
          "paid amount " # paidUsdCents.toText() # " cents exceeds the per-purchase ceiling of "
          # maxUsdCents.toText() # " cents for order " # orderId # " — nothing delivered; refund or raise the ceiling"
        );
      };
    };
    switch (Orders.markPaid(deps.orders, orderId, session.amountTotalCents, nowNs)) {
      case (#ok(_)) {
        // Link the payment to the order it funded, so a later refund of this
        // intent can tell whether cycles were already delivered.
        deps.paidIntents.add(session.paymentIntent, orderId);
        // ⚠️ **Close any `#paidNotCredited` obligation for this order (#52).** The
        // recovery sweep files that when Stripe reports a paid session we never
        // credited; this is the resend landing, which is the remedy the entry asks for.
        // The rule every closer follows here: **an open worklist entry
        // must describe a live problem**, and the moment the order is credited this one
        // does not.
        //
        // ⚠️ Its closer is deliberately **the order being credited, not the money
        // moving** — a `charge.refunded` must not close it, because refunding settles
        // the money and leaves the order stranded in `#created` with no event left to
        // release its capacity. That is why the kind withholds its `paymentRef` from
        // `paymentRefOf`, and why the sweep's do-not-re-file guard is safe.
        ignore Orders.resolveProblems(
          deps.orders,
          orderId,
          func(k) { switch (k) { case (#paidNotCredited(_)) true; case (_) false } },
          nowNs,
        );
        // The one path that creates money-out work.
        { response = Http.text(200, "ok"); paidOrder = ?orderId };
      };
      // Unreachable: status was checked above and nothing awaits in
      // between. A trap rolls the dedup writes back and 5xxs, so Stripe
      // retries rather than losing the payment to a swallowed error.
      case (#err(_)) Runtime.trap("markPaid rejected a checked transition for order " # orderId);
    };
  };

  /// The full POST /webhook/stripe path (§6.1): verify → dedup → route.
  /// Synchronous end to end. `secret` is `Secret.get(...)` — null answers
  /// 503 so Stripe keeps retrying until the operator provisions it.
  public func handleWebhook(
    deps : Deps,
    secret : ?Blob,
    req : Http.Request,
    nowNs : Int,
    toleranceSeconds : Nat,
  ) : Outcome {
    let ?key = secret else return ack(Http.text(503, "webhook secret not provisioned"));
    let ?header = Http.headerValue(req.headers, "stripe-signature") else {
      return ack(Http.text(400, "missing Stripe-Signature header"));
    };
    switch (verify(key, header, req.body, nowNs, toleranceSeconds)) {
      case (#err(_)) return ack(Http.text(400, "signature verification failed"));
      case (#ok) {};
    };
    // §4.2 opportunistic pruning: every verified delivery sweeps Stripe
    // dedup keys past the ~7-day retention. Reached only after the MAC
    // verifies, so unauthenticated traffic cannot drive it.
    ignore Idempotency.pruneStripe(deps.dedup, nowNs);
    switch (parseEvent(req.body)) {
      case (#err(#invalidJson)) {
        // The MAC verified, so this really came from Stripe — but we cannot read
        // it and never will. 200 for the same reason as `#missingField` below.
        audit(deps, nowNs, "stripe.unparseable", "verified event body is not valid JSON");
        ack(Http.text(200, "acknowledged: unreadable body logged for operator review"));
      };
      case (#err(#missingField({ field; eventId }))) handleUnprocessable(deps, field, eventId, nowNs);
      case (#ok(#unhandled({ eventId; eventType }))) {
        // Audited rather than silently dropped: an event type arriving here that
        // nobody subscribed to is a Stripe-config surprise, and the only way an
        // operator learns of it is this line.
        if (Idempotency.recordStripeEvent(deps.dedup, eventId, nowNs)) {
          audit(deps, nowNs, "stripe.unhandledType", eventType # " (" # eventId # ")");
        };
        ack(Http.text(200, "ignored"));
      };
      case (#ok(#asyncPaymentFailed({ eventId; paymentIntent }))) {
        if (Idempotency.recordStripeEvent(deps.dedup, eventId, nowNs)) {
          audit(deps, nowNs, "stripe.asyncPaymentFailed", "intent " # paymentIntent # " will never pay");
        };
        ack(Http.text(200, "ok"));
      };
      case (#ok(#disputeCreated({ eventId; paymentIntent; amountCents }))) {
        // Audit only, deliberately. A chargeback is the one loss nothing can
        // prevent: the cycles are delivered and irreversible while the card
        // network pulls the funds back. There is no automated response worth
        // making — but an operator has to be able to see it happened.
        if (Idempotency.recordStripeEvent(deps.dedup, eventId, nowNs)) {
          let amount = switch (amountCents) {
            case (?cents) cents.toText() # " cents";
            case null "an unstated amount";
          };
          audit(deps, nowNs, "stripe.disputeCreated", "intent " # paymentIntent # " disputed for " # amount # " — reconcile in Stripe; cycles cannot be recovered");
        };
        ack(Http.text(200, "ok"));
      };
      case (#ok(#sessionExpired(expired))) handleSessionExpired(deps, expired, nowNs);
      case (#ok(#chargeRefunded(refund))) handleRefund(deps, refund, nowNs);
      case (#ok(#checkoutCompleted(session))) handleCheckout(deps, session, nowNs);
    };
  };

  /// Stripe closed a session unpaid (#33).
  ///
  /// ⚠️ **This handler must never trap.** A trap here is a 5xx, which Stripe
  /// retries for about three days. Three reachable cases, all of which end 200:
  ///
  /// 1. **A `#cancelled` order — the NORMAL path.** Cancelling expires the
  ///    session, so Stripe fires this event for *every* cancel. "Mark it expired"
  ///    is an illegal transition there, so it degrades to a status no-op through
  ///    `applyTransition` rather than being treated as an error.
  /// 2. **A session we do not recognise** — an order from before a reinstall, or
  ///    another integration pointed at this endpoint. Audit and ack.
  /// 3. **A redelivery.** Deduped on the event id, so the status and (once #30
  ///    lands) the tally are both no-ops.
  ///
  /// **Binding:** if the order has a `stripeSessionId`, the event's must match it
  /// — a mismatch is audited and treated as unattributed. If it is null, attribute
  /// by `client_reference_id` and backfill the id. That null-accept half is
  /// load-bearing: it is how the residue order whose session-create response was
  /// lost heals itself when that session's own expiry arrives ~30 minutes later.
  func handleSessionExpired(
    deps : Deps,
    expired : { eventId : Text; sessionId : Text; clientReferenceId : ?Text },
    nowNs : Int,
  ) : Outcome {
    if (not Idempotency.recordStripeEvent(deps.dedup, expired.eventId, nowNs)) {
      // A redelivery. Everything below is idempotent anyway, but returning here
      // keeps the audit log from filling with copies.
      return ack(Http.text(200, "duplicate event"));
    };
    let ?ref = expired.clientReferenceId else {
      audit(deps, nowNs, "stripe.expiredUnattributed", "session " # expired.sessionId # " expired with no client_reference_id");
      return ack(Http.text(200, "ok"));
    };
    let ?(_, orderId) = Orders.parseClientReferenceId(ref) else {
      audit(deps, nowNs, "stripe.expiredUnattributed", "session " # expired.sessionId # " expired with a malformed reference");
      return ack(Http.text(200, "ok"));
    };
    let ?order = Orders.get(deps.orders, orderId) else {
      audit(deps, nowNs, "stripe.expiredUnattributed", "session " # expired.sessionId # " names order " # orderId # ", which this gateway does not hold");
      return ack(Http.text(200, "ok"));
    };
    switch (order.stripeSessionId) {
      case (?stored) {
        if (stored != expired.sessionId) {
          audit(deps, nowNs, "stripe.expiredSessionMismatch", "order " # orderId # " holds session " # stored # " but the event names " # expired.sessionId);
          return ack(Http.text(200, "ok"));
        };
      };
      // Null is accepted and backfilled — see the note above.
      case null {};
    };
    switch (Orders.expireBySession(deps.orders, orderId, expired.sessionId, nowNs)) {
      case (#ok(_)) {
        audit(deps, nowNs, "stripe.sessionExpired", "order " # orderId # " expired by Stripe (session " # expired.sessionId # ")");
      };
      case (#err(_)) {
        // Case 1 above, almost always: the order is already `#cancelled`, which
        // is what cancelling it did. Not an error, and not silent.
        audit(deps, nowNs, "stripe.sessionExpiredNoop", "order " # orderId # " was already " # Types.statusToText(order.status));
      };
    };
    ack(Http.text(200, "ok"));
  };

  /// A verified event we cannot process — e.g. a checkout session with no
  /// `payment_intent`, reachable through a subscription-mode link or a 100%-off
  /// promo code.
  ///
  /// **Acked 200, not 400.** Parsing is deterministic, so a 400 here would repeat
  /// on every Stripe retry for the full ~3-day horizon; Stripe warns about and can
  /// **disable** an endpoint that keeps failing, and a disabled endpoint loses
  /// every *legitimate* webhook after it. Refusing delivery of a message that can
  /// never succeed trades a permanent outage for no benefit. Non-2xx stays for
  /// input we cannot authenticate and for the unprovisioned-secret case, where
  /// retrying is exactly what we want.
  ///
  /// The obligation goes on the worklist instead, deduped on the event id so
  /// Stripe's retries do not pile up copies.
  func handleUnprocessable(deps : Deps, field : Text, eventId : ?Text, nowNs : Int) : Outcome {
    let detail = "verified Stripe event is missing " # field
      # " — cannot be processed; inspect it in the Stripe Dashboard and reconcile by hand";
    switch (eventId) {
      case (?id) {
        if (not Idempotency.recordStripeEvent(deps.dedup, id, nowNs)) {
          return ack(Http.text(200, "duplicate event"));
        };
        // Past the ~7-day dedup retention the check above no longer recognises a
        // resend, so the worklist itself is the second line of defence: one
        // unreadable event must not become two items to reconcile.
        switch (Orphans.unresolvedUnprocessable(deps.orphanStore, id)) {
          case (?_) {
            audit(deps, nowNs, "stripe.unprocessableResend", id # " already on the worklist");
            return ack(Http.text(200, "already queued"));
          };
          case null {};
        };
        ignore Orphans.add(
          deps.orphanStore,
          deps.orphanCapacity,
          #card,
          #unprocessable({ eventId = id; field }),
          detail,
          nowNs,
        );
        audit(deps, nowNs, "stripe.unprocessable", id # ": " # detail);
      };
      case null {
        // No id parsed, so nothing to dedup on and nothing stable to key an
        // entry to. The audit line is the whole trail here.
        audit(deps, nowNs, "stripe.unprocessable", detail);
      };
    };
    ack(Http.text(200, "acknowledged: queued for operator review"));
  };

};
