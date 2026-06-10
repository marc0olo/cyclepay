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

export type Destination =
  | { canister: Principal }
  | { cyclesLedgerAccount: Account };

export type OrderStatusKey =
  | 'created' | 'expired' | 'paid' | 'minting' | 'icpAtCmc'
  | 'delivered' | 'awaitingTreasury' | 'errorQueue';

export type StatusVariant = Partial<Record<OrderStatusKey, null>>;

export interface Pricing {
  usdCents: bigint;
  xdrPerUsdMicros: bigint;
  feeBps: bigint;
  feeFixedCents: bigint;
}

export interface Order {
  id: string;
  owner: { ii: Principal };
  rail: Partial<Record<'card' | 'ckUsdc', null>>;
  destination: Destination;
  lockedCycles: bigint;
  pricing: Pricing;
  status: StatusVariant;
  createdAtNs: bigint;
  updatedAtNs: bigint;
}

export interface CreatedOrder {
  order: Order;
  clientReferenceId: string;
}

export type CreateOrderError =
  | { anonymous: null }
  | { unknownTier: string }
  | { tierBelowFees: string }
  | { rateUnavailable: null }
  | { idGeneration: null };

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
  | { stuckMint: { orderId: string; stage: string } };

export interface ErrorEntry {
  id: bigint;
  rail: Partial<Record<'card' | 'ckUsdc', null>>;
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
  paymentLinkUrl: string;
}

export interface ForexConfig {
  url: string;
  feeBps: bigint;
  feeFixedCents: bigint;
  maxAgeNs: bigint;
}

export interface TreasuryConfig {
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
  create_order(tierId: string, destination: Destination): Promise<Result<CreatedOrder, CreateOrderError>>;
  error_queue(): Promise<ErrorEntry[]>;
  forex_status(): Promise<{ rate: Opt<{ xdrPerUsdMicros: bigint; fetchedAtNs: bigint }>; config: ForexConfig }>;
  get_order(id: string): Promise<Opt<Order>>;
  health(): Promise<boolean>;
  http_request(req: HttpRequest): Promise<HttpResponse>;
  http_request_update(req: HttpRequest): Promise<HttpResponse>;
  list_orders(): Promise<Order[]>;
  mint_journal(id: string): Promise<Opt<JournalEntry>>;
  process_order(id: string): Promise<Result<Order, { notFound: null } | { inFlight: null }>>;
  recovery_status(): Promise<{ intervalNs: bigint; lastSweep: Opt<{ atNs: bigint; pending: bigint }>; sweepInFlight: boolean }>;
  refresh_float(): Promise<bigint>;
  reset_burn_window(): Promise<bigint>;
  resolve_error(id: bigint): Promise<Result<ErrorEntry, { notFound: bigint } | { alreadyResolved: bigint }>>;
  set_card_tiers(tiers: Tier[]): Promise<Result<null, unknown>>;
  set_forex_config(config: ForexConfig): Promise<Result<null, unknown>>;
  set_recovery_interval(intervalNs: bigint): Promise<Result<null, unknown>>;
  set_treasury_config(config: TreasuryConfig): Promise<Result<null, unknown>>;
  set_webhook_secret(secret: string): Promise<Result<null, unknown>>;
  treasury_status(): Promise<TreasuryStatus>;
  webhook_secret_status(): Promise<{ isSet: boolean; setAtNs: Opt<bigint>; generation: bigint }>;
}

export interface Icrc1Service {
  icrc1_balance_of(account: Account): Promise<bigint>;
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
