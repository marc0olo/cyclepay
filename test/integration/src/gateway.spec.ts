/// PocketIC integration suite — the Card-rail go-live bar (spec §9).
///
/// Scenarios run **sequentially against one instance**: the on-chain state
/// accumulates the way a live gateway's would (orders, dedup sets, burn-cap
/// consumption, audit trail), and several scenarios deliberately build on
/// earlier ones. Coverage demanded by §9: happy path, duplicate/replay,
/// ambiguous-transfer recovery, AwaitingTreasury, error queue Type 1/Type 2,
/// forex fail-closed, upgrade-mid-flight, postupgrade timer re-arm.
import { afterAll, beforeAll, expect, test } from 'vitest';
import { Principal } from '@icp-sdk/core/principal';
import {
  BACKEND_WASM, FOREX_BODY_OK, ICP_FEE_E8S, ORDER_E8S, TIER_LOCKED_CYCLES,
  TIER_USD_CENTS, WEBHOOK_SECRET, admin, user,
  Gateway, setupGateway, teardownGateway,
  setCmcRate, fundFloat, floatBalance,
  checkoutSessionBody, chargeRefundedBody, deliverWebhook, stripeSignature,
  createOrderWithForexMocks, nowSeconds,
  orderStatus, statusKey, tickUntilStatus, expectOk, expectErr,
} from './harness';
import type { ErrorEntry, Order } from './types';

let gw: Gateway;
/// Destination canister for #canister deliveries (created empty, on the app
/// subnet, with a known cycles balance).
let destinationId: Principal;

// Orders created along the way (suite-global on purpose — later scenarios
// replay and re-attack earlier ones).
let orderA: Order; let refA: string; // happy path via AwaitingTreasury resume
let orderB: Order; let refB: string; // cycles-ledger delivery
let orderC: Order; let refC: string; // Type 2 undeliverable
let orderE: Order; let refE: string; // upgrade-mid-transfer replay
let orderF: Order; let refF: string; // treasury max-wait escalation

const FLOAT_E8S = 5_000_000_000n; // 50 ICP

beforeAll(async () => {
  gw = await setupGateway();
  const [appSubnet] = await gw.pic.getApplicationSubnets();
  destinationId = await gw.pic.createCanister({
    targetSubnetId: appSubnet.id,
    cycles: 1_000_000_000_000n,
  });
  await setCmcRate(gw);
  await fundFloat(gw, FLOAT_E8S);
});

afterAll(async () => {
  if (gw) await teardownGateway(gw);
});

test('01 — deploy, fail-closed before provisioning, admin authz', async () => {
  expect(await gw.asAnon.health()).toBe(true);

  // §6.1: an unprovisioned secret answers 503 so Stripe keeps retrying.
  const before = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_pre', paymentIntent: 'pi_pre', clientReferenceId: null,
    amountCents: TIER_USD_CENTS,
  }));
  expect(before.status_code).toBe(503);

  // §7: only controllers may provision; the user and anonymous callers trap.
  await expect(gw.asUser.set_webhook_secret(WEBHOOK_SECRET)).rejects.toThrow(/not a controller/);
  await expect(gw.asAnon.set_webhook_secret(WEBHOOK_SECRET)).rejects.toThrow(/anonymous/);

  expectOk(await gw.asAdmin.set_webhook_secret(WEBHOOK_SECRET));
  const status = await gw.asAdmin.webhook_secret_status();
  expect(status.isSet).toBe(true);
  expect(status.generation).toBe(1n);
});

test('02 — tier config is admin-gated and public to read', async () => {
  await expect(gw.asUser.set_card_tiers([])).rejects.toThrow(/not a controller/);
  expectOk(await gw.asAdmin.set_card_tiers([
    { id: 'tier5', usdCents: TIER_USD_CENTS, paymentLinkUrl: 'https://buy.stripe.com/test_tier5' },
  ]));
  const tiers = await gw.asAnon.card_tiers();
  expect(tiers).toHaveLength(1);
  expect(tiers[0].id).toBe('tier5');
});

