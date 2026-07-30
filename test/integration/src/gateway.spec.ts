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
  CYCLES_LEDGER_DEPOSIT_FEE, ICP_FEE_E8S, ICP_USD_RATE, ORDER_E8S,
  TIER_LOCKED_CYCLES, TIER_USD_CENTS, WEBHOOK_SECRET, XDR_PERMYRIAD_PER_ICP, user,
  Gateway, setupGateway, teardownGateway, upgradeBackendMidFlight,
  setCmcRate, fundFloat, floatBalance,
  checkoutSessionBody, chargeRefundedBody, deliverWebhook, stripeSignature,
  nowSeconds, setXrcRate, setXrcResponse, warmRates, ensureRates, tickRateTimer,
  orderStatus, statusKey, tickUntilStatus, expectOk, expectErr,
  allErrorEntries, openErrorEntries,
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
  // The admission gate (Gate.mo) refuses to quote when the burn window has no
  // headroom, and the fail-closed default cap is 0 — so orders cannot be
  // created at all until the operator sizes the cap. Every scenario below that
  // creates an order needs this; the ones that exercise #awaitingTreasury drop
  // the cap back to 0 *after* creating, which is the documented pause lever.
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));
});

/// Cap sized, float gating off (scenarios assert on the cap, not the float).
const WORKING_TREASURY = {
  burnCapE8s: 10_000_000_000n, // 100 ICP / 24 h
  burnWindowNs: 86_400_000_000_000n,
  lowFloatThresholdE8s: 0n,
  maxHoldNs: 259_200_000_000_000n, // 72 h — terminate, operator refunds
  alertAfterNs: 7_200_000_000_000n, // 2 h — alert while it is still fixable
};

/// The §5.3 pause lever: cap 0 holds every mint.
const PAUSED_TREASURY = { ...WORKING_TREASURY, burnCapE8s: 0n };

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

test('03 — pricing fails closed: an XRC error leaves no rate and blocks orders (§3.1)', async () => {
  // Anonymous callers can never own orders.
  const anonResult = await gw.asAnon.create_order('tier5', { canister: destinationId });
  expect(expectErr(anonResult)).toEqual({ anonymous: null });

  // The XRC declining to answer is the realistic outage: it refuses rather than
  // guessing. Nothing may be priced off it, and no order may be created.
  await setXrcResponse(gw, { kind: 'error', error: 'InconsistentRatesReceived' });
  await tickRateTimer(gw);

  const status = await gw.asAnon.pricing_status();
  expect(status.rates).toEqual([]);
  // The failure is diagnosable — "timer dead" and "XRC erroring" must not look
  // the same to an operator.
  expect(status.lastAttempt[0]!.ok).toBe(false);
  expect(status.lastAttempt[0]!.detail).toContain('InconsistentRatesReceived');

  expect(expectErr(await gw.asUser.create_order('tier5', { canister: destinationId })))
    .toEqual({ rateUnavailable: null });
});

test('04 — a healthy XRC + CMC pair prices the §3 vector exactly', async () => {
  await setXrcRate(gw);
  await warmRates(gw);

  const rates = (await gw.asAnon.pricing_status()).rates[0]!;
  // $4.55 at XRC's 9 decimals → 4_550_000 micro-USD per ICP.
  expect(rates.usdPerIcpMicros).toBe(4_550_000n);
  expect(rates.xdrPermyriadPerIcp).toBe(XDR_PERMYRIAD_PER_ICP);
  // The quality signal the mock was installed with, recorded for the receipt.
  expect(rates.quality.receivedRates).toBe(5n);
  expect(rates.quality.queriedSources).toBe(6n);

  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  orderA = created.order;
  refA = created.clientReferenceId;

  // THE VECTOR: 500¢ gross − 45¢ fee = 455¢ net; at $4.55/ICP that is exactly
  // one ICP, which mints 35_000 · 10⁸ = 3.5 T cycles.
  expect(orderA.lockedCycles).toBe(TIER_LOCKED_CYCLES);
  expect(statusKey(orderA)).toBe('created');
  expect(refA).toBe(`${user.getPrincipal().toText()}_${orderA.id}`);

  // Both rate inputs are on the order, so the quote is reproducible from the
  // record alone rather than only checkable against a stored result.
  expect(orderA.pricing.usdPerIcpMicros).toBe(4_550_000n);
  expect(orderA.pricing.xdrPermyriadPerIcp).toBe(XDR_PERMYRIAD_PER_ICP);
  const net = TIER_USD_CENTS - (TIER_USD_CENTS * 290n + 9_999n) / 10_000n - 30n;
  expect(net * orderA.pricing.xdrPermyriadPerIcp * 10n ** 12n / orderA.pricing.usdPerIcpMicros)
    .toBe(orderA.lockedCycles);

  // §2 authz: non-owners (including admins) see nothing, not even existence.
  expect(await gw.asUser.get_order(orderA.id)).toHaveLength(1);
  expect(await gw.asAdmin.get_order(orderA.id)).toHaveLength(0);
  expect((await gw.asUser.list_orders()).map((o) => o.id)).toContain(orderA.id);

  // Orders read the cache; nothing user-facing calls the XRC.
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
  // Http.mo emits header *names* lowercased (`allow`) — RFC 9110 §5.1 makes
  // them case-insensitive on the wire, so this asserts the actual bytes.
  expect(wrongMethod.headers).toContainEqual(['allow', 'POST']);
  const oversize = await gw.asAnon.http_request_update({
    method: 'POST', url: '/webhook/stripe', headers: [], body: new Uint8Array(65_537),
  });
  expect(oversize.status_code).toBe(413);

  expect(await orderStatus(gw, orderA.id)).toBe('created');
});

