/// PocketIC suite for `withdraw_reserve` (#103) — the second destination class for the
/// one outflow, and the guard that makes it safe.
///
/// ⚠️ **Its own PocketIC instance**, because the guard is "no promise-holder at all" and
/// every other suite deliberately accumulates orders.
import { afterAll, beforeAll, expect, test } from 'vitest';
import {
  CYCLES_LEDGER_FEE, TIER_LOCKED_CYCLES, TIER_USD_CENTS, WEBHOOK_SECRET,
  CYCLES_LEDGER_ID, admin, allAuditEvents, allowTestBuyers, checkoutSessionBody,
  clientReferenceFor, createOrderWithSession, deliverWebhook, ensureRates, expectErr,
  expectOk, fundReserve, reserveBalance, setCmcRate, setXrcRate,
  orderStatus, setupGateway, startNns, stopNns, teardownGateway, tickUntilStatus, user,
  type Gateway,
} from './harness';

let gw: Gateway;
beforeAll(async () => { gw = await setupGateway(); }, 180_000);
afterAll(async () => { await teardownGateway(gw); });

const RESERVE = 50_000_000_000_000n;
const USER_ACCOUNT = {
  cyclesLedgerAccount: { owner: user.getPrincipal(), subaccount: [] as [] },
};

async function adminCycles(): Promise<bigint> {
  return gw.cyclesLedger.icrc1_balance_of({ owner: admin.getPrincipal(), subaccount: [] });
}

async function holders(): Promise<bigint> {
  return (await gw.asAdmin.reserve_status()).promiseHolders;
}

test('103a — provision, and an empty reserve has nothing to withdraw', async () => {
  await setXrcRate(gw);
  await setCmcRate(gw);
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_webhook_secret(WEBHOOK_SECRET));
  expectOk(await gw.asAdmin.set_stripe_api_key('rk_test_withdraw_spec'));
  expectOk(await gw.asAdmin.set_stripe_origin('https://withdraw.example'));
  const { gate } = await gw.asAnon.lifecycle_config();
  expectOk(await gw.asAdmin.set_gate_config({ ...gate, minPurchaseUsdCents: 100n }));
  expectOk(await gw.asAdmin.set_card_tiers([{ id: 'tier5', usdCents: TIER_USD_CENTS }]));
  await allowTestBuyers(gw);

  // Distinguishable from "withdrew nothing successfully".
  expect(expectErr(await gw.asAdmin.withdraw_reserve())).toEqual({ nothingToWithdraw: null });
});

