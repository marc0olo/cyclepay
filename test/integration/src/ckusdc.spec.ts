/// PocketIC integration suite — the ck-USDC-rail go-live bar (task 15, §6.2).
///
/// Runs against its own instance (vitest runs spec files sequentially), with
/// the REAL ic-icrc1-ledger (pinned release, sha256-verified by the pretest
/// script) installed at the exact mainnet ck-USDC id CkUsdc.mo pins — on the
/// fiduciary subnet, whose canister range mirrors mainnet's. Coverage:
/// fail-closed rail config, the shared §3 quote path with this rail's fee
/// formula, approve→pull happy path, §6.2 amount-short mismatch (definite
/// rejections drop the intent), §5.1 money-IN replay (upgrade-mid-pull →
/// Duplicate recovery, user debited exactly once), stale-intent escalation +
/// operator reset levers, treasury interplay (cap-0 hold → resume), and the
/// hold-ckUSDC withdraw lever.
import { afterAll, beforeAll, expect, test } from 'vitest';
import { Principal } from '@icp-sdk/core/principal';
import type { Actor } from '@dfinity/pic';
import {
  CK_ORDER_APPROVE_UNITS, CK_ORDER_E8S, CK_ORDER_LOCKED_CYCLES,
  CK_ORDER_UNITS, CK_ORDER_USD_CENTS, CKUSDC_FEE_UNITS,
  ICP_FEE_E8S, XDR_PERMYRIAD_PER_ICP, admin, poorUser, user,
  Gateway, setupGateway, teardownGateway, upgradeBackendMidFlight,
  setCmcRate, fundFloat, floatBalance, setXrcRate, warmRates, ensureRates,
  CkLedger, installCkUsdcLedger, approveCkUsdc, ckBalance,
  orderStatus, statusKey, tickUntilStatus, expectOk, expectErr,
} from './harness';
import { backendIdlFactory } from './idl';
import type { BackendService, ErrorEntry, Order } from './types';

let gw: Gateway;
let ck: CkLedger;
let asPoor: Actor<BackendService>;
/// Destination canister for #canister deliveries.
let destinationId: Principal;

// Orders created along the way (suite-global on purpose — later scenarios
// replay and operate on earlier ones).
let order1: Order; // amount-short → happy path via AwaitingTreasury resume
let order2: Order; // §5.1 upgrade-mid-pull replay (Duplicate recovery)
let order3: Order; // stale-intent escalation → operator reset → completion

const FLOAT_E8S = 5_000_000_000n; // 50 ICP
const USER_CK_UNITS = 1_000_000_000n; // $1000 of ck-USDC
const POOR_CK_UNITS = 3_000_000n; // $3 — can approve, cannot cover a $5 pull
/// One e8s mints exactly `permyriad` cycles, so the ceil overshoot
/// (25_000 cycles here) stays in the app balance as operator-side dust (§3).
const CK_ORDER_MINTED_CYCLES = CK_ORDER_E8S * XDR_PERMYRIAD_PER_ICP;

const RAIL_CONFIG = {
  minUsdCents: 100n,
  maxUsdCents: 100_000n,
  feeBps: 0n,
  feeFixedCents: 0n,
  ledgerFeeUnits: CKUSDC_FEE_UNITS,
};

/// Cap sized so the admission gate admits and mints can proceed.
const WORKING_TREASURY = {
  burnCapE8s: 10_000_000_000n, // 100 ICP / 24 h
  burnWindowNs: 86_400_000_000_000n,
  lowFloatThresholdE8s: 0n,
  maxHoldNs: 259_200_000_000_000n, // 72 h
};

/// The §5.3 pause lever: cap 0 holds every mint.
const PAUSED_TREASURY = { ...WORKING_TREASURY, burnCapE8s: 0n };

