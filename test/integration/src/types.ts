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
  | 'created' | 'cancelled' | 'expired' | 'paid'
  | 'delivered' | 'needsReview' | 'abandoned';

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
  /// When it first crossed `alertAfterNs` while waiting to deliver, else null.
  /// The historical half of the dropped `#deliveryDelayed` entry (#37).
  delayedAtNs: Opt<bigint>;
  /// Why an operator ended this order, set only on `#abandoned`. Replaces the
  /// `#abandoned` queue entry, which was the fourth copy of one decision (#37).
  abandonedReason: Opt<string>;
  /// Problems that belong to this order, with resolution state (#37). The worklist
  /// is a filter over these rather than a separate structure.
  problems: Problem[];
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
  | { reserveShort: { requested: bigint; available: bigint } }
  | { amountAboveMax: { usdCents: bigint; maxUsdCents: bigint } }
  | { amountBelowMin: { usdCents: bigint; minUsdCents: bigint } };

/// One counter per `GateReason` (#61), replacing the per-attempt audit line.
/// An order-bound problem (#37). Every arm had an `orderId` in the old
/// the queue that is now `Orphans`; the order it hangs off supplies that now.
export type ProblemKind =
  | { duplicate: { paymentRef: string } }
  | { deliveryStuck: { stage: string } }
  | { refundAfterDelivery: { paymentRef: string; cycles: bigint; refundedCents: bigint; fullRefund: boolean } }
  | { paidNotCredited: { paymentRef: string; sessionId: string } };

export interface Problem {
  kind: ProblemKind;
  detail: string;
  filedAtNs: bigint;
  resolvedAtNs: Opt<bigint>;
}

export interface OrderFilter {
  status: Opt<StatusVariant>;
  owner: Opt<Principal>;
  createdFromNs: Opt<bigint>;
  createdToNs: Opt<bigint>;
  withUnresolvedProblems: boolean;
}

export interface RefusalCounts {
  amountAboveMax: bigint;
  amountBelowMin: bigint;
  canisterCyclesLow: bigint;
  /// Not a `GateReason`: the rail being unprovisioned refuses BEFORE the gate, so
  /// while it is closed no attempt reaches `admit` at all.
  railClosed: bigint;
  reserveShort: bigint;
  /// The session outcall failed. Separate from `railClosed`: a present-but-invalid
  /// key is a different incident from an absent one, with a different lever.
  stripeApiFailed: bigint;
  tooManyOpenOrders: bigint;
}

/// Which rail-state conditions are refusing right now. Latched per condition, so
/// entering one writes exactly one `gate.startedRefusing` line.
/// Heir to the `#deliveryDelayed` worklist entry (#37): a reading, not an
/// obligation, and self-clearing by construction.
export interface DelayedDelivery {
  orderId: string;
  /// When it FIRST crossed the threshold — the permanent record on the order,
  /// where every other field here is a live reading.
  delayedAtNs: Opt<bigint>;
  status: StatusVariant;
  heldSinceNs: bigint;
  waitedNs: bigint;
  retries: bigint;
  pastMaxHold: boolean;
}

export interface RailStateLatch {
  canisterCyclesLow: boolean;
  railClosed: boolean;
  reserveShort: boolean;
  stripeApiFailing: boolean;
}

export interface GateConfig {
  maxOpenOrdersPerPrincipal: bigint;
  minCanisterCycles: bigint;
  maxPurchaseUsdCents: bigint;
  minPurchaseUsdCents: bigint;
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
  amountCycles: bigint;
  memo: Bytes;
  createdAtTimeNs: bigint;
}

export interface JournalEntry {
  /// The ledger's own words from the most recent failed attempt (#37 §1b). The one
  /// thing `#deliveryStuck` carried that exists nowhere else — overwritten rather
  /// than accumulated, since `retries` already says how many there were.
  lastError: Opt<string>;
  orderId: string;
  status: StatusVariant;
  destination: Destination;
  transferIntent: Opt<TransferIntent>;
  blockIndex: Opt<bigint>;
  cyclesDelivered: Opt<bigint>;
  retries: bigint;
  createdAtNs: bigint;
  updatedAtNs: bigint;
}

export type ErrorKind =
  | { unattributed: { claimedRef: string; paymentRef: string } }
  | { unprocessable: { eventId: string; field: string } }


export interface OrphanPage {
  entries: OrphanEntry[];
  nextCursor: Opt<bigint>;
}

