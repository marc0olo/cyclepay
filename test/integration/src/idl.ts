/// Candid IDL factories for the suite.
///
/// `backendIdlFactory` is a hand transcription of the generated
/// `src/backend/dist/backend.did` (the committed interface is the source of
/// truth; a drift here surfaces as a candid decode error in the tests).
/// The ledger/CMC/cycles-ledger factories are minimal subsets of the real
/// NNS interfaces — only the methods the suite itself calls; the backend
/// talks to those canisters with its own Motoko bindings (Cmc.mo).
import { IDL } from '@icp-sdk/core/candid';
import type { IDL as IDLNamespace } from '@icp-sdk/core/candid';
import type { Principal } from '@icp-sdk/core/principal';

export const backendIdlFactory: IDLNamespace.InterfaceFactory = ({ IDL }) => {
  const Account = IDL.Record({
    owner: IDL.Principal,
    subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
  });
  const Destination = IDL.Variant({
    canister: IDL.Principal,
    cyclesLedgerAccount: Account,
  });
  const Owner = IDL.Variant({ ii: IDL.Principal });
  const Rail = IDL.Variant({ card: IDL.Null, ckUsdc: IDL.Null });
  const OrderStatus = IDL.Variant({
    awaitingTreasury: IDL.Null,
    created: IDL.Null,
    delivered: IDL.Null,
    errorQueue: IDL.Null,
    expired: IDL.Null,
    icpAtCmc: IDL.Null,
    minting: IDL.Null,
    paid: IDL.Null,
  });
  const Pricing = IDL.Record({
    feeBps: IDL.Nat,
    feeFixedCents: IDL.Nat,
    usdCents: IDL.Nat,
    xdrPerUsdMicros: IDL.Nat,
  });
  const Order = IDL.Record({
    createdAtNs: IDL.Int,
    destination: Destination,
    id: IDL.Text,
    lockedCycles: IDL.Nat,
    owner: Owner,
    pricing: Pricing,
    rail: Rail,
    status: OrderStatus,
    updatedAtNs: IDL.Int,
  });
  const CreatedOrder = IDL.Record({ clientReferenceId: IDL.Text, order: Order });
  const CreateOrderError = IDL.Variant({
    anonymous: IDL.Null,
    idGeneration: IDL.Null,
    rateUnavailable: IDL.Null,
    tierBelowFees: IDL.Text,
    unknownTier: IDL.Text,
  });
  const TransferIntent = IDL.Record({
    amountE8s: IDL.Nat,
    createdAtTimeNs: IDL.Nat64,
    memo: IDL.Vec(IDL.Nat8),
    to: Account,
  });
  const JournalEntry = IDL.Record({
    blockIndex: IDL.Opt(IDL.Nat),
    createdAtNs: IDL.Int,
    cyclesMinted: IDL.Opt(IDL.Nat),
    destination: Destination,
    orderId: IDL.Text,
    retries: IDL.Nat,
    status: OrderStatus,
    transferIntent: IDL.Opt(TransferIntent),
    updatedAtNs: IDL.Int,
  });
  const Kind = IDL.Variant({
    duplicate: IDL.Record({ orderId: IDL.Text, paymentRef: IDL.Text }),
    stuckMint: IDL.Record({ orderId: IDL.Text, stage: IDL.Text }),
    unattributed: IDL.Record({ claimedRef: IDL.Text, paymentRef: IDL.Text }),
    undeliverable: IDL.Record({ cycles: IDL.Nat, orderId: IDL.Text }),
  });
  const ErrorEntry = IDL.Record({
    createdAtNs: IDL.Int,
    detail: IDL.Text,
    id: IDL.Nat,
    kind: Kind,
    rail: Rail,
    resolvedAtNs: IDL.Opt(IDL.Int),
  });
  const ResolveError = IDL.Variant({ alreadyResolved: IDL.Nat, notFound: IDL.Nat });
  const AuditEvent = IDL.Record({
    atNs: IDL.Int,
    detail: IDL.Text,
    seq: IDL.Nat,
    tag: IDL.Text,
  });
  const Tier = IDL.Record({
    id: IDL.Text,
    paymentLinkUrl: IDL.Text,
    usdCents: IDL.Nat,
  });
  const TiersValidateError = IDL.Variant({
    duplicateTierId: IDL.Text,
    emptyTierId: IDL.Null,
    zeroUsdCents: IDL.Text,
  });
  const ForexRate = IDL.Record({ fetchedAtNs: IDL.Int, xdrPerUsdMicros: IDL.Nat });
  const ForexConfig = IDL.Record({
    feeBps: IDL.Nat,
    feeFixedCents: IDL.Nat,
    maxAgeNs: IDL.Int,
    url: IDL.Text,
  });
  const ForexConfigError = IDL.Variant({
    feeBpsTooHigh: IDL.Null,
    nonPositiveMaxAge: IDL.Null,
    notHttps: IDL.Null,
  });
  const TreasuryConfig = IDL.Record({
    burnCapE8s: IDL.Nat,
    burnWindowNs: IDL.Int,
    lowFloatThresholdE8s: IDL.Nat,
    maxHoldNs: IDL.Int,
  });
  const TreasuryConfigError = IDL.Variant({
    nonPositiveBurnWindow: IDL.Null,
    nonPositiveMaxHold: IDL.Null,
  });
  const FloatObservation = IDL.Record({ atNs: IDL.Int, e8s: IDL.Nat });
  const TreasuryStatus = IDL.Record({
    burnedInWindowE8s: IDL.Nat,
    config: TreasuryConfig,
    heldOrders: IDL.Nat,
    lastObservedFloat: IDL.Opt(FloatObservation),
    lowFloat: IDL.Bool,
  });
  const IntervalError = IDL.Variant({
    intervalTooLong: IDL.Record({ maxNs: IDL.Nat }),
    zeroInterval: IDL.Null,
  });
  const SecretSetError = IDL.Variant({
    tooShort: IDL.Record({ min: IDL.Nat, size: IDL.Nat }),
  });
  const SecretStatus = IDL.Record({
    generation: IDL.Nat,
    isSet: IDL.Bool,
    setAtNs: IDL.Opt(IDL.Int),
  });
  const ProcessOrderError = IDL.Variant({ inFlight: IDL.Null, notFound: IDL.Null });
  const CkUsdcConfig = IDL.Record({
    feeBps: IDL.Nat,
    feeFixedCents: IDL.Nat,
    ledgerFeeUnits: IDL.Nat,
    maxUsdCents: IDL.Nat,
    minUsdCents: IDL.Nat,
  });
  const CkUsdcConfigError = IDL.Variant({
    feeBpsTooHigh: IDL.Null,
    minAboveMax: IDL.Null,
  });
  const CreatedCkUsdcOrder = IDL.Record({
    amountUnits: IDL.Nat,
    approveUnits: IDL.Nat,
    order: Order,
  });
  const CreateCkUsdcOrderError = IDL.Variant({
    aboveMaximum: IDL.Nat,
    amountBelowFees: IDL.Null,
    anonymous: IDL.Null,
    belowMinimum: IDL.Nat,
    idGeneration: IDL.Null,
    railDisabled: IDL.Null,
    rateUnavailable: IDL.Null,
    zeroAmount: IDL.Null,
  });
  const ClaimCkUsdcError = IDL.Variant({
    anonymous: IDL.Null,
    badFee: IDL.Record({ expectedFee: IDL.Nat }),
    inFlight: IDL.Null,
    insufficientAllowance: IDL.Record({ allowance: IDL.Nat, required: IDL.Nat }),
    insufficientFunds: IDL.Record({ balance: IDL.Nat, required: IDL.Nat }),
    ledgerRejected: IDL.Text,
    notClaimable: IDL.Text,
    notFound: IDL.Null,
    retryable: IDL.Text,
    staleIntent: IDL.Null,
    wrongRail: IDL.Null,
  });
  const PullIntent = IDL.Record({
    amountUnits: IDL.Nat,
    createdAtTimeNs: IDL.Nat64,
    feeUnits: IDL.Nat,
    fromOwner: IDL.Principal,
    memo: IDL.Vec(IDL.Nat8),
  });
  const PullEntry = IDL.Record({
    blockIndex: IDL.Opt(IDL.Nat),
    createdAtNs: IDL.Int,
    escalatedAtNs: IDL.Opt(IDL.Int),
    intent: PullIntent,
    orderId: IDL.Text,
    updatedAtNs: IDL.Int,
  });
  const HeaderField = IDL.Tuple(IDL.Text, IDL.Text);
  const HttpRequest = IDL.Record({
    body: IDL.Vec(IDL.Nat8),
    headers: IDL.Vec(HeaderField),
    method: IDL.Text,
    url: IDL.Text,
  });
  const HttpResponse = IDL.Record({
    body: IDL.Vec(IDL.Nat8),
    headers: IDL.Vec(HeaderField),
    status_code: IDL.Nat16,
    upgrade: IDL.Opt(IDL.Bool),
  });
  const HttpHeader = IDL.Record({ name: IDL.Text, value: IDL.Text });
  const HttpRequestResult = IDL.Record({
    body: IDL.Vec(IDL.Nat8),
    headers: IDL.Vec(HttpHeader),
    status: IDL.Nat,
  });

  return IDL.Service({
    audit_log: IDL.Func([], [IDL.Vec(AuditEvent)], ['query']),
    card_tiers: IDL.Func([], [IDL.Vec(Tier)], ['query']),
    ck_usdc_config: IDL.Func([], [CkUsdcConfig], ['query']),
    ck_usdc_pull: IDL.Func([IDL.Text], [IDL.Opt(PullEntry)], ['query']),
    claim_ck_usdc_order: IDL.Func(
      [IDL.Text],
      [IDL.Variant({ ok: Order, err: ClaimCkUsdcError })],
      [],
    ),
    create_ck_usdc_order: IDL.Func(
      [IDL.Nat, Destination],
      [IDL.Variant({ ok: CreatedCkUsdcOrder, err: CreateCkUsdcOrderError })],
      [],
    ),
    create_order: IDL.Func(
      [IDL.Text, Destination],
      [IDL.Variant({ ok: CreatedOrder, err: CreateOrderError })],
      [],
    ),
    error_queue: IDL.Func([], [IDL.Vec(ErrorEntry)], ['query']),
    forex_status: IDL.Func(
      [],
      [IDL.Record({ config: ForexConfig, rate: IDL.Opt(ForexRate) })],
      ['query'],
    ),
    forex_transform: IDL.Func(
      [IDL.Record({ context: IDL.Vec(IDL.Nat8), response: HttpRequestResult })],
      [HttpRequestResult],
      ['query'],
    ),
    get_order: IDL.Func([IDL.Text], [IDL.Opt(Order)], ['query']),
    health: IDL.Func([], [IDL.Bool], ['query']),
    http_request: IDL.Func([HttpRequest], [HttpResponse], ['query']),
    http_request_update: IDL.Func([HttpRequest], [HttpResponse], []),
    list_orders: IDL.Func([], [IDL.Vec(Order)], ['query']),
    mint_journal: IDL.Func([IDL.Text], [IDL.Opt(JournalEntry)], ['query']),
    process_order: IDL.Func(
      [IDL.Text],
      [IDL.Variant({ ok: Order, err: ProcessOrderError })],
      [],
    ),
    recovery_status: IDL.Func(
      [],
      [
        IDL.Record({
          intervalNs: IDL.Nat,
          lastSweep: IDL.Opt(IDL.Record({ atNs: IDL.Int, pending: IDL.Nat })),
          sweepInFlight: IDL.Bool,
        }),
      ],
      ['query'],
    ),
    refresh_float: IDL.Func([], [IDL.Nat], []),
    reset_burn_window: IDL.Func([], [IDL.Nat], []),
    reset_ck_usdc_pull: IDL.Func([IDL.Text], [IDL.Bool], []),
    resolve_error: IDL.Func(
      [IDL.Nat],
      [IDL.Variant({ ok: ErrorEntry, err: ResolveError })],
      [],
    ),
    set_card_tiers: IDL.Func(
      [IDL.Vec(Tier)],
      [IDL.Variant({ ok: IDL.Null, err: TiersValidateError })],
      [],
    ),
    set_ck_usdc_config: IDL.Func(
      [CkUsdcConfig],
      [IDL.Variant({ ok: IDL.Null, err: CkUsdcConfigError })],
      [],
    ),
    set_forex_config: IDL.Func(
      [ForexConfig],
      [IDL.Variant({ ok: IDL.Null, err: ForexConfigError })],
      [],
    ),
    set_recovery_interval: IDL.Func(
      [IDL.Nat],
      [IDL.Variant({ ok: IDL.Null, err: IntervalError })],
      [],
    ),
    set_treasury_config: IDL.Func(
      [TreasuryConfig],
      [IDL.Variant({ ok: IDL.Null, err: TreasuryConfigError })],
      [],
    ),
    set_webhook_secret: IDL.Func(
      [IDL.Text],
      [IDL.Variant({ ok: IDL.Null, err: SecretSetError })],
      [],
    ),
    treasury_status: IDL.Func([], [TreasuryStatus], ['query']),
    webhook_secret_status: IDL.Func([], [SecretStatus], ['query']),
    withdraw_ck_usdc: IDL.Func(
      [Account, IDL.Nat],
      [IDL.Variant({ ok: IDL.Nat, err: IDL.Text })],
      [],
    ),
  });
};

