import { test; suite } "mo:test";
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import Nat32 "mo:core/Nat32";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import G1 "mo:sealed-secrets-bls/G1";
import Scalar "mo:sealed-secrets-bls/Scalar";
import Sealed "../src/backend/Sealed";
import Secret "../src/backend/Secret";

/// ⚠️ **This suite deliberately does NOT re-test the crypto.** The curve arithmetic, the
/// pairing, hash-to-curve and the IBE/vetKey formats are covered by 102 vector tests in
/// `vendor/icp-seeding-secrets-poc/motoko/{bls12-381,vetkeys}`, generated from the audited Rust reference and
/// run as their own gate step (`scripts/test-all.sh`). Restating them here would measure
/// the same thing twice and grow the impression of coverage without adding any.
///
/// What is ours to test is the **wiring**: that our error arms map to the right causes,
/// that the two published constants have not moved, and that the checks the doc comments
/// promise are the checks that actually run.
///
/// The vectors below are lifted from `vendor/icp-seeding-secrets-poc/motoko/vectors.json`. The IBE triple is
/// a real ciphertext with the vetKey that opens it, so `open`'s happy path exercises a
/// genuine decryption rather than a stub.

func hexVal(c : Char) : Nat {
  let n = Nat32.toNat(Char.toNat32(c));
  if (n >= 48 and n <= 57) { n - 48 } else if (n >= 97 and n <= 102) { n - 87 } else if (n >= 65 and n <= 70) {
    n - 55;
  } else { 16 };
};

func hexBytes(hex : Text) : [Nat8] {
  let chars = Array.fromIter<Char>(hex.chars());
  assert chars.size() % 2 == 0;
  Array.tabulate<Nat8>(
    chars.size() / 2,
    func(i) = Nat8.fromNat(hexVal(chars[i * 2]) * 16 + hexVal(chars[i * 2 + 1])),
  );
};

func hexBlob(hex : Text) : Blob = hexBytes(hex).toBlob();

/// A real IBE ciphertext, the vetKey that opens it, and what it must yield.
let IBE_VETKEY = "887e66122b2ab97ad8ade759ec0d80a395b889f990fb3623d3a9d27c5a825a7b5f5693664b2e15137015640041341558";
let IBE_CIPHERTEXT = "4943204942450001acb3eb5f0f0f8e8026deca9ee0d9616df6cb80afcff012cd67427b6ce233e2829233d93b0ffbbcc23ef7f80e3928c43c0a6be487f9bfc88b4722c19e83e0abc441ca9799d84c50103d43d8f893624bd593b708cdd54e8be53825d738f8592b306a7913b4bf582dfef541fba06bc05df63134ee224ea732b1fb715073e9a44e6b0bbe03639e88526c7352dac8a09c95";
let IBE_PLAINTEXT = "a sealed secret";

/// A real `vetkd_derive_key` reply, with the transport secret that unblinds it and the
/// derived public key it verifies under. ⚠️ Sealed to the identity `"message"`, **not** to
/// `Sealed.keyLabel()` — which is exactly what makes it useful here.
let REPLY_TSK_BE = "167b736e44a1c134bd46ca834220c75c186768612568ac264a01554c46633e76";
let REPLY_DPK = "972c4c6cc184b56121a1d27ef1ca3a2334d1a51be93573bd18e168f78f8fe15ce44fb029ffe8e9c3ee6bea2660f4f35e0774a35a80d6236c050fd8f831475b5e145116d3e83d26c533545f64b08464e4bcc755f990a381efa89804212d4eef5f";
let REPLY_ENCRYPTED = "b1a13757eaae15a3c8884fc1a3453f8a29b88984418e65f1bd21042ce1d6809b2f8a49f7326c1327f2a3921e8ff1d6c3adde2a801f1f88de98ccb40c62e366a279e7aec5875a0ce2f2a9f3e109d9cb193f0197eadb2c5f5568ee4d6a87e115910662e01e604087246be8b081fc6b8a06b4b0100ed1935d8c8d18d9f70d61718c5dba23a641487e72b3b25884eeede8feb3c71599bfbcebe60d29408795c85b4bdf19588c034d898e7fc513be8dbd04cac702a1672f5625f5833d063b05df7503";

func ibeKey() : G1.Affine {
  let ?k = G1.fromCompressed(hexBlob(IBE_VETKEY)) else Runtime.trap("bad vetkey vector");
  k;
};

suite("Sealed — the two published constants", func() {
  test("⚠️ context and keyLabel are pinned, because moving one orphans every ciphertext", func() {
    // These bytes are a CONTRACT with `scripts/seal-secret.sh` and with every ciphertext
    // an operator has ever produced. Changing either gives this canister a different
    // keypair or a different identity, so previously sealed secrets stop opening — with
    // `#notSealedToThisCanister`, which reads like the operator's mistake rather than
    // ours. Anyone editing them has to edit this test too, which is the point.
    assert Sealed.context() == "cyclepay-secrets".encodeUtf8();
    assert Sealed.keyLabel() == "stripe-secrets".encodeUtf8();
    assert Sealed.keyName == "key_1";
  });

  // ⚠️ **The fee is deliberately NOT asserted here.** It comes from
  // `Prim.costVetkdDeriveKey`, which the `mops test` interpreter does not implement — a
  // call fails with `Value.prim: costVetkdDeriveKey`. Asserting a literal would also
  // re-create the stale-constant problem that primitive exists to remove. What proves the
  // figure is `test/integration/src/sealed.spec.ts`: underpaying `vetkd_derive_key` is
  // rejected outright, so provisioning succeeding on a real replica IS the assertion.
});