test('06 — AwaitingTreasury: a burn cap of 0 holds the mint of an already-created order (§5.3)', async () => {
  // orderA was created in scenario 04 while the cap had headroom. Pausing now
  // is the realistic shape of this hold: the operator drops the cap (or an
  // earlier order exhausts the window) between creation and payment.
  expectOk(await gw.asAdmin.set_treasury_config(PAUSED_TREASURY));

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
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));

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
  const errorsBefore = (await allErrorEntries(gw)).length;

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
  expect((await allErrorEntries(gw)).length).toBe(errorsBefore);

  // Genuine double-pay: a *new* payment intent against the handled order →
  // Type 1 #duplicate, acked 200 (the money is handled — by the operator).
  const doublePay = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_a3', paymentIntent: 'pi_a_double', clientReferenceId: refA,
    amountCents: TIER_USD_CENTS,
  }));
  expect(doublePay.status_code).toBe(200);
  const dupEntry = (await allErrorEntries(gw)).find(
    (e) => 'duplicate' in e.kind && e.kind.duplicate.paymentRef === 'pi_a_double',
  ) as ErrorEntry;
  expect(dupEntry).toBeDefined();
  expect(dupEntry.resolvedAtNs).toEqual([]);

  // charge.refunded auto-resolves the Type 1 entry by payment_intent.
  const refund = await deliverWebhook(gw, chargeRefundedBody('evt_a4', 'pi_a_double'));
  expect(refund.status_code).toBe(200);
  const resolved = (await allErrorEntries(gw)).find((e) => e.id === dupEntry.id) as ErrorEntry;
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

  const entry = (await allErrorEntries(gw)).find(
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

  // ASYMMETRY WORTH KNOWING (documented in docs/STRIPE.md): the cycles-ledger
  // arm nets the ledger's own deposit fee, so the account receives
  // `lockedCycles - CYCLES_LEDGER_DEPOSIT_FEE`. The #canister arm
  // (`deposit_cycles`) has no such fee and delivers the full quantity.
  //
  // The fee is deliberately NOT grossed up by the canister: paying it out of
  // the app's own cycle balance would make every cycles-ledger order a 100M
  // subsidy, i.e. a griefable gas-drain vector (canister-security: cycle drain
  // protection). The user chose the delivery rail, so the user bears its fee.
  expect(await gw.cyclesLedger.icrc1_balance_of({
    owner: user.getPrincipal(), subaccount: [],
  })).toBe(TIER_LOCKED_CYCLES - CYCLES_LEDGER_DEPOSIT_FEE);
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

  const entry = (await allErrorEntries(gw)).find(
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
  await upgradeBackendMidFlight(gw);

  // The §5.1 intent is journaled and survived the upgrade — that is what makes
  // the resume replay-identical regardless of where the interruption landed.
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

test('13 — upgrade mid-forward: the stop-first procedure drains the forward, delivering exactly once (§5.1)', async () => {
  // Scenario 12 advanced past both the CMC window and the rate staleness bound;
  // ensureRates re-arms both.
  await ensureRates(gw);
  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const orderG = created.order;
  const destBefore = await gw.pic.getCyclesBalance(destinationId);

  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_g1', paymentIntent: 'pi_g', clientReferenceId: created.clientReferenceId,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);

  // Catch the pre-forward window: `cyclesMinted` is journaled *before* the
  // forward await, so this is the moment where the forward's outcome would be
  // unknowable if the callback were lost.
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
  await upgradeBackendMidFlight(gw);

  // `stop_canister` does not drop outstanding callbacks: the canister enters
  // `Stopping`, the IC delivers the replies to its in-flight calls, and only
  // once every call context is closed does it reach `Stopped`. The operator
  // procedure (stop → upgrade → start, mandatory because an upgrade with
  // outstanding callbacks is rejected) therefore cannot strand a forward — the
  // forward completes before the upgrade happens.
  //
  // So `#ambiguousForward` is unreachable via a controlled upgrade. It covers
  // genuine faults instead (a call that never replies, a subnet incident,
  // running out of cycles mid-call), and its escalation logic is pinned by unit
  // tests — see `Cmc.stageOf` in test/cmc.test.mo, which asserts `#icpAtCmc` +
  // `cyclesMinted` → `#escalate(#ambiguousForward)`.
  expect(await tickUntilStatus(gw, orderG.id, ['delivered'])).toBe('delivered');

  // Delivered exactly once — not skipped, and not double-forwarded.
  const delivered = (await gw.pic.getCyclesBalance(destinationId)) - destBefore;
  expect(delivered).toBeLessThanOrEqual(TIER_LOCKED_CYCLES);
  expect(delivered).toBeGreaterThan((TIER_LOCKED_CYCLES * 999n) / 1000n);
  expect((await gw.asAdmin.mint_journal(orderG.id))[0]!.blockIndex.length).toBe(1);

  // No error-queue entry: nothing about this needed an operator.
  expect((await allErrorEntries(gw)).find(
    (e) => 'stuckMint' in e.kind && e.kind.stuckMint.orderId === orderG.id,
  )).toBeUndefined();
});

test('14 — a treasury hold alerts but keeps waiting, then delivers when fixed (§5.3)', async () => {
  // The behaviour this pins: a hold past the alert threshold does NOT terminate
  // the order. Its causes — a spent burn window, a short float — are all
  // operator-fixable, so giving up would be abandoning a sale that was always
  // going to complete. The buyer waits; they do not get an unrequested refund.
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));

  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  orderF = created.order;
  refF = created.clientReferenceId;

  expectOk(await gw.asAdmin.set_treasury_config(PAUSED_TREASURY));
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_f1', paymentIntent: 'pi_f', clientReferenceId: refF,
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, orderF.id, ['awaitingTreasury'])).toBe('awaitingTreasury');

  const floatBefore = await floatBalance(gw);

  // Past the ALERT threshold (2 h) but far short of the terminal bound (72 h):
  // the operator is told while the cause is still fixable, and the order waits.
  await gw.pic.advanceTime(3 * 3_600 * 1_000);
  await gw.pic.tick(5);

  const alert = (await openErrorEntries(gw)).find(
    (e) => 'deliveryDelayed' in e.kind && e.kind.deliveryDelayed.orderId === orderF.id,
  ) as ErrorEntry;
  expect(alert).toBeDefined();
  if ('deliveryDelayed' in alert.kind) {
    expect(alert.kind.deliveryDelayed.stage).toBe('treasuryDelayed');
  }
  expect(await orderStatus(gw, orderF.id)).toBe('awaitingTreasury'); // NOT terminal
  expect(await floatBalance(gw)).toBe(floatBefore); // nothing moved

  // The alert is raised once, not once per sweep — it is a worklist item, not a
  // log line.
  await gw.pic.advanceTime(2 * 3_600 * 1_000);
  await gw.pic.tick(5);
  expect((await openErrorEntries(gw)).filter(
    (e) => 'deliveryDelayed' in e.kind && e.kind.deliveryDelayed.orderId === orderF.id,
  )).toHaveLength(1);

  // THE POINT: fixing the cause delivers it, with no further intervention.
  //
  // The default sweep cadence is hourly, but the CMC rate guard is 15 min — so
  // time cannot be advanced far enough to fire a sweep without staling the rate.
  // Shorten the cadence, which is what an operator working an incident would do
  // anyway.
  expectOk(await gw.asAdmin.set_recovery_interval(60_000_000_000n)); // 60 s
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));
  await gw.pic.advanceTime(90_000);
  await gw.pic.tick(5);
  expect(await tickUntilStatus(gw, orderF.id, ['delivered'])).toBe('delivered');
  expect(await floatBalance(gw)).toBe(floatBefore - ORDER_E8S - ICP_FEE_E8S);

  // The alert closes itself: an open obligation describing a delay that is over
  // would be an orphan on the worklist.
  expect((await openErrorEntries(gw)).find(
    (e) => 'deliveryDelayed' in e.kind && e.kind.deliveryDelayed.orderId === orderF.id,
  )).toBeUndefined();
});

