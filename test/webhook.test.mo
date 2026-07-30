import { test; suite } "mo:test";
import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import AuditLog "../src/backend/AuditLog";
import ErrorQueue "../src/backend/ErrorQueue";
import Http "../src/backend/Http";
import Idempotency "../src/backend/Idempotency";
import Orders "../src/backend/Orders";
import Types "../src/backend/Types";
import Card "../src/backend/rails/Card";
import Util "../src/backend/Util";

// Task 8 — webhook ingestion (§6.1 complete), end to end over crafted
// *signed* payloads: verify → dedup → claimed-not-trusted attribution →
// honor the actual paid amount → #paid, with every failure landing in the
// §4.1 Type 1 error queue. Signatures are minted with signedPayloadMac,
// which card.test.mo pins against externally computed vectors — so these
// tests exercise ingestion, not the MAC's self-consistency.

let secret = Text.encodeUtf8("whsec_8fJ3kQ9mN2pX7vR4tL6wY1zB5cD0eH");
let t = 1_749_600_000;
let nowNs = t * 1_000_000_000;

let alice = Principal.fromText("aaaaa-aa");
let orderId = "000102030405060708090a0b0c0d0e0f";
let goodRef = "aaaaa-aa_" # orderId;

// The shared §3 vector, chosen so the at-cost property is visible: 500¢ gross,
// fee ⌈500·290/10⁴⌉+30 = 45¢, net 455¢. At $4.55/ICP that net buys exactly one
// ICP, which mints 35_000 × 10⁸ = 3.5 T cycles. Money in, exactly that much ICP
// out — if those two ever disagree, the formula is wrong.
let pricing : Types.Pricing = {
  usdCents = 500;
  usdPerIcpMicros = 4_550_000; // $4.55 per ICP
  xdrPermyriadPerIcp = 35_000; // 3.5 XDR per ICP
  rateStandardDeviation = 0;
  rateReceivedRates = 5;
  rateQueriedSources = 5;
  feeBps = 290;
  feeFixedCents = 30;
};
let lockedCycles : Nat = 3_500_000_000_000;

func freshDeps() : Card.Deps {
  {
    orders = Orders.emptyStore();
    dedup = Idempotency.emptyStore();
    errorQueue = ErrorQueue.emptyStore();
    errorQueueCapacity = 10;
    // Unset: these tests are about ingestion, not Stripe-mode configuration.
    // The livemode gate has its own suite below.
    expectLivemode = null;
    auditLog = AuditLog.emptyLog();
    auditLogCapacity = 100;
    paidIntents = Map.empty<Text, Types.OrderId>();
    // Well above the 500¢ tier these tests use, so the ceiling is out of the
    // way except where a test deliberately probes it.
    maxPurchaseUsdCents = 100_000;
  };
};

