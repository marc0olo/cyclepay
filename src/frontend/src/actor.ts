// Backend actor construction off the ic_env cookie (asset canister in prod,
// Vite dev-server header locally) — canister id and root key both come from
// it, so there is no environment branching and never a runtime root-key
// fetch (a fetched root key on mainnet is a MITM vector).
import { safeGetCanisterEnv } from "@icp-sdk/core/agent/canister-env";
import type { Identity } from "@icp-sdk/core/agent";
import { createActor, Rail } from "./bindings/backend";

const canisterEnv = safeGetCanisterEnv();
export const backendCanisterId = canisterEnv?.["PUBLIC_CANISTER_ID:backend"];

/// One agent recipe for every actor this app builds (backend and the ck-USDC
/// ledger) — host and root key always come from ic_env.
export function agentOptions(identity?: Identity) {
  return {
    host: window.location.origin,
    rootKey: canisterEnv?.IC_ROOT_KEY,
    ...(identity ? { identity } : {}),
  };
}

export function makeBackend(identity?: Identity) {
  if (!backendCanisterId) {
    throw new Error(
      "backend canister id missing from ic_env. Deploy with `icp deploy`, or run `vite dev` against a started local network.",
    );
  }
  return makeBackendAt(backendCanisterId, identity);
}

/// Build a backend actor against an EXPLICIT canister id.
///
/// Exists for the stale-`ic_env` self-heal (see ic-env.ts): when the browser holds
/// conflicting cookies, the app has to probe each advertised id and adopt the one
/// that answers, which means constructing an actor for an id that did not come
/// from `safeGetCanisterEnv`.
export function makeBackendAt(canisterId: string, identity?: Identity) {
  // agentOptions, never a pre-built agent: passing { agent } to a bindgen
  // actor silently downgrades to the anonymous identity.
  return createActor(canisterId, { agentOptions: agentOptions(identity) });
}

export type Backend = ReturnType<typeof makeBackend>;
// Structural types derived from the generated actor — immune to whatever
// type names bindgen exports.
export type Order = NonNullable<Awaited<ReturnType<Backend["get_order"]>>>;
export type Tier = Awaited<ReturnType<Backend["card_tiers"]>>[number];
export type Destination = Parameters<Backend["create_order"]>[1];
export type CreateOrderResult = Awaited<ReturnType<Backend["create_order"]>>;
export type TreasuryStatus = Awaited<ReturnType<Backend["treasury_status"]>>;
export type PricingStatus = Awaited<ReturnType<Backend["pricing_status"]>>;
export type CkUsdcConfig = Awaited<ReturnType<Backend["ck_usdc_config"]>>;
// Payload-less Candid variants surface as string enums; re-exported so callers
// name the rail instead of hand-building a variant record.
export { Rail };
export type QuotePreview = Awaited<ReturnType<Backend["quote_previews"]>>["quotes"][number];