beforeAll(async () => {
  gw = await setupGateway();
  ck = await installCkUsdcLedger(gw, [
    [user.getPrincipal(), USER_CK_UNITS],
    [poorUser.getPrincipal(), POOR_CK_UNITS],
  ]);
  asPoor = gw.pic.createActor<BackendService>(backendIdlFactory, gw.backendId);
  asPoor.setIdentity(poorUser);
  const [appSubnet] = await gw.pic.getApplicationSubnets();
  destinationId = await gw.pic.createCanister({
    targetSubnetId: appSubnet.id,
    cycles: 1_000_000_000_000n,
  });
  await setCmcRate(gw);
  await fundFloat(gw, FLOAT_E8S);
  // DFINITY's xrc_mock supplies the ICP price; the refresh timer caches it
  // alongside the CMC rate. Installing it here is enough — the timer will not
  // actually refresh until a rail is enabled (`railsLive`), which ck-01 does,
  // so ck-03 warms the cache once there is something to sell.
  await setXrcRate(gw);
  // The admission gate refuses to quote with no burn-cap headroom, and the
  // fail-closed default cap is 0 — so a sized cap is a precondition for
  // creating any order on either rail. ck-06 re-sizes it as part of its own
  // treasury-interplay assertions.
  expectOk(await gw.asAdmin.set_treasury_config({
    burnCapE8s: 10_000_000_000n, // 100 ICP / 24 h
    burnWindowNs: 86_400_000_000_000n,
    lowFloatThresholdE8s: 0n,
    maxHoldNs: 259_200_000_000_000n, // 72 h
  }));
});

afterAll(async () => {
  if (gw) await teardownGateway(gw);
});

/// Tick until the §5.1 pull intent is journaled but no block is recorded —
/// the window where the ledger call's fate is in flight.
async function tickUntilPullIntent(orderId: string, maxTicks = 200): Promise<void> {
  for (let i = 0; i < maxTicks; i++) {
    const entry = await gw.asAdmin.ck_usdc_pull(orderId);
    if (entry.length === 1) {
      if (entry[0].blockIndex.length === 1) {
        throw new Error('pull completed before the suite could interrupt it');
      }
      return;
    }
    await gw.pic.tick();
  }
  throw new Error(`pull intent for ${orderId} never appeared`);
}

test('ck-01 — rail fails closed by default; config is admin-gated and validated (§6.2/§7)', async () => {
  // maxUsdCents = 0 default: the rail is disabled until the operator sizes it.
  const disabled = await gw.asUser.create_ck_usdc_order(
    CK_ORDER_USD_CENTS, { canister: destinationId },
  );
  expect(expectErr(disabled)).toEqual({ railDisabled: null });

  // Anonymous callers can never own orders.
  const anon = await gw.asAnon.create_ck_usdc_order(
    CK_ORDER_USD_CENTS, { canister: destinationId },
  );
  expect(expectErr(anon)).toEqual({ anonymous: null });

  // Admin gate + atomic validation.
  await expect(gw.asUser.set_ck_usdc_config(RAIL_CONFIG)).rejects.toThrow(/not a controller/);
  expect(expectErr(await gw.asAdmin.set_ck_usdc_config({
    ...RAIL_CONFIG, feeBps: 10_000n,
  }))).toEqual({ feeBpsTooHigh: null });
  expect(expectErr(await gw.asAdmin.set_ck_usdc_config({
    ...RAIL_CONFIG, minUsdCents: 200n, maxUsdCents: 100n,
  }))).toEqual({ minAboveMax: null });

  expectOk(await gw.asAdmin.set_ck_usdc_config(RAIL_CONFIG));
  // Bounds and fee formula are public (transparency stance).
  expect(await gw.asAnon.ck_usdc_config()).toEqual(RAIL_CONFIG);
});

test('ck-02 — amount bounds fail closed before any quote (§6.2)', async () => {
  const zero = await gw.asUser.create_ck_usdc_order(0n, { canister: destinationId });
  expect(expectErr(zero)).toEqual({ zeroAmount: null });
  const low = await gw.asUser.create_ck_usdc_order(99n, { canister: destinationId });
  expect(expectErr(low)).toEqual({ belowMinimum: RAIL_CONFIG.minUsdCents });
  const high = await gw.asUser.create_ck_usdc_order(100_001n, { canister: destinationId });
  expect(expectErr(high)).toEqual({ aboveMaximum: RAIL_CONFIG.maxUsdCents });
});

