/// Stripe webhook signing secret — the system's only stored secret (§7).
///
/// Stored **plaintext in canister state, by design** (no vetKeys). HMAC is
/// symmetric, so "verify" = "forge": whoever reads this blob can mint
/// "paid" webhooks. The documented posture (§7) is:
///
/// - **Confidentiality layer: SEV-SNP**, i.e. hardware + attestation, not
///   cryptography in the canister — and only if the target subnet's
///   *checkpoints and state-sync* are confidential too (memory encryption
///   alone does not cover state at rest; verify this hardest, §7).
/// - **Provisioning exposure:** the set/rotate call's argument transits the
///   TLS-terminating boundary node as a plain ingress message.
/// - **Blast-radius backstop (always on):** a leaked secret only lets an
///   attacker mint cycles at operator expense; the per-period ICP burn cap
///   (§5.3, task 10) bounds the drain, off-chain reconciliation detects it,
///   and rotation recovers. Launch must not block on SEV availability.
///
/// Rotation needs no dual-secret window on this side: while a rolled Stripe
/// secret's predecessor is live, Stripe sends one `v1=` per active secret
/// and Card.verify accepts any single match — so swapping the stored blob
/// at any point during the overlap never drops a delivery.
import Blob "mo:core/Blob";
import Result "mo:core/Result";

module {

  /// Reject obviously truncated provisioning. Real Stripe secrets are
  /// `whsec_` + ≥32 chars (the whole string, prefix included, is the HMAC
  /// key); a fat-fingered short paste should fail loudly at set time, not
  /// silently 401 every webhook.
  public let minSecretBytes : Nat = 16;

  public type Store = {
    /// UTF-8 bytes of the full `whsec_...` string. Null until provisioned;
    /// the webhook route answers 503 (Stripe retries) while unset.
    var secret : ?Blob;
    /// When the current value was set (canister time, ns).
    var setAtNs : ?Int;
    /// Successful set count — 0 = never provisioned. Lets ops confirm a
    /// rotation landed without ever reading the secret back.
    var generation : Nat;
  };

  public type SetError = { #tooShort : { size : Nat; min : Nat } };

  /// Safe-to-share provisioning state: everything *about* the secret,
  /// never the secret.
  public type Status = {
    isSet : Bool;
    generation : Nat;
    setAtNs : ?Int;
  };

  public func emptyStore() : Store {
    { var secret = null; var setAtNs = null; var generation = 0 };
  };

  /// Set or rotate. On `#err` the store is untouched — a bad rotation
  /// attempt never clobbers a working secret.
  public func set(store : Store, secret : Blob, nowNs : Int) : Result.Result<(), SetError> {
    if (secret.size() < minSecretBytes) {
      return #err(#tooShort({ size = secret.size(); min = minSecretBytes }));
    };
    store.secret := ?secret;
    store.setAtNs := ?nowNs;
    store.generation += 1;
    #ok;
  };

  /// The HMAC key for Card.verify; null = not provisioned yet.
  public func get(store : Store) : ?Blob {
    store.secret;
  };

  public func status(store : Store) : Status {
    {
      isSet = store.secret != null;
      generation = store.generation;
      setAtNs = store.setAtNs;
    };
  };

};