test('15 — operational trail is coherent end-to-end (§4.2)', async () => {
  const audit = await gw.asAdmin.audit_log();
  expect(audit.length).toBeGreaterThan(0);
  for (let i = 1; i < audit.length; i++) {
    expect(audit[i].seq).toBeGreaterThan(audit[i - 1].seq);
  }
  const tags = audit.map((e) => e.tag);
  for (const expected of ['mint.held', 'mint.delivered', 'mint.undeliverable', 'mint.delayed']) {
    expect(tags).toContain(expected);
  }

  // Every queue entry is accounted for: the C undeliverable (open — operator
  // re-delivers off-chain) and the F max-wait (open). Scenario 13's order
  // delivers cleanly across its upgrade, so it contributes no entry.
  // The server-side worklist, which is what an operator actually reads.
  const open = await openErrorEntries(gw);
  // Only the Type 2 undeliverable is still live. Note what is absent and why:
  //  - no terminal escalation for a recoverable delay (scenario 14 recovered),
  //  - and no leftover delay alert either — it closed itself when the order
  //    delivered, so the worklist holds only obligations that are still real.
  expect(open.map((e) => Object.keys(e.kind)[0]).sort()).toEqual(['undeliverable']);
  // Depth agrees with the paged content — the number ops monitors.
  expect((await gw.asAnon.error_queue_depth()).unresolved).toBe(BigInt(open.length));

  // Admin gates on the trail itself.
  await expect(gw.asUser.audit_log()).rejects.toThrow(/not a controller/);
  await expect(gw.asUser.error_queue([], 10n)).rejects.toThrow(/not a controller/);
  await expect(gw.asUser.error_queue_unresolved([], 10n)).rejects.toThrow(/not a controller/);
  // Depth is public — it is the monitoring signal, not the payment references.
  expect((await gw.asAnon.error_queue_depth()).retained).toBeGreaterThan(0n);
});

test('16 — admission gate: no burn-cap headroom refuses the quote before any money moves', async () => {
  // Pause minting. The gate refuses to *quote* rather than accepting money it
  // could only park in #awaitingTreasury and later refund.
  expectOk(await gw.asAdmin.set_treasury_config(PAUSED_TREASURY));

  const refused = expectErr(await gw.asUser.create_order('tier5', { canister: destinationId }));
  expect(refused).toHaveProperty('notAdmitted');
  expect((refused as { notAdmitted: Record<string, unknown> }).notAdmitted)
    .toHaveProperty('burnCapExhausted');

  // can_purchase reports the same refusal, so the frontend can disable the
  // button with a real reason instead of failing at submit time.
  expect(expectErr(await gw.asAnon.can_purchase(TIER_USD_CENTS)))
    .toHaveProperty('burnCapExhausted');

  // Restoring headroom re-opens the rail with no other intervention.
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));
  await ensureRates(gw);
  expectOk(await gw.asAnon.can_purchase(TIER_USD_CENTS));
  const admitted = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  expect(statusKey(admitted.order)).toBe('created');
});

test('17 — admission gate: the per-purchase ceiling bounds tiers and amounts', async () => {
  const { gate } = await gw.asAnon.lifecycle_config();

  // A tier above the ceiling cannot be registered at all — the operator-typo
  // guard. Rejection is atomic, so the live tier list is untouched.
  const tooBig = gate.maxPurchaseUsdCents + 1n;
  expectErr(await gw.asAdmin.set_card_tiers([
    { id: 'tier5', usdCents: TIER_USD_CENTS, paymentLinkUrl: 'https://buy.stripe.com/test_tier5' },
    { id: 'fat', usdCents: tooBig, paymentLinkUrl: 'https://buy.stripe.com/test_fat' },
  ]));
  expect((await gw.asAnon.card_tiers()).map((t) => t.id)).toEqual(['tier5']);

  // And an amount above it is refused at admission.
  expect(expectErr(await gw.asAnon.can_purchase(tooBig))).toEqual({
    amountAboveMax: { usdCents: tooBig, maxUsdCents: gate.maxPurchaseUsdCents },
  });

  // Lowering the ceiling under the live tier makes the gate refuse it, without
  // needing the tier list to be rewritten.
  expectOk(await gw.asAdmin.set_gate_config({ ...gate, maxPurchaseUsdCents: TIER_USD_CENTS - 1n }));
  expectErr(await gw.asUser.create_order('tier5', { canister: destinationId }));
  expectOk(await gw.asAdmin.set_gate_config(gate));
});

test('18 — retention: created → expired → swept, and a late payment names the tombstone', async () => {
  const before = await gw.asAnon.retention_status();

  await ensureRates(gw);
  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const doomed = created.order;
  const doomedRef = created.clientReferenceId;

  // Short bands so the sweep is observable. The horizon must exceed the TTL —
  // band 2 is where a late payment is still honoured.
  expectOk(await gw.asAdmin.set_retention_config({
    orderTtlNs: 3_600_000_000_000n, // 1 h
    retentionHorizonNs: 7_200_000_000_000n, // 2 h
  }));

  // Assertions track `doomed` specifically rather than the global counters:
  // this suite shares one instance, and the §5.2 timer runs the same retention
  // pass on its own hourly cadence over every order earlier scenarios left
  // behind.
  //
  // Band 1: inside the TTL, the order is untouched however often the sweep runs.
  await gw.asAdmin.run_retention();
  expect(await orderStatus(gw, doomed.id)).toBe('created');

  // Band 2: past the TTL the order expires — still payable, record intact.
  await gw.pic.advanceTime(3_600_000 + 60_000); // 1 h 1 min
  await gw.pic.tick();
  await gw.asAdmin.run_retention();
  expect(await orderStatus(gw, doomed.id)).toBe('expired');
  expect(await gw.asAnon.was_swept(doomed.id)).toBe(false);

  // Band 3: past the horizon the record is deleted and the id tombstoned.
  await gw.pic.advanceTime(7_200_000);
  await gw.pic.tick();
  await gw.asAdmin.run_retention();
  expect(await gw.asUser.get_order(doomed.id)).toHaveLength(0);
  expect((await gw.asUser.list_orders()).map((o) => o.id)).not.toContain(doomed.id);
  expect(await gw.asAnon.was_swept(doomed.id)).toBe(true);
  expect((await gw.asAnon.retention_status()).tombstones)
    .toBeGreaterThan(before.tombstones);

  // A Payment Link is permanent, so the payment can still arrive. It becomes
  // Type 1 — money visible, refundable — and the detail says SWEPT, so the
  // operator knows this was a deliberate deletion rather than a forged param.
  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_swept', paymentIntent: 'pi_swept', clientReferenceId: doomedRef,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);
  const entry = (await allErrorEntries(gw)).find(
    (e) => 'unattributed' in e.kind && e.kind.unattributed.paymentRef === 'pi_swept',
  ) as ErrorEntry;
  expect(entry).toBeDefined();
  expect(entry.detail).toContain('SWEPT');
});