test('ck-03 — order priced through the shared §3 quote path with this rail\'s fee formula', async () => {
  // ck-01 enabled the rail, so the refresh timer will now do work.
  await warmRates(gw);

  const created = expectOk(await gw.asUser.create_ck_usdc_order(
    CK_ORDER_USD_CENTS, { canister: destinationId },
  ));
  order1 = created.order;

  // 500¢ at the rail's 0 bps / 0¢ formula nets 500¢ — at $4.55/ICP and
  // 3.5 XDR/ICP that locks 3_846_153_846_153 cycles. The card rail's same 500¢
  // tier nets 455¢ → 3.5 T: one quote path, per-rail fee formulas, and this rail
  // buys more because no card processor takes a cut.
  expect(order1.lockedCycles).toBe(CK_ORDER_LOCKED_CYCLES);
  // Same rate snapshot as the card rail — one shared cache.
  expect(order1.pricing.usdPerIcpMicros).toBe(4_550_000n);
  expect(order1.pricing.xdrPermyriadPerIcp).toBe(XDR_PERMYRIAD_PER_ICP);
  expect(order1.rail).toEqual({ ckUsdc: null });
  expect(statusKey(order1)).toBe('created');
  // The exact pull and the approval bound the frontend shows the user.
  expect(created.amountUnits).toBe(CK_ORDER_UNITS);
  expect(created.approveUnits).toBe(CK_ORDER_APPROVE_UNITS);

  // §2 authz unchanged on this rail: non-owners see nothing.
  expect(await gw.asUser.get_order(order1.id)).toHaveLength(1);
  expect(await gw.asAdmin.get_order(order1.id)).toHaveLength(0);
});

test('ck-04 — claim guards: authz, rail match, and the no-approval definite rejection', async () => {
  expect(expectErr(await gw.asAnon.claim_ck_usdc_order(order1.id))).toEqual({ anonymous: null });
  // Not the owner → notFound: existence is not revealed.
  expect(expectErr(await gw.asAdmin.claim_ck_usdc_order(order1.id))).toEqual({ notFound: null });
  expect(expectErr(await gw.asUser.claim_ck_usdc_order(
    '00000000000000000000000000000000',
  ))).toEqual({ notFound: null });

  // A card order cannot be claimed through the ck-USDC pull.
  expectOk(await gw.asAdmin.set_card_tiers([
    { id: 'tier5', usdCents: 500n, paymentLinkUrl: 'https://buy.stripe.com/test_tier5' },
  ]));
  const cardOrder = expectOk(await gw.asUser.create_order('tier5', { canister: destinationId }));
  expect(expectErr(await gw.asUser.claim_ck_usdc_order(cardOrder.order.id)))
    .toEqual({ wrongRail: null });

  // No approval at all: the ledger's dedup-first semantics prove nothing
  // moved, so the intent is dropped and the error is user-actionable.
  expect(expectErr(await gw.asUser.claim_ck_usdc_order(order1.id))).toEqual({
    insufficientAllowance: { allowance: 0n, required: CK_ORDER_APPROVE_UNITS },
  });
  expect(await gw.asAdmin.ck_usdc_pull(order1.id)).toHaveLength(0); // intent dropped
  expect(await orderStatus(gw, order1.id)).toBe('created');

  // The money-in journal is an admin surface.
  await expect(gw.asUser.ck_usdc_pull(order1.id)).rejects.toThrow(/not a controller/);
});

