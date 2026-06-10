/// Small shared helpers (spec §9 layout). Currently: hex codec, used by the
/// Stripe signature path (`v1=` values are lowercase hex) and by tests that
/// pin known HMAC vectors.
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import List "mo:core/List";
import Nat8 "mo:core/Nat8";

module {

  /// Lowercase hex encoding (Stripe's wire format for signatures).
  public func hexEncode(blob : Blob) : Text {
    var out = "";
    for (byte in blob.values()) {
      out #= hexDigit(byte / 16) # hexDigit(byte % 16);
    };
    out;
  };

  /// Decode hex (either case) to bytes; null on odd length or non-hex chars.
  public func hexDecode(hex : Text) : ?Blob {
    let bytes = List.empty<Nat8>();
    var pendingHigh : ?Nat8 = null;
    for (c in hex.chars()) {
      let ?n = nibble(c) else return null;
      switch (pendingHigh) {
        case (null) { pendingHigh := ?n };
        case (?high) { bytes.add(high * 16 + n); pendingHigh := null };
      };
    };
    if (pendingHigh != null) return null;
    ?Blob.fromArray(bytes.toArray());
  };

  func hexDigit(n : Nat8) : Text {
    let digits = "0123456789abcdef";
    var i : Nat8 = 0;
    for (c in digits.chars()) {
      if (i == n) return c.toText();
      i += 1;
    };
    "";
  };

  func nibble(c : Char) : ?Nat8 {
    if (c >= '0' and c <= '9') {
      ?Nat8.fromNat32(c.toNat32() - '0'.toNat32());
    } else if (c >= 'a' and c <= 'f') {
      ?Nat8.fromNat32(c.toNat32() - 'a'.toNat32() + 10);
    } else if (c >= 'A' and c <= 'F') {
      ?Nat8.fromNat32(c.toNat32() - 'A'.toNat32() + 10);
    } else {
      null;
    };
  };

};
