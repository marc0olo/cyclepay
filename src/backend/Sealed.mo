/// vetKD sealing (#11): what turns a ciphertext an operator sent into the plaintext
/// secret `Secret.Store` holds.
///
/// The problem this solves is **provisioning exposure**, and only that. `set_stripe_api_key`
/// used to take the key as `text`, so the value crossed the TLS-terminating boundary node
/// in the clear — a shell history, a CI log and a boundary node all saw a live `rk_...`.
/// Now the operator encrypts to this canister's derived public key, computed offline, and
/// only this canister can open the result.
///
/// ⚠️ **At rest is NOT addressed here, deliberately.** The decrypted secret lives in
/// canister memory, replicated and checkpointed like any other state. That is irreducible:
/// HMAC verification needs the plaintext, so no scheme keeps it out of memory. #11 works
/// this through and rejects the alternatives; the posture is `docs/DESIGN.md` §7, and the
/// confidentiality layer is the confidential subnet (#2), not this module.
///
/// ⚠️ **What the unaudited dependency can and cannot cost us — `docs/DESIGN.md` §7.3.**
/// The encrypting is done by the audited `@icp-sdk/vetkeys`; this side only DECRYPTS. So a
/// bug here fails provisioning closed — the operator gets an error and no secret is stored
/// — rather than weakening a ciphertext that is already on the wire. That asymmetry is why
/// an experimental BLS12-381 is acceptable on this path and would not be on a path where a
/// bug could leak a plaintext.
// `Array` for the receiver `.toBlob()` on the decrypted `[Nat8]` — the conversion is
// spelled on the source value, so the module for THAT type must be imported.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Result "mo:core/Result";
import Text "mo:core/Text";
import G1 "mo:sealed-secrets-bls/G1";
import G2 "mo:sealed-secrets-bls/G2";
import Scalar "mo:sealed-secrets-bls/Scalar";
import Ibe "mo:sealed-secrets-vetkeys/Ibe";
import VetKey "mo:sealed-secrets-vetkeys/VetKey";

