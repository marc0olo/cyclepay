import { test; suite } "mo:test";
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

// Matches the forex.test.mo quote vector: 500¢ gross, fee ⌈500·290/104⌉+30
// = 45¢, net 455¢ @ 737_000 micros → 3_353_350_000_000 cycles.
let pricing : Types.Pricing = {
  usdCents = 500;
  xdrPerUsdMicros = 737_000;
  feeBps = 290;
  feeFixedCents = 30;
};
let lockedCycles : Nat = 3_353_350_000_000;

func freshDeps() : Card.Deps {
  {
    orders = Orders.emptyStore();
    dedup = Idempotency.emptyStore();
    errorQueue = ErrorQueue.emptyStore();
    errorQueueCapacity = 10;
    auditLog = AuditLog.emptyLog();
    auditLogCapacity = 100;
  };
};

func withOrder(deps : Card.Deps, rail : Types.Rail) {
  switch (Orders.create(deps.orders, orderId, #ii(alice), rail, #canister(alice), lockedCycles, pricing, 100)) {
    case (#ok(_)) {};
    case (#err(_)) Runtime.trap("test order creation failed");
  };
};

func checkoutBody(eventId : Text, intent : Text, ref : ?Text, amountCents : Nat, currency : Text, paymentStatus : Text) : Blob {
  let refJson = switch (ref) {
    case (?r) "\"" # r # "\"";
    case (null) "null";
  };
  (
    "{\"id\":\"" # eventId # "\",\"type\":\"checkout.session.completed\"," #
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

func refundBody(eventId : Text, intent : Text) : Blob {
  (
    "{\"id\":\"" # eventId # "\",\"type\":\"charge.refunded\"," #
    "\"data\":{\"object\":{\"payment_intent\":\"" # intent # "\"}}}"
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

func deliver(deps : Card.Deps, body : Blob) : Http.Response {
  Card.handleWebhook(deps, ?secret, signedReq(body), nowNs, Card.defaultToleranceSeconds);
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
    assert Card.parseEvent(body) == #err(#missingField("data.object.payment_intent"));
  });

  test("non-integer amount_total is a missing field", func() {
    let body = (
      "{\"id\":\"evt_1\",\"type\":\"checkout.session.completed\"," #
      "\"data\":{\"object\":{\"payment_intent\":\"pi_1\",\"client_reference_id\":null," #
      "\"amount_total\":5.5,\"currency\":\"usd\",\"payment_status\":\"paid\"}}}"
    ).encodeUtf8();
    assert Card.parseEvent(body) == #err(#missingField("data.object.amount_total"));
  });
});

suite("handleWebhook: envelope guards", func() {
  test("unprovisioned secret answers 503 (Stripe keeps retrying)", func() {
    let resp = Card.handleWebhook(freshDeps(), null, signedReq(paidBody("evt_1", "pi_1", ?goodRef, 500)), nowNs, Card.defaultToleranceSeconds);
    assert resp.status_code == 503;
  });

  test("missing Stripe-Signature header is 400", func() {
    let req = { signedReq(paidBody("evt_1", "pi_1", ?goodRef, 500)) with headers = [] : [Http.HeaderField] };
    assert Card.handleWebhook(freshDeps(), ?secret, req, nowNs, Card.defaultToleranceSeconds).status_code == 400;
  });

  test("bad signature is 400 and touches no state", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    let body = paidBody("evt_1", "pi_1", ?goodRef, 500);
    let forged = { signedReq(body) with body = paidBody("evt_1", "pi_1", ?goodRef, 9_999) };
    assert Card.handleWebhook(deps, ?secret, forged, nowNs, Card.defaultToleranceSeconds).status_code == 400;
    assert statusOf(deps) == #created;
    // the rejected delivery consumed nothing: the genuine one still lands
    assert deliver(deps, body).status_code == 200;
    assert statusOf(deps) == #paid;
  });

  test("signed but unparseable body is 400", func() {
    assert deliver(freshDeps(), ("not json at all").encodeUtf8()).status_code == 400;
  });

  test("signed unhandled event type is acked 200 and ignored", func() {
    let resp = deliver(freshDeps(), ("{\"id\":\"evt_x\",\"type\":\"invoice.paid\"}").encodeUtf8());
    assert resp.status_code == 200;
    assert bodyText(resp) == "ignored";
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

  test("non-paid payment_status is acked without consuming the intent", func() {
    let deps = freshDeps();
    withOrder(deps, #card);
    let resp = deliver(deps, checkoutBody("evt_1", "pi_1", ?goodRef, 500, "usd", "unpaid"));
    assert resp.status_code == 200;
    assert statusOf(deps) == #created;
    // the later genuinely-paid delivery for the same intent still mints
    assert deliver(deps, paidBody("evt_2", "pi_1", ?goodRef, 500)).status_code == 200;
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
    // 1000¢ ≠ the 500¢ tier: fee = ⌈1000·290/10_000⌉ + 30 = 59, net 941¢
    // @ 737_000 micros → 941 · 7_370_000_000 cycles.
    assert deliver(deps, paidBody("evt_1", "pi_1", ?goodRef, 1_000)).status_code == 200;
    switch (Orders.get(deps.orders, orderId)) {
      case (?order) {
        assert order.status == #paid;
        assert order.lockedCycles == 6_935_170_000_000;
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
});