test('03 — forex fail-closed: empty cache + failing refresh blocks orders (§3.1)', async () => {
  // Anonymous callers can never own orders.
  const anonResult = await gw.asAnon.create_order('tier5', { canister: destinationId });
  expect(expectErr(anonResult)).toEqual({ anonymous: null });

  // The refresh retries up to 3 times in-call; all rejected → #rateUnavailable.
  const result = await createOrderWithForexMocks(
    gw, 'tier5', { canister: destinationId },
    [{ kind: 'reject' }, { kind: 'reject' }, { kind: 'reject' }],
  );
  expect(expectErr(result)).toEqual({ rateUnavailable: null });
  const forex = await gw.asAnon.forex_status();
  expect(forex.rate).toEqual([]);
});

test('04 — order priced from a mocked outcall through the real transform', async () => {
  // Stretch the forex staleness window so one fetched rate prices the whole
  // suite — the CMC's 15-min rate window stays the live constraint.
  expectOk(await gw.asAdmin.set_forex_config({
    url: 'https://open.er-api.com/v6/latest/USD',
    feeBps: 290n,
    feeFixedCents: 30n,
    maxAgeNs: 2_592_000_000_000_000n, // 30 days
  }));

  const created = expectOk(await createOrderWithForexMocks(
    gw, 'tier5', { canister: destinationId },
    [{ kind: 'success', body: FOREX_BODY_OK }],
  ));
  orderA = created.order;
  refA = created.clientReferenceId;

  // The §3 vector: 500¢ gross − (⌈500·290/10⁴⌉ + 30)¢ fee = 455¢ net at
  // 737_000 micro-XDR/USD → 3_353_350_000_000 cycles, locked at creation.
  expect(orderA.lockedCycles).toBe(TIER_LOCKED_CYCLES);
  expect(statusKey(orderA)).toBe('created');
  expect(refA).toBe(`${user.getPrincipal().toText()}_${orderA.id}`);

  // §2 authz: non-owners (including admins) see nothing, not even existence.
  expect(await gw.asUser.get_order(orderA.id)).toHaveLength(1);
  expect(await gw.asAdmin.get_order(orderA.id)).toHaveLength(0);
  expect((await gw.asUser.list_orders()).map((o) => o.id)).toContain(orderA.id);

  // Cached rate now serves orders without an outcall.
  const again = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  expect(again.order.lockedCycles).toBe(TIER_LOCKED_CYCLES);
});

test('05 — HTTP ingress guards on the live route table (§6.0/§6.1)', async () => {
  const body = checkoutSessionBody({
    eventId: 'evt_guard', paymentIntent: 'pi_guard', clientReferenceId: refA,
    amountCents: TIER_USD_CENTS,
  });

  // Query half: the matched upgrade route defers to consensus.
  const query = await gw.asAnon.http_request({
    method: 'POST', url: '/webhook/stripe', headers: [],
    body: new TextEncoder().encode(body),
  });
  expect(query.upgrade).toEqual([true]);

  // Tampered MAC → 400, and the order is untouched.
  const badSig = await deliverWebhook(gw, body, {
    signature: stripeSignature('whsec_wrong_secret_entirely', await nowSeconds(gw.pic), body),
  });
  expect(badSig.status_code).toBe(400);

  // Replayed timestamp outside the ±300 s tolerance → 400.
  const staleT = await deliverWebhook(gw, body, {
    signature: stripeSignature(WEBHOOK_SECRET, (await nowSeconds(gw.pic)) - 301n, body),
  });
  expect(staleT.status_code).toBe(400);

  // Unknown path / wrong method / oversized body.
  const notFound = await gw.asAnon.http_request_update({
    method: 'POST', url: '/webhook/other', headers: [], body: new Uint8Array(),
  });
  expect(notFound.status_code).toBe(404);
  const wrongMethod = await gw.asAnon.http_request_update({
    method: 'GET', url: '/webhook/stripe', headers: [], body: new Uint8Array(),
  });
  expect(wrongMethod.status_code).toBe(405);
  expect(wrongMethod.headers).toContainEqual(['Allow', 'POST']);
  const oversize = await gw.asAnon.http_request_update({
    method: 'POST', url: '/webhook/stripe', headers: [], body: new Uint8Array(65_537),
  });
  expect(oversize.status_code).toBe(413);

  expect(await orderStatus(gw, orderA.id)).toBe('created');
});

