/// Candid IDL factories for the suite.
///
/// `backendIdlFactory` is GENERATED from `src/backend/dist/backend.did` (#66) and
/// re-exported here so callers keep one import site.
///
/// ⚠️ The ledger/CMC/cycles-ledger factories below stay hand-written, correctly: we do
/// not own those `.did` files, and the suite calls only a handful of their methods. They
/// are minimal subsets of the real
/// NNS interfaces — only the methods the suite itself calls; the backend
/// talks to those canisters with its own Motoko bindings (Cmc.mo).
import { IDL } from '@icp-sdk/core/candid';
import type { IDL as IDLNamespace } from '@icp-sdk/core/candid';

/// ⚠️ **GENERATED, not transcribed (#66).** `backendIdlFactory` was 555 hand-written
/// `IDL.Func` lines mirroring `src/backend/dist/backend.did`, with nothing checking the
/// two against each other — so the suite could decode against an interface the canister
/// no longer had, and did: `GateReason` still carried `burnCapExhausted` and `floatLow`
/// after #36 deleted the treasury path, and was missing `reserveShort` entirely, making a
/// reserve-short refusal untestable.
///
/// ⚠️ **The asymmetry is why this could not be caught by a test.** A mirror that DECLARES
/// a field the canister lacks fails the Candid decode and is found. A mirror that OMITS a
/// field decodes fine, and the test silently covers less than it claims — the same shape
/// as a check that runs, passes, and never visits the thing that matters.
///
/// `scripts/check-bindings.sh` rebuilds the `.did`, regenerates into a temp directory and
/// diffs, so the committed output cannot rot.
export { idlFactory as backendIdlFactory } from './generated/declarations/backend.did.js';

export const icrc1IdlFactory: IDLNamespace.InterfaceFactory = ({ IDL }) => {
  const Account = IDL.Record({
    owner: IDL.Principal,
    subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
  });
  const TransferArg = IDL.Record({
    from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
    to: Account,
    amount: IDL.Nat,
    fee: IDL.Opt(IDL.Nat),
    memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time: IDL.Opt(IDL.Nat64),
  });
  const TransferError = IDL.Variant({
    BadFee: IDL.Record({ expected_fee: IDL.Nat }),
    BadBurn: IDL.Record({ min_burn_amount: IDL.Nat }),
    InsufficientFunds: IDL.Record({ balance: IDL.Nat }),
    TooOld: IDL.Null,
    CreatedInFuture: IDL.Record({ ledger_time: IDL.Nat64 }),
    Duplicate: IDL.Record({ duplicate_of: IDL.Nat }),
    TemporarilyUnavailable: IDL.Null,
    GenericError: IDL.Record({ error_code: IDL.Nat, message: IDL.Text }),
  });
  return IDL.Service({
    icrc1_balance_of: IDL.Func([Account], [IDL.Nat], ['query']),
    icrc1_fee: IDL.Func([], [IDL.Nat], ['query']),
    icrc1_transfer: IDL.Func(
      [TransferArg],
      [IDL.Variant({ Ok: IDL.Nat, Err: TransferError })],
      [],
    ),
  });
};

/// CMC subset: the governance-gated conversion-rate setter (the suite
/// impersonates the governance canister principal — PocketIC allows any
/// sender) and the public rate query.
export const cmcIdlFactory: IDLNamespace.InterfaceFactory = ({ IDL }) => {
  const UpdateIcpXdrConversionRatePayload = IDL.Record({
    data_source: IDL.Text,
    timestamp_seconds: IDL.Nat64,
    xdr_permyriad_per_icp: IDL.Nat64,
    reason: IDL.Opt(
      IDL.Variant({
        OldRate: IDL.Null,
        DivergedRate: IDL.Null,
        EnableAutomaticExchangeRateUpdates: IDL.Null,
      }),
    ),
  });
  const IcpXdrConversionRate = IDL.Record({
    timestamp_seconds: IDL.Nat64,
    xdr_permyriad_per_icp: IDL.Nat64,
  });
  return IDL.Service({
    set_icp_xdr_conversion_rate: IDL.Func(
      [UpdateIcpXdrConversionRatePayload],
      [IDL.Variant({ Ok: IDL.Null, Err: IDL.Text })],
      [],
    ),
    get_icp_xdr_conversion_rate: IDL.Func(
      [],
      [
        IDL.Record({
          data: IcpXdrConversionRate,
          hash_tree: IDL.Vec(IDL.Nat8),
          certificate: IDL.Vec(IDL.Nat8),
        }),
      ],
      ['query'],
    ),
  });
};

