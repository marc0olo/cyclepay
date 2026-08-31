/// PocketIC harness for the Card go-live bar (spec §9).
///
/// Real-world simulation per the spec: the **real** ICP ledger, CMC, and
/// cycles ledger (PocketIC's `icpFeatures` deploys the actual NNS canisters at
/// their mainnet IDs and keeps the CMC's subnet lists in sync with the instance
/// **DFINITY's own xrc_mock** at the mainnet XRC id, **crafted HMAC-signed
/// Stripe webhooks**, and PocketIC **time control** for staleness windows and
/// both timers.
///
/// The backend makes no HTTPS outcall of its own — pricing reads the XRC and the
/// CMC — so there is nothing to intercept. Rates are driven by installing the
/// mock with a chosen response and letting the refresh timer fire.
import { createHmac } from 'node:crypto';
import { resolve } from 'node:path';
import {
  PocketIc,
  PocketIcServer,
  createIdentity,
  IcpFeaturesConfig,
  SubnetStateType,
  type PendingHttpsOutcall,
  type Actor,
  type DeferredActor,
} from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import {
  backendIdlFactory, cmcIdlFactory, encodeXrcMockInit,
  icrc1IdlFactory, xrcMockIdlFactory,
} from './idl';
import type {
  BackendService, CmcService, OrphanEntry,
  Destination, HttpResponse, Icrc1Service, Order, OrderStatusKey, Result, StatusVariant,
  CreatedOrder, CreateOrderError, Amount, Problem,
} from './types';

// Mainnet principals — identical on PocketIC's NNS subnet (Cmc.mo pins the
// same ledger/CMC/cycles-ledger IDs; the governance ID is only impersonated
// as a *sender*, which PocketIC permits, to drive the CMC's rate-setter).
export const ICP_LEDGER_ID = Principal.fromText('ryjl3-tyaaa-aaaaa-aaaba-cai');
export const CMC_ID = Principal.fromText('rkp4c-7iaaa-aaaaa-aaaca-cai');
export const CYCLES_LEDGER_ID = Principal.fromText('um5iw-rqaaa-aaaaq-qaaba-cai');
export const GOVERNANCE_ID = Principal.fromText('rrkah-fqaaa-aaaaa-aaaaq-cai');
/// Which subnet hosts a given canister id, found by searching the instance's
/// declared canister ranges.
///
/// Installing at a fixed mainnet id requires naming the subnet that owns that
/// range, and the assignment is a PocketIC implementation detail — the XRC id
/// lands on the II subnet, which is not where you would guess. Searching the
/// topology means a reshuffle surfaces as a clear error here instead of a
/// confusing `CanisterNotHostedBySubnet` at install time.
async function subnetHosting(pic: PocketIc, canisterId: Principal): Promise<Principal> {
  const target = canisterId.toUint8Array();
  const compare = (a: Uint8Array, b: Uint8Array): number => {
    if (a.length !== b.length) return a.length - b.length;
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return a[i] - b[i];
    }
    return 0;
  };
  for (const subnet of await pic.getTopology()) {
    for (const range of subnet.canisterRanges) {
      if (
        compare(range.start.toUint8Array(), target) <= 0 &&
        compare(target, range.end.toUint8Array()) <= 0
      ) {
        return subnet.id;
      }
    }
  }
  throw new Error(`no subnet in this instance hosts ${canisterId.toText()}`);
}

/// The mainnet Exchange Rate Canister id `Xrc.mo` pins. It lives in the SNS
/// subnet's canister range, which is why the instance below creates one.
export const XRC_ID = Principal.fromText('uf6dk-hyaaa-aaaaq-qaaaq-cai');

export const BACKEND_WASM = resolve(
  import.meta.dirname,
  '..', '..', '..', 'src', 'backend', 'dist', 'backend.wasm',
);
/// DFINITY's own XRC mock, same pinning. Its response is fixed by the init
/// argument, so changing the rate means reinstalling it — see `setXrcRate`.
export const XRC_MOCK_WASM = resolve(
  import.meta.dirname,
  '..', 'wasm', 'xrc_mock.wasm.gz',
);

/// Deterministic suite epoch — must only be later than the CMC feature's
/// built-in default timestamp (2021); everything else is relative to it.
export const BASE_TIME = new Date('2026-06-10T12:00:00.000Z');

/// 3.5 XDR/ICP — one e8s mints exactly 35_000 cycles (Cmc.mo derivation).
export const XDR_PERMYRIAD_PER_ICP = 35_000n;

/// The shared §3 vector, matching pricing.test.mo and chosen so the at-cost
/// property is visible: a 500¢ tier nets 455¢, which at $4.55/ICP buys exactly
/// one ICP, which mints 35_000 · 10⁸ = 3.5 T cycles. Money in, exactly that much
/// ICP out.
///
/// The XRC reports rates with 9 decimals, so $4.55 is 4_550_000_000.
export const XRC_DECIMALS = 9;
export const ICP_USD_RATE = 4_550_000_000n; // $4.55, 9 decimals
export const TIER_USD_CENTS = 500n;
export const TIER_LOCKED_CYCLES = 3_500_000_000_000n;
/// The cycles ledger's fee. Since #30 PR-A it is charged on the **transfer** out
/// of the reserve rather than on a `deposit` into the buyer's account, so a
/// delivery still credits exactly `lockedCycles - CYCLES_LEDGER_FEE` — the same
/// number, charged on a different operation, measured at 100 M either way.
///
/// The name lost `DEPOSIT` because the operation changed; the constant is still
/// a test-side copy of what `icrc1_fee` reports, and the suite asserts they
/// agree rather than trusting this.
export const CYCLES_LEDGER_FEE = 100_000_000n;

