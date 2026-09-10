/**
 * Seals a Stripe secret to the backend canister's vetKD public key (#11).
 *
 * Two steps, and only the second one involves any identity:
 *
 *   1. Derive the canister's public key **offline** — from a master public key shipped in
 *      `@icp-sdk/vetkeys` plus the canister id. No network call, no principal, nothing to
 *      trust. Anyone can seal a secret *to* the canister; only the canister can open it.
 *   2. Encrypt to it. Pure computation with no key of ours in it.
 *
 * Sending the result is a separate, signed call, which `scripts/seal-secret.sh` makes.
 * That split is why this file never talks to a network: if it could fetch the public key,
 * whoever answered could substitute one they hold.
 *
 * ⚠️ **The encryption here is the audited half.** `@icp-sdk/vetkeys` is DFINITY's own
 * library. The canister's decryption runs on an experimental BLS12-381 port — see
 * `docs/DESIGN.md` §7.3 for why that asymmetry is what makes the arrangement acceptable.
 */
import { writeFileSync } from "node:fs";
import { Principal } from "@icp-sdk/core/principal";
import {
  IbeCiphertext,
  IbeIdentity,
  IbeSeed,
  MasterPublicKey,
  MasterPublicKeyId,
  PocketIcMasterPublicKeyId,
} from "@icp-sdk/vetkeys";

/**
 * ⚠️ **Both must match `src/backend/Sealed.mo` byte for byte**, and `test/sealed.test.mo`
 * pins the Motoko side so the two cannot drift silently.
 *
 * `CONTEXT` selects the canister's keypair; `KEY_LABEL` is the IBE identity every secret
 * is sealed to. One label means one derivation covers both secrets.
 */
const CONTEXT = new TextEncoder().encode("cyclepay-secrets");
const KEY_LABEL = new TextEncoder().encode("stripe-secrets");

const USAGE = `Seal a Stripe secret to the backend canister.

  --canister <id>    the backend canister id
  --source <which>   mainnet | pocketic   (REQUIRED — see below)
  --out <path>       write the Candid argument here instead of stdout

The secret is read from CYCLEPAY_SEAL_SECRET in the environment, never from a flag: a
--value argument would land in shell history and in CI logs, which is the exposure this
whole mechanism exists to close.

⚠️  --source has NO DEFAULT, on purpose.

Mainnet and a local network BOTH have a vetKD key called key_1, backed by different
master keys — necessarily, since a local network cannot hold mainnet's master secret. So
the key NAME does not identify the key. Choose the wrong table and you produce a
ciphertext nobody can ever open, and nothing detects it until the canister tries to
decrypt. A default here would be a silent wrong answer waiting for a mainnet deploy;
scripts/seal-secret.sh derives the value from the environment instead.
`;

function arg(name: string, fallback?: string): string {
  const i = process.argv.indexOf(name);
  if (i === -1 || i + 1 >= process.argv.length) {
    if (fallback !== undefined) return fallback;
    console.error(`error: ${name} is required\n\n${USAGE}`);
    process.exit(1);
  }
  return process.argv[i + 1]!;
}

/** Step 1: the canister's public key, computed here, offline. */
function derivePublicKey(source: string, keyName: string, canisterId: Principal) {
  let master;
  if (source === "mainnet") {
    master = MasterPublicKey.productionKey(
      keyName === "test_key_1" ? MasterPublicKeyId.TEST_KEY_1 : MasterPublicKeyId.KEY_1,
    );
  } else if (source === "pocketic") {
    master = MasterPublicKey.pocketicKey(
      keyName === "test_key_1"
        ? PocketIcMasterPublicKeyId.TEST_KEY_1
        : PocketIcMasterPublicKeyId.KEY_1,
    );
  } else {
    console.error(`error: --source must be "mainnet" or "pocketic", got "${source}"\n\n${USAGE}`);
    process.exit(1);
  }
  return master.deriveCanisterKey(canisterId.toUint8Array()).deriveSubKey(CONTEXT);
}

/** Candid text for a `blob` argument: every byte escaped, so quoting cannot surprise. */
function candidBlob(bytes: Uint8Array): string {
  const escaped = Array.from(bytes, (b) => `\\${b.toString(16).padStart(2, "0")}`).join("");
  return `(blob "${escaped}")`;
}

function main() {
  if (process.argv.includes("--help")) {
    console.log(USAGE);
    return;
  }

  const canisterId = Principal.fromText(arg("--canister"));
  const source = arg("--source");
  const keyName = arg("--key-name", "key_1");
  const out = arg("--out", "");

  const secret = process.env.CYCLEPAY_SEAL_SECRET;
  if (!secret) {
    console.error(
      "error: CYCLEPAY_SEAL_SECRET is unset.\n" +
        "       scripts/seal-secret.sh sets it from STRIPE_API_KEY or STRIPE_WEBHOOK_SECRET.\n" +
        "       Read from the environment on purpose — a --value flag would land in shell\n" +
        "       history and CI logs.",
    );
    process.exit(1);
  }

  const publicKey = derivePublicKey(source, keyName, canisterId);

  const ciphertext = IbeCiphertext.encrypt(
    publicKey,
    IbeIdentity.fromBytes(KEY_LABEL),
    new TextEncoder().encode(secret),
    IbeSeed.random(),
  ).serialize();

  const candid = candidBlob(ciphertext);
  if (out) {
    writeFileSync(out, candid);
    // The secret's LENGTH is reported, never any of its bytes: enough to see that the
    // right value was picked up, useless to anyone reading a log.
    console.error(
      `sealed ${secret.length} bytes to ${canisterId.toText()} using the ${source} ` +
        `${keyName} master key (offline) -> ${ciphertext.length}-byte ciphertext in ${out}`,
    );
  } else {
    console.log(candid);
  }
}

main();