test('103b — refused while a promise is held, through both reachable classes', async () => {
  await fundReserve(gw, RESERVE);

  // ⚠️ **Both reachable classes, not one.** `Reserve.holdsPromise` is phrased as "not
  // terminal" rather than as a list of holding statuses — deliberately, so a new status
  // counts by default — which means every non-terminal status holds by construction.
  // What is worth exercising is the two an operator can actually produce here.
  //
  // The open-order cap is 1 per principal, so these are sequential rather than
  // concurrent; a second buyer would prove nothing extra about the guard.

  // ── 1. #created: a payable session the buyer might pay any second ────────
  const order = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []),
  );
  expect(await holders()).toBe(1n);
  const refusedCreated = expectErr(await gw.asAdmin.withdraw_reserve()) as {
    ordersOutstanding: { holders: bigint; promised: bigint };
  };
  expect(refusedCreated.ordersOutstanding.holders).toBe(1n);
  expect(refusedCreated.ordersOutstanding.promised).toBe(TIER_LOCKED_CYCLES);
  // A refused withdraw touches nothing.
  expect(await reserveBalance(gw)).toBeGreaterThan(0n);

  // ── 2. #paid and NOT delivered — the class a naive guard misses ──────────
  //
  // ⚠️ `Reserve.tallyDelta` makes `#created -> #paid` a ZERO delta precisely so the
  // promise survives payment: releasing at payment would let a second order be admitted
  // against capacity the first still needs. A withdraw here would take cycles a buyer
  // has already paid for, which is the whole point of the guard.
  //
  // Parked by stopping the cycles ledger, so the delivery transfer cannot land.
  await stopNns(gw, CYCLES_LEDGER_ID);
  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_paid', paymentIntent: 'pi_paid',
    clientReferenceId: clientReferenceFor(order.order.id),
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);
  expect(await orderStatus(gw, order.order.id)).toBe('paid');
  expect(await holders()).toBe(1n);

  await startNns(gw, CYCLES_LEDGER_ID);
  const refusedPaid = expectErr(await gw.asAdmin.withdraw_reserve()) as {
    ordersOutstanding: { holders: bigint; promised: bigint };
  };
  expect(refusedPaid.ordersOutstanding.holders).toBe(1n);
  expect(refusedPaid.ordersOutstanding.promised).toBe(TIER_LOCKED_CYCLES);

  // ── ⚠️ And `abandon_order` will NOT clear it while the delivery is outstanding ──
  //
  // The lever RUNBOOK's evacuation reaches for refuses here, for the same reason the
  // withdraw guard exists: whether this buyer already holds their cycles is not yet
  // known, so abandoning would refund someone who may have been paid.
  //
  // ⚠️ **So the evacuation cannot be forced.** Step 2 waits for the delivery to settle
  // or escalate; there is no lever that releases a promise over an unresolved delivery,
  // and that is deliberate.
  const cannotAbandon = expectErr(
    await gw.asAdmin.abandon_order(order.order.id, 'withdraw spec'),
  );
  expect(cannotAbandon).toContain('delivery outstanding');

  // Letting it settle is what clears the promise. `process_order` is the re-drive — a
  // stopped ledger leaves the delivery needing another attempt, and the hourly sweep
  // would get there eventually. `#delivered` is terminal, so the holder count falls to
  // zero with no promise-releasing lever involved at all.
  expectOk(await gw.asAdmin.process_order(order.order.id));
  expect(await tickUntilStatus(gw, order.order.id, ['delivered'])).toBe('delivered');
  expect(await holders()).toBe(0n);
});

test('103c — a full withdrawal drains the account to ZERO, not to the fee', async () => {
  expect(await holders()).toBe(0n);
  await gw.asAdmin.refresh_reserve();
  const before = await reserveBalance(gw);
  expect(before).toBeGreaterThan(0n);
  const adminBefore = await adminCycles();

  const result = expectOk(await gw.asAdmin.withdraw_reserve()) as {
    withdrawn: bigint; debited: bigint; to: { owner: unknown };
  };
  // ⚠️ `debited` is `withdrawn + fee`, the figure the reserve actually fell by. The
  // ledger charges its fee ON TOP, so draining means transferring `balance - fee` and
  // decrementing by `balance`. Decrementing by the transferred amount alone would leave
  // the floor overstating the account by exactly the fee.
  expect(result.debited).toBe(before);
  expect(result.withdrawn).toBe(before - CYCLES_LEDGER_FEE);
  expect(result.debited).toBe(result.withdrawn + CYCLES_LEDGER_FEE);

  // Drained to zero, not left holding the fee.
  expect(await reserveBalance(gw)).toBe(0n);
  expect((await adminCycles()) - adminBefore).toBe(result.withdrawn);

  // ⚠️ And the floor is zero too, so `Gate.solvent` now refuses every purchase — the
  // gateway is closed to sales without touching another lever. That is the property
  // that makes this a stop-the-application lever rather than just a refund.
  const status = await gw.asAdmin.reserve_status();
  expect(status.reserveFloor).toBe(0n);
  expect(status.availableToSell).toBe(0n);
  const refused = expectErr(
    await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []),
  ) as { notAdmitted: Record<string, unknown> };
  expect(Object.keys(refused.notAdmitted)).toEqual(['reserveShort']);
});

test('103d — the destination is IN the audit record, not just the fact of a withdrawal', async () => {
  // A controller destination is the new class in the whole design, so an audited call
  // whose record omits where the cycles went is weaker than it looks.
  const withdrawn = (await allAuditEvents(gw)).filter((e) => e.tag === 'reserve.withdrawn');
  expect(withdrawn.length).toBe(1);
  expect(withdrawn[0]!.detail).toContain(admin.getPrincipal().toText());
  expect(withdrawn[0]!.detail).toContain('incl. fee');
});

