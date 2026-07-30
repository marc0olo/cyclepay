/// Minimal strict JSON parser for Stripe webhook payloads (§6.1).
///
/// Hand-rolled deliberately: the mops `json` package (1.4.0) depends on the
/// deprecated `base@0.11.1` next to our `core` — the same dependency-split
/// reason the `hmac` package was rejected in task 3. Scope is exactly what
/// webhook ingestion needs: parse one complete document into a tree and read
/// string / integer fields by dotted path. Numbers keep their raw lexeme;
/// the only numbers we ever read are integer cent amounts.
///
/// Why a real parser and not key-scanning (the Forex.mo approach): webhook
/// bodies carry attacker-influenced *string values* (customer email, names),
/// so a substring scan for `"payment_intent"` could be steered by a value
/// containing that text. A tree parse makes string contents inert. The
/// parser only ever runs on HMAC-verified bodies, but it still hard-fails
/// (null) on any deviation — unescaped control chars, lone surrogates,
/// trailing garbage — and caps recursion depth as a backstop.
import Char "mo:core/Char";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";

module {

  public type Json = {
    #obj : [(Text, Json)];
    #arr : [Json];
    #str : Text;
    /// Raw lexeme (`"5000"`, `"-1.5e3"`) — interpret via `asNat`/`natAt`.
    #num : Text;
    #bool : Bool;
    #nul;
  };

  /// Recursion backstop. Stripe events nest ~6 levels; 64 is generous
  /// headroom while keeping a crafted `[[[[…` from exhausting the stack.
  public let maxDepth : Nat = 64;

  /// Parse a complete JSON document. Null on any deviation from the JSON
  /// grammar, including trailing non-whitespace.
  public func parse(text : Text) : ?Json {
    let chars = text.toArray();
    var i = 0;

    func isWs(c : Char) : Bool {
      c == ' ' or c == '\t' or c == '\n' or c == '\r';
    };

    func skipWs() {
      while (i < chars.size() and isWs(chars[i])) i += 1;
    };

    func hexDigit(c : Char) : ?Nat32 {
      if (c >= '0' and c <= '9') return ?(c.toNat32() - 48);
      if (c >= 'a' and c <= 'f') return ?(c.toNat32() - 87);
      if (c >= 'A' and c <= 'F') return ?(c.toNat32() - 55);
      null;
    };

    /// Four hex digits after a `\u`, as a UTF-16 code unit.
    func parseHex4() : ?Nat32 {
      if (i + 4 > chars.size()) return null;
      var unit : Nat32 = 0;
      for (_ in Nat.range(0, 4)) {
        let ?d = hexDigit(chars[i]) else return null;
        unit := unit * 16 + d;
        i += 1;
      };
      ?unit;
    };

    /// One escaped or literal character inside a string, including UTF-16
    /// surrogate pairs (`𝄞`); a lone surrogate fails the parse.
    func parseEscape() : ?Char {
      if (i >= chars.size()) return null;
      let c = chars[i];
      i += 1;
      switch (c) {
        case ('\"') ?'\"';
        case ('\\') ?'\\';
        case ('/') ?'/';
        case ('b') ?'\u{08}';
        case ('f') ?'\u{0C}';
        case ('n') ?'\n';
        case ('r') ?'\r';
        case ('t') ?'\t';
        case ('u') {
          let ?unit = parseHex4() else return null;
          if (unit >= 0xDC00 and unit <= 0xDFFF) return null; // lone low surrogate
          if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (i + 2 > chars.size() or chars[i] != '\\' or chars[i + 1] != 'u') return null;
            i += 2;
            let ?low = parseHex4() else return null;
            if (low < 0xDC00 or low > 0xDFFF) return null;
            return ?Char.fromNat32(0x10000 + (unit - 0xD800) * 0x400 + (low - 0xDC00));
          };
          ?Char.fromNat32(unit);
        };
        case (_) null;
      };
    };

    /// String body, assuming the opening `"` is at `chars[i]`.
    func parseString() : ?Text {
      if (i >= chars.size() or chars[i] != '\"') return null;
      i += 1;
      let out = List.empty<Char>();
      while (i < chars.size()) {
        let c = chars[i];
        if (c == '\"') {
          i += 1;
          return ?Text.fromIter(out.values());
        };
        if (c == '\\') {
          i += 1;
          let ?decoded = parseEscape() else return null;
          out.add(decoded);
        } else if (c.toNat32() < 0x20) {
          return null; // control characters must be escaped
        } else {
          out.add(c);
          i += 1;
        };
      };
      null; // unterminated
    };

    /// Number lexeme per the JSON grammar (`-? digits (. digits)? (e…)?`),
    /// kept raw — only integer interpretation happens later, in `asNat`.
    func parseNumber() : ?Json {
      let lexeme = List.empty<Char>();
      func takeDigits() : Nat {
        var count = 0;
        while (i < chars.size() and chars[i] >= '0' and chars[i] <= '9') {
          lexeme.add(chars[i]);
          i += 1;
          count += 1;
        };
        count;
      };
      if (i < chars.size() and chars[i] == '-') {
        lexeme.add('-');
        i += 1;
      };
      if (takeDigits() == 0) return null;
      if (i < chars.size() and chars[i] == '.') {
        lexeme.add('.');
        i += 1;
        if (takeDigits() == 0) return null;
      };
      if (i < chars.size() and (chars[i] == 'e' or chars[i] == 'E')) {
        lexeme.add(chars[i]);
        i += 1;
        if (i < chars.size() and (chars[i] == '+' or chars[i] == '-')) {
          lexeme.add(chars[i]);
          i += 1;
        };
        if (takeDigits() == 0) return null;
      };
      ?#num(Text.fromIter(lexeme.values()));
    };

    func parseLiteral(word : Text, value : Json) : ?Json {
      for (expected in word.chars()) {
        if (i >= chars.size() or chars[i] != expected) return null;
        i += 1;
      };
      ?value;
    };

    func parseObject(depth : Nat) : ?Json {
      i += 1; // past '{'
      let fields = List.empty<(Text, Json)>();
      skipWs();
      if (i < chars.size() and chars[i] == '}') {
        i += 1;
        return ?#obj(fields.toArray());
      };
      loop {
        skipWs();
        let ?key = parseString() else return null;
        skipWs();
        if (i >= chars.size() or chars[i] != ':') return null;
        i += 1;
        let ?value = parseValue(depth) else return null;
        fields.add((key, value));
        skipWs();
        if (i >= chars.size()) return null;
        switch (chars[i]) {
          case (',') i += 1;
          case ('}') { i += 1; return ?#obj(fields.toArray()) };
          case (_) return null;
        };
      };
    };

    func parseArray(depth : Nat) : ?Json {
      i += 1; // past '['
      let items = List.empty<Json>();
      skipWs();
      if (i < chars.size() and chars[i] == ']') {
        i += 1;
        return ?#arr(items.toArray());
      };
      loop {
        let ?value = parseValue(depth) else return null;
        items.add(value);
        skipWs();
        if (i >= chars.size()) return null;
        switch (chars[i]) {
          case (',') i += 1;
          case (']') { i += 1; return ?#arr(items.toArray()) };
          case (_) return null;
        };
      };
    };

    func parseValue(depth : Nat) : ?Json {
      if (depth >= maxDepth) return null;
      skipWs();
      if (i >= chars.size()) return null;
      switch (chars[i]) {
        case ('{') parseObject(depth + 1);
        case ('[') parseArray(depth + 1);
        case ('\"') {
          switch (parseString()) {
            case (?s) ?#str(s);
            case null null;
          };
        };
        case ('t') parseLiteral("true", #bool(true));
        case ('f') parseLiteral("false", #bool(false));
        case ('n') parseLiteral("null", #nul);
        case (_) parseNumber();
      };
    };

    let ?value = parseValue(0) else return null;
    skipWs();
    if (i != chars.size()) return null; // trailing garbage
    ?value;
  };

  /// First value of `key` in an object (first-key-wins on the duplicates
  /// JSON technically allows; Stripe never sends them).
  public func field(json : Json, key : Text) : ?Json {
    let #obj(fields) = json else return null;
    for ((k, v) in fields.values()) {
      if (k == key) return ?v;
    };
    null;
  };

  /// Dotted-path lookup, e.g. `at(event, "data.object.payment_intent")`.
  /// Stripe keys never contain `.`, so the split is unambiguous.
  public func at(json : Json, path : Text) : ?Json {
    var current = json;
    for (key in path.split(#char '.')) {
      let ?next = field(current, key) else return null;
      current := next;
    };
    ?current;
  };

  /// Non-negative integer value — null for floats, negatives, exponents
  /// (`Nat.fromText` rejects every non-digit lexeme character).
  public func asNat(json : Json) : ?Nat {
    let #num(raw) = json else return null;
    Nat.fromText(raw);
  };

  public func textAt(json : Json, path : Text) : ?Text {
    switch (at(json, path)) {
      case (?#str(s)) ?s;
      case (_) null;
    };
  };

  public func natAt(json : Json, path : Text) : ?Nat {
    switch (at(json, path)) {
      case (?value) asNat(value);
      case (null) null;
    };
  };

  /// Null unless the path holds a genuine JSON boolean — a string `"true"` or a
  /// missing field are both "not a boolean", so a caller deciding something
  /// security-relevant cannot be fooled by a value of the wrong type.
  public func boolAt(json : Json, path : Text) : ?Bool {
    switch (at(json, path)) {
      case (?#bool(b)) ?b;
      case (_) null;
    };
  };

};