export const WEBHOOK_SECRET = 'whsec_8fJ3kQ9mN2pX7vR4tL6wY1zB5cD0eH';

export const admin = createIdentity('cyclepay integration admin');
export const user = createIdentity('cyclepay integration user');
/// A second authenticated buyer, and the ONLY identity that can tell an
/// owner-scoped method from an open one: `admin` is a controller (so it takes every
/// admin branch) and `asAnon` owns nothing (so it is refused by accident rather than
/// by the ownership check). Added for #30 PR-B's owner-scoped `process_order`.
export const stranger = createIdentity('cyclepay integration stranger');

export interface Gateway {
  server: PocketIcServer;
  pic: PocketIc;
  backendId: Principal;
  /// Backend actors per caller role.
  asAdmin: Actor<BackendService>;
  asUser: Actor<BackendService>;
  /// A second authenticated buyer, for owner-scoped methods (see `stranger`).
  asStranger: Actor<BackendService>;
  asAnon: Actor<BackendService>;
  /// create_order as the user, submitted-not-awaited — used by the
  /// interruption tests to catch a money path mid-flight.
  deferredUser: DeferredActor<BackendService>;
  /// Admin identity, deferred — needed by any admin method that makes an outcall, so the
  /// outcall can be answered while the call is still in flight. `expire_order` (#52) is
  /// the first; without it the ingress polls for 100 rounds and reports
  /// `BadIngressMessage` rather than "your outcall was never answered".
  deferredAdmin: DeferredActor<BackendService>;
  ledger: Actor<Icrc1Service>;
  cyclesLedger: Actor<Icrc1Service>;
  cmcAsGovernance: Actor<CmcService>;
  /// Whether the XRC mock has been installed yet — the first call installs, the
  /// rest reinstall with a new response.
  xrcInstalled: boolean;
}

