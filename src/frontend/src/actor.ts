// Backend actor construction off the ic_env cookie (asset canister in prod,
// Vite dev-server header locally) — canister id and root key both come from
// it, so there is no environment branching and never a runtime root-key
// fetch (a fetched root key on mainnet is a MITM vector).
import { safeGetCanisterEnv } from "@icp-sdk/core/agent/canister-env";
import type { Identity } from "@icp-sdk/core/agent";
import { createActor } from "./bindings/backend";

const canisterEnv = safeGetCanisterEnv();
const backendCanisterId = canisterEnv?.["PUBLIC_CANISTER_ID:backend"];

export function makeBackend(identity?: Identity) {
  if (!backendCanisterId) {
    throw new Error(
      "backend canister id missing from ic_env — deploy with `icp deploy` (or run `vite dev` against a started local network)",
    );
  }
  // agentOptions, never a pre-built agent: passing { agent } to a bindgen
  // actor silently downgrades to the anonymous identity.
  return createActor(backendCanisterId, {
    agentOptions: {
      host: window.location.origin,
      rootKey: canisterEnv?.IC_ROOT_KEY,
      ...(identity ? { identity } : {}),
    },
  });
}

export type Backend = ReturnType<typeof makeBackend>;
// Structural types derived from the generated actor — immune to whatever
// type names bindgen exports.
export type Order = NonNullable<Awaited<ReturnType<Backend["get_order"]>>>;
export type Tier = Awaited<ReturnType<Backend["card_tiers"]>>[number];
export type Destination = Parameters<Backend["create_order"]>[1];
export type CreateOrderResult = Awaited<ReturnType<Backend["create_order"]>>;
export type TreasuryStatus = Awaited<ReturnType<Backend["treasury_status"]>>;
export type ForexStatus = Awaited<ReturnType<Backend["forex_status"]>>;
