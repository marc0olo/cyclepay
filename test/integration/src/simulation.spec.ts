/// PocketIC suite for simulation mode (#99): the divisor, the faucet refusal, and
/// the guards that keep the unsafe configurations unrepresentable.
///
/// ⚠️ **Its own PocketIC instance, and the reason is the `storedCount` guard.**
/// `set_pricing_config` refuses a divisor CHANGE while any order is stored, so the
/// divisor has to be set before the first order exists — which cannot be done part
/// way through a suite that has already created some. It also dictates the order of
/// the scenarios below: everything that configures the divisor runs before anything
/// that creates an order.
import { afterAll, beforeAll, expect, test } from 'vitest';
import {
  CYCLES_LEDGER_FEE, TIER_LOCKED_CYCLES, TIER_USD_CENTS, WEBHOOK_SECRET,
  allowTestBuyers, checkoutSessionBody, clientReferenceFor, createOrderWithSession,
  deliverWebhook, ensureRates, expectErr, expectOk, fundReserve, reserveBalance,
  setCmcRate, setXrcRate, setupGateway, stranger, teardownGateway, tickUntilStatus, user,
  type Gateway,
} from './harness';

let gw: Gateway;
beforeAll(async () => { gw = await setupGateway(); }, 180_000);
afterAll(async () => { await teardownGateway(gw); });

/// ⚠️ **100, not the recommended 1,000, and the reason is a real constraint worth
/// knowing: the divisor's ceiling scales with `minPurchaseUsdCents`, not with the
/// amount being bought.** This suite lowers the floor to $1 to keep the §3 vector
/// exact, and at a $1 floor a divisor of 1,000 leaves 523 M cycles — under the
/// ten-times-the-ledger-fee headroom — so `set_pricing_config` refuses it. #99's
/// recommended 1,000 assumes the shipped $10 floor. Asserted in 99c.
const DIVISOR = 100n;
/// 3.5 T ÷ 100. Exact because the §3 vector is exact.
const SCALED_LOCKED = TIER_LOCKED_CYCLES / DIVISOR;
const RESERVE = 100_000_000_000_000n;

const USER_ACCOUNT = {
  cyclesLedgerAccount: { owner: user.getPrincipal(), subaccount: [] as [] },
};

async function userCycles(): Promise<bigint> {
  return gw.cyclesLedger.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] });
}

async function pricingConfig() {
  return (await gw.asAnon.pricing_status()).config;
}

test('99a — the faucet refusal: test payments, empty allow-list, funded reserve', async () => {
  await setXrcRate(gw);
  await setCmcRate(gw);
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_webhook_secret(WEBHOOK_SECRET));
  expectOk(await gw.asAdmin.set_stripe_api_key('rk_test_simulation_spec'));
  expectOk(await gw.asAdmin.set_stripe_origin('https://simulation.example'));
  const { gate } = await gw.asAnon.lifecycle_config();
  expectOk(await gw.asAdmin.set_gate_config({ ...gate, minPurchaseUsdCents: 100n }));
  expectOk(await gw.asAdmin.set_card_tiers([{ id: 'tier5', usdCents: TIER_USD_CENTS }]));

  // ⚠️ **Before the reserve is funded there is nothing to give away, so the faucet
  // condition does NOT fire** — `Gate.solvent` refuses instead. This is exactly what
  // makes #99's Part 1 explorable on mainnet with no code and no allow-list.
  const unfunded = expectErr(
    await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []),
  ) as { notAdmitted: Record<string, unknown> };
  expect(Object.keys(unfunded.notAdmitted)).toEqual(['reserveShort']);

  // Fund it, and the same call refuses as the faucet: the empty allow-list stops
  // being harmless the moment there is something to sell.
  await fundReserve(gw, RESERVE);
  const faucet = expectErr(
    await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []),
  ) as { notAdmitted: { unboundedGiveaway: { reserveFloor: bigint } } };
  expect(Object.keys(faucet.notAdmitted)).toEqual(['unboundedGiveaway']);
  expect(faucet.notAdmitted.unboundedGiveaway.reserveFloor).toBeGreaterThan(0n);

  // ⚠️ A GATEWAY condition, so it latches and shows in `refusingNow` — an operator
  // sees the state itself, not just a buyer's failed purchase.
  const refusals = await gw.asAnon.refusal_counts();
  expect(refusals.refusingNow.unboundedGiveaway).toBe(true);
  expect(refusals.counts.unboundedGiveaway).toBe(1n);
  // ⚠️ And NOT in the per-buyer counter, which means the opposite thing: this one
  // says the list is missing, that one says the list is working.
  expect(refusals.counts.buyerNotAllowed).toBe(0n);
});