// ── XRC mock (dfinity/exchange-rate-canister src/xrc_mock) ─────────────────

const xrcAssetClass = IDL.Variant({ Cryptocurrency: IDL.Null, FiatCurrency: IDL.Null });
const xrcAsset = IDL.Record({ symbol: IDL.Text, class: xrcAssetClass });
const xrcMetadata = IDL.Record({
  decimals: IDL.Nat32,
  base_asset_num_received_rates: IDL.Nat64,
  base_asset_num_queried_sources: IDL.Nat64,
  quote_asset_num_received_rates: IDL.Nat64,
  quote_asset_num_queried_sources: IDL.Nat64,
  standard_deviation: IDL.Nat64,
  forex_timestamp: IDL.Opt(IDL.Nat64),
});
const xrcError = IDL.Variant({
  AnonymousPrincipalNotAllowed: IDL.Null,
  Pending: IDL.Null,
  CryptoBaseAssetNotFound: IDL.Null,
  CryptoQuoteAssetNotFound: IDL.Null,
  StablecoinRateNotFound: IDL.Null,
  StablecoinRateTooFewRates: IDL.Null,
  StablecoinRateZeroRate: IDL.Null,
  ForexInvalidTimestamp: IDL.Null,
  ForexBaseAssetNotFound: IDL.Null,
  ForexQuoteAssetNotFound: IDL.Null,
  ForexAssetsNotFound: IDL.Null,
  RateLimited: IDL.Null,
  NotEnoughCycles: IDL.Null,
  FailedToAcceptCycles: IDL.Null,
  InconsistentRatesReceived: IDL.Null,
  Other: IDL.Record({ code: IDL.Nat32, description: IDL.Text }),
});
/// The mock's `Response` — the shape its init argument carries.
const xrcMockResponse = IDL.Variant({
  ExchangeRate: IDL.Record({
    base_asset: IDL.Opt(xrcAsset),
    quote_asset: IDL.Opt(xrcAsset),
    metadata: IDL.Opt(xrcMetadata),
    rate: IDL.Nat64,
  }),
  Error: xrcError,
});
const xrcMockInit = IDL.Record({ response: xrcMockResponse });

export const xrcMockIdlFactory: IDLNamespace.InterfaceFactory = ({ IDL }) => {
  const AssetClass = IDL.Variant({ Cryptocurrency: IDL.Null, FiatCurrency: IDL.Null });
  const Asset = IDL.Record({ symbol: IDL.Text, class: AssetClass });
  return IDL.Service({
    get_exchange_rate: IDL.Func(
      [IDL.Record({ base_asset: Asset, quote_asset: Asset, timestamp: IDL.Opt(IDL.Nat64) })],
      [IDL.Variant({ Ok: IDL.Unknown, Err: IDL.Unknown })],
      [],
    ),
  });
};

/// Encode the mock's init argument. A `rate` response supplies explicit
/// metadata so the quality fields the backend records on an order are
/// deterministic rather than whatever the mock defaults to.
export function encodeXrcMockInit(response:
  | { kind: 'rate'; rate: bigint; decimals?: number; receivedRates?: bigint; queriedSources?: bigint; standardDeviation?: bigint }
  | { kind: 'error'; error: string },
): Uint8Array {
  const value = response.kind === 'rate'
    ? {
        ExchangeRate: {
          base_asset: [],
          quote_asset: [],
          metadata: [{
            decimals: response.decimals ?? 9,
            base_asset_num_received_rates: response.receivedRates ?? 5n,
            base_asset_num_queried_sources: response.queriedSources ?? 6n,
            quote_asset_num_received_rates: response.receivedRates ?? 5n,
            quote_asset_num_queried_sources: response.queriedSources ?? 6n,
            standard_deviation: response.standardDeviation ?? 0n,
            forex_timestamp: [],
          }],
          rate: response.rate,
        },
      }
    : { Error: { [response.error]: null } };
  return new Uint8Array(IDL.encode([xrcMockInit], [{ response: value }]));
}