test('ck-05 — §6.2 amount-short mismatch, then approve→pull lands the order Paid', async () => {
  const userBefore = await ckBalance(ck, user.getPrincipal());

  // order1 was created while the cap had headroom (the admission gate requires
  // it). Pause minting now so money-IN can be observed settling on its own,
  // with money-OUT held — ck-06 then resumes it.
  expectOk(await gw.asAdmin.set_treasury_config(PAUSED_TREASURY));

  // Approval covers the amount but not the ledger fee — the §6.2 mismatch.
  await approveCkUsdc(ck.asUser, gw.backendId, CK_ORDER_UNITS);
  expect(expectErr(await gw.asUser.claim_ck_usdc_order(order1.id))).toEqual({
    insufficientAllowance: { allowance: CK_ORDER_UNITS, required: CK_ORDER_APPROVE_UNITS },
  });
  expect(await gw.asAdmin.ck_usdc_pull(order1.id)).toHaveLength(0); // dropped again
  expect(await orderStatus(gw, order1.id)).toBe('created');

  // Approve at least `required`, retry — the clean §6.2 recovery.
  await approveCkUsdc(ck.asUser, gw.backendId, CK_ORDER_APPROVE_UNITS);
  const paid = expectOk(await gw.asUser.claim_ck_usdc_order(order1.id));
  expect(statusKey(paid)).toBe('paid');

  // Exactly one pull: amount + ledger fee left the user, the amount landed
  // in the canister's account (hold-ckUSDC posture §6.2), the allowance is
  // spent, and the journal ties the ledger block to the order.
  expect(await ckBalance(ck, user.getPrincipal())).toBe(
    userBefore - CK_ORDER_APPROVE_UNITS - 2n * CKUSDC_FEE_UNITS, // 2 approve fees
  );
  expect(await ckBalance(ck, gw.backendId)).toBe(CK_ORDER_UNITS);
  expect((await ck.query.icrc2_allowance({
    account: { owner: user.getPrincipal(), subaccount: [] },
    spender: { owner: gw.backendId, subaccount: [] },
  })).allowance).toBe(0n);
  const pull = (await gw.asAdmin.ck_usdc_pull(order1.id))[0]!;
  expect(pull.blockIndex).toHaveLength(1);
  expect(pull.intent.amountUnits).toBe(CK_ORDER_UNITS);
  expect(pull.intent.memo).toHaveLength(32); // order id UTF-8, the audit link

  // Money-out is rail-agnostic from #paid: the detached mint kick runs the
  // pre-gate and the paused cap holds it (§5.3).
  expect(await tickUntilStatus(gw, order1.id, ['awaitingTreasury'])).toBe('awaitingTreasury');
  expect((await gw.asAnon.treasury_status()).heldOrders).toBe(1n);
});

test('ck-06 — treasury interplay: cap sized → held ck order resumes → real CMC mint delivers (§5.3/§5)', async () => {
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));

  const floatBefore = await floatBalance(gw);
  const destBefore = await gw.pic.getCyclesBalance(destinationId);

  const driven = expectOk(await gw.asAdmin.process_order(order1.id));
  expect(statusKey(driven)).toBe('delivered');

  // Exactly one float debit, and the §5.3 window recorded the consumption.
  expect(await floatBalance(gw)).toBe(floatBefore - CK_ORDER_E8S - ICP_FEE_E8S);
  expect((await gw.asAnon.treasury_status()).burnedInWindowE8s).toBe(CK_ORDER_E8S);
  expect((await gw.asAnon.treasury_status()).heldOrders).toBe(0n);

  // The ceil(e8s) mint overshoots the locked quantity by dust that stays
  // operator-side; the forward deposits exactly the locked cycles.
  const journal = (await gw.asAdmin.mint_journal(order1.id))[0]!;
  expect(journal.cyclesMinted).toEqual([CK_ORDER_MINTED_CYCLES]);
  expect(statusKey(journal)).toBe('delivered');
  const delivered = (await gw.pic.getCyclesBalance(destinationId)) - destBefore;
  expect(delivered).toBeLessThanOrEqual(CK_ORDER_LOCKED_CYCLES);
  expect(delivered).toBeGreaterThan((CK_ORDER_LOCKED_CYCLES * 999n) / 1000n);

  // Settled order: the pull may never be reset (block recorded = money
  // moved), and a re-claim answers with the status, not a second pull.
  expect(await gw.asAdmin.reset_ck_usdc_pull(order1.id)).toBe(false);
  expect(expectErr(await gw.asUser.claim_ck_usdc_order(order1.id)))
    .toEqual({ notClaimable: 'Delivered' });
});

