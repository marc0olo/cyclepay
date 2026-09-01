/// A stored Stripe secret (§7). **Two stores use this module**: the webhook signing
/// secret and the Checkout Sessions API key.
///
/// They share the rail's on/off switch: "live" means **both provisioned**, because
/// neither state can complete a purchase — no API key means no payable session, no
/// webhook secret means a buyer can pay and we cannot credit them.
///
/// ⚠️ **Stored plaintext in canister state, by design.** HMAC is symmetric, so
/// *verify = forge*: whoever reads the webhook blob can forge "paid" events, and
/// encrypting it would only move the problem to the key that decrypts it. The posture —
/// SEV-SNP as the confidentiality layer, the reserve balance as the always-on blast
/// radius, why a stock beats a per-period cap and the one way it does not — is
/// `docs/DESIGN.md` §7, with the confidential-subnet checklist in RUNBOOK §9.
///
/// ⚠️ **What a leak of each one buys an attacker differs, and that is why the key's SCOPE
/// matters more than its storage.** The webhook secret spends the reserve. A restricted
/// key scoped to Checkout Sessions = Write can only create sessions that pay **us**, and
/// read them back — which the recovery sweep needs. An unrestricted key, able to refund,
/// would be materially worse to leak.
import Blob "mo:core/Blob";
import Result "mo:core/Result";

module {

  /// Reject obviously truncated provisioning: a fat-fingered short paste should
  /// fail loudly at set time, not silently reject every webhook.
  ///
  /// 16, deliberately **below** the length of a real Stripe secret (`whsec_` plus
  /// ~32 chars — the whole string, prefix included, is the HMAC key). The floor
  /// only has to catch a truncated paste; keeping it under Stripe's real length
  /// leaves shorter test secrets usable on a local network, where nothing is being
  /// protected. It is not a strength check, and no length here makes a leaked
  /// secret safe — see §2 of the RUNBOOK for rotation.
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