module {

  /// The vetKD key to ask for. `key_1` exists on mainnet **and** on a local network, so
  /// one constant covers both.
  ///
  /// ⚠️ **The same NAME, backed by different master keys** — necessarily, since a local
  /// network cannot hold mainnet's master secret. So the name does not identify the key,
  /// and the client must choose its master key from the network it is talking to. That is
  /// `scripts/seal-secret.sh`'s job and it derives the choice from the environment rather
  /// than taking it as an argument, because a wrong choice produces a ciphertext nobody
  /// can ever open.
  public let keyName : Text = "key_1";

  /// The vetKD **context**: what selects this canister's keypair.
  ///
  /// ⚠️ **Changing one byte gives this canister an entirely different keypair**, which
  /// makes every ciphertext ever sealed to the old one unopenable. It is not a version
  /// number and must not be edited to "rotate" anything — rotation is re-sealing the
  /// secret, which `Secret.generation` counts. Must match the client exactly.
  ///
  /// A function rather than a `let` because a module-level binding must be a static
  /// expression (M0014) and `encodeUtf8` is a call. Both strings are short, so
  /// recomputing per use costs nothing worth caching.
  public func context() : Blob = "cyclepay-secrets".encodeUtf8();

  /// The IBE identity every secret here is sealed to.
  ///
  /// `(canister, context)` fixes a keypair; this picks one key under it, and **one key
  /// opens every ciphertext sealed to it**. That is why holding two secrets costs one
  /// derivation rather than two: the API key and the webhook secret share this identity,
  /// and which store a plaintext lands in is decided by which endpoint was called — a
  /// fact that never reaches vetKD.
  ///
  /// Named `keyLabel`, not `label`: `label` is a Motoko reserved word.
  public func keyLabel() : Blob = "stripe-secrets".encodeUtf8();

  /// Domain separator turning 32 random bytes into the transport scalar. Nothing
  /// interoperates with this value — the subnet only ever sees the matching public key —
  /// so it is ours to choose and never has to match the client.
  let transportDomain = "cyclepay-vetkd-transport-key";

  /// The published `key_1` derivation fee, charged per call. Overpaying is refunded;
  /// underpaying is rejected outright, so this is attached exactly.
  ///
  /// ~26.15 B cycles, about 3.5 US cents. Paid once per provisioning call and never on
  /// the webhook or delivery path — which is what makes sealing affordable here and is
  /// the reason #11 rejects deriving per use.
  public let vetkdFee : Nat = 26_153_846_153;

  /// Why a provisioning call could not store a secret.
  ///
  /// ⚠️ **A structural SUPERTYPE of `Secret.SetError`, which is why no mapping layer
  /// exists.** Motoko variant subtyping lets `Secret.set`'s `#err(#tooShort …)` return
  /// straight out of an endpoint declared with this type. `#tooShort` is therefore listed
  /// here without `Secret.mo` importing this module or the reverse.
  ///
  /// Every arm is a distinct operator action, which is the T4 bar: a bare `text` would
  /// force whoever is provisioning to match on prose to tell "you sealed to the wrong
  /// network" from "this subnet has no vetKD key".
  public type ProvisionError = {
    /// The decrypted plaintext was shorter than `Secret.minSecretBytes` — a truncated
    /// paste, caught after decryption because that is the first point the real value exists.
    #tooShort : { size : Nat; min : Nat };
    /// The argument is not an IBE ciphertext at all. Usually a plaintext secret sent to
    /// the new endpoint, or a file that never went through the sealing step.
    #notCiphertext;
    /// It is a well-formed ciphertext, but not one this canister's key opens.
    ///
    /// ⚠️ **The wrong-network case lands here**, and so do a wrong `context`, a wrong
    /// identity, and tampering — the authenticated check cannot tell them apart, and
    /// reporting which failed would tell a prober which half of a forged input was wrong.
    /// By far the most likely cause is sealing against the other network's master key.
    #notSealedToThisCanister;
    /// Decrypted, but the bytes are not UTF-8 — so not a Stripe secret.
    #notUtf8;
    /// The subnet reported a derived public key that is not a valid `G2` point.
    #malformedPublicKey;
    /// `vetkd_derive_key` replied with something that is not an encrypted vetKey.
    #malformedReply;
    /// The reply's halves disagree, or the key that fell out is not a valid signature
    /// over `keyLabel`. This is the check that makes a forged reply useless.
    #unverifiableReply;
    /// `vetkd_derive_key` or `vetkd_public_key` rejected the call. `detail` is the
    /// subnet's own wording, which is the T1 case for keeping a `Text` payload: an
    /// external system owns the string, and the most common cause — no vetKD key on this
    /// subnet — is only distinguishable by reading it.
    #vetkdUnavailable : { detail : Text };
    /// `raw_rand` failed, so there is no transport keypair to ask with.
    #entropyUnavailable : { detail : Text };
  };

  /// The single-use transport secret, from `raw_rand` bytes.
  ///
  /// ⚠️ **The private half never leaves this canister, and that is the whole point.** Only
  /// the matching public key is sent, and it goes into the share computation itself — so
  /// each node produces a share already encrypted under it and **no node ever assembles
  /// the plaintext vetKey**.
  public func transportSecret(entropy : Blob) : Scalar.Scalar {
    Scalar.hashToScalar(entropy.toArray(), transportDomain);
  };

  /// The public half to send with the derivation request.
  public func transportPublicKey(secret : Scalar.Scalar) : Blob {
    VetKey.transportPublicKey(secret);
  };

  /// Unwraps `vetkd_derive_key`'s reply into the key that opens our ciphertexts.
  ///
  /// Strips the transport blinding, then checks the result really is a BLS signature over
  /// `keyLabel` under the reported public key — which is what makes a forged reply useless.
  ///
  /// ⚠️ **Verifying against the key the same subnet reported is circular, and cheap to
  /// accept.** A subnet willing to lie here already holds the master key and could decrypt
  /// everything regardless. What keeps the ARRANGEMENT honest is on the client: it derives
  /// this canister's public key offline from a master key it ships and never asks us for
  /// one, so there is no reply for anyone in between to substitute.
  public func unwrap(
    encryptedKey : Blob,
    transport : Scalar.Scalar,
    reportedPublicKey : Blob,
  ) : Result.Result<G1.Affine, ProvisionError> {
    let ?derivedPublicKey = G2.fromCompressed(reportedPublicKey) else return #err(#malformedPublicKey);
    let ?reply = VetKey.deserialize(encryptedKey.toArray()) else return #err(#malformedReply);
    let ?key = VetKey.decryptAndVerify(reply, transport, derivedPublicKey, keyLabel().toArray()) else {
      return #err(#unverifiableReply);
    };
    #ok(key);
  };

  /// Opens a sealed secret with the unwrapped key.
  ///
  /// ⚠️ **Decrypting at provisioning time rather than storing the ciphertext is the
  /// design.** It costs one derivation per call instead of one per use — #11 rejects
  /// per-use derivation because the webhook path would pay ~3.5 cents per event — and it
  /// means a ciphertext sealed to the wrong network fails **now**, in front of whoever is
  /// seeding it, rather than being accepted and found unreadable at the first webhook.
  /// ⚠️ **UTF-8 is checked HERE rather than at first use**, because at first use the only
  /// available answer is `#railClosed` — `Main.sessionConfig` reads the store, calls
  /// `decodeUtf8`, and has no way to say why. That would present a bad provisioning as a
  /// closed rail hours later. The store holds bytes, so nothing downstream re-checks.
  public func open(ciphertext : Blob, key : G1.Affine) : Result.Result<Blob, ProvisionError> {
    let ?parsed = Ibe.deserialize(ciphertext.toArray()) else return #err(#notCiphertext);
    let ?plaintext = Ibe.decrypt(parsed, key) else return #err(#notSealedToThisCanister);
    let bytes = plaintext.toBlob();
    let ?_ = bytes.decodeUtf8() else return #err(#notUtf8);
    #ok(bytes);
  };

};