func withOrder(deps : Card.Deps, rail : Types.Rail) {
  switch (Orders.create(deps.orders, orderId, #ii(alice), rail, #canister(alice), lockedCycles, pricing, 100)) {
    case (#ok(_)) {};
    case (#err(_)) Runtime.trap("test order creation failed");
  };
};

func checkoutBody(eventId : Text, intent : Text, ref : ?Text, amountCents : Nat, currency : Text, paymentStatus : Text) : Blob {
  typedCheckoutBody("checkout.session.completed", eventId, intent, ref, amountCents, currency, paymentStatus, true);
};

/// The session shape, parameterised on event type and livemode — Stripe sends
/// the identical object for `completed` and `async_payment_succeeded`.
func typedCheckoutBody(
  eventType : Text,
  eventId : Text,
  intent : Text,
  ref : ?Text,
  amountCents : Nat,
  currency : Text,
  paymentStatus : Text,
  livemode : Bool,
) : Blob {
  let refJson = switch (ref) {
    case (?r) "\"" # r # "\"";
    case (null) "null";
  };
  (
    "{\"id\":\"" # eventId # "\",\"type\":\"" # eventType # "\"," #
    "\"livemode\":" # (if (livemode) "true" else "false") # "," #
    "\"data\":{\"object\":{\"payment_intent\":\"" # intent # "\"," #
    "\"client_reference_id\":" # refJson # "," #
    "\"amount_total\":" # amountCents.toText() # "," #
    "\"currency\":\"" # currency # "\"," #
    "\"payment_status\":\"" # paymentStatus # "\"}}}"
  ).encodeUtf8();
};

func paidBody(eventId : Text, intent : Text, ref : ?Text, amountCents : Nat) : Blob {
  checkoutBody(eventId, intent, ref, amountCents, "usd", "paid");
};

/// A **full** refund: cumulative refunded equals the charge total.
func refundBody(eventId : Text, intent : Text) : Blob {
  partialRefundBody(eventId, intent, 500, 500);
};

/// `charge.refunded` carries a charge, so `amount` is the total and
/// `amount_refunded` is cumulative.
func partialRefundBody(eventId : Text, intent : Text, refunded : Nat, chargeTotal : Nat) : Blob {
  (
    "{\"id\":\"" # eventId # "\",\"type\":\"charge.refunded\",\"livemode\":true," #
    "\"data\":{\"object\":{\"payment_intent\":\"" # intent # "\"," #
    "\"amount\":" # chargeTotal.toText() # "," #
    "\"amount_refunded\":" # refunded.toText() # "}}}"
  ).encodeUtf8();
};

func signedReq(body : Blob) : Http.Request {
  let mac = Util.hexEncode(Card.signedPayloadMac(secret, t, body));
  {
    method = "POST";
    url = "/webhook/stripe";
    headers = [("Stripe-Signature", "t=" # t.toText() # ",v1=" # mac)];
    body;
  };
};

func deliverFull(deps : Card.Deps, body : Blob) : Card.Outcome {
  Card.handleWebhook(deps, ?secret, signedReq(body), nowNs, Card.defaultToleranceSeconds);
};

func deliver(deps : Card.Deps, body : Blob) : Http.Response {
  deliverFull(deps, body).response;
};

func bodyText(resp : Http.Response) : Text {
  switch (resp.body.decodeUtf8()) {
    case (?text) text;
    case (null) Runtime.trap("non-utf8 response body");
  };
};

func statusOf(deps : Card.Deps) : Types.OrderStatus {
  switch (Orders.get(deps.orders, orderId)) {
    case (?order) order.status;
    case (null) Runtime.trap("test order vanished");
  };
};

suite("parseEvent", func() {
  test("checkout.session.completed parses every field", func() {
    let body = paidBody("evt_1", "pi_1", ?goodRef, 500);
    switch (Card.parseEvent(body)) {
      case (#ok(#checkoutCompleted(s))) {
        assert s.eventId == "evt_1";
        assert s.paymentIntent == "pi_1";
        assert s.clientReferenceId == ?goodRef;
        assert s.amountTotalCents == 500;
        assert s.currency == "usd";
        assert s.paid;
      };
      case _ assert false;
    };
  });

  test("client_reference_id JSON null reads as absent", func() {
    switch (Card.parseEvent(paidBody("evt_1", "pi_1", null, 500))) {
      case (#ok(#checkoutCompleted(s))) assert s.clientReferenceId == null;
      case _ assert false;
    };
  });

  test("payment_status other than \"paid\" parses with paid = false", func() {
    switch (Card.parseEvent(checkoutBody("evt_1", "pi_1", ?goodRef, 500, "usd", "unpaid"))) {
      case (#ok(#checkoutCompleted(s))) assert not s.paid;
      case _ assert false;
    };
  });

  test("charge.refunded parses", func() {
    switch (Card.parseEvent(refundBody("evt_2", "pi_1"))) {
      case (#ok(#chargeRefunded(r))) {
        assert r.eventId == "evt_2";
        assert r.paymentIntent == "pi_1";
      };
      case _ assert false;
    };
  });

  test("unknown event type is recognized as unhandled, not an error", func() {
    let body = ("{\"id\":\"evt_3\",\"type\":\"invoice.paid\",\"data\":{\"object\":{}}}").encodeUtf8();
    switch (Card.parseEvent(body)) {
      case (#ok(#unhandled({ eventId = "evt_3"; eventType = "invoice.paid" }))) {};
      case _ assert false;
    };
  });

  test("invalid JSON and non-UTF-8 bodies fail", func() {
    assert Card.parseEvent(("{not json").encodeUtf8()) == #err(#invalidJson);
    assert Card.parseEvent("\FF\FE" : Blob) == #err(#invalidJson);
  });

  test("null payment_intent (subscription-mode session) is a missing field", func() {
    let body = (
      "{\"id\":\"evt_1\",\"type\":\"checkout.session.completed\"," #
      "\"data\":{\"object\":{\"payment_intent\":null,\"client_reference_id\":null," #
      "\"amount_total\":500,\"currency\":\"usd\",\"payment_status\":\"paid\"}}}"
    ).encodeUtf8();
    assert Card.parseEvent(body) == #err(#missingField({ field = "data.object.payment_intent"; eventId = ?"evt_1" }));
  });

  test("non-integer amount_total is a missing field", func() {
    let body = (
      "{\"id\":\"evt_1\",\"type\":\"checkout.session.completed\"," #
      "\"data\":{\"object\":{\"payment_intent\":\"pi_1\",\"client_reference_id\":null," #
      "\"amount_total\":5.5,\"currency\":\"usd\",\"payment_status\":\"paid\"}}}"
    ).encodeUtf8();
    assert Card.parseEvent(body) == #err(#missingField({ field = "data.object.amount_total"; eventId = ?"evt_1" }));
  });
});

suite("handleWebhook: envelope guards", func() {
  test("unprovisioned secret answers 503 (Stripe keeps retrying)", func() {
    let resp = Card.handleWebhook(freshDeps(), null, signedReq(paidBody("evt_1", "pi_1", ?goodRef, 500)), nowNs, Card.defaultToleranceSeconds).response;
    assert resp.status_code == 503;
  });

  test("missing Stripe-Signature header is 400", func() {
    let req = { signedReq(paidBody("evt_1", "pi_1", ?goodRef, 500)) with headers = [] : [Http.HeaderField] };
    assert Card.handleWebhook(freshDeps(), ?secret, req, nowNs, Card.defaultToleranceSeconds).response.status_code == 400;
  });

  test("bad signature is 400 and touches no state", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    let body = paidBody("evt_1", "pi_1", ?goodRef, 500);
    let forged = { signedReq(body) with body = paidBody("evt_1", "pi_1", ?goodRef, 9_999) };
    assert Card.handleWebhook(deps, ?secret, forged, nowNs, Card.defaultToleranceSeconds).response.status_code == 400;
    assert statusOf(deps) == #created;
    // the rejected delivery consumed nothing: the genuine one still lands
    assert deliver(deps, body).status_code == 200;
    assert statusOf(deps) == #paid;
  });

  test("a signed but unreadable body is acked 200, never retried into oblivion", func() {
    // Once the MAC verifies, the event really came from Stripe. Parsing is
    // deterministic, so a non-2xx would fail identically on every retry for the
    // full ~3-day horizon — and Stripe can DISABLE an endpoint that keeps
    // failing, which would then lose every legitimate webhook after it. Trading
    // a permanent outage for a refusal that can never succeed is strictly worse.
    let deps = freshDeps();
    let resp = deliver(deps, ("not json at all").encodeUtf8());
    assert resp.status_code == 200;
    // Not silent: the operator has to be able to find it.
    assert AuditLog.events(deps.auditLog).find(func(e) = e.tag == "stripe.unparseable") != null;
  });

  test("a verified event missing a required field is queued, not refused", func() {
    // Reachable in production: a subscription-mode link or a 100%-off promo code
    // produces a session with no payment_intent.
    let deps = freshDeps();
    let body = (
      "{\"id\":\"evt_nopi\",\"type\":\"checkout.session.completed\",\"livemode\":true," #
      "\"data\":{\"object\":{\"payment_intent\":null,\"client_reference_id\":null," #
      "\"amount_total\":500,\"currency\":\"usd\",\"payment_status\":\"paid\"}}}"
    ).encodeUtf8();
    assert deliver(deps, body).status_code == 200;
    let open = ErrorQueue.unresolved(deps.errorQueue);
    assert open.size() == 1;
    switch (open[0].kind) {
      case (#unprocessable({ eventId; field })) {
        assert eventId == "evt_nopi";
        assert field == "data.object.payment_intent";
      };
      case (_) Runtime.trap("expected #unprocessable");
    };
    // Stripe retries the same event; the obligation must not be duplicated.
    assert deliver(deps, body).status_code == 200;
    assert ErrorQueue.unresolved(deps.errorQueue).size() == 1;
  });

  test("signed unhandled event type is acked 200, ignored, and audited", func() {
    let deps = freshDeps();
    let resp = deliver(deps, ("{\"id\":\"evt_x\",\"type\":\"invoice.paid\"}").encodeUtf8());
    assert resp.status_code == 200;
    assert bodyText(resp) == "ignored";
    // An unsubscribed type arriving is a Stripe-config surprise, and this line is
    // the only way an operator ever learns of it.
    assert AuditLog.events(deps.auditLog).find(func(e) = e.tag == "stripe.unhandledType") != null;
  });

  test("a dispute event is acked rather than refused", func() {
    // charge.dispute.* is deliberately not subscribed (§11), but if a Dashboard
    // config sends one it must not 400 its way toward disabling the endpoint.
    let resp = deliver(
      freshDeps(),
      ("{\"id\":\"evt_d\",\"type\":\"charge.dispute.created\"}").encodeUtf8(),
    );
    assert resp.status_code == 200;
  });
});

suite("a resent webhook is never a second payment", func() {
  test("an intent already credited is a redelivery even with both dedup keys gone", func() {
    // Automatic Stripe retries (~3 days) can never outlive the ~7-day dedup
    // retention — but a manual "resend" from the Dashboard can, and resending an
    // event to confirm it was processed is an ordinary operator move. With the
    // keys pruned, attribution succeeds again and the old code reported a second
    // payment for an already-delivered charge, inviting a refund of legitimate
    // revenue. paidIntents is permanent and answers the real question.
    let deps = freshDeps();
    withOrder(deps, #card);
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    assert statusOf(deps) == #paid;

    // Simulate the pruning by starting from a store with only paidIntents intact:
    // a fresh dedup set is exactly what >7 days of pruning leaves behind.
    let replayed : Card.Deps = { deps with dedup = Idempotency.emptyStore() };
    let resp = deliver(replayed, paidBody("evt_1", "pi_1", ?goodRef, 500));
    assert resp.status_code == 200;
    assert bodyText(resp) == "already credited";
    // No obligation invented, and nothing minted twice.
    assert ErrorQueue.unresolved(replayed.errorQueue).size() == 0;
    assert AuditLog.events(replayed.auditLog).find(
      func(e) = e.tag == "stripe.replayedAfterPruning"
    ) != null;
  });

  test("a genuinely different intent for a handled order IS still a duplicate", func() {
    // The protection must not swallow real second payments — that is the whole
    // reason #duplicate exists (§4.1: Stripe dedup ≠ double-pay protection).
    let deps = freshDeps();
    withOrder(deps, #card);
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    assert deliver(deps, paidBody("evt_2", "pi_2", ?goodRef, 500)).status_code == 200;
    let open = ErrorQueue.unresolved(deps.errorQueue);
    assert open.size() == 1;
    switch (open[0].kind) {
      case (#duplicate({ paymentRef; orderId = _ })) assert paymentRef == "pi_2";
      case (_) Runtime.trap("expected #duplicate");
    };
  });
});

suite("charge.refunded: partial vs full", func() {
  test("isFullRefund is cumulative-vs-total, and a zero-total charge is never full", func() {
    assert Card.isFullRefund({ eventId = "e"; paymentIntent = "p"; amountRefundedCents = 500; chargeAmountCents = 500 });
    assert Card.isFullRefund({ eventId = "e"; paymentIntent = "p"; amountRefundedCents = 501; chargeAmountCents = 500 });
    assert not Card.isFullRefund({ eventId = "e"; paymentIntent = "p"; amountRefundedCents = 499; chargeAmountCents = 500 });
    assert not Card.isFullRefund({ eventId = "e"; paymentIntent = "p"; amountRefundedCents = 0; chargeAmountCents = 500 });
    // A charge total of 0 would make any refund look complete.
    assert not Card.isFullRefund({ eventId = "e"; paymentIntent = "p"; amountRefundedCents = 0; chargeAmountCents = 0 });
  });

  test("a PARTIAL refund leaves the Type 1 obligation open", func() {
    // The expensive bug this prevents: Stripe fires charge.refunded on ANY
    // refund, so a small courtesy refund would otherwise auto-resolve the whole
    // entry and the unrefunded remainder would have no record anywhere except
    // the audit ring, which drops.
    let deps = freshDeps();
    assert deliver(deps, paidBody("evt_1", "pi_1", ?"bogus_ref", 500)).status_code == 200;
    assert ErrorQueue.unresolved(deps.errorQueue).size() == 1;

    assert deliver(deps, partialRefundBody("evt_2", "pi_1", 5, 500)).status_code == 200;
    assert ErrorQueue.unresolved(deps.errorQueue).size() == 1;
    assert AuditLog.events(deps.auditLog).find(func(e) = e.tag == "stripe.refundPartial") != null;
    // ...and it does NOT also claim the refund matched nothing. Two audit lines
    // contradicting each other is worse than either alone: an operator reading
    // the trail cannot tell which is true.
    assert AuditLog.events(deps.auditLog).find(func(e) = e.tag == "stripe.refundUnmatched") == null;

    // Completing the refund settles it.
    assert deliver(deps, partialRefundBody("evt_3", "pi_1", 500, 500)).status_code == 200;
    assert ErrorQueue.unresolved(deps.errorQueue).size() == 0;
  });

  test("a partial refund after delivery records the amount actually returned", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    // The real money-out path, and asserted rather than ignored — a skipped
    // state is not a legal transition, and swallowing that would leave the order
    // in #paid and silently test the wrong branch.
    for (to in ([#minting, #icpAtCmc, #delivered] : [Types.OrderStatus]).values()) {
      switch (Orders.applyTransition(deps.orders, orderId, to, nowNs)) {
        case (#ok(_)) {};
        case (#err(_)) Runtime.trap("could not drive the order to #delivered");
      };
    };

    assert deliver(deps, partialRefundBody("evt_2", "pi_1", 125, 500)).status_code == 200;
    let open = ErrorQueue.unresolved(deps.errorQueue);
    assert open.size() == 1;
    switch (open[0].kind) {
      case (#refundAfterDelivery({ refundedCents; fullRefund; cycles; orderId = oid; paymentRef })) {
        // A partial refund is a partial loss, and the operator reconciles by
        // amount — so the amount has to be on the record, not just the fact.
        assert refundedCents == 125;
        assert not fullRefund;
        assert cycles == lockedCycles;
        assert oid == orderId;
        assert paymentRef == "pi_1";
      };
      case (_) Runtime.trap("expected #refundAfterDelivery");
    };
  });
});

suite("handleWebhook: livemode gate", func() {
  func depsExpecting(expected : ?Bool) : Card.Deps {
    { freshDeps() with expectLivemode = expected };
  };

  test("a test-mode payment never mints on a gateway declared live", func() {
    // The scenario: an operator pastes a test-mode signing secret into a canister
    // funded with a real ICP float. Without this check, test events mint real
    // cycles for payments that never happened.
    let deps = depsExpecting(?true);
    withOrder(deps, #card);
    let body = typedCheckoutBody(
      "checkout.session.completed", "evt_1", "pi_1", ?goodRef, 500, "usd", "paid", false,
    );
    assert deliver(deps, body).status_code == 200;
    assert statusOf(deps) == #created;
    // No obligation: a test payment owes nobody anything.
    assert ErrorQueue.unresolved(deps.errorQueue).size() == 0;
    assert AuditLog.events(deps.auditLog).find(func(e) = e.tag == "stripe.livemodeMismatch") != null;
  });

  test("a LIVE payment on a test-declared gateway is an obligation, not a shrug", func() {
    // The reverse mistake: real money arrived somewhere configured for test. It
    // must not mint, but it must land on the worklist — the money is real.
    let deps = depsExpecting(?false);
    withOrder(deps, #card);
    let body = typedCheckoutBody(
      "checkout.session.completed", "evt_1", "pi_1", ?goodRef, 500, "usd", "paid", true,
    );
    assert deliver(deps, body).status_code == 200;
    assert statusOf(deps) == #created;
    assert ErrorQueue.unresolved(deps.errorQueue).size() == 1;
  });

  test("an UNSETTLED session raises no livemode obligation — no money has moved", func() {
    // The bug this pins: the mismatch check used to run before the paid check, so
    // an unpaid async session on a mode-mismatched gateway queued an entry
    // claiming "LIVE payment arrived — money is in the live Stripe account" when
    // nothing had settled and possibly never would. And if it later settled, the
    // mismatch branch returned before intent dedup, so it queued a SECOND
    // obligation for the same intent.
    let deps = depsExpecting(?false);
    withOrder(deps, #card);
    let pending = typedCheckoutBody(
      "checkout.session.completed", "evt_1", "pi_1", ?goodRef, 500, "usd", "unpaid", true,
    );
    assert deliver(deps, pending).status_code == 200;
    assert ErrorQueue.unresolved(deps.errorQueue).size() == 0;
    assert AuditLog.events(deps.auditLog).find(func(e) = e.tag == "stripe.unpaidSession") != null;
    assert AuditLog.events(deps.auditLog).find(func(e) = e.tag == "stripe.livemodeMismatch") == null;

    // Settlement now raises exactly ONE obligation, not a second copy.
    let settled = typedCheckoutBody(
      "checkout.session.async_payment_succeeded", "evt_2", "pi_1", ?goodRef, 500, "usd", "paid", true,
    );
    assert deliver(deps, settled).status_code == 200;
    assert ErrorQueue.unresolved(deps.errorQueue).size() == 1;
  });

  test("a live-on-test obligation keeps the real reference, not a placeholder", func() {
    // The reference is the only field identifying WHICH order to rescue once the
    // configuration is fixed; discarding it turns a recoverable misconfiguration
    // into a manual hunt through the Stripe Dashboard.
    let deps = depsExpecting(?false);
    withOrder(deps, #card);
    let body = typedCheckoutBody(
      "checkout.session.completed", "evt_1", "pi_1", ?goodRef, 500, "usd", "paid", true,
    );
    assert deliver(deps, body).status_code == 200;
    let open = ErrorQueue.unresolved(deps.errorQueue);
    assert open.size() == 1;
    switch (open[0].kind) {
      case (#unattributed({ claimedRef; paymentRef })) {
        assert claimedRef == goodRef;
        assert paymentRef == "pi_1";
      };
      case (_) Runtime.trap("expected #unattributed");
    };
  });

  test("an unset expectation is audited on every honoured payment", func() {
    // A gateway taking payments without a declared mode has no defence against a
    // test-mode secret minting real cycles. The nudge stops once it is declared.
    let deps = depsExpecting(null);
    withOrder(deps, #card);
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    assert statusOf(deps) == #paid;
    assert AuditLog.events(deps.auditLog).find(func(e) = e.tag == "stripe.livemodeUnset") != null;

    // Declared: no nudge.
    let declared = depsExpecting(?true);
    withOrder(declared, #card);
    assert deliver(declared, paidBody("evt_2", "pi_2", ?goodRef, 500)).status_code == 200;
    assert AuditLog.events(declared.auditLog).find(func(e) = e.tag == "stripe.livemodeUnset") == null;
  });

  test("matching modes mint normally, and an unset expectation accepts either", func() {
    let live = depsExpecting(?true);
    withOrder(live, #card);
    assert deliver(live, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    assert statusOf(live) == #paid;

    let unset = depsExpecting(null);
    withOrder(unset, #card);
    let testEvent = typedCheckoutBody(
      "checkout.session.completed", "evt_2", "pi_2", ?goodRef, 500, "usd", "paid", false,
    );
    assert deliver(unset, testEvent).status_code == 200;
    assert statusOf(unset) == #paid;
  });
});

suite("handleWebhook: checkout happy path + dedup (§4.2)", func() {
  test("verified paid session moves the order to #paid at the locked quantity", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    let resp = deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500));
    assert resp.status_code == 200;
    assert bodyText(resp) == "ok";
    switch (Orders.get(deps.orders, orderId)) {
      case (?order) {
        assert order.status == #paid;
        assert order.lockedCycles == lockedCycles; // amount matched the tier
      };
      case (null) assert false;
    };
    assert ErrorQueue.size(deps.errorQueue) == 0;
  });

  test("redelivered event.id is acked and dropped", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    let resp = deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500));
    assert resp.status_code == 200;
    assert bodyText(resp) == "duplicate event";
    assert ErrorQueue.size(deps.errorQueue) == 0; // a redelivery is not a double-pay
  });

  test("same payment_intent under a fresh event.id is acked and dropped", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    let resp = deliver(deps, paidBody("evt_2", "pi_1", ?goodRef, 500));
    assert resp.status_code == 200;
    assert bodyText(resp) == "duplicate payment intent";
    assert ErrorQueue.size(deps.errorQueue) == 0;
  });

  test("genuine second payment (fresh event + intent) is Type 1 #duplicate", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    let resp = deliver(deps, paidBody("evt_2", "pi_2", ?goodRef, 500));
    assert resp.status_code == 200;
    assert bodyText(resp) == "queued for operator review";
    let queued = ErrorQueue.unresolved(deps.errorQueue);
    assert queued.size() == 1;
    assert queued[0].kind == #duplicate({ orderId; paymentRef = "pi_2" });
    assert statusOf(deps) == #paid; // first payment's delivery is untouched
  });

  test("late payment on an expired order is honored (§4)", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    switch (Orders.applyTransition(deps.orders, orderId, #expired, 200)) {
      case (#ok(_)) {};
      case (#err(_)) assert false;
    };
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    assert statusOf(deps) == #paid;
  });

  test("an unsettled async payment mints when Stripe reports it succeeded", func() {
    // The real sequence for a delayed payment method. `completed` arrives with
    // payment_status != paid and money has NOT moved; settlement is reported
    // later as `checkout.session.async_payment_succeeded`, carrying the same
    // session object. Handling only `completed` would mean fiat arriving with
    // nothing minted and nothing on the worklist.
    let deps = freshDeps();
    withOrder(deps, #card);
    let resp = deliver(deps, checkoutBody("evt_1", "pi_1", ?goodRef, 500, "usd", "unpaid"));
    assert resp.status_code == 200;
    assert statusOf(deps) == #created;
    let settled = typedCheckoutBody(
      "checkout.session.async_payment_succeeded", "evt_2", "pi_1", ?goodRef, 500, "usd", "paid", true,
    );
    assert deliver(deps, settled).status_code == 200;
    assert statusOf(deps) == #paid;
  });

  test("an async payment that fails for good is acked and leaves the order payable", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    assert deliver(deps, checkoutBody("evt_1", "pi_1", ?goodRef, 500, "usd", "unpaid")).status_code == 200;
    let failed = (
      "{\"id\":\"evt_2\",\"type\":\"checkout.session.async_payment_failed\",\"livemode\":true," #
      "\"data\":{\"object\":{\"payment_intent\":\"pi_1\"}}}"
    ).encodeUtf8();
    assert deliver(deps, failed).status_code == 200;
    assert statusOf(deps) == #created;
    // The intent was never credited, so a genuine later payment still works.
    assert deliver(deps, paidBody("evt_3", "pi_1", ?goodRef, 500)).status_code == 200;
    assert statusOf(deps) == #paid;
  });
});

suite("handleWebhook: attribution failures are Type 1 #unattributed (§4.1)", func() {
  func expectUnattributed(deps : Card.Deps, body : Blob, claimedRef : Text, paymentRef : Text) {
    let resp = deliver(deps, body);
    assert resp.status_code == 200;
    assert bodyText(resp) == "queued for operator review";
    let queued = ErrorQueue.unresolved(deps.errorQueue);
    assert queued.size() == 1;
    assert queued[0].kind == #unattributed({ claimedRef; paymentRef });
  };

  test("missing client_reference_id", func() {
    expectUnattributed(freshDeps(), paidBody("evt_1", "pi_1", null, 500), "", "pi_1");
  });

  test("malformed client_reference_id", func() {
    let bad = "no-underscore-here";
    expectUnattributed(freshDeps(), paidBody("evt_1", "pi_1", ?bad, 500), bad, "pi_1");
  });

  test("well-formed reference to no order", func() {
    expectUnattributed(freshDeps(), paidBody("evt_1", "pi_1", ?goodRef, 500), goodRef, "pi_1");
  });

  test("claimed owner does not match the stored order", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    let forged = "2vxsx-fae_" # orderId;
    expectUnattributed(deps, paidBody("evt_1", "pi_1", ?forged, 500), forged, "pi_1");
    assert statusOf(deps) == #created;
  });

  test("reference to a non-card order", func() {
    let deps = freshDeps();
    withOrder(deps, #ckUsdc);
    expectUnattributed(deps, paidBody("evt_1", "pi_1", ?goodRef, 500), goodRef, "pi_1");
    assert statusOf(deps) == #created;
  });

  test("unexpected currency", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    expectUnattributed(deps, checkoutBody("evt_1", "pi_1", ?goodRef, 500, "eur", "paid"), goodRef, "pi_1");
    assert statusOf(deps) == #created;
  });

  test("paid amount below the order's fee floor", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    // 31¢: fee = ⌈31·290/10_000⌉ + 30 = 31 ≥ 31 → no net amount
    expectUnattributed(deps, paidBody("evt_1", "pi_1", ?goodRef, 31), goodRef, "pi_1");
    assert statusOf(deps) == #created;
  });
});

suite("handleWebhook: actual paid amount is honored (§3/§6.1)", func() {
  test("mismatched amount is repriced from the creation pricing snapshot", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    // 1000¢ ≠ the 500¢ tier: fee = ⌈1000·290/10⁴⌉ + 30 = 59, net 941¢, repriced
    // from the order's OWN rate snapshot (not a fresh rate):
    // 941 · 35_000 · 10¹² / 4_550_000, floored.
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 1_000)).status_code == 200;
    switch (Orders.get(deps.orders, orderId)) {
      case (?order) {
        assert order.status == #paid;
        assert order.lockedCycles == 7_238_461_538_461;
      };
      case (null) assert false;
    };
    // the mismatch is on the audit trail
    var seen = false;
    for (event in AuditLog.events(deps.auditLog).values()) {
      if (event.tag == "stripe.amountMismatch") seen := true;
    };
    assert seen;
  });
});

suite("handleWebhook: charge.refunded auto-resolve (§4.1)", func() {
  test("refund resolves every unresolved Type 1 entry for its intent", func() {
    let deps = freshDeps();
    // two unattributed payments under the same intent... impossible (intent
    // dedup), so: one unattributed payment, refunded.
    assert deliver(deps, paidBody("evt_1", "pi_1", null, 500)).status_code == 200;
    assert ErrorQueue.unresolved(deps.errorQueue).size() == 1;
    let resp = deliver(deps, refundBody("evt_2", "pi_1"));
    assert resp.status_code == 200;
    assert ErrorQueue.unresolved(deps.errorQueue).size() == 0;
    assert ErrorQueue.size(deps.errorQueue) == 1; // resolved, retained
  });

  test("redelivered refund event is deduped", func() {
    let deps = freshDeps();
    assert deliver(deps, refundBody("evt_1", "pi_1")).status_code == 200;
    let resp = deliver(deps, refundBody("evt_1", "pi_1"));
    assert bodyText(resp) == "duplicate event";
  });

  test("refund matching nothing is still 200 (operator refunds freely)", func() {
    let resp = deliver(freshDeps(), refundBody("evt_1", "pi_unknown"));
    assert resp.status_code == 200;
    assert bodyText(resp) == "ok";
  });

  test("an unmatched refund is audited rather than passing silently", func() {
    let deps = freshDeps();
    assert deliver(deps, refundBody("evt_1", "pi_unknown")).status_code == 200;
    assert AuditLog.events(deps.auditLog).find(
      func(e) = e.tag == "stripe.refundUnmatched"
    ) != null;
  });

  test("a paid payment is indexed so a later refund can find its order", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    assert deps.paidIntents.get("pi_1") == ?orderId;
  });

  test("refund of a DELIVERED order queues #refundAfterDelivery", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    // Drive the order to its terminal delivered state the way money-out does.
    for (to in ([#minting, #icpAtCmc, #delivered] : [Types.OrderStatus]).values()) {
      switch (Orders.applyTransition(deps.orders, orderId, to, nowNs)) {
        case (#ok(_)) {};
        case (#err(_)) Runtime.trap("could not drive the order to #delivered");
      };
    };

    assert deliver(deps, refundBody("evt_2", "pi_1")).status_code == 200;

    let open = ErrorQueue.unresolved(deps.errorQueue);
    assert open.size() == 1;
    switch (open[0].kind) {
      case (#refundAfterDelivery({ orderId = queued; paymentRef; cycles })) {
        assert queued == orderId;
        assert paymentRef == "pi_1";
        assert cycles == lockedCycles;
      };
      case (_) Runtime.trap("expected #refundAfterDelivery");
    };
    assert AuditLog.events(deps.auditLog).find(
      func(e) = e.tag == "stripe.refundAfterDelivery"
    ) != null;
  });

  test("#refundAfterDelivery is never auto-resolved by the refund that made it", func() {
    // The refund is what created the entry, so resolving on its paymentRef
    // would close the loss the instant it was recorded. Only a human closes it.
    assert ErrorQueue.paymentRefOf(#refundAfterDelivery({
      orderId; paymentRef = "pi_1"; cycles = lockedCycles;
      refundedCents = 500; fullRefund = true;
    })) == null;
  });

  test("refund of a paid-but-undelivered order is audited, not queued as a loss", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    assert deliver(deps, refundBody("evt_2", "pi_1")).status_code == 200;
    // Money-out may still be mid-flight — a race for the operator to look at,
    // not a settled loss.
    assert ErrorQueue.unresolved(deps.errorQueue).size() == 0;
    assert AuditLog.events(deps.auditLog).find(
      func(e) = e.tag == "stripe.refundBeforeDelivery"
    ) != null;
  });
});

suite("handleWebhook: the purchase ceiling", func() {
  test("an unknown reference is the generic unattributed case", func() {
    let deps = freshDeps();
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    let open = ErrorQueue.unresolved(deps.errorQueue);
    assert open.size() == 1;
    assert open[0].detail.contains(#text "no order");
  });

  test("a payment above the ceiling is not minted — Type 1 instead", func() {
    let deps = { freshDeps() with maxPurchaseUsdCents = 1_000 };
    withOrder(deps, #card);
    // Repricing is an upward path, so without the ceiling this would mint an
    // arbitrary quantity off a tampered or misconfigured Stripe price.
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 5_000)).status_code == 200;
    assert statusOf(deps) == #created; // never marked paid
    let open = ErrorQueue.unresolved(deps.errorQueue);
    assert open.size() == 1;
    assert open[0].detail.contains(#text "exceeds the per-purchase ceiling");
  });

  test("a payment exactly at the ceiling is honored", func() {
    let deps = { freshDeps() with maxPurchaseUsdCents = 500 };
    withOrder(deps, #card);
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 500)).status_code == 200;
    assert statusOf(deps) == #paid;
  });

  test("an over-long claimed reference is truncated before it is stored", func() {
    let deps = freshDeps();
    var long = "";
    for (_ in Nat.range(0, 40)) long #= "0123456789";
    assert deliver(deps, paidBody("evt_1", "pi_1", ?long, 500)).status_code == 200;
    let open = ErrorQueue.unresolved(deps.errorQueue);
    assert open.size() == 1;
    switch (open[0].kind) {
      case (#unattributed({ claimedRef; paymentRef = _ })) {
        assert claimedRef.size() < long.size();
        assert claimedRef.contains(#text "truncated");
      };
      case (_) Runtime.trap("expected #unattributed");
    };
  });
});


suite("handleWebhook: only a real payment creates money-out work", func() {
  // The webhook route is unauthenticated by necessity, so whatever it triggers
  // is free for anyone to invoke. `paidOrder` is what the caller gates the mint
  // kick on, and it must be null on every path except an actual #paid.
  test("a verified payment reports the order it paid", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    let outcome = deliverFull(deps, paidBody("evt_1", "pi_1", ?goodRef, 500));
    assert outcome.response.status_code == 200;
    assert outcome.paidOrder == ?orderId;
  });

  test("no other path reports one", func() {
    // Each of these is a distinct exit from handleWebhook.
    let cases : [(Text, Card.Deps -> Card.Outcome)] = [
      ("unparseable body", func(deps) = deliverFull(deps, "{ not json".encodeUtf8())),
      ("unhandled event type", func(deps) = deliverFull(deps, ("{\"id\":\"e\",\"type\":\"invoice.paid\",\"data\":{\"object\":{}}}").encodeUtf8())),
      ("missing reference", func(deps) = deliverFull(deps, paidBody("evt_1", "pi_1", null, 500))),
      ("unknown order", func(deps) = deliverFull(deps, paidBody("evt_1", "pi_1", ?goodRef, 500))),
      ("payment not completed", func(deps) = deliverFull(deps, checkoutBody("evt_1", "pi_1", ?goodRef, 500, "usd", "unpaid"))),
      ("refund", func(deps) = deliverFull(deps, refundBody("evt_1", "pi_1"))),
    ];
    for ((name, run) in cases.values()) {
      let outcome = run(freshDeps());
      if (outcome.paidOrder != null) Runtime.trap("path reported a paid order: " # name);
    };
  });

  test("an unsigned request reports none and touches nothing", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    let unsigned : Http.Request = {
      method = "POST";
      url = "/webhook/stripe";
      headers = [];
      body = paidBody("evt_1", "pi_1", ?goodRef, 500);
    };
    let outcome = Card.handleWebhook(deps, ?secret, unsigned, nowNs, Card.defaultToleranceSeconds);
    assert outcome.response.status_code == 400;
    assert outcome.paidOrder == null;
    assert statusOf(deps) == #created;
  });

  test("an unprovisioned secret reports none", func() {
    let outcome = Card.handleWebhook(freshDeps(), null, signedReq(paidBody("e", "p", null, 500)), nowNs, Card.defaultToleranceSeconds);
    assert outcome.response.status_code == 503;
    assert outcome.paidOrder == null;
  });
});
