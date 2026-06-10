/// Card rail (Stripe) — webhook signature verification half (§6.1).
/// Event JSON parsing + order resolution land with task 8.
///
/// HTTP requests reach the canister as the *anonymous* principal (§6.0), so
/// this route is authenticated purely by payload: HMAC-SHA256 over the
/// Stripe signed payload `"<t>.<raw body>"` under the webhook signing secret,
/// plus a timestamp window as the replay guard. The window bounds how long a
/// captured-and-replayed delivery stays valid; inside the window, replay is
/// the dedup sets' job (Idempotency.mo — `event.id` / `payment_intent`).
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Hmac "../Hmac";
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
    for (element in Text.split(header, #char ',')) {
      let parts = Text.split(element.trim(#char ' '), #char '=').toArray();
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

};