test('ck-07 — insufficient funds is a definite rejection: clean error, no stuck order (§6.2)', async () => {
  const created = expectOk(await asPoor.create_ck_usdc_order(
    CK_ORDER_USD_CENTS, { canister: destinationId },
  ));
  // The allowance may exceed the balance — approving only costs the fee.
  await approveCkUsdc(ck.asPoorUser, gw.backendId, CK_ORDER_APPROVE_UNITS);
  expect(expectErr(await asPoor.claim_ck_usdc_order(created.order.id))).toEqual({
    insufficientFunds: {
      balance: POOR_CK_UNITS - CKUSDC_FEE_UNITS, // one approve fee spent
      required: CK_ORDER_APPROVE_UNITS,
    },
  });
  expect(await gw.asAdmin.ck_usdc_pull(created.order.id)).toHaveLength(0);
  expect(statusKey((await asPoor.get_order(created.order.id))[0]!)).toBe('created');
});

test('ck-08 — upgrade mid-pull: the §5.1 money-IN intent replays, the user is debited exactly once', async () => {
  const created = expectOk(await gw.asUser.create_ck_usdc_order(
    CK_ORDER_USD_CENTS, { canister: destinationId },
  ));
  order2 = created.order;
  await approveCkUsdc(ck.asUser, gw.backendId, CK_ORDER_APPROVE_UNITS);
  const userBefore = await ckBalance(ck, user.getPrincipal());

  // Submit the claim and interrupt the instant the intent is journaled — the
  // transfer_from is in flight to the fiduciary subnet.
  const execute = await gw.deferredUser.claim_ck_usdc_order(order2.id);
  await tickUntilPullIntent(order2.id);
  await upgradeBackendMidFlight(gw);
  // The claim's own reply is gone (the ingress call outlived the upgrade), but
  // the *inter-canister* pull was drained by the stop — see below.
  await execute().catch(() => undefined);

  // `stop_canister` drains outstanding callbacks rather than dropping them (the
  // canister sits in `Stopping` until every call context closes), and an
  // upgrade with outstanding callbacks is rejected outright — so the
  // stop-first procedure means the pull completes across the upgrade rather
  // than being orphaned. An operator following it cannot leave a user debited
  // with the order unaware.
  //
  // The `#Duplicate`-replay and `stalePullIntent` branches cover genuine faults
  // instead. They are pinned by unit tests in test/ckusdc.test.mo
  // (`CkUsdc.claimStage` / `interpretPull` → `#uncertain`), and by ck-09 below,
  // which manufactures a truly orphaned intent by stopping the *ledger*.
  await gw.pic.tick(5);

  // THE §6.2 invariant that matters either way: debited exactly once.
  expect(await ckBalance(ck, user.getPrincipal())).toBe(userBefore - CK_ORDER_APPROVE_UNITS);
  expect(await orderStatus(gw, order2.id)).toBe('paid');
  expect((await gw.asAdmin.ck_usdc_pull(order2.id))[0]!.blockIndex).toHaveLength(1);

  // Re-claiming a settled order is refused, not re-pulled — no second debit.
  expectErr(await gw.asUser.claim_ck_usdc_order(order2.id));
  expect(await ckBalance(ck, user.getPrincipal())).toBe(userBefore - CK_ORDER_APPROVE_UNITS);

  // The claim's detached money-out kick did not survive the upgrade, so the
  // order sits `#paid` until something drives it. The §5.2 timer is the
  // backstop (proven in gateway.spec scenario 12, which advances past the 1 h
  // cadence); here the admin kick is the deterministic equivalent and is the
  // documented ops lever for exactly this situation (RUNBOOK §9).
  await setCmcRate(gw); // ticks may have aged the 15-min CMC window
  const driven = expectOk(await gw.asAdmin.process_order(order2.id));
  expect(statusKey(driven)).toBe('delivered');
  // Still exactly one debit after money-out completes.
  expect(await ckBalance(ck, user.getPrincipal())).toBe(userBefore - CK_ORDER_APPROVE_UNITS);
});