test('99b — an unlisted buyer against a POPULATED list is a different refusal', async () => {
  // Only `user` is listed, so `stranger` meets a populated list it is not on.
  expectOk(await gw.asAdmin.add_allowed_buyer(user.getPrincipal()));
  expect((await gw.asAdmin.allowed_buyers()).length).toBe(1);

  const refused = expectErr(
    await gw.asStranger.create_order({ tier: 'tier5' }, {
      cyclesLedgerAccount: { owner: stranger.getPrincipal(), subaccount: [] },
    }, []),
  ) as { notAdmitted: Record<string, unknown> };
  expect(Object.keys(refused.notAdmitted)).toEqual(['buyerNotAllowed']);

  const refusals = await gw.asAnon.refusal_counts();
  expect(refusals.counts.buyerNotAllowed).toBe(1n);
  // ⚠️ **A per-principal refusal never latches**, so this did not add a second
  // gateway condition. The faucet latch from 99a is still set, because only a
  // successful ADMISSION clears it and none has happened yet — 99e is where it does.
  expect(refusals.refusingNow.unboundedGiveaway).toBe(true);

  // ⚠️ **The anonymous principal is exempt from the list**, so `can_purchase` still
  // answers about the GATEWAY when probed without an identity. That is what the
  // frontend does before sign-in and what every suite here does; filtered, an
  // anonymous probe reported `buyerNotAllowed` and hid the gas floor behind it.
  // It cannot widen anything: `create_order` rejects anonymous before the gate.
  expectOk(await gw.asAnon.can_purchase(TIER_USD_CENTS));
  const anonBuy = expectErr(
    await gw.asAnon.create_order({ tier: 'tier5' }, USER_ACCOUNT, []),
  );
  expect(anonBuy).toEqual({ anonymous: null });

  await allowTestBuyers(gw);
});

test('99c — the mutual refusal: neither order of operations reaches the unsafe state', async () => {
  const config = await pricingConfig();
  expect(config.divisor).toBe(1n);

  // ⚠️ `null` is the DEFAULT and it means "either mode", so it accepts live
  // payments. A divisor here would take real money and under-deliver — the exact
  // row a guard keyed on `?true` would have missed.
  expect(await gw.asAnon.expected_livemode()).toEqual([]);
  expect(expectErr(await gw.asAdmin.set_pricing_config({ ...config, divisor: DIVISOR })))
    .toEqual({ divisorNeedsSandbox: { expectLivemode: [] } });

  // Live is refused for the same reason, and this is the row that shorts a buyer.
  expectOk(await gw.asAdmin.set_expected_livemode([true]));
  expect(expectErr(await gw.asAdmin.set_pricing_config({ ...config, divisor: DIVISOR })))
    .toEqual({ divisorNeedsSandbox: { expectLivemode: [true] } });

  // Only `?false` — declaring the sandbox — admits a divisor.
  expectOk(await gw.asAdmin.set_expected_livemode([false]));

  // ⚠️ **The recommended 1,000 is refused HERE, and that is the guard working.**
  // This suite's floor is $1, where 1,000 leaves 515 M cycles — five times the
  // ledger fee, not the ten this refuses under. #99's band table is derived at the
  // shipped $10 floor; lower the floor and the divisor ceiling falls with it.
  //
  // The figure: `feeCents` rounds UP, so $1 nets 67c (not 68c) — 100 − ⌈2.9⌉ − 30.
  // 67c × 3.5 XDR/ICP ÷ $4.55/ICP × 10¹² = 515.38 G, ÷ 1,000 = 515,384,615.
  const tooDeep = expectErr(
    await gw.asAdmin.set_pricing_config({ ...config, divisor: 1_000n }),
  ) as { divisorUndeliverable: { scaledCycles: bigint; ledgerFee: bigint } };
  expect(tooDeep.divisorUndeliverable.scaledCycles).toBe(515_384_615n);
  expect(tooDeep.divisorUndeliverable.ledgerFee).toBe(CYCLES_LEDGER_FEE);

  expectOk(await gw.asAdmin.set_pricing_config({ ...config, divisor: DIVISOR }));
  expect((await pricingConfig()).divisor).toBe(DIVISOR);

  // ⚠️ Now the OTHER half: with a divisor set, livemode cannot move to anything but
  // `?false`. Mutual, so neither order of operations gets to the unsafe state.
  expect(await gw.asAdmin.set_expected_livemode([true])).toHaveProperty('err');
  expect(await gw.asAdmin.set_expected_livemode([])).toHaveProperty('err');
  expect(await gw.asAnon.expected_livemode()).toEqual([false]);
  // Setting it to the value it already holds is not a change, so it is allowed.
  expectOk(await gw.asAdmin.set_expected_livemode([false]));
});

