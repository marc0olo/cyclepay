/// Sealed provisioning (#11), end to end against a real vetKD-serving subnet.
///
/// ⚠️ **What this covers that `test/sealed.test.mo` cannot.** The Motoko suite tests the
/// pure functions with fixed vectors; it never derives a key, because deriving needs the
/// management canister. Everything here runs the full path: `raw_rand`, a real
/// `vetkd_derive_key` through consensus, `vetkd_public_key`, verification, then decryption
/// — which is also the only place the ~26 B cycle fee is actually charged.
///
/// ⚠️ **And it is the only automated check of the WRONG-NETWORK failure.** Sealing with
/// mainnet's master key against a PocketIC canister is the mistake `scripts/seal-secret.sh`
/// exists to make untypeable, and the mistake whose symptom — a ciphertext nobody can ever
/// open — has no other way of being observed before an operator hits it. It is reproduced
/// here deliberately.
import { beforeAll, afterAll, describe, it, expect } from "vitest";
import {
  IbeCiphertext,
  IbeIdentity,
  IbeSeed,
  MasterPublicKey,
  MasterPublicKeyId,
} from "@icp-sdk/vetkeys";
import { setupGateway, teardownGateway, expectOk, expectErr, type Gateway } from "./harness";
import { seal } from "./seal";

const SECRET = "whsec_sealed_spec_0123456789abcdef";

let gw: Gateway;

beforeAll(async () => {
  gw = await setupGateway();
}, 180_000);

afterAll(async () => {
  if (gw) await teardownGateway(gw);
});

/// The same seal, but against MAINNET's master key — the wrong table for this instance.
function sealWithMainnetKey(canisterId: { toUint8Array(): Uint8Array }, secret: string): Uint8Array {
  const publicKey = MasterPublicKey.productionKey(MasterPublicKeyId.KEY_1)
    .deriveCanisterKey(canisterId.toUint8Array())
    .deriveSubKey(new TextEncoder().encode("cyclepay-secrets"));
  return IbeCiphertext.encrypt(
    publicKey,
    IbeIdentity.fromBytes(new TextEncoder().encode("stripe-secrets")),
    new TextEncoder().encode(secret),
    IbeSeed.random(),
  ).serialize();
}

describe("sealed provisioning", () => {
  it("a correctly sealed secret is decrypted and stored", async () => {
    expectOk(await gw.asAdmin.set_webhook_secret(seal(gw.backendId, SECRET)));
    const status = await gw.asAdmin.webhook_secret_status();
    expect(status.isSet).toBe(true);
    expect(status.generation).toBe(1n);
  }, 120_000);

  it("⚠️ one derivation serves BOTH secrets — they share the identity", async () => {
    // The second provisioning hits the cached vetKey, so it pays no second fee. If the
    // two secrets had separate labels this would cost another ~26 B cycles, which is the
    // arrangement #11 rejects.
    expectOk(await gw.asAdmin.set_stripe_api_key(seal(gw.backendId, "rk_test_sealed_spec_key")));
    expect((await gw.asAdmin.stripe_api_key_status()).isSet).toBe(true);
  }, 120_000);

  it("a plaintext secret sent to the sealed endpoint is refused as #notCiphertext", async () => {
    // The old habit. It must not present as a key mismatch — the fix is different.
    const before = await gw.asAdmin.webhook_secret_status();
    const err = expectErr(
      await gw.asAdmin.set_webhook_secret(new TextEncoder().encode("whsec_plain_not_sealed")),
    );
    expect(err).toHaveProperty("notCiphertext");
    // ⚠️ The working secret survives a bad rotation attempt.
    const after = await gw.asAdmin.webhook_secret_status();
    expect(after.generation).toBe(before.generation);
  }, 120_000);

  it("⚠️ sealing with MAINNET's master key is refused as #notSealedToThisCanister", async () => {
    // This instance's vetKD is backed by PocketIC's master key. Both are called `key_1`,
    // so nothing about the NAME distinguishes them — which is exactly why the choice is
    // derived from the environment in `scripts/seal-secret.sh` rather than typed.
    const before = await gw.asAdmin.webhook_secret_status();
    const err = expectErr(
      await gw.asAdmin.set_webhook_secret(sealWithMainnetKey(gw.backendId, SECRET)),
    );
    expect(err).toHaveProperty("notSealedToThisCanister");
    const after = await gw.asAdmin.webhook_secret_status();
    expect(after.generation).toBe(before.generation);
  }, 120_000);

  it("⚠️ a ciphertext sealed for a DIFFERENT canister does not open here", async () => {
    // The canister id is a derivation input, so a seal made for the cycles ledger cannot
    // be opened by the backend. This is what makes a ciphertext safe to hand around: it
    // is useless to everyone except its one intended reader.
    const other = { toUint8Array: () => gw.backendId.toUint8Array().map((b, i) => (i === 0 ? b ^ 1 : b)) };
    const err = expectErr(await gw.asAdmin.set_webhook_secret(seal(other, SECRET)));
    expect(err).toHaveProperty("notSealedToThisCanister");
  }, 120_000);

  it("authorization is checked BEFORE decryption, so a valid seal from a stranger is refused", async () => {
    // Ordering matters for cost as much as for access: an ungated endpoint would let any
    // principal spend ~26 B cycles per call forcing a derivation.
    await expect(gw.asStranger.set_webhook_secret(seal(gw.backendId, SECRET))).rejects.toThrow(
      /not a controller/,
    );
    await expect(gw.asAnon.set_webhook_secret(seal(gw.backendId, SECRET))).rejects.toThrow(
      /anonymous/,
    );
  }, 120_000);

  it("a decrypted value below the length floor is refused, and the floor sees the PLAINTEXT", async () => {
    // The ciphertext is ~170 bytes; the secret inside is 4. Checking the argument's size
    // instead of the decrypted value would wave this through on the strength of its
    // envelope.
    const before = await gw.asAdmin.webhook_secret_status();
    const err = expectErr(await gw.asAdmin.set_webhook_secret(seal(gw.backendId, "tiny")));
    expect(err).toHaveProperty("tooShort");
    const after = await gw.asAdmin.webhook_secret_status();
    expect(after.generation).toBe(before.generation);
  }, 120_000);
});
