/// PocketIC harness for the Card go-live bar (spec §9).
///
/// Real-world simulation per the spec: the **real** ICP ledger, CMC, and
/// cycles ledger (PocketIC's `icpFeatures` deploys the actual NNS canisters
/// at their mainnet IDs and keeps the CMC's subnet lists in sync with the
/// instance topology), **crafted HMAC-signed Stripe webhooks**, a **mocked
/// HTTPS outcall** for forex, and PocketIC **time control** for staleness
/// windows and the recovery timer.
import { createHmac } from 'node:crypto';
import { resolve } from 'node:path';
import {
  PocketIc,
  PocketIcServer,
  createIdentity,
  IcpFeaturesConfig,
  SubnetStateType,
  type Actor,
  type DeferredActor,
  type PendingHttpsOutcall,
} from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import { backendIdlFactory, cmcIdlFactory, icrc1IdlFactory } from './idl';
import type {
  BackendService, CmcService, Destination, HttpResponse, Icrc1Service,
  Order, OrderStatusKey, Result, StatusVariant,
} from './types';

// Mainnet principals — identical on PocketIC's NNS subnet (Cmc.mo pins the
// same ledger/CMC/cycles-ledger IDs; the governance ID is only impersonated
// as a *sender*, which PocketIC permits, to drive the CMC's rate-setter).
export const ICP_LEDGER_ID = Principal.fromText('ryjl3-tyaaa-aaaaa-aaaba-cai');
export const CMC_ID = Principal.fromText('rkp4c-7iaaa-aaaaa-aaaca-cai');
export const CYCLES_LEDGER_ID = Principal.fromText('um5iw-rqaaa-aaaaq-qaaba-cai');
export const GOVERNANCE_ID = Principal.fromText('rrkah-fqaaa-aaaaa-aaaaq-cai');

export const BACKEND_WASM = resolve(
  import.meta.dirname,
  '..', '..', '..', 'src', 'backend', 'dist', 'backend.wasm',
);

/// Deterministic suite epoch — must only be later than the CMC feature's
/// built-in default timestamp (2021); everything else is relative to it.
export const BASE_TIME = new Date('2026-06-10T12:00:00.000Z');

/// 3.5 XDR/ICP — one e8s mints exactly 35_000 cycles (Cmc.mo derivation).
export const XDR_PERMYRIAD_PER_ICP = 35_000n;

/// The unit-test forex vector: a raw rate of exactly 0.737 XDR/USD
/// canonicalizes to 737_000 micros (no rounding ambiguity), pricing a 500¢
/// tier at net 455¢ → 3_353_350_000_000 cycles (forex.test.mo vector).
export const FOREX_BODY_OK = JSON.stringify({ result: 'success', rates: { USD: 1, XDR: 0.737 } });
export const TIER_USD_CENTS = 500n;
export const TIER_LOCKED_CYCLES = 3_353_350_000_000n;
/// ceil(3_353_350_000_000 / 35_000) — the e8s the backend derives per order.
export const ORDER_E8S = 95_810_000n;
export const ICP_FEE_E8S = 10_000n;

export const WEBHOOK_SECRET = 'whsec_8fJ3kQ9mN2pX7vR4tL6wY1zB5cD0eH';

export const admin = createIdentity('cyclepay integration admin');
export const user = createIdentity('cyclepay integration user');

export interface Gateway {
  server: PocketIcServer;
  pic: PocketIc;
  backendId: Principal;
  /// A canister id inside the application subnet's range that is never
  /// allocated (the top of the range) — the §4.1 Type-2 trigger: a forward
  /// to it is cleanly rejected and the cycles refund to the app balance.
  neverCanisterId: Principal;
  /// Backend actors per caller role.
  asAdmin: Actor<BackendService>;
  asUser: Actor<BackendService>;
  asAnon: Actor<BackendService>;
  /// create_order as the user, submitted-not-awaited — the suite mocks the
  /// pending forex outcall(s) between submit and await.
  deferredUser: DeferredActor<BackendService>;
  ledger: Actor<Icrc1Service>;
  cyclesLedger: Actor<Icrc1Service>;
  cmcAsGovernance: Actor<CmcService>;
}