test('99d — an undeliverable divisor is refused at set time, and writes nothing', async () => {
  const config = await pricingConfig();
  expect(config.divisor).toBe(DIVISOR);

  const err = expectErr(
    await gw.asAdmin.set_pricing_config({ ...config, divisor: 1_000_000n }),
  ) as { divisorUndeliverable: { scaledCycles: bigint; ledgerFee: bigint } };
  expect(err.divisorUndeliverable.ledgerFee).toBe(CYCLES_LEDGER_FEE);
  // ⚠️ Headroom, not a bare comparison with the fee.
  expect(err.divisorUndeliverable.scaledCycles).toBeLessThan(CYCLES_LEDGER_FEE * 10n);

  expect(expectErr(await gw.asAdmin.set_pricing_config({ ...config, divisor: 0n })))
    .toEqual({ zeroDivisor: null });

  // Validated before anything writes, so a refused call leaves the config alone.
  expect((await pricingConfig()).divisor).toBe(DIVISOR);
});

test('99d2 — lowering the FLOOR is checked against the divisor, symmetrically', async () => {
  const { gate } = await gw.asAnon.lifecycle_config();
  expect((await pricingConfig()).divisor).toBe(DIVISOR);

  // ⚠️ **The divisor's ceiling is a function of the floor, so the guard has to run
  // in both setters or the configuration is reachable from the other direction.**
  // `set_pricing_config` refuses a divisor the current minimum cannot survive; this
  // is the mirror. Without it: accept the divisor at this floor, then lower the
  // floor, and every minimum-amount purchase refuses with a message about the
  // simulation scale rather than about the change the operator just made.
  //
  // Not unsafe — `Pricing.quote` still refuses at creation, so no money moves and
  // nothing stalls. What goes missing is learning at set time instead of through a
  // buyer's refusal.
  // 42c, because the trip point depends on the divisor and this suite's is pinned at
  // 100 (see DIVISOR). At 42c the net is 10c, which scales to 769 M — under the
  // ten-times-the-fee headroom. ⚠️ At the recommended divisor of 1,000 the trip point
  // is a far more plausible floor: $1 itself is refused there, which is exactly the
  // coupling this guard makes visible at set time.
  //
  // Not lower than 42c: below ~30c the gross does not clear the STRIPE fee, so
  // `divisorDeliverable` correctly declines to judge (there is no net to scale) and
  // returns #ok. A first draft used 2c, passed for that reason, and proved nothing.
  const err = expectErr(
    await gw.asAdmin.set_gate_config({ ...gate, minPurchaseUsdCents: 42n }),
  ) as {
    floorUndeliverableAtDivisor: {
      minUsdCents: bigint; divisor: bigint; scaledCycles: bigint; ledgerFee: bigint;
    };
  };
  expect(err.floorUndeliverableAtDivisor.divisor).toBe(DIVISOR);
  expect(err.floorUndeliverableAtDivisor.minUsdCents).toBe(42n);
  expect(err.floorUndeliverableAtDivisor.scaledCycles).toBe(769_230_769n);
  expect(err.floorUndeliverableAtDivisor.ledgerFee).toBe(CYCLES_LEDGER_FEE);

  // Refused before anything writes: the floor is untouched.
  expect((await gw.asAnon.lifecycle_config()).gate.minPurchaseUsdCents)
    .toBe(gate.minPurchaseUsdCents);

  // ⚠️ And the guard does not fire on a floor the divisor CAN survive, or it would
  // be an unconditional refusal wearing a reason. Non-vacuous both ways.
  expectOk(await gw.asAdmin.set_gate_config({ ...gate, minPurchaseUsdCents: 60n }));
  expectOk(await gw.asAdmin.set_gate_config({ ...gate }));
});