export async function setupGateway(): Promise<Gateway> {
  const server = await PocketIcServer.start({
    showRuntimeLogs: false,
    showCanisterLogs: false,
  });
  const pic = await PocketIc.create(server.getUrl(), {
    nns: { state: { type: SubnetStateType.New } },
    application: [{ state: { type: SubnetStateType.New } }],
    // Mirrors mainnet's topology so canister ids fall in the same ranges.
    fiduciary: { state: { type: SubnetStateType.New } },
    // The XRC id falls in the `aaaaq` canister range, which PocketIC assigns to
    // the II subnet (the same range holds the cycles ledger). `subnetHosting`
    // below finds it by range rather than trusting that assignment.
    ii: { state: { type: SubnetStateType.New } },
    icpFeatures: {
      icpToken: IcpFeaturesConfig.DefaultConfig,
      cyclesMinting: IcpFeaturesConfig.DefaultConfig,
      cyclesToken: IcpFeaturesConfig.DefaultConfig,
      // ⚠️ `ii: IcpFeaturesConfig.DefaultConfig` would give this instance its own
      // Internet Identity, which is what a fully local browser flow needs. It is
      // deliberately NOT enabled: adding it makes the PocketIC server close the
      // connection during instance creation —
      //   TypeError: fetch failed … SocketError: other side closed
      // — so every suite fails at setup. The instance never comes up, so there is
      // no server log to read either.
      //
      // Likely cause, unconfirmed: depending on the PocketIC version, II is split
      // into separate backend and frontend canisters, so `DefaultConfig` here may
      // not match what this server build expects. Whoever picks this up should
      // check the server's own version against the `IcpFeatures` shape rather than
      // assume the flag is a one-liner.
      //
      // Until then the browser flow signs in against mainnet II, which both a
      // local network and PocketIC trust (see src/frontend/src/auth.ts). The
      // `VITE_II_URL` override is already in place for when a local II works.
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

  const asAdmin = fixture.actor;
  asAdmin.setIdentity(admin);
  const asUser = pic.createActor<BackendService>(backendIdlFactory, backendId);
  asUser.setIdentity(user);
  const asStranger = pic.createActor<BackendService>(backendIdlFactory, backendId);
  asStranger.setIdentity(stranger);
  const asAnon = pic.createActor<BackendService>(backendIdlFactory, backendId);
  const deferredUser = pic.createDeferredActor<BackendService>(backendIdlFactory, backendId);
  deferredUser.setIdentity(user);
  const deferredAdmin = pic.createDeferredActor<BackendService>(backendIdlFactory, backendId);
  deferredAdmin.setIdentity(admin);

  const ledger = pic.createActor<Icrc1Service>(icrc1IdlFactory, ICP_LEDGER_ID);
  const cyclesLedger = pic.createActor<Icrc1Service>(icrc1IdlFactory, CYCLES_LEDGER_ID);
  const cmcAsGovernance = pic.createActor<CmcService>(cmcIdlFactory, CMC_ID);
  cmcAsGovernance.setPrincipal(GOVERNANCE_ID);

  return {
    server, pic, backendId,
    asAdmin, asUser, asStranger, asAnon, deferredUser, deferredAdmin,
    ledger, cyclesLedger, cmcAsGovernance,
    xrcInstalled: false,
  };
}

export async function teardownGateway(gw: Gateway): Promise<void> {
  await gw.pic.tearDown();
  await gw.server.stop();
}

/// Upgrade the backend the way an operator actually has to, mid-flight.
///
/// A canister with **outstanding message callbacks cannot be upgraded**: the
/// IC traps with `canister_pre_upgrade attempted with outstanding message
/// callbacks (try stopping the canister before upgrade)`. That is a platform
/// constraint, not a Motoko one (`canister-security` skill pitfall 12), and it
/// applies on mainnet exactly as it does here — so a naive
/// `upgradeCanister` during an in-flight delivery always fails.
///
/// `stopCanister` is what resolves it: stopping rejects the outstanding
/// callbacks, which is precisely the §5.1 ambiguity window we want to test —
/// the ledger call may already have executed, and the reply is lost. The
/// persisted write-intent is the only record, and the replay on restart must
/// recover the block index without double-spending.
///
/// The pause is mandatory for every upgrade, not just this test — RUNBOOK.md
/// §11 documents the operator procedure.
export async function upgradeBackendMidFlight(gw: Gateway): Promise<void> {
  await gw.pic.stopCanister({
    canisterId: gw.backendId,
    sender: admin.getPrincipal(),
  });
  try {
    await gw.pic.upgradeCanister({
      canisterId: gw.backendId,
      wasm: BACKEND_WASM,
      sender: admin.getPrincipal(),
      // REQUIRED for Motoko's enhanced orthogonal persistence. Without it the
      // upgrade is rejected outright: "Missing upgrade option: Enhanced
      // orthogonal persistence requires the `wasm_memory_persistence` upgrade
      // option." `keep` preserves the main Wasm memory where a `persistent
      // actor` keeps all its state — `replace` would discard every order,
      // journal, and dedup set.
      upgradeModeOptions: {
        skip_pre_upgrade: [],
        wasm_memory_persistence: [{ keep: null }],
      },
    });
  } finally {
    // Always restart, even if the upgrade was rejected — a stopped canister
    // would fail every subsequent scenario with an unrelated `CanisterStopped`
    // and bury the real error.
    await gw.pic.startCanister({
      canisterId: gw.backendId,
      sender: admin.getPrincipal(),
    });
  }
}

/// Current PocketIC time in whole seconds (Stripe `t=` granularity).
/// NNS root controls the ledger/CMC that `icpFeatures` deploys, and PocketIC
/// accepts any impersonated sender — the same mechanism `setCmcRate` already uses
/// to impersonate governance. So the real NNS canisters CAN be taken out of
/// service, which is what makes the money-out failure paths reachable end to end.
export const NNS_ROOT = Principal.fromText('r7inp-6aaaa-aaaaa-aaabq-cai');

/// Internet Identity, deployed locally by the `ii` ICP feature at its mainnet id.
export const II_ID = Principal.fromText('rdmx6-jaaaa-aaaaa-aaadq-cai');

/// Take an NNS canister out of service. Calls into it are then rejected, which is
/// how a real ledger or CMC outage looks to the backend.
export async function stopNns(gw: Gateway, canisterId: Principal): Promise<void> {
  await gw.pic.stopCanister({ canisterId, sender: NNS_ROOT });
}

export async function startNns(gw: Gateway, canisterId: Principal): Promise<void> {
  await gw.pic.startCanister({ canisterId, sender: NNS_ROOT });
}

export async function nowSeconds(pic: PocketIc): Promise<bigint> {
  return BigInt(Math.floor((await pic.getTime()) / 1_000));
}

/// Freshen the CMC's ICP/XDR rate at the current PocketIC time, the way
/// governance does after an exchange-rate proposal. The backend refuses to
/// quote on a rate older than 15 min (Cmc.cmcRateMaxAgeNs), so any test that
/// advances time past that re-arms the rate through this before ordering.
/// ⚠️ Delivery reads no rate — only order CREATION does, so a stale rate fails a
/// `create_order`, never a delivery already in flight.
export async function setCmcRate(
  gw: Gateway,
  permyriad: bigint = XDR_PERMYRIAD_PER_ICP,
): Promise<void> {
  // The CMC rejects a proposal whose timestamp is not STRICTLY greater than
  // the current one ("Proposed conversion rate must have greater timestamp").
  // Two calls inside the same PocketIC second would collide, so nudge time
  // forward first — 1 s is far below every staleness window in play (the CMC's
  // is 15 min, forex's is set to 30 days by scenario 04).
  await gw.pic.advanceTime(1_000);
  await gw.pic.tick();
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

/// Put cycles in the gateway's own cycles-ledger account — the reserve it delivers
/// from.
///
/// ⚠️ **Measured, because it looks impossible.** Cycles normally enter a ledger
/// account only through `deposit` with cycles attached, which an ingress message
/// cannot do — so there appeared to be no way to fund a reserve in PocketIC
/// without a purpose-built helper canister. A probe found that PocketIC's cycles
/// ledger starts the **anonymous principal** with 2^127-1 cycles, and a transfer
/// from the default sender to any account simply succeeds. That is a PocketIC
/// fixture, not ledger behaviour: on mainnet the reserve is funded by
/// `icp cycles transfer` from outside, and nothing creates cycles into it.
///
/// Fund the gateway's reserve, and by default make it SELLABLE.
///
/// ⚠️ **The transfer alone is not enough, and this is the trap #30 PR-B introduced
/// on purpose.** Solvency is decided against `reserveFloor`, a maintained lower bound
/// that starts at zero and only rises when the canister looks at the ledger. Funding
/// without observing produces a gateway that refuses every order with
/// `#reserveShort{available = 0}` against a fully funded account — which shows up
/// here as *every* order-creating scenario failing at once, not as anything about the
/// reserve.
///
/// Pass `observe: false` to reproduce that state deliberately.
export async function fundReserve(
  gw: Gateway,
  cycles: bigint,
  observe = true,
): Promise<void> {
  const result = await gw.cyclesLedger.icrc1_transfer({
    from_subaccount: [],
    to: { owner: gw.backendId, subaccount: [] },
    amount: cycles,
    fee: [],
    memo: [],
    created_at_time: [],
  });
  if (!('Ok' in result)) {
    throw new Error(`reserve funding transfer failed: ${JSON.stringify(result, bigIntReplacer)}`);
  }
  if (observe) await gw.asAdmin.refresh_reserve();
}

export async function reserveBalance(gw: Gateway): Promise<bigint> {
  return await gw.cyclesLedger.icrc1_balance_of({ owner: gw.backendId, subaccount: [] });
}


// ── XRC mock (§3 pricing) ─────────────────────────────────────────────────

/// What the XRC mock should answer. Its response is baked into the init
/// argument, so switching between these means reinstalling the canister —
/// which is clean, since the mock holds no state the suite cares about.
export type XrcResponse =
  | { kind: 'rate'; rate: bigint; decimals?: number; receivedRates?: bigint; queriedSources?: bigint; standardDeviation?: bigint }
  | { kind: 'error'; error: string };

/// Install or reinstall DFINITY's xrc_mock at the mainnet XRC id.
///
/// Using the official mock rather than a hand-rolled stub means the Candid
/// contract exercised here is the real one — including the error variants, so
/// the backend's XRC failure handling is tested against the actual shapes
/// rather than against something written to match the code.
export async function setXrcResponse(gw: Gateway, response: XrcResponse): Promise<void> {
  const arg = encodeXrcMockInit(response);
  if (gw.xrcInstalled) {
    await gw.pic.reinstallCode({
      canisterId: XRC_ID,
      wasm: XRC_MOCK_WASM,
      arg,
      sender: admin.getPrincipal(),
    });
    return;
  }
  await gw.pic.setupCanister({
    idlFactory: xrcMockIdlFactory,
    wasm: XRC_MOCK_WASM,
    arg,
    sender: admin.getPrincipal(),
    controllers: [admin.getPrincipal()],
    targetCanisterId: XRC_ID,
    targetSubnetId: await subnetHosting(gw.pic, XRC_ID),
  });
  gw.xrcInstalled = true;
}

/// The suite's standard ICP price ($4.55, XRC 9-decimal format).
export async function setXrcRate(gw: Gateway, rate: bigint = ICP_USD_RATE): Promise<void> {
  await setXrcResponse(gw, { kind: 'rate', rate });
}

/// Force a rate refresh through the admin lever and assert it landed.
///
/// Needed after any time jump: the staleness window is capped at 1 h by
/// validation (it is a security bound, not a knob), so a scenario that advances
/// time past it leaves the cache stale and every order would answer
/// `rateUnavailable`. Using the admin lever rather than waiting for the timer
/// keeps scenarios deterministic — and it is the documented ops path for exactly
/// this situation.
export async function ensureRates(
  gw: Gateway,
  permyriad: bigint = XDR_PERMYRIAD_PER_ICP,
): Promise<void> {
  // Re-arm the CMC rate first: it carries its own 15-min guard, and a stale CMC
  // rate makes the refresh bail before caching anything.
  await setCmcRate(gw, permyriad);
  await gw.asAdmin.refresh_rates();
  // `refresh_rates` returns whatever is cached, which is the PREVIOUS pair when
  // the refresh failed — so assert on the attempt, not on the return value.
  const status = await gw.asAnon.pricing_status();
  const attempt = status.lastAttempt[0];
  if (attempt === undefined || !attempt.ok || status.rates.length !== 1) {
    throw new Error(`rate refresh failed: ${JSON.stringify(attempt, bigIntReplacer)}`);
  }
}

/// Advance past one rate-timer interval and tick, so the *timer* (not the admin
/// lever) does the work — for tests that assert the timer itself is alive.
export async function tickRateTimer(gw: Gateway): Promise<void> {
  const { config } = await gw.asAnon.pricing_status();
  // The cadence is maxAgeNs/2 with a 30 s floor; overshoot it.
  const intervalMs = Number(config.maxAgeNs / 2_000_000n);
  await gw.pic.advanceTime(Math.max(intervalMs, 30_000) + 5_000);
  await gw.pic.tick(5);
}

/// Drive the backend's rate-refresh timer and wait until it has cached a pair.
///
/// The refresh is timer-driven precisely so no user call can trigger it, which
/// means tests must advance time rather than relying on a side effect of
/// `create_order`. The cadence is `maxAgeNs / 2` (min 30 s), so one nudge past
/// that is enough.
export async function warmRates(gw: Gateway, maxAttempts = 20): Promise<void> {
  for (let i = 0; i < maxAttempts; i++) {
    const status = await gw.asAnon.pricing_status();
    if (status.rates.length === 1) return;
    await tickRateTimer(gw);
  }
  const status = await gw.asAnon.pricing_status();
  throw new Error(
    `rates never cached; last attempt: ${JSON.stringify(status.lastAttempt, bigIntReplacer)}`,
  );
}

// ── Crafted Stripe webhooks (§6.1) ────────────────────────────────────────

export function checkoutSessionBody(args: {
  eventId: string;
  paymentIntent: string;
  clientReferenceId: string | null;
  amountCents: bigint;
  currency?: string;
  paymentStatus?: string;
  /// Defaults to `checkout.session.completed`; pass
  /// `checkout.session.async_payment_succeeded` to model a delayed method
  /// settling, which carries the identical session object.
  eventType?: string;
  /// Defaults to live. Only the livemode-gate scenario varies it.
  livemode?: boolean;
}): string {
  return JSON.stringify({
    id: args.eventId,
    type: args.eventType ?? 'checkout.session.completed',
    livemode: args.livemode ?? true,
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

/// A **full** refund of the standard tier charge — cumulative refunded equals
/// the charge total, which is what settles an obligation.
export function chargeRefundedBody(eventId: string, paymentIntent: string): string {
  return partialRefundBody(eventId, paymentIntent, TIER_USD_CENTS, TIER_USD_CENTS);
}

/// `charge.refunded` carries a **charge**: `amount` is its total and
/// `amount_refunded` is the cumulative amount returned. Stripe fires the same
/// event type for a partial refund, so the two are only distinguishable by
/// comparing them.
export function partialRefundBody(
  eventId: string,
  paymentIntent: string,
  refundedCents: bigint,
  chargeTotalCents: bigint,
): string {
  return JSON.stringify({
    id: eventId,
    type: 'charge.refunded',
    livemode: true,
    data: {
      object: {
        payment_intent: paymentIntent,
        amount: Number(chargeTotalCents),
        amount_refunded: Number(refundedCents),
      },
    },
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

/// The canister query is paged (unresolved obligations are never evicted, so the
/// queue can outgrow a 2 MB Candid response). Scenarios assert over the full set,
/// so the paging lives here rather than in every test.
export async function allOrphans(gw: Gateway): Promise<OrphanEntry[]> {
  const all: OrphanEntry[] = [];
  let cursor: [] | [bigint] = [];
  for (;;) {
    const page = await gw.asAdmin.orphans(cursor, 200n);
    all.push(...page.entries);
    if (page.nextCursor.length === 0) return all;
    cursor = page.nextCursor;
  }
}

/// The operator worklist — open obligations only, paged server-side.
export async function openOrphans(gw: Gateway): Promise<OrphanEntry[]> {
  const open: OrphanEntry[] = [];
  let cursor: [] | [bigint] = [];
  for (;;) {
    const page = await gw.asAdmin.orphans_unresolved(cursor, 200n);
    open.push(...page.entries);
    if (page.nextCursor.length === 0) return open;
    cursor = page.nextCursor;
  }
}

// ── Polling helpers ───────────────────────────────────────────────────────

export function statusKey(holder: { status: StatusVariant }): OrderStatusKey {
  return Object.keys(holder.status)[0] as OrderStatusKey;
}

/// The order's own problems (#37), as the owner sees them.
///
/// ⚠️ **Owner-scoped, like `orderStatus`.** Reading another principal's order needs
/// #38's admin view, which does not exist yet — so scenarios asserting a problem must
/// either own the order or read it off the mutating call's return value.
export async function orderProblems(gw: Gateway, orderId: string): Promise<Problem[]> {
  const result = await gw.asUser.get_order(orderId);
  if (result.length === 0) throw new Error(`order ${orderId} not visible to user`);
  return result[0]!.problems;
}

export function unresolvedProblems(problems: Problem[]): Problem[] {
  return problems.filter((p) => p.resolvedAtNs.length === 0);
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



// ── HTTPS outcalls (#33) ──────────────────────────────────────────────────────
//
// PocketIC does not perform real outcalls: it parks each one and lets the test
// answer it. That is *better* coverage than a live call for the request shape,
// because the exact bytes the canister sends can be asserted — and nothing
// pinned them before #33.
//
// ⚠️ It is a MOCK, so two things it cannot tell you: the real cycle cost, and
// whether the size cap is big enough for a real Stripe response. Both are first
// observable in a manual run.

/// Is this parked outcall the recovery sweep's session retrieve (#52), rather than
/// something a scenario asked for?
///
/// The retrieve is the only **GET** the canister makes: creating a session is a POST to
/// the collection, expiring one is a POST to `/{id}/expire`.
export function isSweepRetrieve(outcall: PendingHttpsOutcall): boolean {
  return String(outcall.httpMethod).toUpperCase() === 'GET'
    && outcall.url.includes('/v1/checkout/sessions/');
}

/// Answer a sweep retrieve with "the session is still open", which is a **no-op** for the
/// sweep: it means Stripe says the deadline has not really passed, so nothing is released
/// and nothing is filed.
export async function answerSweepRetrieveOpen(gw: Gateway, outcall: PendingHttpsOutcall): Promise<void> {
  await answerOutcall(gw, outcall, 200, JSON.stringify({ id: 'cs_sweep', object: 'checkout.session', status: 'open' }));
}

/// Wait for the canister to park an outcall a SCENARIO asked for, ticking to let it get
/// there, and answering any sweep retrieve it meets on the way.
///
/// Returns the pending request so a test can assert on the URL, headers and body the
/// canister actually built.
///
/// ⚠️ **This used to return `pending[0]`, and #52 made that wrong.** The implicit
/// contract was "there is only one outcall in flight" — true while `create_order` and
/// `cancel_order` were the only producers. The recovery sweep is now a second, *background*
/// producer: any scenario that advances the clock past a lingering `#created` order's
/// deadline plus the grace makes it retrieve that order's session. Taking the first parked
/// call then hands a scenario the sweep's GET and it asserts against the wrong request.
///
/// ⚠️ **Strays are answered here rather than left for `afterEach`.** A parked outcall is
/// an in-flight message; leaving it parked mid-scenario lets later ticks stack on it, and
/// the resulting failure looks like the order-coupling class this README warns about
/// instead of what it is. `afterEach` stays as the backstop, and a stray count above one
/// there is a signal, not noise.
export async function awaitPendingOutcall(gw: Gateway, rounds = 40): Promise<PendingHttpsOutcall> {
  for (let i = 0; i < rounds; i += 1) {
    const pending = await gw.pic.getPendingHttpsOutcalls();
    for (const outcall of pending) {
      if (!isSweepRetrieve(outcall)) return outcall;
      await answerSweepRetrieveOpen(gw, outcall);
    }
    await gw.pic.tick();
  }
  throw new Error('no HTTPS outcall was made (sweep retrieves are answered and skipped)');
}

/// Answer every parked sweep retrieve, and report how many there were.
///
/// The `afterEach` backstop: it keeps a scenario's strays out of the next scenario, and
/// its count is the signal for "this scenario provoked more background retrieves than
/// anyone expected".
export async function drainSweepRetrieves(gw: Gateway): Promise<number> {
  const pending = await gw.pic.getPendingHttpsOutcalls();
  let drained = 0;
  for (const outcall of pending) {
    if (isSweepRetrieve(outcall)) {
      await answerSweepRetrieveOpen(gw, outcall);
      drained += 1;
    }
  }
  return drained;
}

/// Like `awaitPendingOutcall`, but tolerates there being none.
///
/// Needed because some calls complete WITHOUT an outcall and a test cannot always
/// know in advance which: `cancel_order` on an already-cancelled order returns
/// early (it is idempotent), and on an order that never got a session there is
/// nothing to expire. Waiting for an outcall there hangs until the ingress
/// deadline and reports as a confusing timeout rather than as what happened.
export async function maybePendingOutcall(
  gw: Gateway,
  rounds = 15,
): Promise<PendingHttpsOutcall | undefined> {
  for (let i = 0; i < rounds; i += 1) {
    const pending = await gw.pic.getPendingHttpsOutcalls();
    for (const outcall of pending) {
      // Same filter as `awaitPendingOutcall`: a sweep retrieve is not the thing the
      // caller is unsure about, and returning it would be worse than returning nothing.
      if (!isSweepRetrieve(outcall)) return outcall;
      await answerSweepRetrieveOpen(gw, outcall);
    }
    await gw.pic.tick();
  }
  return undefined;
}

/// Wait for the sweep's session retrieve specifically (#52) — the mirror of
/// `awaitPendingOutcall`, which skips exactly this one.
export async function awaitSweepRetrieve(gw: Gateway, rounds = 40): Promise<PendingHttpsOutcall> {
  for (let i = 0; i < rounds; i += 1) {
    const pending = await gw.pic.getPendingHttpsOutcalls();
    for (const outcall of pending) {
      if (isSweepRetrieve(outcall)) return outcall;
    }
    await gw.pic.tick();
  }
  throw new Error('the recovery sweep did not retrieve a session');
}

/// Like `awaitSweepRetrieve`, but tolerates there being none — for asserting that the
/// grace suppressed the ask entirely.
export async function maybeSweepRetrieve(
  gw: Gateway,
  rounds = 12,
): Promise<PendingHttpsOutcall | undefined> {
  for (let i = 0; i < rounds; i += 1) {
    const pending = await gw.pic.getPendingHttpsOutcalls();
    for (const outcall of pending) {
      if (isSweepRetrieve(outcall)) return outcall;
    }
    await gw.pic.tick();
  }
  return undefined;
}

/// Answer the sweep's retrieve **for one specific session**, answering every other
/// order's retrieve with a no-op "open" along the way.
///
/// ⚠️ **Necessary because the scan is not about one order.** This suite accumulates
/// lingering `#created` orders, so once the clock is past their deadlines the scan has
/// several due at once and works through them sequentially — up to
/// `Recovery.maxRetrievesPerPass`. A scenario that answered the first parked retrieve
/// would be answering for whichever order the scan reached first, which is usually a
/// neighbour's. That is the order-coupling this README warns about, in outcall form.
export async function settleSweepRetrieveFor(
  gw: Gateway,
  sessionId: string,
  status: number,
  body: string,
  rounds = 60,
): Promise<void> {
  for (let i = 0; i < rounds; i += 1) {
    const pending = await gw.pic.getPendingHttpsOutcalls();
    for (const outcall of pending) {
      if (!isSweepRetrieve(outcall)) continue;
      if (outcall.url.includes(sessionId)) {
        await answerOutcall(gw, outcall, status, body);
        await gw.pic.tick(5);
        return;
      }
      await answerSweepRetrieveOpen(gw, outcall);
    }
    await gw.pic.tick();
  }
  throw new Error(`the sweep never retrieved session ${sessionId}`);
}

/// Park (without answering) the sweep's retrieve for one specific session, draining
/// neighbours' retrieves so the scan reaches it.
export async function awaitSweepRetrieveFor(
  gw: Gateway,
  sessionId: string,
  rounds = 60,
): Promise<PendingHttpsOutcall> {
  for (let i = 0; i < rounds; i += 1) {
    const pending = await gw.pic.getPendingHttpsOutcalls();
    for (const outcall of pending) {
      if (!isSweepRetrieve(outcall)) continue;
      if (outcall.url.includes(sessionId)) return outcall;
      await answerSweepRetrieveOpen(gw, outcall);
    }
    await gw.pic.tick();
  }
  throw new Error(`the sweep never retrieved session ${sessionId}`);
}

/// Wait for an outcall that is NOT a sweep retrieve, **leaving any retrieve parked**.
///
/// The difference from `awaitPendingOutcall` matters exactly once: when a scenario is
/// deliberately holding a retrieve in flight and needs another outcall answered
/// underneath it. Draining there would invalidate the handle it is holding, and pic-js
/// reports that as `InvalidCanisterHttpRequestId` — which reads like a pic-js fault
/// rather than "something answered your outcall for you".
export async function awaitNonRetrieveOutcall(gw: Gateway, rounds = 40): Promise<PendingHttpsOutcall> {
  for (let i = 0; i < rounds; i += 1) {
    for (const outcall of await gw.pic.getPendingHttpsOutcalls()) {
      if (!isSweepRetrieve(outcall)) return outcall;
    }
    await gw.pic.tick();
  }
  throw new Error('no non-retrieve outcall was made');
}

/// Is the sweep asking about THIS session? Drains other orders' retrieves while looking,
/// and answers `undefined` if this one is never asked about.
///
/// ⚠️ **The targeted form is the only honest one for a negative assertion.** "No retrieve
/// happened at all" is not a property any scenario can claim once its own file has
/// accumulated `#created` orders — a neighbour past its deadline makes the untargeted
/// check fail for a reason the scenario is not about.
export async function maybeSweepRetrieveFor(
  gw: Gateway,
  sessionId: string,
  rounds = 20,
): Promise<PendingHttpsOutcall | undefined> {
  for (let i = 0; i < rounds; i += 1) {
    for (const outcall of await gw.pic.getPendingHttpsOutcalls()) {
      if (!isSweepRetrieve(outcall)) continue;
      if (outcall.url.includes(sessionId)) return outcall;
      await answerSweepRetrieveOpen(gw, outcall);
    }
    await gw.pic.tick();
  }
  return undefined;
}

/// Answer a parked outcall with the SAME response from every replica.
export async function answerOutcall(
  gw: Gateway,
  outcall: PendingHttpsOutcall,
  status: number,
  body: string,
): Promise<void> {
  await gw.pic.mockPendingHttpsOutcall({
    subnetId: outcall.subnetId,
    requestId: outcall.requestId,
    response: { type: 'success', body: new TextEncoder().encode(body), statusCode: status, headers: [] },
  });
}

/// ⚠️ **`additionalResponses` does NOT let this suite test the transform, and
/// that is MEASURED, not assumed.**
///
/// pic-js can answer an outcall with one response per replica, which looks like a
/// way to reproduce what real Stripe does — a unique `request-id` per request —
/// and so to check that the transform strips it. A scenario was written on that
/// basis and then **mutation-tested**: with `Session.strip` changed to pass every
/// header through, the whole suite still passed. So the mock does not enforce
/// consensus the way a real subnet does, and such a scenario asserts nothing.
///
/// #33's claim stands: the transform is first observable in a manual run against
/// real Stripe, where the failure is `No consensus could be reached` and the
/// symptom is the entire rail down. `Session.classifyFailure` names that case so
/// the audit log points at the transform when it happens.
///
/// A minimal but realistic session-create response body.
export function sessionCreatedBody(opts: {
  id?: string;
  url?: string;
  expiresAtSeconds: number;
  livemode?: boolean;
}): string {
  return JSON.stringify({
    id: opts.id ?? 'cs_test_a1b2',
    object: 'checkout.session',
    url: opts.url ?? `https://checkout.stripe.com/c/pay/${opts.id ?? 'cs_test_a1b2'}`,
    expires_at: opts.expiresAtSeconds,
    livemode: opts.livemode ?? false,
    status: 'open',
  });
}

/// `checkout.session.expired`, the only thing that expires an order (#33).
export function sessionExpiredBody(opts: {
  eventId: string;
  sessionId: string;
  clientReferenceId?: string;
}): string {
  return JSON.stringify({
    id: opts.eventId,
    type: 'checkout.session.expired',
    livemode: false,
    data: {
      object: {
        id: opts.sessionId,
        object: 'checkout.session',
        status: 'expired',
        client_reference_id: opts.clientReferenceId ?? null,
      },
    },
  });
}

/// Read a header from a pending outcall, case-insensitively.
export function outcallHeader(outcall: PendingHttpsOutcall, name: string): string | undefined {
  const lower = name.toLowerCase();
  for (const [k, v] of outcall.headers) {
    if (k.toLowerCase() === lower) return v;
  }
  return undefined;
}

export function outcallBody(outcall: PendingHttpsOutcall): string {
  return new TextDecoder().decode(outcall.body);
}

/// `create_order`, answering the Checkout Session outcall it now blocks on (#33).
///
/// ⚠️ **Every successful `create_order` needs this.** The method awaits an HTTPS
/// outcall before it returns, so a plain `await gw.asUser.create_order(...)`
/// never resolves under PocketIC — nothing answers the parked request. Calls that
/// are expected to FAIL before the outcall (anonymous, a bad destination, an
/// unknown tier, an unpriceable rate, a closed gate) still use the direct actor,
/// because they never reach it.
///
/// Submitted through `deferredUser` so the outcall can be answered while the
/// update call is still in flight.
export async function createOrderWithSession(
  gw: Gateway,
  amount: Amount,
  destination: Destination,
  minCycles: [] | [bigint],
  opts: {
    sessionId?: string;
    /// Absolute Unix seconds. Defaults to Stripe's floor plus slack from now.
    expiresAtSeconds?: number;
    livemode?: boolean;
    status?: number;
  } = {},
): Promise<Result<CreatedOrder, CreateOrderError>> {
  const settle = await gw.deferredUser.create_order(amount, destination, minCycles);
  const outcall = await awaitPendingOutcall(gw);
  const expiresAtSeconds =
    opts.expiresAtSeconds ?? Number(await nowSeconds(gw.pic)) + 2_100;
  // ⚠️ **A UNIQUE session id per order, derived from the order it belongs to.**
  //
  // `sessionCreatedBody` defaults to `cs_test_a1b2`, so before this every order in the
  // suite shared one session id. That was invisible while nothing looked a session up by
  // id — and #52's sweep does: its retrieve URL carries the id, so a scenario answering
  // "expired" for its own order was settling whichever neighbour the scan reached first,
  // while its own order sat `#created`. Three scenarios failed that way before the cause
  // was found.
  //
  // Derived rather than counted, so a session id in a failure message names the order it
  // belongs to instead of an anonymous sequence number. `client_reference_id` is
  // `<principal>_<orderId>` and the canister has just put it in the request body.
  const reference = outcallBody(outcall).match(/client_reference_id=[^&]*_([0-9a-f]{8})/);
  const body = sessionCreatedBody({
    id: opts.sessionId ?? (reference ? `cs_test_${reference[1]}` : undefined),
    expiresAtSeconds,
    livemode: opts.livemode,
  });
  const status = opts.status ?? 200;
  await answerOutcall(gw, outcall, status, body);
  return settle();
}

/// `cancel_order`, answering the expire outcall it now blocks on (#33).
///
/// Cancellation is atomic with Stripe: the session is expired first, so this is
/// an outcall too. `expireStatus` drives the three outcomes — 200 cancels, a
/// "not open" body leaves the order alone, anything else is a failure that leaves
/// it payable.
export async function cancelOrderWithExpire(
  gw: Gateway,
  orderId: string,
  opts: { expireStatus?: number; expireBody?: string } = {},
): Promise<Result<Order, string>> {
  const settle = await gw.deferredUser.cancel_order(orderId);
  // Optional on purpose: an already-cancelled order returns early without an
  // outcall (idempotent), and so does one that never got a session — the residue
  // case where no URL ever left the canister, so nothing needs expiring.
  const outcall = await maybePendingOutcall(gw);
  if (outcall !== undefined) {
    await answerOutcall(
      gw,
      outcall,
      opts.expireStatus ?? 200,
      opts.expireBody ?? JSON.stringify({ id: 'cs_test_a1b2', status: 'expired' }),
    );
  }
  return settle();
}

/// `<principal>_<orderId>` — the attribution reference.
///
/// Derived here because #33 dropped it from `create_order`'s response: the
/// canister sets `client_reference_id` through the Stripe API now, so handing it
/// back was a Payment-Link relic. Building it in the test is also stricter — it
/// asserts the canister and the suite agree on the shape rather than trusting
/// whatever the canister returned.
export function clientReferenceFor(orderId: string, who = user): string {
  return `${who.getPrincipal().toText()}_${orderId}`;
}