test('ck-09 — stale intent escalates once, order stays Created, operator reset re-opens the claim (§5.1/§6.2)', async () => {
  const created = expectOk(await gw.asUser.create_ck_usdc_order(
    CK_ORDER_USD_CENTS, { canister: destinationId },
  ));
  order3 = created.order;
  await approveCkUsdc(ck.asUser, gw.backendId, CK_ORDER_APPROVE_UNITS);
  const userBefore = await ckBalance(ck, user.getPrincipal());

  // A stopped ledger rejects the pull after the intent is journaled — the
  // deterministic way to age an intent that never executed.
  await ck.stop();
  const rejected = expectErr(await gw.asUser.claim_ck_usdc_order(order3.id));
  expect('retryable' in rejected).toBe(true);
  const entry = (await gw.asAdmin.ck_usdc_pull(order3.id))[0]!;
  expect(entry.blockIndex).toHaveLength(0);
  expect(entry.escalatedAtNs).toHaveLength(0);

  // At the 24 h dedup window the pull's fate is unknowable: escalate to the
  // operator, never rebuild fresh args (a lost executed pull would mean a
  // double debit). The order deliberately stays #created.
  await gw.pic.advanceTime(24 * 3_600 * 1_000);
  await gw.pic.tick(2);
  expect(expectErr(await gw.asUser.claim_ck_usdc_order(order3.id))).toEqual({ staleIntent: null });
  expect(await orderStatus(gw, order3.id)).toBe('created');
  const stuck = (await gw.asAdmin.error_queue()).filter(
    (e: ErrorEntry) => 'stuckMint' in e.kind && e.kind.stuckMint.orderId === order3.id,
  );
  expect(stuck).toHaveLength(1);
  if ('stuckMint' in stuck[0].kind) {
    expect(stuck[0].kind.stuckMint.stage).toBe('stalePullIntent');
  }

  // Once-only: further claims answer #staleIntent without re-queueing.
  expect(expectErr(await gw.asUser.claim_ck_usdc_order(order3.id))).toEqual({ staleIntent: null });
  expect((await gw.asAdmin.error_queue()).filter(
    (e: ErrorEntry) => 'stuckMint' in e.kind && e.kind.stuckMint.orderId === order3.id,
  )).toHaveLength(1);

  // Operator reads the ledger (it was stopped — nothing executed), clears
  // the intent; the next claim builds fresh args and completes.
  await ck.start();
  await expect(gw.asUser.reset_ck_usdc_pull(order3.id)).rejects.toThrow(/not a controller/);
  expect(await gw.asAdmin.reset_ck_usdc_pull(order3.id)).toBe(true);
  expect(await gw.asAdmin.ck_usdc_pull(order3.id)).toHaveLength(0);

  await setCmcRate(gw); // the 24 h jump aged the CMC rate
  const paid = expectOk(await gw.asUser.claim_ck_usdc_order(order3.id));
  expect(statusKey(paid)).toBe('paid');
  expect(await ckBalance(ck, user.getPrincipal())).toBe(userBefore - CK_ORDER_APPROVE_UNITS);
  // The 24 h jump also rolled the burn window, so the mint proceeds.
  expect(await tickUntilStatus(gw, order3.id, ['delivered'])).toBe('delivered');

  // The escalation entry outlives the recovery for the operator to resolve.
  const resolved = expectOk(await gw.asAdmin.resolve_error(stuck[0].id));
  expect(resolved.resolvedAtNs).toHaveLength(1);
});

