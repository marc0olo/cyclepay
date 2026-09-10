/**
 * Seals a secret to the backend's vetKD public key, for the suite (#11).
 *
 * Both setters take a ciphertext now, so every provisioning call in the suite goes
 * through here. That is deliberate: a helper per spec file would let the constants drift,
 * and `CONTEXT`/`KEY_LABEL` drifting from `src/backend/Sealed.mo` produces
 * `#notSealedToThisCanister` — an error that reads like the canister's fault.
 *
 * ⚠️ **PocketIC's master key, always.** This suite only ever runs against PocketIC, so
 * unlike `scripts/seal-secret.sh` there is nothing to choose here. The mainnet master key
 * would produce ciphertext this instance's vetKD cannot open.
 */
import {
  IbeCiphertext,
  IbeIdentity,
  IbeSeed,
  MasterPublicKey,
  PocketIcMasterPublicKeyId,
} from "@icp-sdk/vetkeys";

/** ⚠️ Must match `src/backend/Sealed.mo`; `test/sealed.test.mo` pins the Motoko side. */
const CONTEXT = new TextEncoder().encode("cyclepay-secrets");
const KEY_LABEL = new TextEncoder().encode("stripe-secrets");

/**
 * The ciphertext for `secret`, openable only by `canisterId`.
 *
 * Pure computation — no `pic` call, no identity. The canister id is a derivation input,
 * so a ciphertext made for one canister is useless to another.
 *
 * ⚠️ **The parameter is STRUCTURAL, not `Principal`, and that is not fussiness.**
 * `@dfinity/pic` bundles its own nested `@icp-sdk/core`, so importing `Principal` here
 * from a top-level `@icp-sdk/core` yields a SECOND nominal `Principal` whose private
 * `_arr` is incompatible — and `gw.backendId` comes from pic's copy. That produced four
 * TS2345/TS2322 errors in `withdraw.spec.ts`, nowhere near this file. Taking the one
 * method actually needed keeps the suite on a single copy and needs no dependency at all.
 */
export function seal(canisterId: { toUint8Array(): Uint8Array }, secret: string): Uint8Array {
  const publicKey = MasterPublicKey.pocketicKey(PocketIcMasterPublicKeyId.KEY_1)
    .deriveCanisterKey(canisterId.toUint8Array())
    .deriveSubKey(CONTEXT);

  return IbeCiphertext.encrypt(
    publicKey,
    IbeIdentity.fromBytes(KEY_LABEL),
    new TextEncoder().encode(secret),
    IbeSeed.random(),
  ).serialize();
}
