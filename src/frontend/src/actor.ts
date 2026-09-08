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

/// The cycles-ledger **index** canister, for one account's transaction history.
///
/// ⚠️ **On-chain, not the dashboard's REST API**, and that was a real decision. The
/// public dashboard has this data and calling it would have been easier — but this
/// page's whole pitch is that its figures come from canisters anyone can query, and an
/// off-chain dependency in the middle of that would undercut it. The index is a
/// canister; asking it keeps the claim intact.
///
/// ⚠️ **An ICRC-1 ledger cannot answer this.** It serves balances, not history, and
/// ICRC-3 serves blocks BY INDEX rather than by account — filtering to one principal
/// from a browser would mean scanning the chain. The index exists for exactly this.
///
/// Measured rather than assumed, against mainnet: `status` reports 16.4M blocks
/// synced, and `ledger_id` returns `um5iw-rqaaa-aaaaq-qaaba-cai` — the same ledger
/// this gateway delivers to. A hardcoded index pointing at a DIFFERENT ledger would
/// render someone else's history under the buyer's name, so that pairing is the one
/// fact worth checking before trusting the id.
export const cyclesIndexCanisterId = "ul4oc-4iaaa-aaaaq-qaabq-cai";

const cyclesIndexIdl: IDL.InterfaceFactory = ({ IDL }) => {
  const Account = IDL.Record({
    owner: IDL.Principal,
    subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
  });
  const Tokens = IDL.Nat;
  // Only the fields this page renders. A partial interface is deliberate: it makes
  // plain that the app is a READER here, and it means an unrelated change to the
  // index's other methods cannot break this decode.
  const Transfer = IDL.Record({
    from: Account,
    to: Account,
    amount: Tokens,
    fee: IDL.Opt(Tokens),
    memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time: IDL.Opt(IDL.Nat64),
    spender: IDL.Opt(Account),
  });
  const Mint = IDL.Record({
    to: Account,
    amount: Tokens,
    memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time: IDL.Opt(IDL.Nat64),
  });
  const Burn = IDL.Record({
    from: Account,
    amount: Tokens,
    memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time: IDL.Opt(IDL.Nat64),
    spender: IDL.Opt(Account),
    fee: IDL.Opt(IDL.Nat),
  });
  const Approve = IDL.Record({
    from: Account,
    spender: Account,
    amount: Tokens,
    fee: IDL.Opt(Tokens),
    memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time: IDL.Opt(IDL.Nat64),
    expected_allowance: IDL.Opt(Tokens),
    expires_at: IDL.Opt(IDL.Nat64),
  });
  const Transaction = IDL.Record({
    kind: IDL.Text,
    timestamp: IDL.Nat64,
    transfer: IDL.Opt(Transfer),
    mint: IDL.Opt(Mint),
    burn: IDL.Opt(Burn),
    approve: IDL.Opt(Approve),
  });
  const TransactionWithId = IDL.Record({ id: IDL.Nat, transaction: Transaction });
  const GetTransactions = IDL.Record({
    balance: Tokens,
    transactions: IDL.Vec(TransactionWithId),
    oldest_tx_id: IDL.Opt(IDL.Nat),
  });
  const GetTransactionsResult = IDL.Variant({
    Ok: GetTransactions,
    Err: IDL.Record({ message: IDL.Text }),
  });
  const GetAccountTransactionsArgs = IDL.Record({
    account: Account,
    start: IDL.Opt(IDL.Nat),
    max_results: IDL.Nat,
  });
  return IDL.Service({
    get_account_transactions:
      IDL.Func([GetAccountTransactionsArgs], [GetTransactionsResult], ["query"]),
  });
};

export interface IndexAccount {
  owner: unknown;
  subaccount: [] | [Uint8Array];
}

export interface IndexTransfer {
  from: IndexAccount;
  to: IndexAccount;
  amount: bigint;
  fee: [] | [bigint];
  /// ⚠️ CALLER-supplied, unlike a burn's. Only meaningful once the sender is known:
  /// see `decodeOrderMemo`.
  memo: [] | [Uint8Array];
}

export interface IndexTransaction {
  kind: string;
  timestamp: bigint;
  transfer: [] | [IndexTransfer];
  mint: [] | [{ to: IndexAccount; amount: bigint }];
  burn: [] | [{ from: IndexAccount; amount: bigint; memo: [] | [Uint8Array] }];
  approve: [] | [{ from: IndexAccount; spender: IndexAccount; amount: bigint }];
}

export interface CyclesIndex {
  get_account_transactions(args: {
    account: IndexAccount;
    start: [] | [bigint];
    max_results: bigint;
  }): Promise<
    | { Ok: { balance: bigint; transactions: Array<{ id: bigint; transaction: IndexTransaction }>; oldest_tx_id: [] | [bigint] } }
    | { Err: { message: string } }
  >;
}

export function makeCyclesIndex(): CyclesIndex {
  const agent = HttpAgent.createSync(agentOptions());
  return Actor.createActor<CyclesIndex>(cyclesIndexIdl, {
    agent,
    canisterId: cyclesIndexCanisterId,
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
export type PricingStatus = Awaited<ReturnType<Backend["pricing_status"]>>;
// Payload-less Candid variants surface as string enums; re-exported so callers
// name the rail instead of hand-building a variant record.
export { Rail };
export type QuotePreview = Awaited<ReturnType<Backend["quote_previews"]>>["quotes"][number];
