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
  const Destination = IDL.Variant({ cyclesLedgerAccount: Account });
  const Owner = IDL.Variant({ ii: IDL.Principal });
  const Rail = IDL.Variant({ card: IDL.Null });
  const OrderStatus = IDL.Variant({
    abandoned: IDL.Null,
    cancelled: IDL.Null,
    created: IDL.Null,
    delivered: IDL.Null,
    expired: IDL.Null,
    needsReview: IDL.Null,
    paid: IDL.Null,
  });
  const ExpiredBy = IDL.Variant({
    sessionExpired: IDL.Null,
    sessionFailed: IDL.Null,
  });
  const Pricing = IDL.Record({
    feeBps: IDL.Nat,
    feeFixedCents: IDL.Nat,
    rateQueriedSources: IDL.Nat,
    rateReceivedRates: IDL.Nat,
    rateStandardDeviation: IDL.Nat,
    ratesFetchedAtNs: IDL.Int,
    usdCents: IDL.Nat,
    usdPerIcpMicros: IDL.Nat,
    xdrPermyriadPerIcp: IDL.Nat,
  });
  const Order = IDL.Record({
    createdAtNs: IDL.Int,
    paidUsdCents: IDL.Opt(IDL.Nat),
    expiredBy: IDL.Opt(ExpiredBy),
    expiresAtNs: IDL.Opt(IDL.Int),
    stripeSessionId: IDL.Opt(IDL.Text),
    stripeSessionUrl: IDL.Opt(IDL.Text),
    destination: Destination,
    id: IDL.Text,
    lockedCycles: IDL.Nat,
    owner: Owner,
    pricing: Pricing,
    rail: Rail,
    status: OrderStatus,
    updatedAtNs: IDL.Int,
  });
  const CreatedOrder = IDL.Record({ order: Order });
  const GateReason = IDL.Variant({
    amountAboveMax: IDL.Record({ maxUsdCents: IDL.Nat, usdCents: IDL.Nat }),
    amountBelowMin: IDL.Record({ minUsdCents: IDL.Nat, usdCents: IDL.Nat }),
    burnCapExhausted: IDL.Record({ burnedE8s: IDL.Nat, capE8s: IDL.Nat }),
    canisterCyclesLow: IDL.Record({ balance: IDL.Nat, min: IDL.Nat }),
    floatLow: IDL.Record({ observedE8s: IDL.Opt(IDL.Nat), thresholdE8s: IDL.Nat }),
    tooManyOpenOrders: IDL.Record({ max: IDL.Nat, open: IDL.Nat }),
  });
  const GateConfig = IDL.Record({
    maxOpenOrdersPerPrincipal: IDL.Nat,
    maxPurchaseUsdCents: IDL.Nat,
    minPurchaseUsdCents: IDL.Nat,
    minCanisterCycles: IDL.Nat,
  });
  const GateConfigError = IDL.Variant({
    zeroOpenOrderCap: IDL.Null,
    zeroPurchaseCeiling: IDL.Null,
    tierAboveCeiling: IDL.Record({
      tierId: IDL.Text,
      usdCents: IDL.Nat,
      maxUsdCents: IDL.Nat,
    }),
    tierBelowFloor: IDL.Record({
      tierId: IDL.Text,
      usdCents: IDL.Nat,
      minUsdCents: IDL.Nat,
    }),
    floorAboveCeiling: IDL.Record({
      minUsdCents: IDL.Nat,
      maxUsdCents: IDL.Nat,
    }),
  });
  const CreateOrderError = IDL.Variant({
    anonymous: IDL.Null,
    cancelledDuringCreation: IDL.Null,
    destinationNotOwned: IDL.Null,
    idGeneration: IDL.Null,
    sessionUnavailable: IDL.Text,
    quoteChanged: IDL.Record({ minimum: IDL.Nat, quoted: IDL.Nat }),

    notAdmitted: GateReason,
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
    refundAfterDelivery: IDL.Record({
      cycles: IDL.Nat,
      orderId: IDL.Text,
      paymentRef: IDL.Text,
      refundedCents: IDL.Nat,
      fullRefund: IDL.Bool,
    }),
    abandoned: IDL.Record({ orderId: IDL.Text, reason: IDL.Text }),
    unprocessable: IDL.Record({ eventId: IDL.Text, field: IDL.Text }),
    deliveryDelayed: IDL.Record({
      orderId: IDL.Text,
      sinceNs: IDL.Int,
      stage: IDL.Text,
    }),
    // #36 folded `stuckMint` and `transferUnresolved` into one honestly-named kind:
    // `stage` carries the money position, `blockIndex` the should-be-unreachable landed case.
    deliveryStuck: IDL.Record({ orderId: IDL.Text, stage: IDL.Text, blockIndex: IDL.Opt(IDL.Nat) }),
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
    usdCents: IDL.Nat,
  });
  const Amount = IDL.Variant({ custom: IDL.Nat, tier: IDL.Text });
  const TiersValidateError = IDL.Variant({
    aboveCeiling: IDL.Record({
      id: IDL.Text,
      maxUsdCents: IDL.Nat,
      usdCents: IDL.Nat,
    }),
    belowFloor: IDL.Record({
      id: IDL.Text,
      minUsdCents: IDL.Nat,
      usdCents: IDL.Nat,
    }),
    duplicateTierId: IDL.Text,
    emptyTierId: IDL.Null,
    zeroUsdCents: IDL.Text,
  });
  const Quality = IDL.Record({
    queriedSources: IDL.Nat,
    receivedRates: IDL.Nat,
    standardDeviation: IDL.Nat,
  });
  const Rates = IDL.Record({
    fetchedAtNs: IDL.Int,
    quality: Quality,
    usdPerIcpMicros: IDL.Nat,
    xdrPermyriadPerIcp: IDL.Nat,
  });
  const PricingConfig = IDL.Record({
    feeBps: IDL.Nat,
    feeFixedCents: IDL.Nat,
    maxAgeNs: IDL.Int,
    maxRateDeltaBps: IDL.Nat,
    minRateSources: IDL.Nat,
  });
  const PricingConfigError = IDL.Variant({
    feeBpsTooHigh: IDL.Null,
    maxAgeTooLong: IDL.Record({ allowedNs: IDL.Int, maxAgeNs: IDL.Int }),
    nonPositiveMaxAge: IDL.Null,
    zeroRateDelta: IDL.Null,
    zeroRateSources: IDL.Null,
  });
  const RateAttempt = IDL.Record({ atNs: IDL.Int, detail: IDL.Text, ok: IDL.Bool });
  const DeliveryConfig = IDL.Record({
    maxHoldNs: IDL.Int,
    alertAfterNs: IDL.Int,
  });
  const DeliveryConfigError = IDL.Variant({
    alertNotBeforeMaxHold: IDL.Record({ alertAfterNs: IDL.Int, maxHoldNs: IDL.Int }),
    nonPositiveAlertAfter: IDL.Null,
    nonPositiveMaxHold: IDL.Null,
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

  return IDL.Service({
    audit_log: IDL.Func([], [IDL.Vec(AuditEvent)], ['query']),
    card_tiers: IDL.Func([], [IDL.Vec(Tier)], ['query']),
    create_order: IDL.Func(
      [Amount, Destination, IDL.Opt(IDL.Nat)],
      [IDL.Variant({ ok: CreatedOrder, err: CreateOrderError })],
      [],
    ),
    set_expected_livemode: IDL.Func([IDL.Opt(IDL.Bool)], [], []),
    expected_livemode: IDL.Func([], [IDL.Opt(IDL.Bool)], ['query']),
    cancel_order: IDL.Func(
      [IDL.Text],
      [IDL.Variant({ ok: Order, err: IDL.Text })],
      [],
    ),
    can_purchase: IDL.Func(
      [IDL.Nat],
      [IDL.Variant({ ok: IDL.Null, err: GateReason })],
      ['query'],
    ),
    quote_previews: IDL.Func(
      [IDL.Vec(IDL.Nat)],
      [
        IDL.Record({
          quotes: IDL.Vec(
            IDL.Record({
              usdCents: IDL.Nat,
              feeCents: IDL.Nat,
              netCents: IDL.Opt(IDL.Nat),
              cycles: IDL.Opt(IDL.Nat),
            }),
          ),
          rates: IDL.Opt(Rates),
        }),
      ],
      ['query'],
    ),
    error_queue: IDL.Func(
      [IDL.Opt(IDL.Nat), IDL.Nat],
      [IDL.Record({ entries: IDL.Vec(ErrorEntry), nextCursor: IDL.Opt(IDL.Nat) })],
      ['query'],
    ),
    error_queue_unresolved: IDL.Func(
      [IDL.Opt(IDL.Nat), IDL.Nat],
      [IDL.Record({ entries: IDL.Vec(ErrorEntry), nextCursor: IDL.Opt(IDL.Nat) })],
      ['query'],
    ),
    error_queue_depth: IDL.Func(
      [],
      [IDL.Record({ retained: IDL.Nat, unresolved: IDL.Nat })],
      ['query'],
    ),
    lifecycle_config: IDL.Func(
      [],
      [IDL.Record({ gate: GateConfig })],
      ['query'],
    ),
    order_for_payment: IDL.Func([IDL.Text], [IDL.Opt(IDL.Text)], ['query']),
    abandon_order: IDL.Func(
      [IDL.Text, IDL.Text],
      [IDL.Variant({ ok: Order, err: IDL.Text })],
      [],
    ),
    // #30 PR-B — the counterpart to abandon_order: the operator read the cycles
    // ledger and the transfer HAD landed, so the block index is the evidence.
    record_delivered: IDL.Func(
      [IDL.Text, IDL.Nat],
      [IDL.Variant({ ok: Order, err: IDL.Text })],
      [],
    ),
    // #30 PR-B folded `order_stats`' four counters in here, as #33 planned when it
    // renamed `retention_status` to that waypoint. One query, one round trip, and the
    // three solvency figures sit next to the order counts that explain them.
    reserve_status: IDL.Func(
      [],
      [IDL.Record({
        availableToSell: IDL.Nat,
        canisterCycles: IDL.Nat,
        cyclesLedgerFee: IDL.Nat,
        expiredOrders: IDL.Nat,
        minCanisterCycles: IDL.Nat,
        openOrders: IDL.Nat,
        paidIntentsIndexed: IDL.Nat,
        promisedTotal: IDL.Nat,
        reserveAccount: Account,
        reserveFloor: IDL.Nat,
        reserveObservedAtNs: IDL.Opt(IDL.Int),
        tallySaturations: IDL.Nat,
        totalOrders: IDL.Nat,
      })],
      ['query'],
    ),
    cycles_status: IDL.Func(
      [],
      [IDL.Record({ balance: IDL.Nat, floor: IDL.Nat })],
      ['query'],
    ),
    recount_orders: IDL.Func([], [IDL.Vec(IDL.Tuple(IDL.Text, IDL.Nat))], []),
    // #30 PR-B — every delivery with money-out work outstanding, right now. Admin,
    // because it scans the whole journal; self-clearing, because an entry leaves the
    // set the moment delivery records its block.
    pending_deliveries: IDL.Func([], [IDL.Vec(JournalEntry)], ['query']),
    receipt: IDL.Func(
      [IDL.Text],
      [IDL.Opt(IDL.Record({
        cyclesMinted: IDL.Opt(IDL.Nat),
        deliveryBlockIndex: IDL.Opt(IDL.Nat),
        order: Order,
        paidUsdCents: IDL.Opt(IDL.Nat),
        verification: IDL.Record({
          netCents: IDL.Opt(IDL.Nat),
          rateQueriedSources: IDL.Nat,
          rateReceivedRates: IDL.Nat,
          usdPerIcpMicros: IDL.Nat,
          xdrPermyriadPerIcp: IDL.Nat,
        }),
      }))],
      ['query'],
    ),
    set_gate_config: IDL.Func(
      [GateConfig],
      [IDL.Variant({ ok: IDL.Null, err: GateConfigError })],
      [],
    ),
    pricing_status: IDL.Func(
      [],
      [IDL.Record({
        config: PricingConfig,
        lastAttempt: IDL.Opt(RateAttempt),
        rates: IDL.Opt(Rates),
        xrcCanisterId: IDL.Opt(IDL.Text),
      })],
      ['query'],
    ),
    refresh_rates: IDL.Func([], [IDL.Opt(Rates)], []),
    set_pricing_config: IDL.Func(
      [PricingConfig],
      [IDL.Variant({ ok: IDL.Null, err: PricingConfigError })],
      [],
    ),
    get_order: IDL.Func([IDL.Text], [IDL.Opt(Order)], ['query']),
    health: IDL.Func([], [IDL.Bool], ['query']),
    http_request: IDL.Func([HttpRequest], [HttpResponse], ['query']),
    http_request_update: IDL.Func([HttpRequest], [HttpResponse], []),
    list_orders: IDL.Func([], [IDL.Vec(Order)], ['query']),
    delivery_journal: IDL.Func([IDL.Text], [IDL.Opt(JournalEntry)], ['query']),
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
          lastCountReconcile: IDL.Opt(
            IDL.Record({
              atNs: IDL.Int,
              drift: IDL.Vec(IDL.Record({ status: IDL.Text, was: IDL.Nat, is: IDL.Nat })),
            }),
          ),
          lastCountReconcileAttemptNs: IDL.Int,
          lastSweep: IDL.Opt(IDL.Record({ atNs: IDL.Int, pending: IDL.Nat })),
          sweepInFlight: IDL.Bool,
        }),
      ],
      ['query'],
    ),
    refresh_reserve: IDL.Func([], [IDL.Nat], []),
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
    set_recovery_interval: IDL.Func(
      [IDL.Nat],
      [IDL.Variant({ ok: IDL.Null, err: IntervalError })],
      [],
    ),
    set_delivery_config: IDL.Func(
      [DeliveryConfig],
      [IDL.Variant({ ok: IDL.Null, err: DeliveryConfigError })],
      [],
    ),
    set_stripe_api_key: IDL.Func([IDL.Text], [IDL.Variant({ ok: IDL.Null, err: SecretSetError })], []),
    stripe_api_key_status: IDL.Func([], [SecretStatus], ['query']),
    set_stripe_origin: IDL.Func(
      [IDL.Text],
      [IDL.Variant({ ok: IDL.Null, err: IDL.Variant({ empty: IDL.Null, hasQueryOrFragment: IDL.Null, notHttps: IDL.Null }) })],
      [],
    ),
    stripe_origin: IDL.Func([], [IDL.Opt(IDL.Text)], ['query']),
    set_webhook_secret: IDL.Func(
      [IDL.Text],
      [IDL.Variant({ ok: IDL.Null, err: SecretSetError })],
      [],
    ),
    webhook_secret_status: IDL.Func([], [SecretStatus], ['query']),
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