test('06 — AwaitingTreasury: the default burn cap of 0 holds every mint (§5.3)', async () => {
  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_a1', paymentIntent: 'pi_a', clientReferenceId: refA,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);

  // The detached money-out kick runs #begin (CMC rate + float reads), then
  // the pre-gate holds: cap 0 means "operator has not sized the bound yet".
  expect(await tickUntilStatus(gw, orderA.id, ['awaitingTreasury'])).toBe('awaitingTreasury');

  const treasury = await gw.asAnon.treasury_status();
  expect(treasury.heldOrders).toBe(1n);
  expect(treasury.config.burnCapE8s).toBe(0n);
  expect(treasury.lastObservedFloat[0]?.e8s).toBe(FLOAT_E8S);

  const audit = await gw.asAdmin.audit_log();
  expect(audit.some((e) => e.tag === 'mint.held' && e.detail.includes(orderA.id))).toBe(true);
});

test('07 — happy path: cap sized → held order resumes → real CMC mint lands at the destination (§5)', async () => {
  expectOk(await gw.asAdmin.set_treasury_config({
    burnCapE8s: 10_000_000_000n, // 100 ICP / 24 h
    burnWindowNs: 86_400_000_000_000n,
    lowFloatThresholdE8s: 0n,
    maxHoldNs: 259_200_000_000_000n, // 72 h
  }));

  const floatBefore = await floatBalance(gw);
  const destBefore = await gw.pic.getCyclesBalance(destinationId);

  const driven = expectOk(await gw.asAdmin.process_order(orderA.id));
  expect(statusKey(driven)).toBe('delivered');

  // Exactly one ledger debit: the order's e8s + the protocol fee.
  expect(await floatBalance(gw)).toBe(floatBefore - ORDER_E8S - ICP_FEE_E8S);

  // The CMC minted e8s × permyriad = exactly the locked quantity, and the
  // forward deposited it on the destination canister.
  const destAfter = await gw.pic.getCyclesBalance(destinationId);
  const delivered = destAfter - destBefore;
  expect(delivered).toBeLessThanOrEqual(TIER_LOCKED_CYCLES);
  expect(delivered).toBeGreaterThan((TIER_LOCKED_CYCLES * 999n) / 1000n);

  // §4.2 journal: block recorded, minted quantity recorded, terminal status.
  const journal = (await gw.asAdmin.mint_journal(orderA.id))[0]!;
  expect(journal.blockIndex.length).toBe(1);
  expect(journal.cyclesMinted).toEqual([TIER_LOCKED_CYCLES]);
  expect(statusKey(journal)).toBe('delivered');

  // §5.3 cap consumption is recorded against the rolling window.
  expect((await gw.asAnon.treasury_status()).burnedInWindowE8s).toBe(ORDER_E8S);
  expect((await gw.asAnon.treasury_status()).heldOrders).toBe(0n);
});

