/// TypeScript mirrors of the backend's candid interface (and the ledger/CMC
/// subsets the suite drives directly). Candid → TS conventions: `opt T` is
/// `[] | [T]`, variants are single-key objects, `nat`/`int` are bigint.
import type { Principal } from '@icp-sdk/core/principal';

export type Opt<T> = [] | [T];
export type Result<T, E> = { ok: T } | { err: E };
export type Bytes = Uint8Array | number[];

export interface Account {
  owner: Principal;
  subaccount: Opt<Bytes>;
}

/// Single-case since #29: the caller's own cycles-ledger account, default
/// subaccount. `create_order` refuses anything else.
export type Destination = { cyclesLedgerAccount: Account };

export type OrderStatusKey =
  | 'created' | 'cancelled' | 'expired' | 'paid' | 'minting' | 'icpAtCmc'
  | 'delivered' | 'awaitingTreasury' | 'needsReview' | 'abandoned';

/// Why an `#expired` order expired. Both producers arrived with #33, and since
/// it deleted the retention sweep they are the only ones — nothing else in the
/// system can expire an order, so this is never null on an `#expired` order.
export type ExpiredBy = { sessionExpired: null } | { sessionFailed: null };

export type StatusVariant = Partial<Record<OrderStatusKey, null>>;

export interface Pricing {
  usdCents: bigint;
  /// Both rate inputs are stored so a quote is reproducible from first
  /// principles against the XRC and the CMC.
  usdPerIcpMicros: bigint;
  xdrPermyriadPerIcp: bigint;
  rateStandardDeviation: bigint;
  rateReceivedRates: bigint;
  rateQueriedSources: bigint;
  feeBps: bigint;
  feeFixedCents: bigint;
  /// When the rate pair above was READ — earlier than `createdAtNs`, because
  /// quotes come from a cache the timer refreshes (#34).
  ratesFetchedAtNs: bigint;
}

export interface PricingQuality {
  standardDeviation: bigint;
  receivedRates: bigint;
  queriedSources: bigint;
}

export interface PricingRates {
  usdPerIcpMicros: bigint;
  xdrPermyriadPerIcp: bigint;
  fetchedAtNs: bigint;
  quality: PricingQuality;
}

export interface PricingConfig {
  feeBps: bigint;
  feeFixedCents: bigint;
  maxAgeNs: bigint;
  maxRateDeltaBps: bigint;
  minRateSources: bigint;
}

export interface Order {
  paidUsdCents: Opt<bigint>;
  /// Null except on an `#expired` order with a known cause, and null for every
  /// sweep expiry — that mechanism has no tag because #33 deletes it (#34).
  expiredBy: Opt<ExpiredBy>;
  /// Stripe's `expires_at` in nanoseconds. Null until #33 creates the session.
  expiresAtNs: Opt<bigint>;
  stripeSessionId: Opt<string>;
  stripeSessionUrl: Opt<string>;
  id: string;
  owner: { ii: Principal };
  rail: Partial<Record<'card', null>>;
  destination: Destination;
  lockedCycles: bigint;
  pricing: Pricing;
  status: StatusVariant;
  createdAtNs: bigint;
  updatedAtNs: bigint;
}

export interface CreatedOrder {
  /// Carrying `stripeSessionUrl`, which is all a caller needs. `clientReferenceId`
  /// was dropped in #33 — a Payment-Link relic in a public response type — and is
  /// derivable as `<principal>_<orderId>`.
  order: Order;
}

/// Gate.mo admission refusal — each case carries the observed value and the
/// bound that refused it.
export type GateReason =
  | { tooManyOpenOrders: { open: bigint; max: bigint } }
  | { canisterCyclesLow: { balance: bigint; min: bigint } }
  | { burnCapExhausted: { burnedE8s: bigint; capE8s: bigint } }
  | { floatLow: { observedE8s: Opt<bigint>; thresholdE8s: bigint } }
  | { amountAboveMax: { usdCents: bigint; maxUsdCents: bigint } }
  | { amountBelowMin: { usdCents: bigint; minUsdCents: bigint } };

export interface GateConfig {
  maxOpenOrdersPerPrincipal: bigint;
  minCanisterCycles: bigint;
  maxPurchaseUsdCents: bigint;
  minPurchaseUsdCents: bigint;
}

export interface OrderStats {
  openOrders: bigint;
  expiredOrders: bigint;
  totalOrders: bigint;
  paidIntentsIndexed: bigint;
}

