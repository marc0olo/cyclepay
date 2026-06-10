// Hand-rolled ICRC-2 actor for the ck-USDC ledger — only the three methods
// the approve→claim flow needs. Raw IDL (not bindgen): there is no committed
// .did for an external canister, and the raw wrapper's [] | [T] opt shape is
// fine at this size.
//
// The canister id is the same mainnet pin as `CkUsdc.mo` — PocketIC's
// fiduciary subnet hosts the test ledger at the identical id, so there is no
// environment branching here either.
import { Actor, HttpAgent } from "@icp-sdk/core/agent";
import type { Identity } from "@icp-sdk/core/agent";
import type { IDL } from "@icp-sdk/core/candid";
import type { Principal } from "@icp-sdk/core/principal";
import { agentOptions } from "./actor";

export const CK_USDC_LEDGER_ID = "xevnm-gaaaa-aaaar-qafnq-cai";

export interface RawAccount {
  owner: Principal;
  subaccount: [] | [Uint8Array];
}

export interface ApproveArgs {
  from_subaccount: [] | [Uint8Array];
  spender: RawAccount;
  amount: bigint;
  expected_allowance: [] | [bigint];
  expires_at: [] | [bigint];
  fee: [] | [bigint];
  memo: [] | [Uint8Array];
  created_at_time: [] | [bigint];
}

export type ApproveResult = { Ok: bigint } | { Err: Record<string, unknown> };

export interface CkUsdcLedger {
  icrc1_balance_of: (account: RawAccount) => Promise<bigint>;
  icrc2_allowance: (args: {
    account: RawAccount;
    spender: RawAccount;
  }) => Promise<{ allowance: bigint; expires_at: [] | [bigint] }>;
  icrc2_approve: (args: ApproveArgs) => Promise<ApproveResult>;
}

const idlFactory: IDL.InterfaceFactory = ({ IDL }) => {
  const Subaccount = IDL.Vec(IDL.Nat8);
  const Account = IDL.Record({
    owner: IDL.Principal,
    subaccount: IDL.Opt(Subaccount),
  });
  const ApproveArgs = IDL.Record({
    from_subaccount: IDL.Opt(Subaccount),
    spender: Account,
    amount: IDL.Nat,
    expected_allowance: IDL.Opt(IDL.Nat),
    expires_at: IDL.Opt(IDL.Nat64),
    fee: IDL.Opt(IDL.Nat),
    memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time: IDL.Opt(IDL.Nat64),
  });
  const ApproveError = IDL.Variant({
    BadFee: IDL.Record({ expected_fee: IDL.Nat }),
    InsufficientFunds: IDL.Record({ balance: IDL.Nat }),
    AllowanceChanged: IDL.Record({ current_allowance: IDL.Nat }),
    Expired: IDL.Record({ ledger_time: IDL.Nat64 }),
    TooOld: IDL.Null,
    CreatedInFuture: IDL.Record({ ledger_time: IDL.Nat64 }),
    Duplicate: IDL.Record({ duplicate_of: IDL.Nat }),
    TemporarilyUnavailable: IDL.Null,
    GenericError: IDL.Record({ error_code: IDL.Nat, message: IDL.Text }),
  });
  return IDL.Service({
    icrc1_balance_of: IDL.Func([Account], [IDL.Nat], ["query"]),
    icrc2_allowance: IDL.Func(
      [IDL.Record({ account: Account, spender: Account })],
      [IDL.Record({ allowance: IDL.Nat, expires_at: IDL.Opt(IDL.Nat64) })],
      ["query"],
    ),
    icrc2_approve: IDL.Func([ApproveArgs], [IDL.Variant({ Ok: IDL.Nat, Err: ApproveError })], []),
  });
};

/// Identity is required, not optional: an anonymous approve would burn the
/// fee approving from the shared anonymous account.
export function makeCkUsdcLedger(identity: Identity): CkUsdcLedger {
  const agent = HttpAgent.createSync(agentOptions(identity));
  return Actor.createActor<CkUsdcLedger>(idlFactory, { agent, canisterId: CK_USDC_LEDGER_ID });
}