/// ICRC-1 subset shared by the ICP ledger and the cycles ledger — the suite
/// funds the float and asserts balances with these.
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
    icrc1_transfer: IDL.Func(
      [TransferArg],
      [IDL.Variant({ Ok: IDL.Nat, Err: TransferError })],
      [],
    ),
  });
};

/// ICRC-2 superset for the ck-USDC ledger: the suite plays the *user* here —
/// `icrc2_approve` before claiming — and audits balances/allowances. The
/// backend side of the flow (`icrc2_transfer_from`) goes through its own
/// Motoko bindings (rails/CkUsdc.mo).
export const icrc2IdlFactory: IDLNamespace.InterfaceFactory = ({ IDL }) => {
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
  const ApproveArgs = IDL.Record({
    fee: IDL.Opt(IDL.Nat),
    memo: IDL.Opt(IDL.Vec(IDL.Nat8)),
    from_subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
    created_at_time: IDL.Opt(IDL.Nat64),
    amount: IDL.Nat,
    expected_allowance: IDL.Opt(IDL.Nat),
    expires_at: IDL.Opt(IDL.Nat64),
    spender: Account,
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
    icrc1_balance_of: IDL.Func([Account], [IDL.Nat], ['query']),
    icrc1_transfer: IDL.Func(
      [TransferArg],
      [IDL.Variant({ Ok: IDL.Nat, Err: TransferError })],
      [],
    ),
    icrc2_approve: IDL.Func(
      [ApproveArgs],
      [IDL.Variant({ Ok: IDL.Nat, Err: ApproveError })],
      [],
    ),
    icrc2_allowance: IDL.Func(
      [IDL.Record({ account: Account, spender: Account })],
      [IDL.Record({ allowance: IDL.Nat, expires_at: IDL.Opt(IDL.Nat64) })],
      ['query'],
    ),
  });
};

