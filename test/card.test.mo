import { test; suite } "mo:test";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Card "../src/backend/rails/Card";
import Util "../src/backend/Util";

// Stripe-Signature verification (§6.1): header parsing, timestamp-window
// replay guard, constant-time MAC check. The crafted vector was computed
// externally with python hmac/hashlib and pinned here, so these tests fail
// if Hmac/Card drift from Stripe's actual scheme rather than agreeing with
// themselves.

let secret = Text.encodeUtf8("whsec_8fJ3kQ9mN2pX7vR4tL6wY1zB5cD0eH");
let body = Text.encodeUtf8("{\"id\":\"evt_TEST0001\",\"type\":\"checkout.session.completed\"}");
let t = 1_749_600_000; // unix seconds, signed into the payload
let v1 = "f862baccf5deef97d4d4907dbba1409d463b4ac793f7105bd04f56ad3c488a93";
// same payload signed under a different (rotated-away) secret
let v1Rotated = "17dec468289ef27ed21135e7d597655e0eb74b8433fa1a388a3a3bbeec6c97be";

let header = "t=" # t.toText() # ",v1=" # v1;
let nowNs = t * 1_000_000_000; // canister clock == send time
let tolerance = Card.defaultToleranceSeconds;

suite("verify: crafted Stripe vector", func() {
  test("valid header verifies", func() {
    assert Card.verify(secret, header, body, nowNs, tolerance) == #ok;
  });

  test("signedPayloadMac matches the externally computed signature", func() {
    assert Util.hexEncode(Card.signedPayloadMac(secret, t, body)) == v1;
  });

  test("extra schemes and spaces are ignored (Stripe wire format)", func() {
    let messy = "v0=6ffbb59b2300aae63f272406069a9788598b792a944a07aba816edb039989a39, t=" # t.toText() # " , v1=" # v1;
    assert Card.verify(secret, messy, body, nowNs, tolerance) == #ok;
  });

  test("any one matching v1 among several verifies (secret rotation)", func() {
    let rotated = "t=" # t.toText() # ",v1=" # v1Rotated # ",v1=" # v1;
    assert Card.verify(secret, rotated, body, nowNs, tolerance) == #ok;
  });

  test("tampered body is rejected", func() {
    let tampered = Text.encodeUtf8("{\"id\":\"evt_TEST0002\",\"type\":\"checkout.session.completed\"}");
    assert Card.verify(secret, header, tampered, nowNs, tolerance) == #err(#signatureMismatch);
  });

  test("wrong secret is rejected", func() {
    let other = Text.encodeUtf8("whsec_not_the_real_secret_000000000");
    assert Card.verify(other, header, body, nowNs, tolerance) == #err(#signatureMismatch);
  });

  test("t altered after signing is rejected (t is inside the MAC)", func() {
    // window still passes (now == altered t), but the MAC was made over the real t
    let altered = "t=" # (t + 60).toText() # ",v1=" # v1;
    assert Card.verify(secret, altered, body, (t + 60) * 1_000_000_000, tolerance) == #err(#signatureMismatch);
  });
});

suite("verify: timestamp window (replay guard)", func() {
  test("exactly tolerance old still verifies", func() {
    assert Card.verify(secret, header, body, (t + tolerance) * 1_000_000_000, tolerance) == #ok;
  });

  test("one second past tolerance is rejected", func() {
    let result = Card.verify(secret, header, body, (t + tolerance + 1) * 1_000_000_000, tolerance);
    assert result == #err(#timestampOutsideWindow({ timestampSeconds = t; nowSeconds = t + tolerance + 1 }));
  });

  test("too far in the future is rejected (clock-skew bound, both directions)", func() {
    let result = Card.verify(secret, header, body, (t - tolerance - 1) * 1_000_000_000, tolerance);
    assert result == #err(#timestampOutsideWindow({ timestampSeconds = t; nowSeconds = t - tolerance - 1 }));
  });

  test("window check happens before MAC work (bad signature, old: window error wins)", func() {
    let bad = "t=" # t.toText() # ",v1=" # v1Rotated;
    let result = Card.verify(secret, bad, body, (t + tolerance + 1) * 1_000_000_000, tolerance);
    assert result == #err(#timestampOutsideWindow({ timestampSeconds = t; nowSeconds = t + tolerance + 1 }));
  });
});

suite("parseSignatureHeader", func() {
  test("order independence: v1 before t", func() {
    let ?parsed = Card.parseSignatureHeader("v1=" # v1 # ",t=" # t.toText()) else {
      assert false;
      return;
    };
    assert parsed.timestampSeconds == t;
    assert parsed.v1 == [switch (Util.hexDecode(v1)) { case (?b) b; case (null) ("" : Blob) }];
  });

  test("missing t is malformed", func() {
    assert Card.parseSignatureHeader("v1=" # v1) == null;
    assert Card.verify(secret, "v1=" # v1, body, nowNs, tolerance) == #err(#malformedHeader);
  });

  test("non-numeric t is malformed (first t wins, later t ignored)", func() {
    assert Card.parseSignatureHeader("t=tomorrow,t=" # t.toText() # ",v1=" # v1) == null;
  });

  test("missing v1 is malformed", func() {
    assert Card.parseSignatureHeader("t=" # t.toText() # ",v0=" # v1) == null;
  });

  test("v1 with bad hex or wrong length is dropped, not matched", func() {
    // 62 hex chars = 31 bytes: well-formed hex, wrong width for SHA-256
    let short = "t=" # t.toText() # ",v1=f862baccf5deef97d4d4907dbba1409d463b4ac793f7105bd04f56ad3c48";
    assert Card.parseSignatureHeader(short) == null;
    let badHex = "t=" # t.toText() # ",v1=zz62baccf5deef97d4d4907dbba1409d463b4ac793f7105bd04f56ad3c488a93";
    assert Card.parseSignatureHeader(badHex) == null;
  });

  test("elements without '=' are ignored", func() {
    let ?parsed = Card.parseSignatureHeader("junk,t=" # t.toText() # ",v1=" # v1) else {
      assert false;
      return;
    };
    assert parsed.timestampSeconds == t;
  });

  test("empty header is malformed", func() {
    assert Card.parseSignatureHeader("") == null;
  });
});
