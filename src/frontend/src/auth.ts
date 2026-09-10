// Internet Identity session handling (@icp-sdk/auth 7.x).
//
// Mainnet II by default: both a local `icp network` and PocketIC trust mainnet
// subnet signatures, so real https://id.ai delegations work against either — no
// environment branching in production, and users always see the real II UI. The
// /authorize path is mandatory in 7.x (the URL is used verbatim; without it the
// popup opens the II homepage and never returns).
//
// `VITE_II_URL` overrides it for a fully local environment — PocketIC can deploy
// its own II (`ii` ICP feature) at the mainnet id, and `npm run sandbox` prints the
// URL to build against. Test-only: production leaves it unset and gets mainnet II.
import { AuthClient } from "@icp-sdk/auth/client";
import type { Identity } from "@icp-sdk/core/agent";
import { derivationOrigin } from "./config";

const EIGHT_HOURS_NS = 8n * 3_600_000_000_000n;

/// Where to send the user to authenticate.
///
/// Mainnet II by default, which works even against a local replica: pocket-ic
/// (icp-cli >= 0.2.4) trusts mainnet subnet signatures, so real `id.ai` delegations
/// are accepted locally too.
///
/// On a local network with `ii: true` the II canisters are served alongside the app,
/// and using them is what makes sign-in **automatable** — the real II UI needs a
/// real passkey, which a headless browser cannot produce, while local II mocks it.
///
/// The local URL is derived from the page's own origin rather than configured.
/// `icp.yaml` currently pins `gateway.port: 8000`, so the II skill's hardcoded
/// `:8000` example would work today — deriving it means this keeps working if that
/// pin changes or the app is served through a different gateway, without a
/// second place to update. Guarded on a `.localhost` hostname so a production
/// origin can never take this branch.
function identityProvider(): string {
  const explicit = import.meta.env?.VITE_II_URL as string | undefined;
  if (explicit) return explicit;
  const { hostname, port, protocol } = window.location;
  if (hostname.endsWith(".localhost")) {
    return `${protocol}//id.ai.localhost${port ? `:${port}` : ""}/authorize`;
  }
  return "https://id.ai/authorize";
}

const IDENTITY_PROVIDER = identityProvider();
const DERIVATION_ORIGIN = derivationOrigin();

/// ⚠️ **`derivationOrigin` is what keeps a buyer's principal the same on every domain
/// this app is ever served from.** Without it II derives from the serving origin, so
/// `cyclepay.raymondk.co` and the canister URL are two different accounts with two
/// different cycles balances — and moving to a production domain later would strand
/// every principal. `config.ts` explains why it is the canister origin and not the
/// domain; II verifies the claim against `/.well-known/ii-alternative-origins` served
/// from that origin, so the serving domain must be listed there or sign-in is refused.
///
/// `undefined` locally, where II is served from the same origin.
const authClient = new AuthClient({
  identityProvider: IDENTITY_PROVIDER,
  ...(DERIVATION_ORIGIN ? { derivationOrigin: DERIVATION_ORIGIN } : {}),
});

export async function signIn(): Promise<Identity> {
  // Rejects when the user closes the popup — callers surface that, not us.
  return authClient.signIn({ maxTimeToLive: EIGHT_HOURS_NS });
}

export async function signOut(): Promise<void> {
  await authClient.signOut();
}

/// The restored session, or null when signed out / expired.
export async function currentIdentity(): Promise<Identity | null> {
  if (!authClient.isAuthenticated()) return null;
  return authClient.getIdentity();
}
