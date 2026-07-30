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
/// Ingestion invariants (§4.1): dedup gates the mint; every verified dollar
/// resolves to a `#paid` order or a Type 1 error-queue entry (Type 2 only
/// exists after minting, §5); `client_reference_id` is claimed, not trusted;
/// the *actual* paid amount is honored, repriced from the order's creation
/// pricing snapshot when it differs from the quoted tier. The whole path is
/// synchronous — no awaits, so no interleaving between check and write.
/// State lives in `Deps` (Main.mo's stores, injected) so the path unit-tests
/// without an IC environment.
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Set "mo:core/Set";
import Text "mo:core/Text";
import AuditLog "../AuditLog";
import ErrorQueue "../ErrorQueue";
import Pricing "../Pricing";
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

  /// Parse a `Stripe-Signature` header: comma-separated `key=value` elements,
  /// e.g. `t=1492774577,v1=5257a8...,v0=6ffbb5...`. Per Stripe's reference
  /// parsers: unknown schemes (`v0=`...) and unparseable elements are
  /// ignored; only the first `t=` counts. Null when no usable `t=`/`v1=`
  /// remain — the verifier treats that as malformed.
  public func parseSignatureHeader(header : Text) : ?ParsedSignature {
    var timestampSeconds : ?Nat = null;
    var sawTimestamp = false;
    let v1 = List.empty<Blob>();
    for (element in header.split(#char ',')) {
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
    /// `payment_status == "paid"`. False = async payment method still
    /// pending — out of scope for card-only Payment Links (§6.1).
    paid : Bool;
  };

  public type Event = {
    #checkoutCompleted : CheckoutCompleted;
    #chargeRefunded : { eventId : Text; paymentIntent : Text };
    /// Recognized envelope, event type we don't handle — acked and dropped
    /// (Stripe endpoints should be subscribed to only the two above, but an
    /// extra type must not look like a delivery failure).
    #unhandled : { eventId : Text; eventType : Text };
  };

  public type ParseError = {
    #invalidJson;
    /// A handled event type missing a field we require — e.g. a checkout
    /// session without a `payment_intent` (subscription-mode link). 400s
    /// so the failure is visible in the Stripe dashboard, not silently
    /// acked into the void.
    #missingField : Text;
  };

  /// Parse a verified webhook body. Only called *after* `verify` — the JSON
  /// is authentic Stripe output, but string values inside it (emails, names)
  /// still carry user-influenced content, which is why this is a tree parse
  /// (Json.mo) and never a substring scan.
  public func parseEvent(body : Blob) : Result.Result<Event, ParseError> {
    let ?text = body.decodeUtf8() else return #err(#invalidJson);
    let ?json = Json.parse(text) else return #err(#invalidJson);
    let ?eventId = Json.textAt(json, "id") else return #err(#missingField("id"));
    let ?eventType = Json.textAt(json, "type") else return #err(#missingField("type"));
    func required(path : Text) : Result.Result<Text, ParseError> {
      switch (Json.textAt(json, path)) {
        case (?value) #ok(value);
        case (null) #err(#missingField(path));
      };
    };
    if (eventType == "checkout.session.completed") {
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
        return #err(#missingField("data.object.amount_total"));
      };
      #ok(#checkoutCompleted({
        eventId;
        paymentIntent;
        // Absent and JSON-null both mean "no reference" (Stripe sends null
        // when the link was opened without the param).
        clientReferenceId = Json.textAt(json, "data.object.client_reference_id");
        amountTotalCents;
        currency;
        paid = paymentStatus == "paid";
      }));
    } else if (eventType == "charge.refunded") {
      switch (required("data.object.payment_intent")) {
        case (#ok(paymentIntent)) #ok(#chargeRefunded({ eventId; paymentIntent }));
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
    errorQueue : ErrorQueue.Store;
    errorQueueCapacity : Nat;
    auditLog : AuditLog.Log;
    auditLogCapacity : Nat;
    /// Retention band-3 tombstones (Retention.mo). A payment quoting a swept
    /// order still becomes Type 1, but with a *certain* reason instead of the
    /// generic "no such order" that a forged reference also produces.
    sweptOrders : Set.Set<Types.OrderId>;
    /// `payment_intent` → order it paid for. Written when an order is marked
    /// paid; the only way a later `charge.refunded` can tell whether the
    /// refunded payment had already been delivered as cycles. A financial
    /// record — never pruned, and bounded by real volume (which the burn cap
    /// bounds), unlike the `#unattributed` spam the dedup sets absorb.
    paidIntents : Map.Map<Text, Types.OrderId>;
    /// Per-purchase ceiling (`Gate.Config.maxPurchaseUsdCents`) — the webhook
    /// honours the *actual* paid amount, so without this an implausible
    /// payment would be repriced upward and minted.
    maxPurchaseUsdCents : Nat;
  };

  /// What the webhook path produced: the HTTP response Stripe sees, plus
  /// whether this delivery actually created money-out work.
  ///
  /// `paidOrder` is non-null on exactly one path — a verified, deduped,
  /// attributed payment that transitioned an order to `#paid`. Everything else
  /// (guard rejections, duplicates, Type 1 entries, refunds, unhandled event
  /// types) leaves it null. The caller uses it to decide whether to kick the
  /// mint pipeline: an anonymous request that reaches no order must not be able
  /// to trigger a sweep over every order, which is otherwise an operation that
  /// is free to invoke and expensive to run.
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

  /// Queue a Type 1 entry (§4.1: fiat exists, nothing minted — operator
  /// refunds in the Stripe Dashboard). Always 200: the payment is handled,
  /// just not by delivery; a non-2xx would make Stripe redeliver an event
  /// we have already routed.
  func queueType1(deps : Deps, kind : ErrorQueue.Kind, detail : Text, nowNs : Int) : Http.Response {
    let result = ErrorQueue.add(deps.errorQueue, deps.errorQueueCapacity, #card, kind, detail, nowNs);
    for (victim in result.evicted.values()) {
      if (victim.resolvedAtNs == null) {
        // §4.1: an unresolved eviction is a live money obligation dropped
        // from on-chain state — the one thing the audit trail must show.
        audit(deps, nowNs, "errorQueue.evictedUnresolved", "entry " # victim.id.toText() # ": " # victim.detail);
      };
    };
    audit(deps, nowNs, "stripe.type1", "entry " # result.entry.id.toText() # ": " # detail);
    Http.text(200, "queued for operator review");
  };

  /// `charge.refunded` (§4.1): auto-resolve every unresolved Type 1 entry
  /// carrying this payment_intent. No matches is fine — operators may
  /// refund payments that never queued.
  func handleRefund(deps : Deps, refund : { eventId : Text; paymentIntent : Text }, nowNs : Int) : Outcome {
    if (not Idempotency.recordStripeEvent(deps.dedup, refund.eventId, nowNs)) {
      return ack(Http.text(200, "duplicate event"));
    };
    let resolved = ErrorQueue.resolveByPaymentRef(deps.errorQueue, refund.paymentIntent, nowNs);
    for (entry in resolved.values()) {
      audit(deps, nowNs, "stripe.refundResolved", "entry " # entry.id.toText() # " auto-resolved by refund of " # refund.paymentIntent);
    };
    if (resolved.size() > 0) return ack(Http.text(200, "ok"));

    // Nothing resolved. Usually benign — operators may refund a payment that
    // never queued — but it is also how a refund of an already-delivered order
    // arrives, so the two are separated below and each leaves a trace.
    switch (deps.paidIntents.get(refund.paymentIntent)) {
      case null {
        // Genuinely unknown payment — never attributed to an order here.
        audit(deps, nowNs, "stripe.refundUnmatched", "refund of " # refund.paymentIntent # " matched no queue entry and no paid order");
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
                ignore ErrorQueue.add(
                  deps.errorQueue,
                  deps.errorQueueCapacity,
                  order.rail,
                  #refundAfterDelivery({
                    orderId;
                    paymentRef = refund.paymentIntent;
                    cycles = order.lockedCycles;
                  }),
                  "refund/chargeback on a DELIVERED order: " # order.lockedCycles.toText() # " cycles already forwarded and cannot be recovered — reconcile against Stripe and decide whether to restrict the payer",
                  nowNs,
                );
                audit(deps, nowNs, "stripe.refundAfterDelivery", orderId # ": " # refund.paymentIntent # " refunded after " # order.lockedCycles.toText() # " cycles were delivered");
              };
              case (status) {
                // Paid but not yet delivered — the money-out pipeline may
                // still be mid-flight, so this is a race the operator must
                // look at rather than a settled loss.
                audit(deps, nowNs, "stripe.refundBeforeDelivery", orderId # ": " # refund.paymentIntent # " refunded while order was " # Types.statusToText(status));
              };
            };
          };
        };
      };
    };
    ack(Http.text(200, "ok"));
  };

  /// `checkout.session.completed` (§6.1): dedup → attribute (claimed, not
  /// trusted) → honor the actual paid amount → `#paid`, or Type 1.
  func handleCheckout(deps : Deps, session : CheckoutCompleted, nowNs : Int) : Outcome {
    // event.id first: catches Stripe redelivering this exact event.
    if (not Idempotency.recordStripeEvent(deps.dedup, session.eventId, nowNs)) {
      return ack(Http.text(200, "duplicate event"));
    };
    if (not session.paid) {
      // Async payment method on a link that should be card-only — money may
      // arrive later via an event type we don't handle, so make the config
      // problem visible instead of silently acking it.
      audit(deps, nowNs, "stripe.unpaidSession", "payment_status not paid for intent " # session.paymentIntent);
      return ack(Http.text(200, "ignored: payment not completed"));
    };
    // payment_intent second: one mint per payment even across distinct
    // event deliveries for the same intent (§4.2).
    if (not Idempotency.recordStripeIntent(deps.dedup, session.paymentIntent, nowNs)) {
      return ack(Http.text(200, "duplicate payment intent"));
    };
    // ── Attribution (§4.1: claimed, not trusted). Failures are Type 1
    // #unattributed: fiat arrived, nothing will be minted.
    let claimedRef = ErrorQueue.truncateClaimedRef(
      switch (session.clientReferenceId) { case (?r) r; case (null) "" }
    );
    func unattributed(detail : Text) : Outcome {
      ack(queueType1(deps, #unattributed({ claimedRef; paymentRef = session.paymentIntent }), detail, nowNs));
    };
    let ?ref = session.clientReferenceId else return unattributed("missing client_reference_id");
    let ?(claimedOwnerText, orderId) = Orders.parseClientReferenceId(ref) else {
      return unattributed("malformed client_reference_id");
    };
    let ?order = Orders.get(deps.orders, orderId) else {
      // Retention band 3 (Retention.mo): distinguish "we deliberately swept an
      // abandoned order" from "this reference never existed". Same Type 1
      // outcome and the same manual refund, but the operator gets certainty
      // instead of having to guess whether it was a forged parameter.
      if (deps.sweptOrders.contains(orderId)) {
        return unattributed("order " # orderId # " was SWEPT as abandoned past the retention horizon — this is a genuine late payment for an order we deliberately deleted; refund it");
      };
      return unattributed("no order " # orderId);
    };
    let #ii(owner) = order.owner;
    if (owner.toText() != claimedOwnerText) return unattributed("claimed owner does not match order " # orderId);
    if (order.rail != #card) return unattributed("order " # orderId # " is not a card order");
    switch (order.status) {
      case (#created or #expired) {}; // §4: late payment on an expired order is still honored
      case (status) {
        // Distinct payment_intent for an already-handled order = a genuine
        // second payment (§4.1: Stripe dedup ≠ double-pay protection).
        return ack(queueType1(
          deps,
          #duplicate({ orderId; paymentRef = session.paymentIntent }),
          "second payment for order " # orderId # " (status " # Types.statusToText(status) # ")",
          nowNs,
        ));
      };
    };
    if (session.currency != "usd") {
      return unattributed("unexpected currency " # session.currency # " for order " # orderId);
    };
    // ── §3/§6.1: honor the ACTUAL paid amount. The expected tier amount
    // uses the locked quantity verbatim; anything else (user pasted the
    // reference onto a different tier's link) is repriced from the order's
    // creation pricing snapshot — never from a fresh rate.
    //
    // The ceiling applies here as well as at tier-config time: repricing is an
    // *upward* path when more was paid than quoted, so an implausible amount
    // (a tampered link, a misconfigured Stripe price) would otherwise mint an
    // arbitrary quantity. Over the ceiling we refuse to mint and let the money
    // land as Type 1 — the §4.1 rule that dedup gates the mint, applied to
    // amount as well as identity.
    if (session.amountTotalCents > deps.maxPurchaseUsdCents) {
      return unattributed(
        "paid amount " # session.amountTotalCents.toText() # " cents exceeds the per-purchase ceiling of "
        # deps.maxPurchaseUsdCents.toText() # " cents for order " # orderId # " — not minted; refund or raise the ceiling"
      );
    };
    let honoredCycles = if (session.amountTotalCents == order.pricing.usdCents) {
      order.lockedCycles;
    } else {
      let ?net = Pricing.netCents(order.pricing, session.amountTotalCents) else {
        return unattributed("paid amount " # session.amountTotalCents.toText() # " cents is below the fee floor of order " # orderId);
      };
      // Repriced from the order's own rate snapshot, never a fresh rate — both
      // inputs were captured at creation for exactly this.
      let ?repriced = Pricing.cyclesForCents(
        net,
        order.pricing.xdrPermyriadPerIcp,
        order.pricing.usdPerIcpMicros,
      ) else {
        return unattributed("order " # orderId # " carries an unusable rate snapshot; cannot reprice " # session.amountTotalCents.toText() # " cents");
      };
      repriced;
    };
    switch (Orders.markPaid(deps.orders, orderId, honoredCycles, nowNs)) {
      case (#ok(_)) {
        // Link the payment to the order it funded, so a later refund of this
        // intent can tell whether cycles were already delivered.
        deps.paidIntents.add(session.paymentIntent, orderId);
        if (honoredCycles != order.lockedCycles) {
          audit(deps, nowNs, "stripe.amountMismatch", "order " # orderId # " honored at " # session.amountTotalCents.toText() # " cents = " # honoredCycles.toText() # " cycles (quoted " # order.pricing.usdCents.toText() # " cents)");
        };
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
      case (#err(_)) ack(Http.text(400, "unparseable event"));
      case (#ok(#unhandled(_))) ack(Http.text(200, "ignored"));
      case (#ok(#chargeRefunded(refund))) handleRefund(deps, refund, nowNs);
      case (#ok(#checkoutCompleted(session))) handleCheckout(deps, session, nowNs);
    };
  };

};