test('19 — retention never deletes an order that has touched money', async () => {
  // orderA is #delivered with a mint journal entry; orderC is #errorQueue
  // (Type 2). Both are financial records, so no horizon may remove them.
  await gw.pic.advanceTime(30 * 86_400_000); // 30 days, far past the 2 h horizon
  await gw.pic.tick();
  await gw.asAdmin.run_retention();

  expect(await orderStatus(gw, orderA.id)).toBe('delivered');
  expect(await orderStatus(gw, orderC.id)).toBe('errorQueue');
  expect(await gw.asAnon.was_swept(orderA.id)).toBe(false);
  expect(await gw.asAnon.was_swept(orderC.id)).toBe(false);
  expect((await gw.asAdmin.mint_journal(orderA.id))).toHaveLength(1);

  // The reconciliation lookup still resolves the payment that funded it.
  expect(await gw.asAdmin.order_for_payment('pi_a')).toEqual([orderA.id]);
});

test('20 — an unauthenticated webhook that pays nothing triggers no sweep (DoS)', async () => {
  // The webhook route cannot be authenticated (Stripe can't sign in), so
  // anything it triggers is free for anyone on the internet to invoke. A sweep
  // over every order — which makes paid inter-canister calls per sweepable
  // order — must be reachable only from an actual payment.
  //
  // Observable: the mint pre-gate calls observeFloat, so a sweep that reaches
  // any order's #begin stage moves treasury_status.lastObservedFloat.atNs. Park
  // an order in #awaitingTreasury so a sweep would have work to do, then prove
  // junk traffic leaves that timestamp untouched.
  // Scenario 19 advanced 30 days, which staled both rates. Re-arm the CMC rate
  // and force a refresh through the admin lever — deterministic, and it is the
  // documented ops path for exactly this situation. Note the staleness window is
  // capped at 1 h by validation, so widening it is deliberately not an option.
  await setCmcRate(gw);
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));
  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const held = created.order;

  expectOk(await gw.asAdmin.set_treasury_config(PAUSED_TREASURY));
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_dos', paymentIntent: 'pi_dos', clientReferenceId: created.clientReferenceId,
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, held.id, ['awaitingTreasury'])).toBe('awaitingTreasury');

  const observedBefore = (await gw.asAnon.treasury_status()).lastObservedFloat[0]!.atNs;

  // Four ways to reach the canister without paying anything.
  const body = checkoutSessionBody({
    eventId: 'evt_junk', paymentIntent: 'pi_junk', clientReferenceId: created.clientReferenceId,
    amountCents: TIER_USD_CENTS,
  });
  await deliverWebhook(gw, body, { signature: 't=1,v1=deadbeef' });          // malformed
  await deliverWebhook(gw, body, {
    signature: stripeSignature('whsec_wrong', await nowSeconds(gw.pic), body), // bad MAC
  });
  await gw.asAnon.http_request_update({
    method: 'POST', url: '/webhook/nonexistent', headers: [], body: new Uint8Array(),
  });                                                                          // 404
  await deliverWebhook(gw, chargeRefundedBody('evt_junk2', 'pi_nothing'));     // valid, pays nothing
  await gw.pic.tick(10);

  expect((await gw.asAnon.treasury_status()).lastObservedFloat[0]!.atNs).toBe(observedBefore);
  expect(await orderStatus(gw, held.id)).toBe('awaitingTreasury');

  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));
});

test('21 — status counters are O(1) and reconcile against a full recount', async () => {
  // The public status queries read maintained tallies rather than scanning the
  // order store, so a drift would silently misreport operational state.
  const before = await gw.asAnon.retention_status();
  const rebuilt = await gw.asAdmin.recount_orders();
  const asMap = new Map(rebuilt);

  expect(asMap.get('Created')).toBe(before.openOrders);
  expect(asMap.get('Expired')).toBe(before.expiredOrders);
  expect(asMap.get('AwaitingTreasury'))
    .toBe((await gw.asAnon.treasury_status()).heldOrders);

  // Recount is admin-only: it is the expensive O(n) path.
  await expect(gw.asUser.recount_orders()).rejects.toThrow(/not a controller/);

  // And the canister's own gas is observable, distinct from the ICP float.
  const cycles = await gw.asAnon.cycles_status();
  expect(cycles.balance).toBeGreaterThan(0n);
  expect(cycles.floor).toBeGreaterThan(0n);
});

