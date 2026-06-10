/// HMAC-SHA256 (RFC 2104) over the `sha2` mops package, plus the
/// constant-time tag comparison the verifier must use (§6.1).
///
/// The HMAC key is the Stripe webhook signing secret — symmetric, so
/// "verify" = "forge" (§7). Comparison must not short-circuit on the first
/// differing byte: a timing oracle on the compare leaks the expected MAC
/// byte-by-byte and lets an attacker forge "paid" webhooks without the secret.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Sha256 "mo:sha2/Sha256";

module {

  /// SHA-256 block size in bytes (RFC 2104: pad/hash the key to this).
  let blockSize : Nat = 64;

  /// HMAC-SHA256 of the concatenation of `parts` under `key`. Parts let the
  /// caller MAC `"<t>." # body` without copying the body blob.
  public func sha256(key : Blob, parts : [Blob]) : Blob {
    let normalized = if (key.size() > blockSize) Sha256.fromBlob(key) else key;
    let keyBytes = normalized.toArray();
    let padded = func(i : Nat) : Nat8 = if (i < keyBytes.size()) keyBytes[i] else 0;
    let innerDigest = Sha256.new();
    innerDigest.writeArray(Array.tabulate<Nat8>(blockSize, func i = padded(i) ^ 0x36));
    for (part in parts.values()) { innerDigest.writeBlob(part) };
    let outerDigest = Sha256.new();
    outerDigest.writeArray(Array.tabulate<Nat8>(blockSize, func i = padded(i) ^ 0x5c));
    outerDigest.writeBlob(innerDigest.sum());
    outerDigest.sum();
  };

  /// Compare in time independent of *where* the blobs differ. Length is not
  /// secret (MACs are fixed-width), so mismatched sizes may return early.
  public func constantTimeEqual(a : Blob, b : Blob) : Bool {
    if (a.size() != b.size()) return false;
    let aBytes = a.toArray();
    let bBytes = b.toArray();
    var acc : Nat8 = 0;
    for (i in aBytes.keys()) { acc |= aBytes[i] ^ bBytes[i] };
    acc == 0;
  };

};
