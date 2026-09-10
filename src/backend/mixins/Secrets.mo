// ⚠️ `Nat` and `Text` carry no `Nat.`/`Text.` call in this file and are still required:
// they are what makes the receiver methods resolve — `.toText()` on a generation,
// `.startsWith`/`.contains`/`.trimEnd` on the origin. Nothing reports an unused import
// here either way, so both directions are a judgement the compiler makes, not a lint.
import Session "../rails/Session";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Sealed "../Sealed";
import Secret "../Secret";

/// The two Stripe secrets and the buyer-return origin: provision, rotate, and read back
/// only what is safe to read back (§7).
///
/// ⚠️ **State reaches a mixin two different ways and picking the wrong one is silent.**
/// `include` evaluates its arguments ONCE, so:
///
///   * `Secret.Store` is a record of `var` fields — a heap object — so passing it shares
///     it by reference and `Secret.set` writes through to the actor's own field.
///   * `stripeOrigin` is a `var` holding an immutable `?Text`. Passing the field itself
///     would hand this mixin a snapshot taken at include time: `stripe_origin()` would
///     answer `null` forever and `set_stripe_origin` would mutate a copy nobody reads.
///     So it arrives as an accessor pair instead.
///
/// ⚠️ **Accessors rather than a `{ var current : ?Text }` wrapper**, which is the other
/// way to make a `var` shareable. Wrapping changes the actor's STABLE SHAPE — the field
/// stops being `stable var stripeOrigin : ?Text` — and with no migration chain (#32)
/// that costs a reinstall. Closures are mixin parameters, never stable state, so
/// `deployed/backend.most` does not move for this split.
mixin (
  webhookSecret : Secret.Store,
  stripeApiKey : Secret.Store,
  /// ⚠️ Named `originAccess`, not `origin`, so `set_stripe_origin` can keep its own
  /// parameter called `origin`: **Candid records argument names**, and renaming one
  /// moves the published signature. `scripts/check-did-signatures.sh` caught exactly
  /// that when this parameter was called `origin` and the endpoint's became `candidate`.
  originAccess : { get : () -> ?Text; set : (?Text) -> () },
  requireController : (Principal) -> (),
  requireAdmin : (Principal) -> (),
  auditAdmin : (Principal, Text, Text) -> (),
  nowNs : () -> Int,
  /// Decrypts a sealed argument (#11). A closure rather than the vetKey itself: the key is
  /// derived lazily through the management canister and cached in the actor, so handing
  /// this mixin a value would hand it a snapshot of an empty cache.
  openSealed : (Blob) -> async* Result.Result<Blob, Sealed.ProvisionError>,
) {

  /// ⚠️ **Declared inside the mixin body, not above it and not in `Types.mo`.** Only
  /// imports may precede a `mixin` block (M0228, "mixins may only be declared at the
  /// top-level"), and Candid type names come from the Motoko declaration — moving this
  /// to `Types.mo` would risk renaming it in the interface, which is the one thing this
  /// relocation must not do.
  /// Provision or rotate the Stripe webhook signing secret (§7).
  ///
  /// Takes the full `whsec_...` string — the whole string, prefix included, is the HMAC
  /// key — **sealed to this canister's vetKD public key** (#11). `scripts/seal-secret.sh`
  /// produces the argument; the plaintext never travels.
  ///
  /// ⚠️ **This closed the §7 provisioning exposure, and the note that used to sit here
  /// saying otherwise is gone rather than softened.** The ingress argument is now
  /// ciphertext, so the boundary node that terminates TLS sees nothing usable. What
  /// remains is the at-rest exposure, which is the confidential subnet's job (#2) and not
  /// something rotation can help with.
  public shared ({ caller }) func set_webhook_secret(ciphertext : Blob) : async Result.Result<(), Sealed.ProvisionError> {
    requireController(caller);
    let plaintext = switch (await* openSealed(ciphertext)) {
      case (#ok(bytes)) bytes;
      case (#err(e)) {
        auditAdmin(caller, "secret.setRejected", "the sealed argument could not be opened; the working secret is untouched");
        return #err(e);
      };
    };
    let result = Secret.set(webhookSecret, plaintext, nowNs());
    switch (result) {
      case (#ok) {
        // The secret itself is never logged — only that it changed, by whom,
        // and to which generation, which is what a rotation audit needs.
        auditAdmin(caller, "secret.set", "generation " # Secret.status(webhookSecret).generation.toText());
      };
      case (#err(_)) auditAdmin(caller, "secret.setRejected", "rejected as too short; the working secret is untouched");
    };
    result;
  };

  /// Provisioning state only — the secret itself is never readable back
  /// out, even by controllers. `generation` confirms a rotation landed.
  public shared query ({ caller }) func webhook_secret_status() : async Secret.Status {
    requireAdmin(caller);
    Secret.status(webhookSecret);
  };

  /// Provision or rotate the restricted Stripe API key (#33), sealed exactly as
  /// `set_webhook_secret` is — same vetKey, one derivation for both (#11).
  ///
  /// The key to seal is a **restricted key** (`rk_...`) with *Checkout Sessions = Write*
  /// and everything else None; `Secret.mo` records why that scope, not this storage, is
  /// what bounds a leak.
  public shared ({ caller }) func set_stripe_api_key(ciphertext : Blob) : async Result.Result<(), Sealed.ProvisionError> {
    requireController(caller);
    let plaintext = switch (await* openSealed(ciphertext)) {
      case (#ok(bytes)) bytes;
      case (#err(e)) {
        auditAdmin(caller, "stripe.apiKeyRejected", "the sealed argument could not be opened; the working key is untouched");
        return #err(e);
      };
    };
    let result = Secret.set(stripeApiKey, plaintext, nowNs());
    switch (result) {
      case (#ok) auditAdmin(caller, "stripe.apiKeySet", "generation " # Secret.status(stripeApiKey).generation.toText());
      case (#err(_)) auditAdmin(caller, "stripe.apiKeyRejected", "rejected as too short; the working key is untouched");
    };
    result;
  };

  /// Whether the restricted Stripe key is provisioned — **never the key**.
  ///
  /// The console offers this read and no command for the setter: a rendered
  /// `set_stripe_api_key` would put the key in a page's DOM and clipboard, which is what
  /// `scripts/check-admin-commands.py` fails on. Admin-gated like every other read of
  /// operational state that names a secret's presence.
  public shared query ({ caller }) func stripe_api_key_status() : async Secret.Status {
    requireAdmin(caller);
    Secret.status(stripeApiKey);
  };

  /// Set the origin Stripe returns buyers to (#33) — admin.
  ///
  /// Validated at set time rather than at session-create time, so a bad value
  /// fails in front of the operator who typed it instead of breaking every
  /// purchase later. Until a domain is chosen (#40/#23) this is the canister's
  /// own asset origin.
  public shared ({ caller }) func set_stripe_origin(origin : Text) : async Result.Result<(), Session.OriginError> {
    requireController(caller);
    // Validation and normalisation are `Session.validateOrigin`'s, so the parsing has
    // unit tests — `http://` is accepted for loopback hosts only.
    let trimmed = switch (Session.validateOrigin(origin)) {
      case (#ok(value)) value;
      case (#err(e)) return #err(e);
    };
    originAccess.set(?trimmed);
    auditAdmin(caller, "stripe.originSet", trimmed);
    #ok;
  };

  /// The origin, readable back because it is not a secret — it is the URL
  /// buyers are sent to, and an operator needs to confirm it.
  public shared query func stripe_origin() : async ?Text {
    originAccess.get();
  };
};