test('22 — a rate change between order and mint does not move the locked quantity', async () => {
  // The §3 promise: the cycle QUANTITY is locked at creation and the operator
  // absorbs rate movement. This is the operator's actual exposure, and it was
  // untested — every earlier scenario used one unchanging rate.
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));

  // A 2× move exceeds the default 50% delta guard, which scenario 23 covers on
  // purpose. Here the subject is drift, not the guard, so widen it for the
  // duration and restore it at the end.
  const defaultPricing = (await gw.asAnon.pricing_status()).config;
  expectOk(await gw.asAdmin.set_pricing_config({ ...defaultPricing, maxRateDeltaBps: 20_000n }));

  // Both rates must move together. ICP getting dearer in USD without the CMC's
  // XDR/ICP following is not a market move — it is two sources disagreeing, and
  // the cross-check rejects it (scenario 30). Here ICP doubles in USD while the
  // CMC rate rises 1.6×, so the implied XDR/USD shifts 0.769 → 0.615: a real
  // change in what a dollar buys, still inside the plausible band.
  const movedPermyriad = (XDR_PERMYRIAD_PER_ICP * 16n) / 10n;

  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const order = created.order;
  expect(order.lockedCycles).toBe(TIER_LOCKED_CYCLES);
  expect(order.pricing.usdPerIcpMicros).toBe(4_550_000n);

  // The market moves before the payment lands. A fresh quote would now buy 80%
  // as many cycles — this order must not care.
  await setXrcRate(gw, ICP_USD_RATE * 2n);
  await ensureRates(gw, movedPermyriad);
  const moved = (await gw.asAnon.pricing_status()).rates[0]!;
  expect(moved.usdPerIcpMicros).toBe(9_100_000n);
  expect(moved.xdrPermyriadPerIcp).toBe(movedPermyriad);

  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_move', paymentIntent: 'pi_move', clientReferenceId: created.clientReferenceId,
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  const destBefore = await gw.pic.getCyclesBalance(destinationId);
  expect(await tickUntilStatus(gw, order.id, ['delivered'])).toBe('delivered');

  // Delivered at the ORIGINAL locked quantity, and the snapshot still records
  // the rate it was quoted at — not the rate at mint time.
  const delivered = (await gw.pic.getCyclesBalance(destinationId)) - destBefore;
  expect(delivered).toBeGreaterThan((TIER_LOCKED_CYCLES * 999n) / 1000n);
  const stored = (await gw.asUser.get_order(order.id))[0]!;
  expect(stored.lockedCycles).toBe(TIER_LOCKED_CYCLES);
  expect(stored.pricing.usdPerIcpMicros).toBe(4_550_000n);

  // A NEW order at the moved rates buys 80% as much: cycles scale by
  // (P′/P)/(U′/U) = 1.6/2. The locked quantity above is unaffected — only new
  // quotes move, which is the §3 promise.
  const after = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  expect(after.order.lockedCycles).toBe((TIER_LOCKED_CYCLES * 8n) / 10n);

  await setXrcRate(gw, ICP_USD_RATE);
  expectOk(await gw.asAdmin.set_pricing_config(defaultPricing));
  await ensureRates(gw);
});

test('23 — the delta guard rejects an implausible move and keeps serving the old rate', async () => {
  await ensureRates(gw);
  const before = (await gw.asAnon.pricing_status()).rates[0]!;

  // A 10× jump is inside the plausibility band but far beyond the delta bound,
  // so it is refused — and critically, the PREVIOUS rate keeps pricing orders
  // rather than pricing stopping dead.
  await setXrcRate(gw, ICP_USD_RATE * 10n);
  await gw.asAdmin.refresh_rates();

  const status = await gw.asAnon.pricing_status();
  expect(status.lastAttempt[0]!.ok).toBe(false);
  expect(status.lastAttempt[0]!.detail).toContain('delta guard');
  expect(status.rates[0]!.usdPerIcpMicros).toBe(before.usdPerIcpMicros);
  expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));

  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('24 — an implausible rate is refused outright', async () => {
  await ensureRates(gw);
  const before = (await gw.asAnon.pricing_status()).rates[0]!;

  // Below the band floor ($0.10): a decimal-point disaster, not a market move.
  await setXrcResponse(gw, { kind: 'rate', rate: 1_000n, decimals: 9 }); // $0.000001
  await gw.asAdmin.refresh_rates();
  let status = await gw.asAnon.pricing_status();
  expect(status.lastAttempt[0]!.detail).toContain('implausible');
  expect(status.rates[0]!.usdPerIcpMicros).toBe(before.usdPerIcpMicros);

  // A rate that rescales to zero micros is unusable rather than zero-priced.
  await setXrcResponse(gw, { kind: 'rate', rate: 1n, decimals: 12 });
  await gw.asAdmin.refresh_rates();
  status = await gw.asAnon.pricing_status();
  expect(status.lastAttempt[0]!.ok).toBe(false);
  expect(status.rates[0]!.usdPerIcpMicros).toBe(before.usdPerIcpMicros);

  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('25 — every XRC failure mode fails closed with a distinguishable reason', async () => {
  // An operator has to tell "XRC is rate-limiting us" from "we are out of
  // cycles" from "the sources disagreed" — the responses differ.
  for (const error of ['Pending', 'RateLimited', 'NotEnoughCycles', 'CryptoBaseAssetNotFound']) {
    await setXrcResponse(gw, { kind: 'error', error });
    await gw.asAdmin.refresh_rates();
    const status = await gw.asAnon.pricing_status();
    expect(status.lastAttempt[0]!.ok).toBe(false);
    expect(status.lastAttempt[0]!.detail).toContain(error);
  }

  // A prior good rate keeps serving until it goes stale, then orders refuse.
  await gw.pic.advanceTime(3_700_000); // past any allowed staleness window
  await gw.pic.tick(3);
  expect(expectErr(await gw.asUser.create_order('tier5', { canister: destinationId })))
    .toEqual({ rateUnavailable: null });

  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
  expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
});

test('26 — a rate reported with different decimals prices identically', async () => {
  // The mock reports 9 decimals, so the other toMicros branches would never run
  // against a real canister otherwise. Same price, different encoding, same quote.
  await setXrcResponse(gw, { kind: 'rate', rate: 4_550_000n, decimals: 6 });
  await ensureRates(gw);
  expect((await gw.asAnon.pricing_status()).rates[0]!.usdPerIcpMicros).toBe(4_550_000n);
  const sixDecimals = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  expect(sixDecimals.order.lockedCycles).toBe(TIER_LOCKED_CYCLES);

  await setXrcResponse(gw, { kind: 'rate', rate: 4_550_000_000_000n, decimals: 12 });
  await ensureRates(gw);
  const twelveDecimals = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  expect(twelveDecimals.order.lockedCycles).toBe(TIER_LOCKED_CYCLES);

  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('27 — the rate timer re-arms across an upgrade with no manual kick', async () => {
  // Timers are deactivated when the Wasm module changes, so a canister that
  // does not re-arm them silently stops refreshing. Pricing depends on that
  // timer, so this is the regression test for it — the mirror of scenario 12's
  // recovery-timer assertion.
  await ensureRates(gw);
  const before = (await gw.asAnon.pricing_status()).rates[0]!.fetchedAtNs;

  await upgradeBackendMidFlight(gw);

  // The cache is persistent, so the price survives the upgrade itself.
  expect((await gw.asAnon.pricing_status()).rates[0]!.fetchedAtNs).toBe(before);

  // And the timer is alive again: advancing past one interval refreshes with no
  // admin call. The CMC rate is re-armed first because it carries its own guard.
  await setCmcRate(gw);
  await tickRateTimer(gw);
  const after = (await gw.asAnon.pricing_status()).rates[0]!.fetchedAtNs;
  expect(after).toBeGreaterThan(before);

  // Orders work off the timer-refreshed rate, with nothing manual in between.
  expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
});

test('28 — the own-cycles floor refuses orders against a real balance', async () => {
  // The gate's canister-cycles check guards the resource whose exhaustion
  // uninstalls the canister and takes the order store with it. PocketIC can add
  // cycles but not remove them, so the floor is raised above the live balance
  // instead — the same code path, reading a real `Cycles.balance()`.
  await ensureRates(gw);
  const { balance, floor } = await gw.asAnon.cycles_status();
  expect(balance).toBeGreaterThan(0n);

  const gate = (await gw.asAnon.lifecycle_config()).gate;
  expectOk(await gw.asAdmin.set_gate_config({ ...gate, minCanisterCycles: balance * 2n }));

  const refused = expectErr(await gw.asUser.create_order('tier5', { canister: destinationId }));
  expect(refused).toHaveProperty('notAdmitted');
  const reason = (refused as { notAdmitted: Record<string, { balance: bigint; min: bigint }> }).notAdmitted;
  expect(reason).toHaveProperty('canisterCyclesLow');
  // The refusal carries both numbers, so an operator sees how far short it is.
  expect(reason.canisterCyclesLow.min).toBe(balance * 2n);
  expect(reason.canisterCyclesLow.balance).toBeGreaterThan(0n);

  // Both rails are gated, not just the card one — they share the float.
  expect(expectErr(await gw.asAnon.can_purchase(TIER_USD_CENTS)))
    .toHaveProperty('canisterCyclesLow');

  expectOk(await gw.asAdmin.set_gate_config({ ...gate, minCanisterCycles: floor }));
  expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
});

test('29 — pausing the rail stops rate refreshes but never strands a paid order', async () => {
  // An interaction worth pinning: refreshes only run while a rail is live, so
  // emptying the tier list (the documented rail-pause lever) also stops the
  // canister spending cycles on rates. A paid order must still deliver, because
  // money-out reads the CMC directly and never touches the rate cache.
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));

  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const inFlight = created.order;
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_pause', paymentIntent: 'pi_pause', clientReferenceId: created.clientReferenceId,
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });

  // Pause: empty tiers. New card orders are refused outright.
  const tiers = await gw.asAnon.card_tiers();
  expectOk(await gw.asAdmin.set_card_tiers([]));
  expect(expectErr(await gw.asUser.create_order('tier5', { canister: destinationId })))
    .toEqual({ unknownTier: 'tier5' });

  // And the refresh timer goes quiet — a dark gateway spends nothing.
  const attemptBefore = (await gw.asAnon.pricing_status()).lastAttempt[0]!.atNs;
  await tickRateTimer(gw);
  expect((await gw.asAnon.pricing_status()).lastAttempt[0]!.atNs).toBe(attemptBefore);

  // But the already-paid order still delivers: money-out uses the CMC, not the
  // rate cache, so a paused rail cannot strand money already taken.
  await setCmcRate(gw);
  const driven = expectOk(await gw.asAdmin.process_order(inFlight.id));
  expect(statusKey(driven)).toBe('delivered');

  expectOk(await gw.asAdmin.set_card_tiers(tiers));
  await ensureRates(gw);
});

