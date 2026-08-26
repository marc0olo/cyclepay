// Backend actor construction off the ic_env cookie (asset canister in prod,
// Vite dev-server header locally) — canister id and root key both come from
// it, so there is no environment branching and never a runtime root-key
// fetch (a fetched root key on mainnet is a MITM vector).
import { safeGetCanisterEnv } from "@icp-sdk/core/agent/canister-env";
import { Actor, HttpAgent, type Identity } from "@icp-sdk/core/agent";
import { IDL } from "@icp-sdk/core/candid";
import { createActor, Rail } from "./bindings/backend";

const canisterEnv = safeGetCanisterEnv();
export const backendCanisterId = canisterEnv?.["PUBLIC_CANISTER_ID:backend"];

/// One agent recipe for every actor this app builds (the backend and the
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

/// The cycles ledger, queried directly by this app (#30 PR-A).
///
/// ⚠️ **Why the frontend asks the ledger instead of the backend.** The buyer sees
/// `lockedCycles - transferFee`, and the fee is the ledger's to change. A canister
/// *query* cannot `await icrc1_fee`, so disclosing it through `quote_previews`
/// meant the backend storing a copy and correcting it whenever a transfer came
/// back `#BadFee` — a stable field plus a correction path plus a whole staleness
/// class, in exchange for one number the caller can read itself.
///
/// The split is the same one `available = balance - promisedTotal` uses: the
/// canister owns what only it knows, the ledger owns what it owns.
///
/// Hand-written IDL rather than generated bindings: two query methods off a
/// foreign canister do not justify vendoring the ledger's whole `.did`, and a
/// partial interface makes it obvious that this app is a *reader* here.
export const cyclesLedgerCanisterId = "um5iw-rqaaa-aaaaq-qaaba-cai";

const cyclesLedgerIdl: IDL.InterfaceFactory = ({ IDL }) => {
  const Account = IDL.Record({
    owner: IDL.Principal,
    subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
  });
  return IDL.Service({
    icrc1_fee: IDL.Func([], [IDL.Nat], ["query"]),
    icrc1_balance_of: IDL.Func([Account], [IDL.Nat], ["query"]),
  });
};

export interface CyclesLedger {
  icrc1_fee(): Promise<bigint>;
  icrc1_balance_of(account: { owner: unknown; subaccount: [] | [Uint8Array] }): Promise<bigint>;
}

export function makeCyclesLedger(): CyclesLedger {
  const agent = HttpAgent.createSync(agentOptions());
  return Actor.createActor<CyclesLedger>(cyclesLedgerIdl, {
    agent,
    canisterId: cyclesLedgerCanisterId,
  });
}

export type Backend = ReturnType<typeof makeBackend>;
// Structural types derived from the generated actor — immune to whatever
// type names bindgen exports.
export type Order = NonNullable<Awaited<ReturnType<Backend["get_order"]>>>;
export type Tier = Awaited<ReturnType<Backend["card_tiers"]>>[number];
export type Destination = Parameters<Backend["create_order"]>[1];
/// What the buyer is paying for: a preset or a typed amount (#33). Derived from
/// the method signature rather than restated, so a backend change to the variant
/// is a typecheck failure here rather than a silent divergence.
export type Amount = Parameters<Backend["create_order"]>[0];
export type CreateOrderResult = Awaited<ReturnType<Backend["create_order"]>>;
export type TreasuryStatus = Awaited<ReturnType<Backend["treasury_status"]>>;
export type PricingStatus = Awaited<ReturnType<Backend["pricing_status"]>>;
// Payload-less Candid variants surface as string enums; re-exported so callers
// name the rail instead of hand-building a variant record.
export { Rail };
export type QuotePreview = Awaited<ReturnType<Backend["quote_previews"]>>["quotes"][number];