export async function setupGateway(): Promise<Gateway> {
  const server = await PocketIcServer.start({
    showRuntimeLogs: false,
    showCanisterLogs: false,
  });
  const pic = await PocketIc.create(server.getUrl(), {
    nns: { state: { type: SubnetStateType.New } },
    application: [{ state: { type: SubnetStateType.New } }],
    icpFeatures: {
      icpToken: IcpFeaturesConfig.DefaultConfig,
      cyclesMinting: IcpFeaturesConfig.DefaultConfig,
      cyclesToken: IcpFeaturesConfig.DefaultConfig,
    },
  });
  await pic.setTime(BASE_TIME);
  await pic.tick();

  const [appSubnet] = await pic.getApplicationSubnets();
  const fixture = await pic.setupCanister<BackendService>({
    idlFactory: backendIdlFactory,
    wasm: BACKEND_WASM,
    sender: admin.getPrincipal(),
    controllers: [admin.getPrincipal()],
    targetSubnetId: appSubnet.id,
  });
  const backendId = fixture.canisterId;
  const ranges = appSubnet.canisterRanges;
  const neverCanisterId = ranges[ranges.length - 1].end;

  const asAdmin = fixture.actor;
  asAdmin.setIdentity(admin);
  const asUser = pic.createActor<BackendService>(backendIdlFactory, backendId);
  asUser.setIdentity(user);
  const asAnon = pic.createActor<BackendService>(backendIdlFactory, backendId);
  const deferredUser = pic.createDeferredActor<BackendService>(backendIdlFactory, backendId);
  deferredUser.setIdentity(user);

  const ledger = pic.createActor<Icrc1Service>(icrc1IdlFactory, ICP_LEDGER_ID);
  const cyclesLedger = pic.createActor<Icrc1Service>(icrc1IdlFactory, CYCLES_LEDGER_ID);
  const cmcAsGovernance = pic.createActor<CmcService>(cmcIdlFactory, CMC_ID);
  cmcAsGovernance.setPrincipal(GOVERNANCE_ID);

  return {
    server, pic, backendId, neverCanisterId,
    asAdmin, asUser, asAnon, deferredUser,
    ledger, cyclesLedger, cmcAsGovernance,
  };
}

export async function teardownGateway(gw: Gateway): Promise<void> {
  await gw.pic.tearDown();
  await gw.server.stop();
}

/// Current PocketIC time in whole seconds (Stripe `t=` granularity).
export async function nowSeconds(pic: PocketIc): Promise<bigint> {
  return BigInt(Math.floor((await pic.getTime()) / 1_000));
}

/// Freshen the CMC's ICP/XDR rate at the current PocketIC time, the way
/// governance does after an exchange-rate proposal. The backend refuses to
/// mint on a rate older than 15 min (Cmc.cmcRateMaxAgeNs), so any test that
/// advances time past that re-arms the rate through this before minting.
export async function setCmcRate(
  gw: Gateway,
  permyriad: bigint = XDR_PERMYRIAD_PER_ICP,
): Promise<void> {
  const result = await gw.cmcAsGovernance.set_icp_xdr_conversion_rate({
    data_source: 'integration-suite',
    timestamp_seconds: await nowSeconds(gw.pic),
    xdr_permyriad_per_icp: permyriad,
    reason: [],
  });
  if ('Err' in result) {
    throw new Error(`set_icp_xdr_conversion_rate failed: ${result.Err}`);
  }
}

/// Fund the backend's ICP float. The `icpToken` feature seeds the anonymous
/// principal's account with 1B ICP; the suite plays operator and tops the
/// gateway up from there.
export async function fundFloat(gw: Gateway, e8s: bigint): Promise<void> {
  const result = await gw.ledger.icrc1_transfer({
    from_subaccount: [],
    to: { owner: gw.backendId, subaccount: [] },
    amount: e8s,
    fee: [],
    memo: [],
    created_at_time: [],
  });
  if (!('Ok' in result)) {
    throw new Error(`float funding transfer failed: ${JSON.stringify(result, bigIntReplacer)}`);
  }
}

export async function floatBalance(gw: Gateway): Promise<bigint> {
  return await gw.ledger.icrc1_balance_of({ owner: gw.backendId, subaccount: [] });
}

// ── Crafted Stripe webhooks (§6.1) ────────────────────────────────────────

export function checkoutSessionBody(args: {
  eventId: string;
  paymentIntent: string;
  clientReferenceId: string | null;
  amountCents: bigint;
  currency?: string;
  paymentStatus?: string;
}): string {
  return JSON.stringify({
    id: args.eventId,
    type: 'checkout.session.completed',
    data: {
      object: {
        payment_intent: args.paymentIntent,
        client_reference_id: args.clientReferenceId,
        amount_total: Number(args.amountCents),
        currency: args.currency ?? 'usd',
        payment_status: args.paymentStatus ?? 'paid',
      },
    },
  });
}

export function chargeRefundedBody(eventId: string, paymentIntent: string): string {
  return JSON.stringify({
    id: eventId,
    type: 'charge.refunded',
    data: { object: { payment_intent: paymentIntent } },
  });
}