export type CreateOrderError =
  | { anonymous: null }
  | { unknownTier: string }
  | { tierBelowFees: string }
  | { rateUnavailable: null }
  | { quoteChanged: { quoted: bigint; minimum: bigint } }
  | { idGeneration: null }
  | { notAdmitted: GateReason }
  | { destinationNotOwned: null }
  | { sessionUnavailable: string }
  | { cancelledDuringCreation: null };

export type Rail = { card: null };

export interface QuotePreview {
  usdCents: bigint;
  feeCents: bigint;
  netCents: [] | [bigint];
  cycles: [] | [bigint];
}

export interface QuotePreviews {
  quotes: QuotePreview[];
  rates: [] | [PricingRates];
}

export interface TransferIntent {
  to: Account;
  amountE8s: bigint;
  memo: Bytes;
  createdAtTimeNs: bigint;
}

export interface JournalEntry {
  orderId: string;
  status: StatusVariant;
  destination: Destination;
  transferIntent: Opt<TransferIntent>;
  blockIndex: Opt<bigint>;
  cyclesMinted: Opt<bigint>;
  retries: bigint;
  createdAtNs: bigint;
  updatedAtNs: bigint;
}

export type ErrorKind =
  | { duplicate: { orderId: string; paymentRef: string } }
  | { unattributed: { claimedRef: string; paymentRef: string } }
  | { undeliverable: { orderId: string; cycles: bigint } }
  | { stuckMint: { orderId: string; stage: string } }
  | { refundAfterDelivery: { orderId: string; paymentRef: string; cycles: bigint; refundedCents: bigint; fullRefund: boolean } }
  | { unprocessable: { eventId: string; field: string } }
  | { deliveryDelayed: { orderId: string; stage: string; sinceNs: bigint } }
  | { abandoned: { orderId: string; reason: string } };

export interface ErrorQueuePage {
  entries: ErrorEntry[];
  nextCursor: Opt<bigint>;
}

export interface ErrorEntry {
  id: bigint;
  rail: Partial<Record<'card', null>>;
  kind: ErrorKind;
  detail: string;
  createdAtNs: bigint;
  resolvedAtNs: Opt<bigint>;
}

export interface AuditEvent {
  seq: bigint;
  atNs: bigint;
  tag: string;
  detail: string;
}

export interface Tier {
  id: string;
  usdCents: bigint;
}

/// What the buyer is paying for: a preset or a typed amount (#33).
export type Amount = { tier: string } | { custom: bigint };


export interface TreasuryConfig {
  alertAfterNs: bigint;
  burnCapE8s: bigint;
  burnWindowNs: bigint;
  lowFloatThresholdE8s: bigint;
  maxHoldNs: bigint;
}

export interface TreasuryStatus {
  config: TreasuryConfig;
  burnedInWindowE8s: bigint;
  lastObservedFloat: Opt<{ e8s: bigint; atNs: bigint }>;
  lowFloat: boolean;
  heldOrders: bigint;
  paidOrders: bigint;
}

export interface HttpRequest {
  method: string;
  url: string;
  headers: [string, string][];
  body: Bytes;
}

export interface HttpResponse {
  status_code: number;
  headers: [string, string][];
  body: Bytes;
  upgrade: Opt<boolean>;
}

