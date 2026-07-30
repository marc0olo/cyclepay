/// PocketIC harness for the Card go-live bar (spec §9).
///
/// Real-world simulation per the spec: the **real** ICP ledger, CMC, and
/// cycles ledger (PocketIC's `icpFeatures` deploys the actual NNS canisters at
/// their mainnet IDs and keeps the CMC's subnet lists in sync with the instance
/// topology), the **real ic-icrc1-ledger** at the mainnet ck-USDC id,
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
  type Actor,
  type DeferredActor,
} from '@dfinity/pic';
import { Principal } from '@icp-sdk/core/principal';
import {
  backendIdlFactory, cmcIdlFactory, encodeCkUsdcLedgerInit, encodeXrcMockInit,
  icrc1IdlFactory, icrc2IdlFactory, xrcMockIdlFactory,
} from './idl';
import type {
  BackendService, CmcService, CreatedCkUsdcOrder, CreateCkUsdcOrderError, ErrorEntry,
  Destination, HttpResponse, Icrc1Service, Icrc2Service,
  Order, OrderStatusKey, Result, StatusVariant,
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

/// The mainnet ck-USDC ledger id CkUsdc.mo pins. It lives in the fiduciary
/// subnet's canister range, which PocketIC mirrors — the suite installs the
/// real ic-icrc1-ledger wasm at exactly this id (`targetCanisterId` is
/// supported on the Fiduciary subnet).
export const CKUSDC_LEDGER_ID = Principal.fromText('xevnm-gaaaa-aaaar-qafnq-cai');
/// The mainnet Exchange Rate Canister id `Xrc.mo` pins. It lives in the SNS
/// subnet's canister range, which is why the instance below creates one.
export const XRC_ID = Principal.fromText('uf6dk-hyaaa-aaaaq-qaaaq-cai');

export const BACKEND_WASM = resolve(
  import.meta.dirname,
  '..', '..', '..', 'src', 'backend', 'dist', 'backend.wasm',
);
/// Real ic-icrc1-ledger wasm, fetched (sha256-pinned) by the pretest script.
export const CKUSDC_LEDGER_WASM = resolve(
  import.meta.dirname,
  '..', 'wasm', 'ic-icrc1-ledger.wasm.gz',
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
/// ceil(3_500_000_000_000 / 35_000) — exactly 1 ICP, the point of the vector.
export const ORDER_E8S = 100_000_000n;
export const ICP_FEE_E8S = 10_000n;
/// The cycles ledger charges this on `deposit`. It makes the two §5 forward
/// arms asymmetric: a `#cyclesLedgerAccount` destination receives
/// `lockedCycles - CYCLES_LEDGER_DEPOSIT_FEE`, while a `#canister` destination
/// (`deposit_cycles`) receives the full locked quantity. See the note in
/// scenario 10 for why this is not grossed up.
export const CYCLES_LEDGER_DEPOSIT_FEE = 100_000_000n;

export const WEBHOOK_SECRET = 'whsec_8fJ3kQ9mN2pX7vR4tL6wY1zB5cD0eH';

export const admin = createIdentity('cyclepay integration admin');
export const user = createIdentity('cyclepay integration user');
/// ck-USDC suite extras: a user whose balance can't cover a pull, and the
/// ledger's minting account (never used after init).
export const poorUser = createIdentity('cyclepay integration poor user');
export const ckUsdcMinter = createIdentity('cyclepay integration ckusdc minter');

/// ck-USDC constants (CkUsdc.mo): 6 decimals at 1:1 USD ⇒ 1¢ = 10^4 units;
/// ledger transfer fee 10_000 units (1¢) — charged to the user's account on
/// both `icrc2_approve` and the pull.
export const CKUSDC_FEE_UNITS = 10_000n;
/// The suite's standard ck-USDC order: 500¢ with the rail's 0/0 fee formula →
/// net 500¢ (no processor to recover), so 5_000_000 units are pulled and
/// 500 · 35_000 · 10¹² / 4_550_000 = 3_846_153_846_153 cycles are locked.
///
/// Contrast the card rail's same 500¢ tier, which nets 455¢ → 3.5 T: one shared
/// quote path, per-rail fee formulas. The ck rail buys more cycles for the same
/// gross precisely because there is no card processor taking a cut.
export const CK_ORDER_USD_CENTS = 500n;
export const CK_ORDER_UNITS = 5_000_000n;
export const CK_ORDER_APPROVE_UNITS = CK_ORDER_UNITS + CKUSDC_FEE_UNITS;
export const CK_ORDER_LOCKED_CYCLES = 3_846_153_846_153n;
/// ceil(3_846_153_846_153 / 35_000) — the e8s the shared mint pipeline derives.
export const CK_ORDER_E8S = 109_890_110n;

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
  /// create_order as the user, submitted-not-awaited — used by the
  /// interruption tests to catch a money path mid-flight.
  deferredUser: DeferredActor<BackendService>;
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
    // The fiduciary subnet's canister range mirrors mainnet's, so the
    // ck-USDC suite can install a ledger at the exact id CkUsdc.mo pins.
    fiduciary: { state: { type: SubnetStateType.New } },
    // The XRC id falls in the `aaaaq` canister range, which PocketIC assigns to
    // the II subnet (the same range holds the cycles ledger). `subnetHosting`
    // below finds it by range rather than trusting that assignment.
    ii: { state: { type: SubnetStateType.New } },
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
/// `upgradeCanister` during an in-flight mint or pull always fails.
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

// ── ck-USDC ledger (§6.2) ─────────────────────────────────────────────────

export interface CkLedger {
  canisterId: Principal;
  subnetId: Principal;
  /// Ledger actors per caller role — the suite approves as users and audits
  /// balances anonymously.
  asUser: Actor<Icrc2Service>;
  asPoorUser: Actor<Icrc2Service>;
  query: Actor<Icrc2Service>;
  /// Stop/start the ledger canister — the deterministic way to manufacture
  /// a pull whose intent persists without the ledger ever executing it.
  stop(): Promise<void>;
  start(): Promise<void>;
}

/// Install the REAL ic-icrc1-ledger (pinned release, fetched by pretest) at
/// the mainnet ck-USDC id on the fiduciary subnet. ICRC-2 enabled; admin is
/// the controller so the suite can stop/start it.
export async function installCkUsdcLedger(
  gw: Gateway,
  initialBalances: [Principal, bigint][],
): Promise<CkLedger> {
  const fiduciary = await gw.pic.getFiduciarySubnet();
  if (!fiduciary) throw new Error('instance has no fiduciary subnet');
  const fixture = await gw.pic.setupCanister<Icrc2Service>({
    idlFactory: icrc2IdlFactory,
    wasm: CKUSDC_LEDGER_WASM,
    arg: encodeCkUsdcLedgerInit({
      minter: ckUsdcMinter.getPrincipal(),
      archiveController: admin.getPrincipal(),
      initialBalances,
      transferFee: CKUSDC_FEE_UNITS,
    }),
    sender: admin.getPrincipal(),
    controllers: [admin.getPrincipal()],
    targetCanisterId: CKUSDC_LEDGER_ID,
    targetSubnetId: fiduciary.id,
  });
  const asUser = fixture.actor;
  asUser.setIdentity(user);
  const asPoorUser = gw.pic.createActor<Icrc2Service>(icrc2IdlFactory, CKUSDC_LEDGER_ID);
  asPoorUser.setIdentity(poorUser);
  const query = gw.pic.createActor<Icrc2Service>(icrc2IdlFactory, CKUSDC_LEDGER_ID);
  return {
    canisterId: CKUSDC_LEDGER_ID,
    subnetId: fiduciary.id,
    asUser,
    asPoorUser,
    query,
    stop: () => gw.pic.stopCanister({
      canisterId: CKUSDC_LEDGER_ID,
      sender: admin.getPrincipal(),
      targetSubnetId: fiduciary.id,
    }),
    start: () => gw.pic.startCanister({
      canisterId: CKUSDC_LEDGER_ID,
      sender: admin.getPrincipal(),
      targetSubnetId: fiduciary.id,
    }),
  };
}

export async function ckBalance(ledger: CkLedger, owner: Principal): Promise<bigint> {
  return await ledger.query.icrc1_balance_of({ owner, subaccount: [] });
}

/// `icrc2_approve` the gateway as spender — what the frontend asks the
/// user's wallet for between create and claim. Costs the approver one
/// ledger fee.
export async function approveCkUsdc(
  ledgerActor: Actor<Icrc2Service>,
  spender: Principal,
  units: bigint,
): Promise<void> {
  const result = await ledgerActor.icrc2_approve({
    fee: [],
    memo: [],
    from_subaccount: [],
    created_at_time: [],
    amount: units,
    expected_allowance: [],
    expires_at: [],
    spender: { owner: spender, subaccount: [] },
  });
  if (!('Ok' in result)) {
    throw new Error(`icrc2_approve failed: ${JSON.stringify(result, bigIntReplacer)}`);
  }
}

/// Page through the whole error queue as an admin.
///
/// The canister query is paged (unresolved obligations are never evicted, so the
/// queue can outgrow a 2 MB Candid response). Scenarios assert over the full set,
/// so the paging lives here rather than in every test.
export async function allErrorEntries(gw: Gateway): Promise<ErrorEntry[]> {
  const all: ErrorEntry[] = [];
  let cursor: [] | [bigint] = [];
  for (;;) {
    const page = await gw.asAdmin.error_queue(cursor, 200n);
    all.push(...page.entries);
    if (page.nextCursor.length === 0) return all;
    cursor = page.nextCursor;
  }
}

/// The operator worklist — open obligations only, paged server-side.
export async function openErrorEntries(gw: Gateway): Promise<ErrorEntry[]> {
  const open: ErrorEntry[] = [];
  let cursor: [] | [bigint] = [];
  for (;;) {
    const page = await gw.asAdmin.error_queue_unresolved(cursor, 200n);
    open.push(...page.entries);
    if (page.nextCursor.length === 0) return open;
    cursor = page.nextCursor;
  }
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