test('ck-10 — hold-ckUSDC posture: the operator withdraw lever moves the accrued balance (§6.2)', async () => {
  // Three pulls accrued in the canister's own ledger account.
  const accrued = await ckBalance(ck, gw.backendId);
  expect(accrued).toBe(3n * CK_ORDER_UNITS);

  await expect(gw.asUser.withdraw_ck_usdc(
    { owner: admin.getPrincipal(), subaccount: [] }, 1n,
  )).rejects.toThrow(/not a controller/);

  const amount = accrued - CKUSDC_FEE_UNITS; // the withdraw pays the ledger fee
  expectOk(await gw.asAdmin.withdraw_ck_usdc(
    { owner: admin.getPrincipal(), subaccount: [] }, amount,
  ));
  expect(await ckBalance(ck, gw.backendId)).toBe(0n);
  expect(await ckBalance(ck, admin.getPrincipal())).toBe(amount);

  // An over-withdraw surfaces the ledger's rejection, attended-lever style.
  const overdraw = await gw.asAdmin.withdraw_ck_usdc(
    { owner: admin.getPrincipal(), subaccount: [] }, amount,
  );
  expect('err' in overdraw).toBe(true);
});

test('ck-11 — operational trail is coherent across the rail (§4.2)', async () => {
  const audit = await gw.asAdmin.audit_log();
  for (let i = 1; i < audit.length; i++) {
    expect(audit[i].seq).toBeGreaterThan(audit[i - 1].seq);
  }
  const tags = audit.map((e) => e.tag);
  for (const expected of [
    'ckusdc.paid', 'ckusdc.stalePull', 'ckusdc.pullReset', 'ckusdc.withdraw',
    'mint.held', 'mint.delivered',
  ]) {
    expect(tags).toContain(expected);
  }

  // Every queue entry is accounted for: the resolved stale-pull escalation
  // is the rail's only entry (definite rejections never queue).
  const open = (await gw.asAdmin.error_queue()).filter((e) => e.resolvedAtNs.length === 0);
  expect(open).toHaveLength(0);
  expect((await gw.asAnon.treasury_status()).heldOrders).toBe(0n);
});

test('ck-12 — the per-order single-flight guard rejects a concurrent claim', async () => {
  // Two concurrent claims for one order would both pass the status gate before
  // the ledger await, and the guard is what stops that. It had no coverage — the
  // `#inFlight` variant existed only in type declarations.
  await ensureRates(gw);
  const created = expectOk(await gw.asUser.create_ck_usdc_order(
    CK_ORDER_USD_CENTS, { canister: destinationId },
  ));
  const order = created.order;
  await approveCkUsdc(ck.asUser, gw.backendId, CK_ORDER_APPROVE_UNITS);
  const userBefore = await ckBalance(ck, user.getPrincipal());

  // Submit BOTH claims before letting either execute. Awaiting the first and
  // then calling again does not work: the rounds needed to submit the second
  // let the first finish, so it returns `notClaimable` instead. Two pending
  // ingress messages genuinely interleave — one takes the guard at the ledger
  // await, the other sees it held.
  const first = await gw.deferredUser.claim_ck_usdc_order(order.id);
  const second = await gw.deferredUser.claim_ck_usdc_order(order.id);
  const results = [await first(), await second()];

  // Exactly one is refused as in-flight; which one is not deterministic.
  const refused = results.filter((r) => 'err' in r && 'inFlight' in (r.err as object));
  const settled = results.filter((r) => 'ok' in r);
  expect(refused).toHaveLength(1);
  expect(settled).toHaveLength(1);
  expect(await orderStatus(gw, order.id)).toBe('paid');
  expect(await ckBalance(ck, user.getPrincipal())).toBe(userBefore - CK_ORDER_APPROVE_UNITS);
  expect((await gw.asAdmin.ck_usdc_pull(order.id))[0]!.blockIndex).toHaveLength(1);

  // Once settled, a further claim is refused as not-claimable rather than
  // re-pulling.
  const afterSettle = expectErr(await gw.asUser.claim_ck_usdc_order(order.id));
  expect(afterSettle).toHaveProperty('notClaimable');
  expect(await ckBalance(ck, user.getPrincipal())).toBe(userBefore - CK_ORDER_APPROVE_UNITS);
});