test('30 — the rate pair is cross-checked: a plausible-but-wrong ICP price is refused', async () => {
  // The guard that stops us trusting one provider. $45.50/ICP is inside the wide
  // ICP-price band, so nothing else catches it — but against the CMC's
  // 3.5 XDR/ICP it implies 0.077 XDR/USD, which is absurd for an IMF basket.
  await ensureRates(gw);
  const before = (await gw.asAnon.pricing_status()).rates[0]!;

  // The delta guard would catch a 10× jump first, so widen it to isolate the
  // cross-check. That is not artificial: the cross-check's real job is the case
  // where there is no delta baseline — a fresh canister whose very FIRST XRC
  // reading is wrong by a factor — and when the CMC rate is the one that moved.
  const defaults = (await gw.asAnon.pricing_status()).config;
  expectOk(await gw.asAdmin.set_pricing_config({ ...defaults, maxRateDeltaBps: 100_000n }));

  await setXrcResponse(gw, { kind: 'rate', rate: ICP_USD_RATE * 10n, decimals: 9 });
  await gw.asAdmin.refresh_rates();

  const status = await gw.asAnon.pricing_status();
  expect(status.lastAttempt[0]!.ok).toBe(false);
  expect(status.lastAttempt[0]!.detail).toContain('rate pair disagrees');
  // The previous good pair keeps serving rather than pricing stopping dead.
  expect(status.rates[0]!.usdPerIcpMicros).toBe(before.usdPerIcpMicros);
  expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));

  // Symmetric: 10x too low implies 7.69 XDR/USD, equally absurd.
  await setXrcResponse(gw, { kind: 'rate', rate: ICP_USD_RATE / 10n, decimals: 9 });
  await gw.asAdmin.refresh_rates();
  expect((await gw.asAnon.pricing_status()).lastAttempt[0]!.detail).toContain('rate pair disagrees');

  expectOk(await gw.asAdmin.set_pricing_config(defaults));
  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('31 — a single-source rate is refused, because XRC cannot flag it itself', async () => {
  // XRC returns Ok for a one-exchange rate: a single rate cannot disagree with
  // itself, so InconsistentRatesReceived never fires. This is the only guard
  // that sees the degenerate case.
  await ensureRates(gw);
  const before = (await gw.asAnon.pricing_status()).rates[0]!;

  await setXrcResponse(gw, {
    kind: 'rate', rate: ICP_USD_RATE, decimals: 9,
    receivedRates: 1n, queriedSources: 6n,
  });
  await gw.asAdmin.refresh_rates();

  const status = await gw.asAnon.pricing_status();
  expect(status.lastAttempt[0]!.ok).toBe(false);
  expect(status.lastAttempt[0]!.detail).toContain('too few rate sources');
  expect(status.lastAttempt[0]!.detail).toContain('1 of 6');
  expect(status.rates[0]!.fetchedAtNs).toBe(before.fetchedAtNs);

  // Two sources clears the default threshold.
  await setXrcResponse(gw, {
    kind: 'rate', rate: ICP_USD_RATE, decimals: 9,
    receivedRates: 2n, queriedSources: 6n,
  });
  await ensureRates(gw);
  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  // The quality signal reaches the order, so a buyer can see how thin it was.
  expect(created.order.pricing.rateReceivedRates).toBe(2n);
  expect(created.order.pricing.rateQueriedSources).toBe(6n);

  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('32 — rates going bad after payment cannot affect an order already #paid', async () => {
  // The question this answers: what happens if rates go bad while an order is
  // #paid? Nothing. Money-out reads the CMC directly and never touches the rate
  // cache, so the locked quantity is delivered regardless.
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));

  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const order = created.order;
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_ratebad', paymentIntent: 'pi_ratebad', clientReferenceId: created.clientReferenceId,
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });

  // Break the XRC completely while the order is in flight.
  await setXrcResponse(gw, { kind: 'error', error: 'InconsistentRatesReceived' });
  await gw.asAdmin.refresh_rates();
  expect((await gw.asAnon.pricing_status()).lastAttempt[0]!.ok).toBe(false);

  // The order still delivers its locked quantity — no dependency on the XRC.
  // The webhook's own detached kick drives it, so let that finish rather than
  // racing it with process_order (which would answer #inFlight).
  expect(await tickUntilStatus(gw, order.id, ['delivered'])).toBe('delivered');
  const settled = (await gw.asUser.get_order(order.id))[0]!;
  expect(settled.lockedCycles).toBe(TIER_LOCKED_CYCLES);
  expect((await gw.asAdmin.mint_journal(order.id))[0]!.cyclesMinted).toEqual([TIER_LOCKED_CYCLES]);

  // New orders are refused once the cached rate lapses — the fail-closed half.
  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('33 — an unmintable order alerts and waits; only abandon_order ends it', async () => {
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));

  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const stuck = created.order;

  // Let the CMC rate go stale BEFORE payment (its guard is 15 min) so the mint
  // kick cannot proceed and the order parks in #paid.
  await gw.pic.advanceTime(20 * 60 * 1_000);
  await gw.pic.tick(3);
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_stuck', paymentIntent: 'pi_stuck', clientReferenceId: created.clientReferenceId,
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  await gw.pic.tick(10);
  expect(await orderStatus(gw, stuck.id)).toBe('paid');
  expect((await gw.asAnon.treasury_status()).paidOrders).toBeGreaterThanOrEqual(1n);

  // Past the alert threshold but short of the terminal bound.
  await gw.pic.advanceTime(3 * 3_600 * 1_000);
  await gw.pic.tick(5);
  const alert = (await openErrorEntries(gw)).find(
    (e) => 'deliveryDelayed' in e.kind && e.kind.deliveryDelayed.orderId === stuck.id,
  ) as ErrorEntry;
  expect(alert).toBeDefined();
  if ('deliveryDelayed' in alert.kind) {
    expect(alert.kind.deliveryDelayed.stage).toBe('mintDelayed');
  }
  expect(await orderStatus(gw, stuck.id)).toBe('paid');

  // Fixing the cause delivers it, automatically, on the next sweep.
  expectOk(await gw.asAdmin.set_recovery_interval(60_000_000_000n));
  await ensureRates(gw);
  await gw.pic.advanceTime(90_000);
  await gw.pic.tick(5);
  expect(await tickUntilStatus(gw, stuck.id, ['delivered'])).toBe('delivered');
});