test('08 — duplicate/replay: every dedup layer holds through real ingress (§4.1/§4.2)', async () => {
  const floatBefore = await floatBalance(gw);
  const errorsBefore = (await gw.asAdmin.error_queue()).length;

  // Replay 1: identical event redelivered (Stripe retry) → ack-and-drop.
  const sameEvent = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_a1', paymentIntent: 'pi_a', clientReferenceId: refA,
    amountCents: TIER_USD_CENTS,
  }));
  expect(sameEvent.status_code).toBe(200);

  // Replay 2: fresh event id, same payment_intent → one-mint-per-payment.
  const sameIntent = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_a2', paymentIntent: 'pi_a', clientReferenceId: refA,
    amountCents: TIER_USD_CENTS,
  }));
  expect(sameIntent.status_code).toBe(200);

  await gw.pic.tick(10);
  expect(await orderStatus(gw, orderA.id)).toBe('delivered');
  expect(await floatBalance(gw)).toBe(floatBefore);
  expect((await gw.asAdmin.error_queue()).length).toBe(errorsBefore);

  // Genuine double-pay: a *new* payment intent against the handled order →
  // Type 1 #duplicate, acked 200 (the money is handled — by the operator).
  const doublePay = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_a3', paymentIntent: 'pi_a_double', clientReferenceId: refA,
    amountCents: TIER_USD_CENTS,
  }));
  expect(doublePay.status_code).toBe(200);
  const dupEntry = (await gw.asAdmin.error_queue()).find(
    (e) => 'duplicate' in e.kind && e.kind.duplicate.paymentRef === 'pi_a_double',
  ) as ErrorEntry;
  expect(dupEntry).toBeDefined();
  expect(dupEntry.resolvedAtNs).toEqual([]);

  // charge.refunded auto-resolves the Type 1 entry by payment_intent.
  const refund = await deliverWebhook(gw, chargeRefundedBody('evt_a4', 'pi_a_double'));
  expect(refund.status_code).toBe(200);
  const resolved = (await gw.asAdmin.error_queue()).find((e) => e.id === dupEntry.id) as ErrorEntry;
  expect(resolved.resolvedAtNs.length).toBe(1);

  await gw.pic.tick(5);
  expect(await floatBalance(gw)).toBe(floatBefore);
});

test('09 — Type 1 unattributed: claimed-not-trusted reference resolution (§6.1)', async () => {
  // Valid-shaped client_reference_id pointing at a nonexistent order.
  const bogusRef = `${user.getPrincipal().toText()}_00000000000000000000000000000000`;
  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_u1', paymentIntent: 'pi_u', clientReferenceId: bogusRef,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);

  const entry = (await gw.asAdmin.error_queue()).find(
    (e) => 'unattributed' in e.kind && e.kind.unattributed.paymentRef === 'pi_u',
  ) as ErrorEntry;
  expect(entry).toBeDefined();

  // Manual operator resolution (§4.1) — admin-gated.
  await expect(gw.asUser.resolve_error(entry.id)).rejects.toThrow(/not a controller/);
  const resolved = expectOk(await gw.asAdmin.resolve_error(entry.id));
  expect(resolved.resolvedAtNs.length).toBe(1);
});

test('10 — delivery to a real cycles-ledger account (§5 forward, second arm)', async () => {
  const created = expectOk(await gw.asUser.create_order('tier5', {
    cyclesLedgerAccount: { owner: user.getPrincipal(), subaccount: [] },
  }));
  orderB = created.order;
  refB = created.clientReferenceId;

  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_b1', paymentIntent: 'pi_b', clientReferenceId: refB,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);

  expect(await tickUntilStatus(gw, orderB.id, ['delivered'])).toBe('delivered');
  expect(await gw.cyclesLedger.icrc1_balance_of({
    owner: user.getPrincipal(), subaccount: [],
  })).toBe(TIER_LOCKED_CYCLES);
});

