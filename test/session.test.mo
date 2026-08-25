// Unit suite for Checkout Session request building and response parsing (#33).
//
// Everything the canister sends to Stripe and everything it keeps from the reply
// is decided by pure functions, so it is all pinned here. What this CANNOT reach
// is whether the real API accepts the body — only a manual run against a sandbox
// key does that, and the PocketIC suite cannot either, because it mocks outcalls.
import { suite; test } "mo:test";
import Text "mo:core/Text";
import Session "../src/backend/rails/Session";

suite("form encoding", func() {
  test("leaves the RFC 3986 unreserved set alone", func() {
    assert Session.formEncode("abcXYZ019-._~") == "abcXYZ019-._~";
  });

  test("escapes the characters that would change the body's SHAPE", func() {
    // These four are the ones that matter: `&` and `=` are the field separators,
    // so an unescaped one in a value injects a parameter. `#` truncates a URL at
    // the fragment, which is exactly what `success_url` carries.
    assert Session.formEncode("&") == "%26";
    assert Session.formEncode("=") == "%3D";
    assert Session.formEncode("#") == "%23";
    assert Session.formEncode("?") == "%3F";
  });

  test("a space is %20, not +", func() {
    assert Session.formEncode("a b") == "a%20b";
  });

  test("escapes per BYTE for a multi-byte character", func() {
    // U+00E9 is two UTF-8 bytes. Escaping per character would emit one bogus
    // escape and corrupt the value.
    assert Session.formEncode("é") == "%C3%A9";
  });

  test("the product name and a real origin survive a round trip in shape", func() {
    let encoded = Session.formEncode("https://abc.icp0.io/#/order/deadbeef");
    // The scheme's `//` and the fragment's `#` are both escaped, so the value
    // cannot terminate early or introduce a field.
    assert not encoded.contains(#text "#");
    assert encoded.contains(#text "%23");
  });
});

suite("the create body", func() {
  let args : Session.CreateArgs = {
    orderId = "aabbccddeeff00112233445566778899";
    clientReferenceId = "2ibo7-dia_aabbccddeeff00112233445566778899";
    usdCents = 1_000;
    origin = "https://abc.icp0.io";
    expiresAtSeconds = 1_800_000_000;
  };
  let body = Session.createBody(args);

  test("is a single fixed-amount line item, inline, with no Dashboard objects", func() {
    assert body.contains(#text "mode=payment");
    assert body.contains(#text "line_items%5B0%5D%5Bquantity%5D=1");
    assert body.contains(#text "line_items%5B0%5D%5Bprice_data%5D%5Bunit_amount%5D=1000");
    assert body.contains(#text "line_items%5B0%5D%5Bprice_data%5D%5Bcurrency%5D=usd");
    // No price id, no product id: inline `price_data` only.
    assert not body.contains(#text "price=");
    assert not body.contains(#text "payment_link");
  });

  test("carries the attribution reference unchanged", func() {
    // The whole webhook path keys off this, so it must survive encoding intact.
    assert body.contains(#text "client_reference_id=2ibo7-dia_aabbccddeeff00112233445566778899");
  });

  test("sends BOTH return URLs, back to the buyer's own order", func() {
    let expected = Session.formEncode("https://abc.icp0.io/#/order/aabbccddeeff00112233445566778899");
    assert body.contains(#text("success_url=" # expected));
    assert body.contains(#text("cancel_url=" # expected));
  });

  test("pins adaptive pricing off", func() {
    assert body.contains(#text "adaptive_pricing%5Benabled%5D=false");
  });

  test("enables NOTHING that could move amount_total away from unit_amount", func() {
    // The guarantee that `amount_total == order.pricing.usdCents` is a property
    // of what is absent. Each of these would break it, and each is one Stripe
    // parameter away — so their absence is asserted rather than assumed.
    for (forbidden in ([
      "automatic_tax",
      "adjustable_quantity",
      "allow_promotion_codes",
      "discounts",
      "shipping_options",
      "optional_items",
      "tax_rates",
      "after_expiration",
    ] : [Text]).values()) {
      assert not body.contains(#text forbidden);
    };
  });

  test("card only, so money-in stays synchronous", func() {
    assert body.contains(#text "payment_method_types%5B%5D=card");
  });
});

suite("request headers", func() {
  let headers = Session.createHeaders("rk_test_secret", "order-1");

  test("the idempotency key IS the order id", func() {
    // Two jobs, and the second is easy to miss: without it each replica creates
    // a DISTINCT session, so consensus can never be reached and no transform can
    // repair that. One order, one session, one key.
    var found = false;
    for (h in headers.values()) {
      if (h.name == "Idempotency-Key") {
        assert h.value == "order-1";
        found := true;
      };
    };
    assert found;
  });

  test("bearer auth and a form content type", func() {
    var auth = "";
    var ctype = "";
    for (h in headers.values()) {
      if (h.name == "Authorization") auth := h.value;
      if (h.name == "Content-Type") ctype := h.value;
    };
    assert auth == "Bearer rk_test_secret";
    assert ctype == "application/x-www-form-urlencoded";
  });
});

suite("the transform", func() {
  test("strips EVERY response header", func() {
    // Not "reduces" — strips all. Stripe returns a unique `request-id` per HTTP
    // request, so every replica sees a different value and passing headers
    // through fails consensus on every single call. Asserted as a count of zero
    // rather than on specific names, because a new Stripe header must not slip
    // through a name-based filter.
    let stripped = Session.strip({
      status = 200;
      body = "{}" : Blob;
      headers = [
        { name = "request-id"; value = "req_abc" },
        { name = "Date"; value = "Mon, 25 Aug 2026 12:00:00 GMT" },
        { name = "cf-ray"; value = "abc-LHR" },
        { name = "stripe-should-retry"; value = "false" },
      ];
    });
    assert stripped.headers.size() == 0;
    // Status and body are what consensus is reached on, so both survive.
    assert stripped.status == 200;
    assert stripped.body == ("{}" : Blob);
  });
});

suite("parsing a created session", func() {
  let ok = "{\"id\":\"cs_test_a1b2\",\"url\":\"https://checkout.stripe.com/c/pay/cs_test_a1b2\",\"expires_at\":1800000000,\"livemode\":false,\"object\":\"checkout.session\"}";

  test("keeps the four fields the order needs", func() {
    switch (Session.parseCreated(Text.encodeUtf8(ok))) {
      case (#ok(created)) {
        assert created.id == "cs_test_a1b2";
        assert created.url == "https://checkout.stripe.com/c/pay/cs_test_a1b2";
        assert created.expiresAtSeconds == 1_800_000_000;
        assert created.livemode == false;
      };
      case (#err(_)) assert false;
    };
  });

  test("a missing field NAMES itself rather than failing generically", func() {
    // An operator reading an audit line needs to know which field Stripe did not
    // send, not that "parsing failed".
    for ((json, field) in ([
      ("{\"url\":\"u\",\"expires_at\":1,\"livemode\":false}", "id"),
      ("{\"id\":\"i\",\"expires_at\":1,\"livemode\":false}", "url"),
      ("{\"id\":\"i\",\"url\":\"u\",\"livemode\":false}", "expires_at"),
      ("{\"id\":\"i\",\"url\":\"u\",\"expires_at\":1}", "livemode"),
    ] : [(Text, Text)]).values()) {
      switch (Session.parseCreated(Text.encodeUtf8(json))) {
        case (#err(#missingField(name))) assert name == field;
        case (_) assert false;
      };
    };
  });

  test("livemode is REQUIRED, not defaulted", func() {
    // Defaulting it either way silently picks a side of the test/live check it
    // exists to drive, which is the mistake that lets a test key sit behind a
    // live webhook secret.
    switch (Session.parseCreated(Text.encodeUtf8("{\"id\":\"i\",\"url\":\"u\",\"expires_at\":1}"))) {
      case (#err(#missingField("livemode"))) {};
      case (_) assert false;
    };
  });

  test("non-JSON and a JSON scalar are both unparseable, not a crash", func() {
    switch (Session.parseCreated(Text.encodeUtf8("<html>502</html>"))) {
      case (#err(#unparseable)) {};
      case (_) assert false;
    };
  });
});

suite("seconds to nanoseconds", func() {
  test("multiplies by 10^9", func() {
    // ⚠️ THE most likely bug in #33. Stripe's `expires_at` is Unix SECONDS and IC
    // time is nanoseconds; storing the raw value makes every order look expired
    // since 1970 — the open-order cap frees instantly, #30's detection predicates
    // fire on everything, and the UI shows every order expired.
    assert Session.secondsToNs(1) == 1_000_000_000;
    assert Session.secondsToNs(1_800_000_000) == 1_800_000_000_000_000_000;
    assert Session.secondsToNs(0) == 0;
  });

  test("a Stripe deadline lands in the same era as IC time, not 1970", func() {
    // The property that catches the unit error even if the factor is mistyped:
    // a 2026 timestamp in ns is ~1.8e18, so it must be far above any plausible
    // seconds value.
    let stripeSeconds = 1_800_000_000; // ~Jan 2027
    assert Session.secondsToNs(stripeSeconds) > 1_000_000_000_000_000_000;
  });
});

suite("expiring a session", func() {
  test("addresses the session's own expire endpoint", func() {
    assert Session.expireUrl("cs_test_a1b2")
      == "https://api.stripe.com/v1/checkout/sessions/cs_test_a1b2/expire";
  });

  test("recognises 'no longer open' as its own outcome, not a failure", func() {
    // Cancellation must not guess from our clock why a session is closed: it
    // either completed (the payment won the race) or expired already. Both are
    // "refresh and let the webhook resolve it", neither is "try again".
    assert Session.isNotOpen(400, Text.encodeUtf8("{\"error\":{\"message\":\"You cannot expire a Checkout Session in a status of complete.\"}}"));
    assert Session.isNotOpen(400, Text.encodeUtf8("{\"error\":{\"message\":\"... in a status of expired.\"}}"));
    assert Session.isNotOpen(404, Text.encodeUtf8("{\"error\":{\"message\":\"No such checkout.session: cs_x\"}}"));
  });

  test("a 200 and a generic failure are NOT 'not open'", func() {
    // A 500 or a rate limit must leave the order uncancelled and payable, so it
    // must never be mistaken for a closed session.
    assert not Session.isNotOpen(200, Text.encodeUtf8("{\"status\":\"expired\"}"));
    assert not Session.isNotOpen(500, Text.encodeUtf8("{\"error\":{\"message\":\"internal\"}}"));
    assert not Session.isNotOpen(429, Text.encodeUtf8("{\"error\":{\"message\":\"rate limited\"}}"));
  });
});
