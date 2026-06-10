import { test; suite } "mo:test";
import Nat "mo:core/Nat";
import Json "../src/backend/Json";

// Json.mo (task 8, §6.1): strict tree parser for HMAC-verified Stripe
// bodies. The threat model is attacker-influenced *string values* inside
// authentic JSON, so the suite leans on: string contents are inert, any
// grammar deviation hard-fails (null), and number interpretation is
// integer-only.

suite("parse: structure", func() {
  test("object with mixed value types", func() {
    let ?json = Json.parse("{\"a\": \"x\", \"b\": 5, \"c\": true, \"d\": false, \"e\": null}") else {
      assert false;
      return;
    };
    assert Json.field(json, "a") == ?#str("x");
    assert Json.field(json, "b") == ?#num("5");
    assert Json.field(json, "c") == ?#bool(true);
    assert Json.field(json, "d") == ?#bool(false);
    assert Json.field(json, "e") == ?#nul;
    assert Json.field(json, "missing") == null;
  });

  test("empty object and empty array", func() {
    assert Json.parse("{}") == ?#obj([]);
    assert Json.parse("[]") == ?#arr([]);
    assert Json.parse("{ }") == ?#obj([]);
    assert Json.parse("[ ]") == ?#arr([]);
  });

  test("arrays nest and keep order", func() {
    assert Json.parse("[1, [2, 3], \"x\"]") == ?#arr([#num("1"), #arr([#num("2"), #num("3")]), #str("x")]);
  });

  test("top-level scalars parse", func() {
    assert Json.parse("\"hi\"") == ?#str("hi");
    assert Json.parse("42") == ?#num("42");
    assert Json.parse("null") == ?#nul;
  });

  test("surrounding whitespace is tolerated", func() {
    assert Json.parse(" \t\r\n {\"a\":1} \n") == ?#obj([("a", #num("1"))]);
  });

  test("trailing garbage fails the whole parse", func() {
    assert Json.parse("{}x") == null;
    assert Json.parse("{} {}") == null;
    assert Json.parse("1 2") == null;
  });

  test("structural deviations fail: missing colon/comma/bracket, bare words", func() {
    assert Json.parse("{\"a\" 1}") == null;
    assert Json.parse("{\"a\":1 \"b\":2}") == null;
    assert Json.parse("[1 2]") == null;
    assert Json.parse("{\"a\":1") == null;
    assert Json.parse("[1,") == null;
    assert Json.parse("nope") == null;
    assert Json.parse("{a:1}") == null; // unquoted key
    assert Json.parse("") == null;
  });

  test("depth cap: 63 nested arrays parse, 64 do not", func() {
    func nested(n : Nat) : Text {
      var open = "";
      var close = "";
      for (_ in Nat.range(0, n)) {
        open #= "[";
        close #= "]";
      };
      open # "1" # close;
    };
    assert Json.parse(nested(63)) != null;
    assert Json.parse(nested(64)) == null;
  });
});

suite("parse: strings", func() {
  test("simple escapes decode", func() {
    assert Json.parse("\"a\\n\\t\\r\\\"\\\\\\/b\"") == ?#str("a\n\t\r\"\\/b");
    assert Json.parse("\"\\u0041\"") == ?#str("A");
  });

  test("surrogate pair decodes to one char; lone surrogates fail", func() {
    assert Json.parse("\"\\uD834\\uDD1E\"") == ?#str("\u{1D11E}"); // 𝄞
    assert Json.parse("\"\\uD834\"") == null; // lone high
    assert Json.parse("\"\\uDD1E\"") == null; // lone low
    assert Json.parse("\"\\uD834\\u0041\"") == null; // high not followed by low
  });

  test("bad escapes and unterminated strings fail", func() {
    assert Json.parse("\"\\x\"") == null;
    assert Json.parse("\"\\u12\"") == null; // truncated hex
    assert Json.parse("\"\\uZZZZ\"") == null;
    assert Json.parse("\"open") == null;
  });

  test("unescaped control characters fail", func() {
    assert Json.parse("\"a\nb\"") == null;
    assert Json.parse("\"a\u{00}b\"") == null;
  });

  test("string values are inert: JSON syntax inside a value stays data", func() {
    let ?json = Json.parse("{\"note\": \"\\\"payment_intent\\\": \\\"pi_fake\\\", {}[]\", \"payment_intent\": \"pi_real\"}") else {
      assert false;
      return;
    };
    assert Json.textAt(json, "payment_intent") == ?"pi_real";
  });
});

suite("parse: numbers", func() {
  test("lexemes are kept raw", func() {
    assert Json.parse("-1.5e3") == ?#num("-1.5e3");
    assert Json.parse("0.25") == ?#num("0.25");
    assert Json.parse("1E+2") == ?#num("1E+2");
  });

  test("malformed numbers fail", func() {
    assert Json.parse("-") == null;
    assert Json.parse("1.") == null;
    assert Json.parse(".5") == null;
    assert Json.parse("1e") == null;
    assert Json.parse("+1") == null;
  });

  test("asNat: integers only — floats, negatives, exponents are null", func() {
    assert Json.asNat(#num("5000")) == ?5_000;
    assert Json.asNat(#num("0")) == ?0;
    assert Json.asNat(#num("-1")) == null;
    assert Json.asNat(#num("1.5")) == null;
    assert Json.asNat(#num("1e3")) == null;
    assert Json.asNat(#str("5000")) == null; // wrong node type
  });
});

suite("path lookups", func() {
  let body = "{\"id\":\"evt_1\",\"data\":{\"object\":{\"payment_intent\":\"pi_9\",\"amount_total\":5000,\"client_reference_id\":null}}}";

  test("dotted path walks nested objects", func() {
    let ?json = Json.parse(body) else { assert false; return };
    assert Json.textAt(json, "id") == ?"evt_1";
    assert Json.textAt(json, "data.object.payment_intent") == ?"pi_9";
    assert Json.natAt(json, "data.object.amount_total") == ?5_000;
  });

  test("missing keys, JSON null, and type mismatches all read as null", func() {
    let ?json = Json.parse(body) else { assert false; return };
    assert Json.textAt(json, "data.object.missing") == null;
    assert Json.textAt(json, "data.object.client_reference_id") == null; // JSON null
    assert Json.textAt(json, "data.object.amount_total") == null; // number, not string
    assert Json.natAt(json, "data.object.payment_intent") == null; // string, not number
    assert Json.textAt(json, "data.object.payment_intent.deeper") == null; // path into a leaf
  });

  test("first key wins on duplicates", func() {
    let ?json = Json.parse("{\"a\":\"first\",\"a\":\"second\"}") else { assert false; return };
    assert Json.textAt(json, "a") == ?"first";
  });
});