test('103e — the two interleaving windows, and ⚠️ what this suite CANNOT prove', async () => {
  // `withdraw_reserve` has two awaits and a rule for each:
  //
  //   1. the balance read inside `observeReserve` — the floor is still FULL across it,
  //      so the promise-holder count is RE-READ afterwards and the withdrawal refuses if
  //      it moved. Without that, a create queued there is admitted and the buyer walks
  //      away with a payable session against a reserve about to leave.
  //   2. the transfer — the floor is decremented SYNCHRONOUSLY before it, so a create
  //      arriving there is refused by `Gate.solvent` for free.
  //
  // ⚠️ **NEITHER ordering is verified by this suite, and saying so is the point.**
  // Measured, not assumed: with the re-read deleted, and again with the decrement moved
  // after the transfer, every test here still passed. A `pic.tick()` drains the whole
  // message including its inter-canister awaits, and there is no way to land an ingress
  // message inside one — so a create submitted before the withdrawal never reaches the
  // window, and one submitted after finds the work already done.
  //
  // An earlier version of this test asserted "a withdrawal and a create can never both
  // succeed" and passed for the wrong reason every time: the withdrawal simply finished
  // first (`withdrew=true, created=false, outcall=false`), so the create was refused
  // post-drain and the interleave never happened. That is a safety assertion that cannot
  // fail — worse than no test, because it reads as proof.
  //
  // What IS pinned: the predicate both rules depend on (103b — holders > 0 refuses), and
  // the observable end state (below). The orderings rest on review of the two comments in
  // `Main.withdraw_reserve` and on the pattern they copy from `observeReserve`, which
  // captures `unsettledBefore`/`outflowsIssued` and re-checks after its own await for
  // exactly this reason.
  await fundReserve(gw, RESERVE);
  await gw.asAdmin.refresh_reserve();
  expect(await holders()).toBe(0n);
  const before = await reserveBalance(gw);
  expect(before).toBeGreaterThan(TIER_LOCKED_CYCLES);

  expectOk(await gw.asAdmin.withdraw_reserve());

  // ⚠️ The end state is what a buyer's safety actually rests on: once the reserve is
  // gone, no session can be handed out against it. Asserted through the public path
  // rather than through the floor, because that is what a buyer would hit.
  expect(await reserveBalance(gw)).toBe(0n);
  const refused = expectErr(
    await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []),
  ) as { notAdmitted: Record<string, unknown> };
  expect(Object.keys(refused.notAdmitted)).toEqual(['reserveShort']);
  // And no order was left holding a promise against nothing.
  expect(await holders()).toBe(0n);
});

test('103f — a buyer who paid is never left short by a withdrawal', async () => {
  // The end-to-end property the guard exists for, stated as a delivery rather than as a
  // refusal: fund, buy, deliver, and only then withdraw. The buyer keeps their cycles.
  await fundReserve(gw, RESERVE);
  await gw.asAdmin.refresh_reserve();
  const order = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []),
  );
  const buyerBefore = await gw.cyclesLedger.icrc1_balance_of({
    owner: user.getPrincipal(), subaccount: [],
  });
  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_w1', paymentIntent: 'pi_w1',
    clientReferenceId: clientReferenceFor(order.order.id),
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);
  expect(await tickUntilStatus(gw, order.order.id, ['delivered'])).toBe('delivered');
  const delivered = (await gw.cyclesLedger.icrc1_balance_of({
    owner: user.getPrincipal(), subaccount: [],
  })) - buyerBefore;
  expect(delivered).toBe(TIER_LOCKED_CYCLES - CYCLES_LEDGER_FEE);

  // Delivered releases the promise, so the withdrawal now passes.
  expect(await holders()).toBe(0n);
  await gw.asAdmin.refresh_reserve();
  expectOk(await gw.asAdmin.withdraw_reserve());
  // ⚠️ The buyer's cycles are on the LEDGER, in their own account — a withdrawal of the
  // gateway's reserve cannot reach them. That is what "the cycles come to you" means.
  const after = (await gw.cyclesLedger.icrc1_balance_of({
    owner: user.getPrincipal(), subaccount: [],
  })) - buyerBefore;
  expect(after).toBe(delivered);
});
