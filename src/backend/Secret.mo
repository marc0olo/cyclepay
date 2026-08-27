/// A stored Stripe secret (§7). **Two stores use this module**: the webhook
/// signing secret and the Checkout Sessions API key.
///
/// Both share the posture below. They also share the rail's on/off switch:
/// `railsLive` is "both provisioned", because neither state can complete a
/// purchase — no API key means no payable session, no webhook secret means a
/// buyer can pay and we cannot credit them.
///
/// Stored **plaintext in canister state, by design** (no vetKeys). HMAC is
/// symmetric, so "verify" = "forge": whoever reads this blob can forge
/// "paid" webhooks. The documented posture (§7) is:
///
/// - **Confidentiality layer: SEV-SNP**, i.e. hardware + attestation, not
///   cryptography in the canister — and only if the target subnet's
///   *checkpoints and state-sync* are confidential too (memory encryption
///   alone does not cover state at rest; verify this hardest, §7).
/// - **Provisioning exposure:** the set/rotate call's argument transits the
///   TLS-terminating boundary node as a plain ingress message.
/// - **Blast-radius backstop (always on):** a forged "paid" event makes the
///   gateway deliver, so a leaked webhook secret costs the operator cycles. The
///   drain is bounded by the **reserve balance** — the cycles the operator
///   funded the delivery account with — off-chain reconciliation detects it,
///   and rotation recovers. Launch must not block on SEV availability.
///
/// ⚠️ **The reserve is a stock, not a rate.** That makes it a better bound than
/// a per-period cap in two ways worth stating, because the instinct is to read
/// "no rate limit" as weaker. A cap resets, so a patient attacker drains it
/// again every period and the operator's total loss is unbounded over time; the
/// reserve, once empty, refuses further deliveries with `#reserveShort` and
/// cannot be drained again until a human refunds it. And the drain is *visible*
/// in a value the gateway already maintains and reports: the reserve floor is a
/// lower bound that only moves down when this gateway itself issues a transfer,
/// so cycles leaving faster than orders arrive is exactly the discrepancy
/// `reserve_status` exposes. Neither property is a reason to leak the secret;
/// both are reasons the launch decision does not need SEV to be sound.
///
/// ⚠️ **And the one way a stock is worse, stated because an argument that only lists
/// its own advantages is advocacy.** A cap spreads a loss across periods and so
/// bounds how fast it can happen; a stock can go in a single burst between the leak
/// and its rotation. The design accepts that and controls it by *sizing* — keep in
/// the account what you are willing to lose in one go (RUNBOOK §1) — and by the step
/// ordering in §2, which refunds the reserve only after the secret is dead. Both are
/// procedure rather than mechanism, which is exactly why they are written down.
///
/// The two secrets differ in what a leak buys an attacker, which is worth
/// knowing when choosing key scopes: the webhook secret lets them forge "paid"
/// events, so it spends the reserve. A restricted `rk_` API key scoped to
/// *write Checkout Sessions* only lets them create sessions that pay **us** —
/// which is why the scope matters and why an unrestricted `sk_`, able to refund,
/// would be a materially worse thing to leak.
///
/// Rotation needs no dual-secret window on this side: while a rolled Stripe
/// secret's predecessor is live, Stripe sends one `v1=` per active secret
/// and Card.verify accepts any single match — so swapping the stored blob
/// at any point during the overlap never drops a delivery.
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