test('11 — Type 2 undeliverable: failed forward refunds cycles to the app balance (§4.1)', async () => {
  const created = expectOk(await gw.asUser.create_order('tier5', {
    canister: gw.neverCanisterId, // never allocated — the deposit is rejected
  }));
  orderC = created.order;
  refC = created.clientReferenceId;

  const appBalanceBefore = await gw.pic.getCyclesBalance(gw.backendId);

  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_c1', paymentIntent: 'pi_c', clientReferenceId: refC,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);

  expect(await tickUntilStatus(gw, orderC.id, ['errorQueue'])).toBe('errorQueue');

  const entry = (await gw.asAdmin.error_queue()).find(
    (e) => 'undeliverable' in e.kind && e.kind.undeliverable.orderId === orderC.id,
  ) as ErrorEntry;
  expect(entry).toBeDefined();
  if ('undeliverable' in entry.kind) {
    expect(entry.kind.undeliverable.cycles).toBe(TIER_LOCKED_CYCLES);
  }
  expect(statusKey((await gw.asAdmin.mint_journal(orderC.id))[0]!)).toBe('errorQueue');

  // The §4.1 Type-2 invariant: the minted cycles refunded into the app
  // canister's own balance (minus execution costs accrued along the way).
  const appBalanceAfter = await gw.pic.getCyclesBalance(gw.backendId);
  expect(appBalanceAfter - appBalanceBefore).toBeGreaterThan((TIER_LOCKED_CYCLES * 9n) / 10n);
});

test('12 — upgrade mid-transfer: §5.1 write-intent replay recovers without a double spend, timer re-arms', async () => {
  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  orderE = created.order;
  refE = created.clientReferenceId;

  const floatBefore = await floatBalance(gw);
  const sweepBefore = await gw.asAnon.recovery_status();

  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_e1', paymentIntent: 'pi_e', clientReferenceId: refE,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);

  // Tick one round at a time and interrupt the instant the intent commits:
  // #minting means the transfer args are journaled and the ledger call is in
  // flight — its fate is exactly what §5.1 calls unknowable.
  expect(await tickUntilStatus(gw, orderE.id, ['minting'])).toBe('minting');
  await gw.pic.upgradeCanister({
    canisterId: gw.backendId,
    wasm: BACKEND_WASM,
    sender: admin.getPrincipal(),
  });

  // The upgrade dropped the in-flight callback; the order is stuck #minting
  // with the §5.1 intent persisted in the journal.
  expect(await orderStatus(gw, orderE.id)).toBe('minting');
  const journal = (await gw.asAdmin.mint_journal(orderE.id))[0]!;
  expect(journal.transferIntent.length).toBe(1);

  // The transient-initializer timer re-armed on upgrade: advancing past the
  // sweep interval fires recovery with no manual kick. The CMC rate is not
  // refreshed on purpose — the §5.1 replay path must not need one.
  await gw.pic.advanceTime(3_601_000);
  await gw.pic.tick(3);
  expect(await tickUntilStatus(gw, orderE.id, ['delivered'])).toBe('delivered');

  // THE §5.1 invariant: replaying the identical intent moved the money
  // exactly once (the ledger either executed it once or answered Duplicate).
  expect(await floatBalance(gw)).toBe(floatBefore - ORDER_E8S - ICP_FEE_E8S);
  expect((await gw.asAdmin.mint_journal(orderE.id))[0]!.blockIndex.length).toBe(1);

  // Liveness observability: the post-upgrade timer completed a sweep.
  const sweepAfter = await gw.asAnon.recovery_status();
  expect(sweepAfter.lastSweep.length).toBe(1);
  const beforeAt = sweepBefore.lastSweep[0]?.atNs ?? -1n;
  expect(sweepAfter.lastSweep[0]!.atNs).toBeGreaterThan(beforeAt);
});