export interface OrphanEntry {
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


/// The delivery timeline's two thresholds: alert while the cause is still fixable,
/// terminate once it plainly is not.
export interface DeliveryConfig {
  maxHoldNs: bigint;
  alertAfterNs: bigint;
}

export type DeliveryConfigError =
  | { nonPositiveMaxHold: null }
  | { nonPositiveAlertAfter: null }
  | { alertNotBeforeMaxHold: { alertAfterNs: bigint; maxHoldNs: bigint } };

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
  /// Paginated since #38 — necessary the moment #37 removed the ring.
  audit_log(afterSeq: Opt<bigint>, limit: bigint): Promise<{ events: AuditEvent[]; nextCursor: Opt<bigint> }>;
  card_tiers(): Promise<Tier[]>;
  create_order(amount: Amount, destination: Destination, minCycles: [] | [bigint]): Promise<Result<CreatedOrder, CreateOrderError>>;
  set_stripe_api_key(key: string): Promise<Result<null, { tooShort: { size: bigint; min: bigint } }>>;
  stripe_api_key_status(): Promise<{ isSet: boolean; setAtNs: Opt<bigint>; generation: bigint }>;
  set_stripe_origin(origin: string): Promise<Result<null, { notHttps: null } | { hasQueryOrFragment: null } | { empty: null }>>;
  stripe_origin(): Promise<[] | [string]>;
  quote_previews(amounts: bigint[]): Promise<QuotePreviews>;
  cancel_order(id: string): Promise<Result<Order, string>>;
  expire_order(id: string): Promise<Result<Order, string>>;
  set_expected_livemode(expected: [] | [boolean]): Promise<void>;
  expected_livemode(): Promise<[] | [boolean]>;
  can_purchase(usdCents: bigint): Promise<Result<null, GateReason>>;
  orphans(afterId: Opt<bigint>, limit: bigint): Promise<OrphanPage>;
  orphans_unresolved(afterId: Opt<bigint>, limit: bigint): Promise<OrphanPage>;
  orphan_depth(): Promise<{ unresolved: bigint; retained: bigint }>;
  refusal_counts(): Promise<{ counts: RefusalCounts; refusingNow: RailStateLatch }>;
  /// The worklist, as a filter over orders (#37). `unresolved` is NOT orders.length —
  /// one order can carry several problems.
  /// Read any order by id (admin, #38). Audited on every use, hit or miss.
  admin_order(id: string): Promise<Opt<Order>>;
  /// Filtered, cursor-paginated order list (admin, #38) — and #37's worklist, since
  /// `withUnresolvedProblems` is a filter here rather than its own query.
  ///
  /// ⚠️ Ordered by order ID, which is NOT time order: ids are random. Narrow with
  /// `createdFromNs` for recency.
  admin_orders(
    filter: OrderFilter,
    afterId: Opt<string>,
    limit: bigint,
  ): Promise<{ orders: Order[]; nextCursor: Opt<string> }>;
  /// Two numbers rather than a collection — the shape to poll. `unresolved` is NOT
  /// `orders`: one order can carry several problems.
  problem_depth(): Promise<{ unresolved: bigint; orders: bigint }>;
  /// Close ONE order-bound problem. `paymentRef` selects which, and omitting it is
  /// refused when more than one candidate exists (#37).
  resolve_problem(orderId: string, kindTag: string, paymentRef: Opt<string>): Promise<Result<bigint, string>>;
  /// ⚠️ Paginates the RESPONSE, not the work: the scan is still O(all orders) and #63
  /// owns bounding it. Two different limits; this fixes one.
  delayed_deliveries(afterId: Opt<string>, limit: bigint): Promise<{ entries: DelayedDelivery[]; nextCursor: Opt<string> }>;
  lifecycle_config(): Promise<{ gate: GateConfig }>;
  order_for_payment(paymentRef: string): Promise<Opt<string>>;
  abandon_order(id: string, reason: string): Promise<Result<Order, string>>;
  record_delivered(id: string, blockIndex: bigint): Promise<Result<Order, string>>;
  /// #30 PR-B. ⚠️ `reserveFloor` is a maintained lower BOUND on the ledger balance,
  /// not the balance — it rises only by observation (`refresh_reserve` or the hourly
  /// sweep) and falls when the gateway transfers out. `availableToSell` is what the
  /// gate will actually admit against. The four order counters were `order_stats`.
  reserve_status(): Promise<{
    reserveFloor: bigint;
    promisedTotal: bigint;
    availableToSell: bigint;
    reserveObservedAtNs: Opt<bigint>;
    /// The fee the NEXT delivery will use. Self-corrects from `#BadFee`, so this is
    /// how a test observes that correction happening (#30 PR-B).
    cyclesLedgerFee: bigint;
    tallySaturations: bigint;
    reserveAccount: Account;
    canisterCycles: bigint;
    minCanisterCycles: bigint;
    openOrders: bigint;
    expiredOrders: bigint;
    totalOrders: bigint;
    paidIntentsIndexed: bigint;
  }>;
  cycles_status(): Promise<{ balance: bigint; floor: bigint }>;
  recount_orders(): Promise<Array<[string, bigint]>>;
  /// Deliveries with work outstanding, right now (#30 PR-B). Self-clearing: an entry
  /// leaves the set the moment delivery lands. `retries` is how often it has failed.
  pending_deliveries(): Promise<JournalEntry[]>;
  receipt(id: string): Promise<Opt<{
    order: Order;
    paidUsdCents: Opt<bigint>;
    deliveryBlockIndex: Opt<bigint>;
    cyclesDelivered: Opt<bigint>;
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
  /// Paginated since #38. Goes through the same pager as `admin_orders`, with the
  /// owner filter pinned to the caller.
  list_orders(afterId: Opt<string>, limit: bigint): Promise<{ orders: Order[]; nextCursor: Opt<string> }>;
  delivery_journal(id: string): Promise<Opt<JournalEntry>>;
  process_order(id: string): Promise<Result<Order, { notFound: null } | { inFlight: null }>>;
  recovery_status(): Promise<{
    intervalNs: bigint;
    lastCountReconcile: Opt<{ atNs: bigint; drift: { status: string; was: bigint; is: bigint }[] }>;
    lastCountReconcileAttemptNs: bigint;
    lastSweep: Opt<{ atNs: bigint; pending: bigint }>;
    sweepInFlight: boolean;
  }>;
  /// ⚠️ Required after funding the reserve: the gate decides against a maintained
  /// lower bound that only rises by observation, so an unobserved top-up sells nothing.
  refresh_reserve(): Promise<bigint>;
  resolve_orphan(id: bigint): Promise<Result<OrphanEntry, { notFound: bigint } | { alreadyResolved: bigint }>>;
  set_card_tiers(tiers: Tier[]): Promise<Result<null, unknown>>;
  set_recovery_interval(intervalNs: bigint): Promise<Result<null, unknown>>;
  set_delivery_config(config: DeliveryConfig): Promise<Result<null, DeliveryConfigError>>;
  set_webhook_secret(secret: string): Promise<Result<null, unknown>>;
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