/// Sign exactly the way Stripe does: HMAC-SHA256(secret, "<t>.<raw body>"),
/// delivered as `Stripe-Signature: t=<t>,v1=<hex>`.
export function stripeSignature(secret: string, t: bigint, body: string): string {
  const mac = createHmac('sha256', secret)
    .update(`${t}.`)
    .update(body)
    .digest('hex');
  return `t=${t},v1=${mac}`;
}

/// POST the signed body to /webhook/stripe through the canister's HTTP
/// update path (what the gateway re-issues after `upgrade = ?true`).
export async function deliverWebhook(
  gw: Gateway,
  body: string,
  options: { signature?: string } = {},
): Promise<HttpResponse> {
  const signature =
    options.signature ??
    stripeSignature(WEBHOOK_SECRET, await nowSeconds(gw.pic), body);
  return await gw.asAnon.http_request_update({
    method: 'POST',
    url: '/webhook/stripe',
    headers: [['Stripe-Signature', signature]],
    body: new TextEncoder().encode(body),
  });
}

// ── Forex outcall mocking (§3.1) ──────────────────────────────────────────

export type ForexMock =
  | { kind: 'success'; body: string; statusCode?: number }
  | { kind: 'reject' };

/// Tick until the backend's pending HTTPS outcall shows up.
export async function waitForOutcall(
  pic: PocketIc,
  maxTicks = 50,
): Promise<PendingHttpsOutcall> {
  for (let i = 0; i < maxTicks; i++) {
    const outcalls = await pic.getPendingHttpsOutcalls();
    if (outcalls.length > 0) return outcalls[0];
    await pic.tick();
  }
  throw new Error('no pending HTTPS outcall appeared');
}

export async function mockForexOutcall(pic: PocketIc, mock: ForexMock): Promise<void> {
  const outcall = await waitForOutcall(pic);
  await pic.mockPendingHttpsOutcall({
    requestId: outcall.requestId,
    subnetId: outcall.subnetId,
    response:
      mock.kind === 'success'
        ? {
            type: 'success',
            statusCode: mock.statusCode ?? 200,
            headers: [],
            body: new TextEncoder().encode(mock.body),
          }
        : {
            type: 'reject',
            statusCode: 503,
            message: 'integration-suite simulated outage',
          },
    additionalResponses: [],
  });
  await pic.tick(2);
}

/// Submit create_order as the user, service `mocks.length` forex outcalls
/// (a failing refresh retries — the in-call cap is 3 attempts), then await
/// the order result.
export async function createOrderWithForexMocks(
  gw: Gateway,
  tierId: string,
  destination: Destination,
  mocks: ForexMock[],
): Promise<Result<{ order: Order; clientReferenceId: string }, unknown>> {
  const execute = await gw.deferredUser.create_order(tierId, destination);
  for (const mock of mocks) {
    await mockForexOutcall(gw.pic, mock);
  }
  return await execute();
}

// ── Polling helpers ───────────────────────────────────────────────────────

export function statusKey(holder: { status: StatusVariant }): OrderStatusKey {
  return Object.keys(holder.status)[0] as OrderStatusKey;
}

export async function orderStatus(gw: Gateway, orderId: string): Promise<OrderStatusKey> {
  const result = await gw.asUser.get_order(orderId);
  if (result.length === 0) throw new Error(`order ${orderId} not visible to user`);
  return statusKey(result[0]);
}

/// Tick one round at a time until the order reaches one of `want` — the
/// fine-grained stepping the mid-flight interruption tests rely on.
export async function tickUntilStatus(
  gw: Gateway,
  orderId: string,
  want: OrderStatusKey[],
  maxTicks = 200,
): Promise<OrderStatusKey> {
  for (let i = 0; i < maxTicks; i++) {
    const status = await orderStatus(gw, orderId);
    if (want.includes(status)) return status;
    await gw.pic.tick();
  }
  throw new Error(
    `order ${orderId} never reached ${want.join('/')} (last: ${await orderStatus(gw, orderId)})`,
  );
}

export function bigIntReplacer(_key: string, value: unknown): unknown {
  return typeof value === 'bigint' ? value.toString() : value;
}

export function expectOk<T>(result: Result<T, unknown>): T {
  if (!('ok' in result)) {
    throw new Error(`expected #ok, got: ${JSON.stringify(result, bigIntReplacer)}`);
  }
  return result.ok;
}

export function expectErr<T, E>(result: Result<T, E>): E {
  if (!('err' in result)) {
    throw new Error(`expected #err, got: ${JSON.stringify(result, bigIntReplacer)}`);
  }
  return result.err;
}

export function decodeBody(response: { body: Uint8Array | number[] }): string {
  return new TextDecoder().decode(Uint8Array.from(response.body));
}
