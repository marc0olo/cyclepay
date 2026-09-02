/// Types for the PocketIC suite.
///
/// ⚠️ **Everything canister-shaped is PROJECTED off the generated service (#66), never
/// restated.** This file used to hand-write 42 mirrors of the Motoko types with nothing
/// checking them, and the drift was not theoretical: `GateReason` carried
/// `burnCapExhausted` and `floatLow` after #36 deleted the treasury path and was missing
/// `reserveShort` entirely, so a reserve-short refusal was undecodable and therefore
/// untestable — found only because #61 needed to test that exact refusal.
///
/// ⚠️ **A mirror fails ASYMMETRICALLY, which is why no test caught it.** Declaring a
/// field the canister lacks breaks the Candid decode and gets found. *Omitting* one
/// decodes fine, and the suite silently covers less than it claims. Projections have no
/// omission failure mode: there is only one definition.
///
/// The rule for adding to this file: if a type describes the **canister**, project it. If
/// it describes the **test rig** — a helper, another canister's interface we do not own —
/// write it, in the marked section below.
import type { _SERVICE } from './generated/declarations/backend.did.js';

/// Unwrap Candid's tuple-`opt` (`[] | [T]`) to `T`.
///
/// ⚠️ The raw declarations use the tuple form, not the actor wrapper's `T | null` — which
/// is why the suite consumes `declarations/` and is generated `--actor-disabled`. The
/// scenarios were already written against tuples, so nothing in them changed shape.
type Unopt<T> = T extends [infer U] ? U : never;

// ── The canister, projected ─────────────────────────────────────────────────
//
// One definition each, taken from the method that carries it. A backend change to any of
// these is a typecheck failure at the projection rather than a silent divergence.

export type BackendService = _SERVICE;

export type Order = Unopt<Awaited<ReturnType<_SERVICE['get_order']>>>;
export type Amount = Parameters<_SERVICE['create_order']>[0];
export type Destination = Parameters<_SERVICE['create_order']>[1];
export type Account = Extract<Destination, { cyclesLedgerAccount: unknown }>['cyclesLedgerAccount'];
export type Pricing = Order['pricing'];
export type ExpiredBy = Unopt<Order['expiredBy']>;
export type Rail = Order['rail'];
export type Problem = Order['problems'][number];
export type ProblemKind = Problem['kind'];

export type CreateOrderResult = Awaited<ReturnType<_SERVICE['create_order']>>;
export type CreatedOrder = Extract<CreateOrderResult, { ok: unknown }>['ok'];
export type CreateOrderError = Extract<CreateOrderResult, { err: unknown }>['err'];

export type JournalEntry = Unopt<Awaited<ReturnType<_SERVICE['delivery_journal']>>>;
export type TransferIntent = Unopt<JournalEntry['transferIntent']>;
export type Receipt = Unopt<Awaited<ReturnType<_SERVICE['receipt']>>>;

export type Tier = Awaited<ReturnType<_SERVICE['card_tiers']>>[number];
export type QuotePreviews = Awaited<ReturnType<_SERVICE['quote_previews']>>;
export type QuotePreview = QuotePreviews['quotes'][number];

export type RefusalCounts = Awaited<ReturnType<_SERVICE['refusal_counts']>>['counts'];
export type RailStateLatch = Awaited<ReturnType<_SERVICE['refusal_counts']>>['refusingNow'];

export type GateConfig = Awaited<ReturnType<_SERVICE['lifecycle_config']>>['gate'];
export type GateReason = Extract<
  Awaited<ReturnType<_SERVICE['can_purchase']>>,
  { err: unknown }
>['err'];

export type OrderFilter = Parameters<_SERVICE['admin_orders']>[0];
export type OrdersPage = Awaited<ReturnType<_SERVICE['admin_orders']>>;

export type DelayedPage = Awaited<ReturnType<_SERVICE['delayed_deliveries']>>;
export type DelayedDelivery = DelayedPage['entries'][number];

export type OrphanPage = Awaited<ReturnType<_SERVICE['orphans_unresolved']>>;
export type OrphanEntry = OrphanPage['entries'][number];
export type ErrorKind = OrphanEntry['kind'];

export type AuditPage = Awaited<ReturnType<_SERVICE['audit_log']>>;
export type AuditEvent = AuditPage['events'][number];

export type PricingStatus = Awaited<ReturnType<_SERVICE['pricing_status']>>;
export type PricingConfig = PricingStatus['config'];
export type PricingRates = Unopt<PricingStatus['rates']>;
export type PricingQuality = PricingRates['quality'];

export type DeliveryConfig = Parameters<_SERVICE['set_delivery_config']>[0];
export type DeliveryConfigError = Extract<
  Awaited<ReturnType<_SERVICE['set_delivery_config']>>,
  { err: unknown }
>['err'];

export type HttpRequest = Parameters<_SERVICE['http_request']>[0];
export type HttpResponse = Awaited<ReturnType<_SERVICE['http_request']>>;

export type DeliveryStats = Awaited<ReturnType<_SERVICE['delivery_stats']>>;

// ── The test rig's own types ────────────────────────────────────────────────
//
// These describe the harness, or an interface we do not own. ⚠️ The ledger and CMC
// services stay hand-written on purpose: their `.did` files are not ours, and the suite
// calls a handful of methods on each. The backend talks to them through its own Motoko
// bindings, so a drift here breaks the suite's own calls and nothing else.

export type Opt<T> = [] | [T];
export type Bytes = Uint8Array | number[];

/// The status keys as the suite writes them, for building `StatusVariant` selectors.
export type OrderStatusKey =
  | 'created' | 'cancelled' | 'expired' | 'paid'
  | 'delivered' | 'needsReview' | 'abandoned';
export type StatusVariant = Partial<Record<OrderStatusKey, null>>;

export type Result<T, E> = { ok: T } | { err: E };

export interface Icrc1Service {
  icrc1_balance_of(account: Account): Promise<bigint>;
  /// The delivery fee, read from the ledger rather than disclosed by `quote_previews`.
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