test('34 — abandon_order is the only terminal give-up, and it demands a reason', async () => {
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));
  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const doomed = created.order;

  // Not abandonable before money is involved — nothing to decide about.
  expectErr(await gw.asAdmin.abandon_order(doomed.id, 'too early'));

  expectOk(await gw.asAdmin.set_treasury_config(PAUSED_TREASURY));
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_aband', paymentIntent: 'pi_aband', clientReferenceId: created.clientReferenceId,
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, doomed.id, ['awaitingTreasury'])).toBe('awaitingTreasury');

  // Admin-gated, and a reason is mandatory so the trail records why.
  await expect(gw.asUser.abandon_order(doomed.id, 'nope')).rejects.toThrow(/not a controller/);
  expectErr(await gw.asAdmin.abandon_order(doomed.id, ''));

  const abandoned = expectOk(await gw.asAdmin.abandon_order(doomed.id, 'buyer asked to cancel'));
  expect(statusKey(abandoned)).toBe('errorQueue');

  const entry = (await openErrorEntries(gw)).find(
    (e) => 'abandoned' in e.kind && e.kind.abandoned.orderId === doomed.id,
  ) as ErrorEntry;
  expect(entry).toBeDefined();
  if ('abandoned' in entry.kind) {
    expect(entry.kind.abandoned.reason).toBe('buyer asked to cancel');
  }

  // The audit trail names WHO decided, not just that it happened.
  const audit = await gw.asAdmin.audit_log();
  const line = audit.find((e) => e.tag === 'order.abandoned' && e.detail.includes(doomed.id));
  expect(line).toBeDefined();
  expect(line!.detail).toContain('by ');
  expect(line!.detail).toContain('buyer asked to cancel');

  // Terminal: a second abandon is refused.
  expectErr(await gw.asAdmin.abandon_order(doomed.id, 'again'));

  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));
  await ensureRates(gw);
});

test('35 — past the max-wait bound the order terminates so the operator refunds (§5.3)', async () => {
  // The spec's max-wait bound, and the reason it exists: a buyer left waiting
  // indefinitely files a chargeback, which costs the operator more than a refund
  // (dispute fees, dispute process, Stripe account health). By 72 h the cause is
  // structural, not transient, so refunding proactively is the protective act.
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));
  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const doomed = created.order;

  expectOk(await gw.asAdmin.set_treasury_config(PAUSED_TREASURY));
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_maxwait', paymentIntent: 'pi_maxwait', clientReferenceId: created.clientReferenceId,
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, doomed.id, ['awaitingTreasury'])).toBe('awaitingTreasury');

  const floatBefore = await floatBalance(gw);

  // Alert first (2 h), then terminate (72 h) — two tiers, one timeline.
  await gw.pic.advanceTime(3 * 3_600 * 1_000);
  await gw.pic.tick(5);
  expect(await orderStatus(gw, doomed.id)).toBe('awaitingTreasury');

  await gw.pic.advanceTime(70 * 3_600 * 1_000);
  await gw.pic.tick(5);
  expect(await tickUntilStatus(gw, doomed.id, ['errorQueue'])).toBe('errorQueue');

  const entry = (await openErrorEntries(gw)).find(
    (e) => 'stuckMint' in e.kind && e.kind.stuckMint.orderId === doomed.id,
  ) as ErrorEntry;
  expect(entry).toBeDefined();
  if ('stuckMint' in entry.kind) {
    expect(entry.kind.stuckMint.stage).toBe('treasuryWaitExceeded');
  }
  // The money position is stated so the operator knows the action: refund.
  expect(entry.detail).toContain('nothing minted');
  expect(entry.detail).toContain('refund');
  expect(await floatBalance(gw)).toBe(floatBefore); // nothing moved

  // The superseded delay alert was closed, not left orphaned alongside it.
  expect((await openErrorEntries(gw)).filter(
    (e) => 'deliveryDelayed' in e.kind && e.kind.deliveryDelayed.orderId === doomed.id,
  )).toHaveLength(0);

  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));
  await ensureRates(gw);
});

