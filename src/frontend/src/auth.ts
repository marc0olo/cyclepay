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

const EIGHT_HOURS_NS = 8n * 3_600_000_000_000n;

const IDENTITY_PROVIDER =
  (import.meta.env?.VITE_II_URL as string | undefined) ?? "https://id.ai/authorize";

const authClient = new AuthClient({
  identityProvider: IDENTITY_PROVIDER,
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