/// Candid-encode the ic-icrc1-ledger init payload for the suite's ck-USDC
/// stand-in — transcribed from the `candid:service` metadata of the pinned
/// wasm (ledger-suite-icrc-2026-03-09). ICRC-2 explicitly enabled; archive
/// trigger set far above what the suite produces so no archive canister
/// spawns mid-test.
export function encodeCkUsdcLedgerInit(args: {
  minter: Principal;
  archiveController: Principal;
  initialBalances: [Principal, bigint][];
  transferFee: bigint;
}): Uint8Array {
  const Account = IDL.Record({
    owner: IDL.Principal,
    subaccount: IDL.Opt(IDL.Vec(IDL.Nat8)),
  });
  const MetadataValue = IDL.Variant({
    Nat: IDL.Nat,
    Int: IDL.Int,
    Text: IDL.Text,
    Blob: IDL.Vec(IDL.Nat8),
  });
  const InitArgs = IDL.Record({
    minting_account: Account,
    fee_collector_account: IDL.Opt(Account),
    transfer_fee: IDL.Nat,
    decimals: IDL.Opt(IDL.Nat8),
    max_memo_length: IDL.Opt(IDL.Nat16),
    token_symbol: IDL.Text,
    token_name: IDL.Text,
    metadata: IDL.Vec(IDL.Tuple(IDL.Text, MetadataValue)),
    initial_balances: IDL.Vec(IDL.Tuple(Account, IDL.Nat)),
    feature_flags: IDL.Opt(IDL.Record({ icrc2: IDL.Bool })),
    archive_options: IDL.Record({
      num_blocks_to_archive: IDL.Nat64,
      max_transactions_per_response: IDL.Opt(IDL.Nat64),
      trigger_threshold: IDL.Nat64,
      max_message_size_bytes: IDL.Opt(IDL.Nat64),
      cycles_for_archive_creation: IDL.Opt(IDL.Nat64),
      node_max_memory_size_bytes: IDL.Opt(IDL.Nat64),
      controller_id: IDL.Principal,
      more_controller_ids: IDL.Opt(IDL.Vec(IDL.Principal)),
    }),
    index_principal: IDL.Opt(IDL.Principal),
  });
  const LedgerArg = IDL.Variant({ Init: InitArgs, Upgrade: IDL.Opt(IDL.Record({})) });
  return new Uint8Array(IDL.encode([LedgerArg], [{
    Init: {
      minting_account: { owner: args.minter, subaccount: [] },
      fee_collector_account: [],
      transfer_fee: args.transferFee,
      decimals: [6],
      max_memo_length: [], // ledger default 32 bytes — exactly the order-id memo bound
      token_symbol: 'ckUSDC',
      token_name: 'ckUSDC (integration suite)',
      metadata: [],
      initial_balances: args.initialBalances.map(
        ([owner, units]) => [{ owner, subaccount: [] }, units],
      ),
      feature_flags: [{ icrc2: true }],
      archive_options: {
        num_blocks_to_archive: 1_000n,
        max_transactions_per_response: [],
        trigger_threshold: 1_000_000n,
        max_message_size_bytes: [],
        cycles_for_archive_creation: [],
        node_max_memory_size_bytes: [],
        controller_id: args.archiveController,
        more_controller_ids: [],
      },
      index_principal: [],
    },
  }]));
}

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