test('36 — attach_payment rescues a charge the webhook never delivered', async () => {
  // The one card-rail failure that otherwise has NO recovery: Stripe retries a
  // failed webhook for ~3 days then stops, and we hold no API key so we never
  // poll. Past that horizon the charge exists in Stripe with no on-chain trace,
  // the buyer's money is gone, and their order reads "Awaiting payment" forever.
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));

  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const orphan = created.order;
  // No webhook is delivered at all — this is the whole point.
  expect(await orderStatus(gw, orphan.id)).toBe('created');
  expect(orphan.paidUsdCents).toEqual([]);

  // Admin-gated: this creates money, so it is not a user-facing lever.
  await expect(gw.asUser.attach_payment('pi_lost', orphan.id, TIER_USD_CENTS))
    .rejects.toThrow(/not a controller/);

  const attached = expectOk(await gw.asAdmin.attach_payment('pi_lost', orphan.id, TIER_USD_CENTS));
  expect(statusKey(attached)).toBe('paid');
  // The actual amount paid is now ON the order, not only in a ring buffer.
  expect(attached.paidUsdCents).toEqual([TIER_USD_CENTS]);
  expect(attached.lockedCycles).toBe(TIER_LOCKED_CYCLES);

  // Reconciliation works both ways afterwards.
  expect(await gw.asAdmin.order_for_payment('pi_lost')).toEqual([orphan.id]);

  // The audit trail names who did it and what it was worth.
  const line = (await gw.asAdmin.audit_log()).find(
    (e) => e.tag === 'payment.attached' && e.detail.includes(orphan.id),
  );
  expect(line).toBeDefined();
  expect(line!.detail).toContain('by ');
  expect(line!.detail).toContain('pi_lost');

  // And it delivers through the ordinary money-out path.
  expect(await tickUntilStatus(gw, orphan.id, ['delivered'])).toBe('delivered');
});

test('37 — a charge can never be credited twice, by either route', async () => {
  // The dangerous property of a money-creating lever. attach_payment shares the
  // webhook's dedup set, so the same payment_intent cannot be credited via both.
  await ensureRates(gw);
  const first = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const second = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));

  expectOk(await gw.asAdmin.attach_payment('pi_once', first.order.id, TIER_USD_CENTS));

  // Same intent, different order → refused.
  const reused = expectErr(await gw.asAdmin.attach_payment('pi_once', second.order.id, TIER_USD_CENTS));
  expect(reused).toHaveProperty('alreadyCredited');
  expect(await orderStatus(gw, second.order.id)).toBe('created');

  // And the webhook cannot credit it either — one dedup set, both routes.
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_once', paymentIntent: 'pi_once', clientReferenceId: second.clientReferenceId,
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  expect(await orderStatus(gw, second.order.id)).toBe('created');

  // Attaching to an order past money-in is refused rather than double-crediting.
  const late = expectErr(await gw.asAdmin.attach_payment('pi_other', first.order.id, TIER_USD_CENTS));
  expect(late).toHaveProperty('notClaimable');
});

test('38 — attaching an identified payment closes its Type 1 obligation', async () => {
  // Turns "refund and ask them to re-order at today's price" into "deliver what
  // they bought" — and the open obligation must not survive as an orphan.
  await ensureRates(gw);
  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));

  // A payment arrives with an unusable reference → Type 1 unattributed.
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_mangled', paymentIntent: 'pi_mangled', clientReferenceId: 'not-a-reference',
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  const obligation = (await openErrorEntries(gw)).find(
    (e) => 'unattributed' in e.kind && e.kind.unattributed.paymentRef === 'pi_mangled',
  ) as ErrorEntry;
  expect(obligation).toBeDefined();

  // The operator identifies the buyer in Stripe and attaches it.
  expectOk(await gw.asAdmin.attach_payment('pi_mangled', created.order.id, TIER_USD_CENTS));

  // The Type 1 entry is resolved, not left open describing a settled matter.
  expect((await openErrorEntries(gw)).find((e) => e.id === obligation.id)).toBeUndefined();
  expect(await tickUntilStatus(gw, created.order.id, ['delivered'])).toBe('delivered');
});

test('39 — attach_payment enforces the same amount rules as the webhook', async () => {
  await ensureRates(gw);
  const { gate } = await gw.asAnon.lifecycle_config();

  const created = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  // Above the per-purchase ceiling — repricing is an upward path, so a manual
  // rescue must not become a way around the bound.
  const over = expectErr(await gw.asAdmin.attach_payment(
    'pi_toobig', created.order.id, gate.maxPurchaseUsdCents + 1n,
  ));
  expect(over).toHaveProperty('aboveCeiling');

  // Below the fee floor — nothing can be minted from it.
  const tiny = expectErr(await gw.asAdmin.attach_payment('pi_tiny', created.order.id, 5n));
  expect(tiny).toHaveProperty('belowFeeFloor');

  // A refused attach must not consume the intent, or a corrected retry would be
  // permanently blocked.
  const fixed = expectOk(await gw.asAdmin.attach_payment('pi_toobig', created.order.id, TIER_USD_CENTS));
  expect(statusKey(fixed)).toBe('paid');

  // A different amount than quoted is repriced from the order's OWN snapshot.
  const other = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  const repriced = expectOk(await gw.asAdmin.attach_payment('pi_double', other.order.id, TIER_USD_CENTS * 2n));
  expect(repriced.paidUsdCents).toEqual([TIER_USD_CENTS * 2n]);
  expect(repriced.lockedCycles).toBeGreaterThan(TIER_LOCKED_CYCLES);
  expect(await tickUntilStatus(gw, other.order.id, ['delivered'])).toBe('delivered');
});