suite("Sealed.transportSecret — the half that never leaves", func() {
  test("deterministic in the entropy it is given", func() {
    let entropy = hexBlob("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    assert Sealed.transportSecret(entropy) == Sealed.transportSecret(entropy);
  });

  test("different entropy gives a different transport key", func() {
    let a = Sealed.transportSecret(hexBlob("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"));
    let b = Sealed.transportSecret(hexBlob("ff112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"));
    assert a != b;
  });

  test("the public half is a compressed G1 point", func() {
    // 48 bytes is what the management canister expects; a different length is rejected
    // before any derivation happens.
    let secret = Sealed.transportSecret(hexBlob("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"));
    assert Sealed.transportPublicKey(secret).size() == 48;
  });
});

suite("Sealed.open — each refusal names a different operator mistake", func() {
  test("a real ciphertext opens to its plaintext", func() {
    let #ok(bytes) = Sealed.open(hexBlob(IBE_CIPHERTEXT), ibeKey()) else Runtime.trap("expected #ok");
    assert bytes.decodeUtf8() == ?IBE_PLAINTEXT;
  });

  test("a plaintext secret sent to the sealed endpoint is #notCiphertext", func() {
    // The most likely first mistake: calling the new endpoint the old way. It must not
    // present as a key mismatch, because the fix is completely different.
    assert Sealed.open("whsec_not_encrypted_at_all".encodeUtf8(), ibeKey()) == #err(#notCiphertext);
  });

  test("an empty argument is #notCiphertext, not a trap", func() {
    assert Sealed.open("" : Blob, ibeKey()) == #err(#notCiphertext);
  });

  test("⚠️ a well-formed ciphertext under the wrong key is #notSealedToThisCanister", func() {
    // This is the arm the WRONG-NETWORK case lands in — sealing against mainnet's master
    // key when the canister is on a local network, or the reverse. Here it is provoked
    // with a key that is valid but simply not the right one, which is the same failure
    // the authenticated check reports.
    assert Sealed.open(hexBlob(IBE_CIPHERTEXT), G1.generator) == #err(#notSealedToThisCanister);
  });
});

suite("Sealed.unwrap — the verification is real, and it is OUR identity", func() {
  test("a malformed derived public key is refused before any pairing", func() {
    let transport = Scalar.fromBytes(hexBytes(REPLY_TSK_BE)) ?? Runtime.trap("bad tsk vector");
    assert Sealed.unwrap(hexBlob(REPLY_ENCRYPTED), transport, hexBlob("00")) == #err(#malformedPublicKey);
  });

  test("a reply that is not an encrypted vetKey is #malformedReply", func() {
    let transport = Scalar.fromBytes(hexBytes(REPLY_TSK_BE)) ?? Runtime.trap("bad tsk vector");
    assert Sealed.unwrap(hexBlob("dead"), transport, hexBlob(REPLY_DPK)) == #err(#malformedReply);
  });

  test("⚠️ a genuine reply sealed to ANOTHER identity is rejected", func() {
    // Everything about this reply is real — it is a `vetkd_derive_key` response the Rust
    // reference produced, and the submodule’s own suite proves it unwraps correctly for the
    // identity it was made for (`"message"`).
    //
    // ⚠️ **It must fail HERE**, because `unwrap` verifies against `Sealed.keyLabel()`.
    // That makes this the one test that distinguishes "the constant is pinned" from "the
    // constant is actually used in the verification" — pinning `keyLabel` cannot catch an
    // `unwrap` that passes something else, or that skips verifying at all. Both of those
    // turn this assertion from `#unverifiableReply` into `#ok`.
    let transport = Scalar.fromBytes(hexBytes(REPLY_TSK_BE)) ?? Runtime.trap("bad tsk vector");
    let outcome = Sealed.unwrap(hexBlob(REPLY_ENCRYPTED), transport, hexBlob(REPLY_DPK));
    assert outcome == #err(#unverifiableReply);
  });
});

suite("Sealed + Secret — the order the two checks run in", func() {
  test("⚠️ the length floor applies to the DECRYPTED value, not the ciphertext", func() {
    // The 151-byte ciphertext is far above `minSecretBytes`; the 15-byte plaintext inside
    // it is one byte below. So this pins the ordering `Sealed.mo` documents: decrypt
    // first, then judge the real value. Checking the argument's length instead would let
    // a truncated secret through on the strength of its envelope.
    assert IBE_CIPHERTEXT.size() / 2 > Secret.minSecretBytes;
    let #ok(plaintext) = Sealed.open(hexBlob(IBE_CIPHERTEXT), ibeKey()) else Runtime.trap("expected #ok");
    assert plaintext.size() == 15;

    let store = Secret.emptyStore();
    assert Secret.set(store, plaintext, 0) == #err(#tooShort({ size = 15; min = Secret.minSecretBytes }));
    // ⚠️ And the store is untouched, so a bad provisioning never clobbers a working secret.
    assert Secret.status(store).isSet == false;
    assert Secret.status(store).generation == 0;
  });
});