test('99e — a scaled order delivers the scaled quantity, exactly', async () => {
  expect((await pricingConfig()).divisor).toBe(DIVISOR);

  // ⚠️ The divisor lives at `Pricing.quote`, the single derivation, so the preview a
  // buyer sees and the order they get cannot disagree. Checked through the public
  // preview, which is the path the frontend actually uses.
  const preview = await gw.asAnon.quote_previews([TIER_USD_CENTS]);
  expect(preview.quotes[0]!.cycles).toEqual([SCALED_LOCKED]);

  const created = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []),
  );
  expect(created.order.lockedCycles).toBe(SCALED_LOCKED);

  // ⚠️ **A successful admission is what clears the faucet latch**, and this is the
  // first one in the suite. Decided the other way round the latch would never clear
  // and `refusingNow` would report the faucet forever after the list was populated.
  expect((await gw.asAnon.refusal_counts()).refusingNow.unboundedGiveaway).toBe(false);

  const reserveBefore = await reserveBalance(gw);
  const creditedBefore = await userCycles();
  const feeNow = await gw.cyclesLedger.icrc1_fee();
  expect(feeNow).toBe(CYCLES_LEDGER_FEE);

  // ⚠️ **`livemode: false`, and omitting it is a silent no-op.** There are TWO
  // livemode gates, not one: `create_order` checks the session Stripe returns, and
  // the WEBHOOK checks the event (`rails/Card.mo`). `checkoutSessionBody` defaults
  // to live, this gateway declared `?false` in 99c, so a defaulted body is logged
  // as a mismatch and the order sits `#created`.
  //
  // ⚠️ And a 200 does not mean it was processed — an unattributed or refused event
  // answers 200 on purpose, so asserting only the status is reading absence as
  // success. `tickUntilStatus` is what actually proves delivery.
  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_sim1', paymentIntent: 'pi_sim1',
    clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
    livemode: false,
  }));
  expect(response.status_code).toBe(200);
  expect(await tickUntilStatus(gw, created.order.id, ['delivered'])).toBe('delivered');

  // ⚠️ **The ledger fee does NOT scale, and this is what proves it.** The buyer
  // receives the scaled quantity less the FULL flat fee — 35 G less 100 M, not less
  // 1 M. At this divisor the fee is 0.29% of the delivery, where in production it
  // rounds away entirely; that is what makes the fee mechanic demonstrable at all.
  expect((await userCycles()) - creditedBefore).toBe(SCALED_LOCKED - feeNow);
  // And the reserve falls by exactly the scaled locked quantity — the same §5.4
  // rule 2 arithmetic as production, which is why the divisor belongs at the quote
  // and NOT at the transfer. Scaling the transfer would leave this reporting an
  // unexplained shortfall, the one signal that means an outflow we did not cause.
  expect(reserveBefore - (await reserveBalance(gw))).toBe(SCALED_LOCKED);

  const journal = (await gw.asAdmin.delivery_journal(created.order.id))[0]!;
  expect(journal.cyclesDelivered).toEqual([SCALED_LOCKED - feeNow]);
});

test('99f — the divisor cannot change once an order is stored', async () => {
  const config = await pricingConfig();
  const stored = (await gw.asAdmin.reserve_status()).totalOrders;
  expect(stored).toBeGreaterThan(0n);

  // ⚠️ This is what makes a GLOBAL divisor safe without recording it per order:
  // every receipt recomputes against config, so a mid-phase change would make each
  // earlier one report a mismatch — the exact claim the landing page makes.
  expect(expectErr(await gw.asAdmin.set_pricing_config({ ...config, divisor: 50n })))
    .toEqual({ divisorChangeWithOrders: { stored } });
  // Including back to production. Refusing is the safe direction: reinstall to change it.
  expect(expectErr(await gw.asAdmin.set_pricing_config({ ...config, divisor: 1n })))
    .toEqual({ divisorChangeWithOrders: { stored } });

  // Other pricing fields still move freely — it is the divisor that is pinned, not
  // the whole config.
  expectOk(await gw.asAdmin.set_pricing_config({ ...config, maxRateDeltaBps: 4_000n }));
  expect((await pricingConfig()).divisor).toBe(DIVISOR);
});
