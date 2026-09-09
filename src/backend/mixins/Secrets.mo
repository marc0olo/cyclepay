// ⚠️ `Nat` and `Text` carry no `Nat.`/`Text.` call in this file and are still required:
// they are what makes the receiver methods resolve — `.toText()` on a generation,
// `.startsWith`/`.contains`/`.trimEnd` on the origin. Nothing reports an unused import
// here either way, so both directions are a judgement the compiler makes, not a lint.
import Session "../rails/Session";
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Text "mo:core/Text";
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
) {

  /// ⚠️ **Declared inside the mixin body, not above it and not in `Types.mo`.** Only
  /// imports may precede a `mixin` block (M0228, "mixins may only be declared at the
  /// top-level"), and Candid type names come from the Motoko declaration — moving this
  /// to `Types.mo` would risk renaming it in the interface, which is the one thing this
  /// relocation must not do.
  /// Provision or rotate the Stripe webhook signing secret (§7). Pass the
  /// full `whsec_...` string from the Stripe dashboard — the whole string,
  /// prefix included, is the HMAC key. NOTE: the argument transits the
  /// TLS-terminating boundary node as plain ingress (§7 provisioning
  /// exposure); rotate after provisioning over an untrusted path.
  public shared ({ caller }) func set_webhook_secret(secret : Text) : async Result.Result<(), Secret.SetError> {
    requireController(caller);
    let result = Secret.set(webhookSecret, secret.encodeUtf8(), nowNs());
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

  /// Provision or rotate the Stripe API key (#33) — admin, mirroring
  /// `set_webhook_secret` in every respect including the provisioning caveat:
  /// the argument transits the TLS-terminating boundary node as plain ingress.
  /// #11 covers vetKeys for encrypted delivery, and now applies to two secrets.
  public shared ({ caller }) func set_stripe_api_key(key : Text) : async Result.Result<(), Secret.SetError> {
    requireController(caller);
    let result = Secret.set(stripeApiKey, key.encodeUtf8(), nowNs());
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