export interface BackendService {
  audit_log(): Promise<AuditEvent[]>;
  card_tiers(): Promise<Tier[]>;
  create_order(amount: Amount, destination: Destination, minCycles: [] | [bigint]): Promise<Result<CreatedOrder, CreateOrderError>>;
  set_stripe_api_key(key: string): Promise<Result<null, { tooShort: { size: bigint; min: bigint } }>>;
  stripe_api_key_status(): Promise<{ isSet: boolean; setAtNs: Opt<bigint>; generation: bigint }>;
  set_stripe_origin(origin: string): Promise<Result<null, { notHttps: null } | { hasQueryOrFragment: null } | { empty: null }>>;
  stripe_origin(): Promise<[] | [string]>;
  quote_previews(amounts: bigint[]): Promise<QuotePreviews>;
  cancel_order(id: string): Promise<Result<Order, string>>;
  set_expected_livemode(expected: [] | [boolean]): Promise<void>;
  expected_livemode(): Promise<[] | [boolean]>;
  can_purchase(usdCents: bigint): Promise<Result<null, GateReason>>;
  error_queue(afterId: Opt<bigint>, limit: bigint): Promise<ErrorQueuePage>;
  error_queue_unresolved(afterId: Opt<bigint>, limit: bigint): Promise<ErrorQueuePage>;
  error_queue_depth(): Promise<{ unresolved: bigint; retained: bigint }>;
  lifecycle_config(): Promise<{ gate: GateConfig }>;
  order_for_payment(paymentRef: string): Promise<Opt<string>>;
  abandon_order(id: string, reason: string): Promise<Result<Order, string>>;
  order_stats(): Promise<OrderStats>;
  /// #30 PR-B. ⚠️ Reports `promisedTotal`, NOT the reserve balance — that comes
  /// from the ledger, and `available` is the caller's subtraction.
  reserve_status(): Promise<{
    promisedTotal: bigint;
    tallySaturations: bigint;
    reserveAccount: Account;
    canisterCycles: bigint;
    minCanisterCycles: bigint;
  }>;
  cycles_status(): Promise<{ balance: bigint; floor: bigint }>;
  recount_orders(): Promise<Array<[string, bigint]>>;
  receipt(id: string): Promise<Opt<{
    order: Order;
    paidUsdCents: Opt<bigint>;
    mintBlockIndex: Opt<bigint>;
    cyclesMinted: Opt<bigint>;
    verification: {
      netCents: Opt<bigint>;
      usdPerIcpMicros: bigint;
      xdrPermyriadPerIcp: bigint;
      rateReceivedRates: bigint;
      rateQueriedSources: bigint;
    };
  }>>;
  set_gate_config(config: GateConfig): Promise<Result<null, unknown>>;
  pricing_status(): Promise<{
    rates: Opt<PricingRates>;
    config: PricingConfig;
    lastAttempt: Opt<{ atNs: bigint; ok: boolean; detail: string }>;
    xrcCanisterId: Opt<string>;
  }>;
  refresh_rates(): Promise<Opt<PricingRates>>;
  set_pricing_config(config: PricingConfig): Promise<Result<null, unknown>>;
  get_order(id: string): Promise<Opt<Order>>;
  health(): Promise<boolean>;
  http_request(req: HttpRequest): Promise<HttpResponse>;
  http_request_update(req: HttpRequest): Promise<HttpResponse>;
  list_orders(): Promise<Order[]>;
  mint_journal(id: string): Promise<Opt<JournalEntry>>;
  process_order(id: string): Promise<Result<Order, { notFound: null } | { inFlight: null }>>;
  recovery_status(): Promise<{
    intervalNs: bigint;
    lastCountReconcile: Opt<{ atNs: bigint; drift: { status: string; was: bigint; is: bigint }[] }>;
    lastCountReconcileAttemptNs: bigint;
    lastSweep: Opt<{ atNs: bigint; pending: bigint }>;
    sweepInFlight: boolean;
  }>;
  refresh_float(): Promise<bigint>;
  reset_burn_window(): Promise<bigint>;
  resolve_error(id: bigint): Promise<Result<ErrorEntry, { notFound: bigint } | { alreadyResolved: bigint }>>;
  set_card_tiers(tiers: Tier[]): Promise<Result<null, unknown>>;
  set_recovery_interval(intervalNs: bigint): Promise<Result<null, unknown>>;
  set_treasury_config(config: TreasuryConfig): Promise<Result<null, unknown>>;
  set_webhook_secret(secret: string): Promise<Result<null, unknown>>;
  treasury_status(): Promise<TreasuryStatus>;
  webhook_secret_status(): Promise<{ isSet: boolean; setAtNs: Opt<bigint>; generation: bigint }>;
}

export interface Icrc1Service {
  icrc1_balance_of(account: Account): Promise<bigint>;
  /// #30 PR-A: the delivery fee, read from the ledger rather than disclosed by
  /// `quote_previews`.
  icrc1_fee(): Promise<bigint>;
  icrc1_transfer(arg: {
    from_subaccount: Opt<Bytes>;
    to: Account;
    amount: bigint;
    fee: Opt<bigint>;
    memo: Opt<Bytes>;
    created_at_time: Opt<bigint>;
  }): Promise<{ Ok: bigint } | { Err: unknown }>;
}

export interface CmcService {
  set_icp_xdr_conversion_rate(payload: {
    data_source: string;
    timestamp_seconds: bigint;
    xdr_permyriad_per_icp: bigint;
    reason: Opt<unknown>;
  }): Promise<{ Ok: null } | { Err: string }>;
  get_icp_xdr_conversion_rate(): Promise<{
    data: { timestamp_seconds: bigint; xdr_permyriad_per_icp: bigint };
    hash_tree: Bytes;
    certificate: Bytes;
  }>;
}