test('13 — upgrade mid-forward: ambiguous delivery escalates, never re-forwards (§5.1)', async () => {
  await setCmcRate(gw); // scenario 12 advanced time past the 15-min CMC window
  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const orderG = created.order;

  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_g1', paymentIntent: 'pi_g', clientReferenceId: created.clientReferenceId,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);

  // The pre-forward marker (cyclesMinted) commits before the forward await;
  // catch that window and upgrade — the forward's fate becomes unknowable.
  let caught = false;
  for (let i = 0; i < 300; i++) {
    const entry = await gw.asAdmin.mint_journal(orderG.id);
    if (entry.length === 1 && entry[0].cyclesMinted.length === 1
      && statusKey(entry[0]) !== 'delivered') {
      caught = true;
      break;
    }
    if (entry.length === 1 && statusKey(entry[0]) === 'delivered') {
      throw new Error('forward completed before the suite could interrupt it');
    }
    await gw.pic.tick();
  }
  expect(caught).toBe(true);
  await gw.pic.upgradeCanister({
    canisterId: gw.backendId,
    wasm: BACKEND_WASM,
    sender: admin.getPrincipal(),
  });

  // Recovery answers #ambiguousForward: terminal escalation, at-most-once
  // delivery — the operator checks the destination instead of re-sending.
  const driven = expectOk(await gw.asAdmin.process_order(orderG.id));
  expect(statusKey(driven)).toBe('errorQueue');
  const entry = (await gw.asAdmin.error_queue()).find(
    (e) => 'stuckMint' in e.kind && e.kind.stuckMint.orderId === orderG.id,
  ) as ErrorEntry;
  expect(entry).toBeDefined();
  if ('stuckMint' in entry.kind) {
    expect(entry.kind.stuckMint.stage).toBe('ambiguousForward');
  }
});

test('14 — treasury max-wait: a held order escalates with a certain money position (§5.3)', async () => {
  // Cap back to 0 — the §5.3 pause lever.
  expectOk(await gw.asAdmin.set_treasury_config({
    burnCapE8s: 0n,
    burnWindowNs: 86_400_000_000_000n,
    lowFloatThresholdE8s: 0n,
    maxHoldNs: 259_200_000_000_000n, // 72 h
  }));
  await setCmcRate(gw);

  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  orderF = created.order;
  refF = created.clientReferenceId;

  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_f1', paymentIntent: 'pi_f', clientReferenceId: refF,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);
  expect(await tickUntilStatus(gw, orderF.id, ['awaitingTreasury'])).toBe('awaitingTreasury');

  const floatBefore = await floatBalance(gw);

  // Past maxHold the recovery sweep escalates: fiat in, nothing minted —
  // the operator refunds in the Stripe Dashboard.
  await gw.pic.advanceTime(73 * 3_600 * 1_000);
  await gw.pic.tick(3);
  expect(await tickUntilStatus(gw, orderF.id, ['errorQueue'])).toBe('errorQueue');

  const entry = (await gw.asAdmin.error_queue()).find(
    (e) => 'stuckMint' in e.kind && e.kind.stuckMint.orderId === orderF.id,
  ) as ErrorEntry;
  expect(entry).toBeDefined();
  if ('stuckMint' in entry.kind) {
    expect(entry.kind.stuckMint.stage).toBe('treasuryWaitExceeded');
  }
  expect(await floatBalance(gw)).toBe(floatBefore); // nothing moved
  expect((await gw.asAnon.treasury_status()).heldOrders).toBe(0n);
  // The 24 h burn window rolled over during the 73 h wait.
  expect((await gw.asAnon.treasury_status()).burnedInWindowE8s).toBe(0n);
});

test('15 — operational trail is coherent end-to-end (§4.2)', async () => {
  const audit = await gw.asAdmin.audit_log();
  expect(audit.length).toBeGreaterThan(0);
  for (let i = 1; i < audit.length; i++) {
    expect(audit[i].seq).toBeGreaterThan(audit[i - 1].seq);
  }
  const tags = audit.map((e) => e.tag);
  for (const expected of ['mint.held', 'mint.delivered', 'mint.undeliverable', 'mint.stuck']) {
    expect(tags).toContain(expected);
  }

  // Every queue entry is accounted for: the C undeliverable (open, operator
  // re-delivers off-chain), the F max-wait (open), the resolved Type 1s.
  const queue = await gw.asAdmin.error_queue();
  const open = queue.filter((e) => e.resolvedAtNs.length === 0);
  expect(open.map((e) => Object.keys(e.kind)[0]).sort()).toEqual(['stuckMint', 'stuckMint', 'undeliverable']);

  // Admin gates on the trail itself.
  await expect(gw.asUser.audit_log()).rejects.toThrow(/not a controller/);
  await expect(gw.asUser.error_queue()).rejects.toThrow(/not a controller/);
});
