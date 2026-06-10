// Internet Identity session handling (@icp-sdk/auth 7.x).
//
// Mainnet II unconditionally: the local network (icp-cli ≥ 0.2.4) trusts
// mainnet subnet signatures, so https://id.ai delegations work against a
// local replica too — no environment branching, and users always see the
// real II UI. The /authorize path is mandatory in 7.x (the URL is used
// verbatim; without it the popup opens the II homepage and never returns).
import { AuthClient } from "@icp-sdk/auth/client";
import type { Identity } from "@icp-sdk/core/agent";

const EIGHT_HOURS_NS = 8n * 3_600_000_000_000n;

const authClient = new AuthClient({
  identityProvider: "https://id.ai/authorize",
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
