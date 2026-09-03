/// #52 — releasing reserve capacity stranded by a missed `checkout.session.expired`.
///
/// ⚠️ **A separate PocketIC instance, and the reason is structural rather than
/// stylistic.** The recovery sweep is a *background* actor that rotates through **every**
/// lingering `#created` order in the store. `gateway.spec.ts` is order-coupled by design
/// and leaves dozens of orders `#created` forever, so in there "the sweep asks about my
/// order" depends on cursor position among neighbours — and the same scenario passed and
/// then regressed as unrelated fixtures shifted the rotation. Isolation makes the
/// interference *impossible* rather than absorbed, which is the choice this repo makes
/// everywhere it can. `live-gateway.spec.ts` is here for the same class of reason: a
/// mechanism whose global behaviour contradicts the shared instance's assumptions.
///
/// ⚠️ **What deliberately did NOT move: the cursor's coverage property.** "With many
/// lingering orders, every due order is eventually asked about, not just the head of the
/// cursor" needs a crowd, and the crowd is a fact of `gateway.spec.ts` rather than
/// something a scenario should build. That scenario stays there — it is what found the
/// starvation bug, and moving it would ship the resume cursor untested.
import { afterAll, beforeAll, expect, test } from 'vitest';
import {
  TIER_USD_CENTS, WEBHOOK_SECRET,
  answerOutcall, awaitNonRetrieveOutcall, awaitSweepRetrieveFor, maybeSweepRetrieveFor,
  checkoutSessionBody, clientReferenceFor, createOrderWithSession,
  deliverWebhook, ensureRates, expectErr, expectOk, fundReserve, openOrphans,
  nowSeconds, orderStatus, setCmcRate, setXrcRate, settleSweepRetrieveFor, setupGateway, teardownGateway,
  tickUntilStatus, user,
  type Gateway,

  orderProblems,
  unresolvedProblems,

  allAuditEvents,
} from './harness';
import type { Destination, Order } from './types';

/// The buyer's own cycles-ledger account — the only destination the gateway accepts (#29).
const USER_ACCOUNT: Destination = {
  cyclesLedgerAccount: { owner: user.getPrincipal(), subaccount: [] },
};

/// Enough reserve that no scenario here runs short: an unfunded reserve is PR-B's
/// subject, and running short would fail as a hang rather than an assertion.
const RESERVE_CYCLES = 500_000_000_000_000n; // 500 T

let gw: Gateway;
beforeAll(async () => {
  gw = await setupGateway();
  // ⚠️ **`setXrcRate` first, and it is not optional in a fresh instance.** A new
  // PocketIC instance has no armed XRC mock, so `ensureRates` fails with "Canister
  // uf6dk-… not found" — which reads like a missing canister rather than an unarmed one.
  // `gateway.spec.ts` gets away without it here only because its first scenario arms it.
  await setXrcRate(gw);
  await setCmcRate(gw);
  await fundReserve(gw, RESERVE_CYCLES);
  // ⚠️ **Lower the purchase floor, or every `create_order` here is refused before it
  // reaches Stripe.** `tier5` is $5 and the gate's `minPurchaseUsdCents` default is $10,
  // so the refusal happens at admission and the symptom is "no HTTPS outcall was made" —
  // which reads as a missing outcall rather than a rejected order. `gateway.spec.ts` does
  // the same thing, and so does the PocketIC sandbox harness.
  //
  // The floor moves rather than the amount: 500¢ − 45¢ fee = 455¢ = exactly one ICP at
  // $4.55 = exactly 3.5 T cycles at the seeded CMC rate, and every quantity assertion in
  // this suite comes off that vector.
  // ⚠️ **Pin the open-order cap too.** The shipped default is 1 per principal, and every
  // scenario here creates an order for the same buyer. They worked at 1 only because
  // `openOrderCount` stops counting an order past its own deadline and these scenarios
  // advance the clock — an accidental dependency on behaviour they do not test, which a
  // mutation removing that check exposed by failing four of them. Pinned, so a cap change
  // fails scenario 88 and nothing else.
  const gate = (await gw.asAnon.lifecycle_config()).gate;
  expectOk(await gw.asAdmin.set_gate_config({
    ...gate,
    minPurchaseUsdCents: 100n,
    maxOpenOrdersPerPrincipal: 20n,
  }));

  // ⚠️ **`setupGateway` provisions NOTHING** — no secrets, no key, no tiers, no origin.
  // `gateway.spec.ts` gets its provisioning from its own early scenarios (01–04), which
  // is invisible until a file boots its own instance and every `create_order` is refused
  // before it reaches Stripe. The symptom is "no HTTPS outcall was made", which reads as
  // a missing outcall rather than a rail that was never opened.
  expectOk(await gw.asAdmin.set_webhook_secret(WEBHOOK_SECRET));
  expectOk(await gw.asAdmin.set_stripe_api_key('rk_test_stranded_suite_key'));
  expectOk(await gw.asAdmin.set_stripe_origin('https://stranded.example'));
  expectOk(await gw.asAdmin.set_card_tiers([{ id: 'tier5', usdCents: TIER_USD_CENTS }]));
  // ⚠️ **`expected_livemode` is deliberately left UNSET, and both directions are wrong.**
  // The mocked *create* response defaults `livemode: false`, while `checkoutSessionBody`
  // for the *webhook* defaults to live — so expecting test mode refuses every webhook
  // ("acknowledged: livemode mismatch logged", acked 200 and credits nothing) and
  // expecting live refuses every `create_order` at the session-create check. The shared
  // suite leaves it unset for exactly this reason and varies it only in its livemode
  // scenario. Cost of unset: a `stripe.livemodeUnset` audit line per payment.
  //
  // Both halves were found by asserting on the webhook's response BODY rather than its
  // status — a 200 that credits nothing looks identical to a 200 that credits.
  await ensureRates(gw);
}, 180_000);
afterAll(async () => { await teardownGateway(gw); });

/// Answer the sweep's retrieve for THIS order's session.
///
/// Still targeted by session id even in isolation: a scenario that has created two orders
/// would otherwise answer for whichever the cursor reached first, and the failure would
/// look like the code being wrong.
async function answerSweepRetrieve(order: Order, body: string): Promise<void> {
  await settleSweepRetrieveFor(gw, order.stripeSessionId[0]!, 200, body);
}

// Each scenario advances the clock past a deadline (35 min) plus the sweep's grace
// (30 min) and then ticks; the hourly cadence gate is satisfied by the same advance.

test('81 — a missed expiry event: the sweep asks Stripe and releases the capacity', async () => {
  await setCmcRate(gw);
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_stranded_81' }));
  const stranded = created.order;
  const promisedBefore = (await gw.asAnon.reserve_status()).promisedTotal;
  expect(promisedBefore).toBeGreaterThanOrEqual(stranded.lockedCycles);

  // No `checkout.session.expired` is ever delivered — that is the whole premise. Past
  // the deadline plus the grace, the order is still `#created` and still holding.
  await gw.pic.advanceTime(70 * 60 * 1_000);
  await gw.pic.tick(5);
  expect(await orderStatus(gw, stranded.id)).toBe('created');

  await answerSweepRetrieve(stranded, JSON.stringify({ id: stranded.stripeSessionId[0], object: 'checkout.session', status: 'expired' }));

  expect(await orderStatus(gw, stranded.id)).toBe('expired');
  // THE assertion: capacity came back, by exactly the order's own locked quantity.
  expect((await gw.asAnon.reserve_status()).promisedTotal).toBe(promisedBefore - stranded.lockedCycles);
  // ⚠️ The `expiredBy` provenance says *Stripe expired the session*, not that an operator
  // or a buyer did — but nothing can read another principal's order until #38, so the
  // status above is the assertion this scenario can make. Scenario 84 covers the half
  // that matters: a buyer's own cancellation is never overwritten by this path.
  await setCmcRate(gw);
  await ensureRates(gw);
});

test('82 — a PAID session inside Stripe\'s retry window is not an obligation yet', async () => {
  await setCmcRate(gw);
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_paid_82' }));
  const paid = created.order;
  const promisedBefore = (await gw.asAnon.reserve_status()).promisedTotal;
  const openBefore = (await openOrphans(gw)).length;

  await gw.pic.advanceTime(70 * 60 * 1_000);
  await gw.pic.tick(5);
  await answerSweepRetrieve(paid, JSON.stringify({
    id: paid.stripeSessionId[0], object: 'checkout.session',
    status: 'complete', payment_status: 'paid', payment_intent: 'pi_82',
  }));

  // ⚠️ **Nothing filed, and the capacity is STILL HELD — both deliberate.** The buyer
  // paid, so those cycles are genuinely owed: holding them is the promise doing its job,
  // not a leak. And Stripe redelivers for ~3 days, so the `completed` event is still
  // coming and the real credit path will handle it. Filing here would put a
  // self-resolving item into a bounded, evicting queue.
  expect(await orderStatus(gw, paid.id)).toBe('created');
  expect((await gw.asAnon.reserve_status()).promisedTotal).toBe(promisedBefore);
  expect((await openOrphans(gw)).length).toBe(openBefore);
  // The support signal is an audit line, because a buyer who paid sees their own page
  // render expired and calls the same hour.
  expect((await allAuditEvents(gw)).map((e) => e.tag)).toContain('stripe.paidAwaitingEvent');
  await setCmcRate(gw);
  await ensureRates(gw);
});

test('83 — past the retry horizon it becomes an obligation, and a resend closes it', async () => {
  await setCmcRate(gw);
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_paid_83' }));
  const paid = created.order;
  const promisedBefore = (await gw.asAnon.reserve_status()).promisedTotal;

  // Five days: past Stripe's ~3-day redelivery window and the 4-day horizon.
  await gw.pic.advanceTime(5 * 24 * 3_600 * 1_000);
  await gw.pic.tick(5);
  await answerSweepRetrieve(paid, JSON.stringify({
    id: paid.stripeSessionId[0], object: 'checkout.session',
    status: 'complete', payment_status: 'paid', payment_intent: 'pi_83',
  }));

  // ⚠️ **Now on the ORDER, not in a queue (#37).** The problem always had an
  // `orderId`, so the order it belongs to supplies that structurally — which is the
  // whole reason it moved. No `orderId` field to compare against any more.
  const filed = unresolvedProblems(await orderProblems(gw, paid.id))
    .find((p) => 'paidNotCredited' in p.kind);
  expect(filed).toBeDefined();
  // It carries the intent, which is the first thing an operator looks up in Stripe — and
  // the ONLY place it could come from is the retrieve, since the order never reached
  // `#paid` so nothing indexed the payment against it.
  expect((filed!.kind as { paidNotCredited: { paymentRef: string } }).paidNotCredited.paymentRef).toBe('pi_83');
  // Still `#created`, still holding: `#created → #paid` is the only edge a resend can
  // travel, so keeping the order here is what preserves the remedy that delivers.
  expect(await orderStatus(gw, paid.id)).toBe('created');
  expect((await gw.asAnon.reserve_status()).promisedTotal).toBe(promisedBefore);

  // ⚠️ **The resend is the remedy, and it closes the entry.** Not `charge.refunded`:
  // refunding settles the money and leaves the order stranded with no event left to
  // release it, which is why the kind withholds its paymentRef from `paymentRefOf`.
  const resend = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_83_resend', paymentIntent: 'pi_83',
    clientReferenceId: clientReferenceFor(paid.id), amountCents: TIER_USD_CENTS,
  }));
  expect(resend).toMatchObject({ status_code: 200 });
  // A 200 that did not credit is one of the deliberate refusals (duplicate, unattributed,
  // amount mismatch, livemode). Surface which, so a failure here names the reason instead
  // of only saying the order never moved.
  expect(
    new TextDecoder().decode(resend.body as Uint8Array),
    'the resend was acked but did not credit the order',
  ).toBe('ok');
  expect(await tickUntilStatus(gw, paid.id, ['delivered'])).toBe('delivered');
  // Resolved, not deleted: nothing drops, so the record of what happened survives on
  // the order while the worklist count goes to zero.
  const after = await orderProblems(gw, paid.id);
  expect(after.some((p) => 'paidNotCredited' in p.kind)).toBe(true);
  expect(unresolvedProblems(after).some((p) => 'paidNotCredited' in p.kind)).toBe(false);
  await setCmcRate(gw);
  await ensureRates(gw);
});

test('84 — a cancel landing DURING the retrieve keeps the buyer\'s own decision', async () => {
  await setCmcRate(gw);
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_raced_84' }));
  const raced = created.order;

  await gw.pic.advanceTime(70 * 60 * 1_000);
  await gw.pic.tick(5);
  // Park the retrieve WITHOUT answering it, then let the buyer cancel underneath it.
  const parked = await awaitSweepRetrieveFor(gw, raced.stripeSessionId[0]!);

  // ⚠️ **Cancel inline rather than through `cancelOrderWithExpire`.** That helper waits
  // with `maybePendingOutcall`, which ANSWERS any sweep retrieve it meets — including the
  // one being held here, which invalidates the handle and surfaces as pic-js's
  // `InvalidCanisterHttpRequestId`. `awaitNonRetrieveOutcall` leaves it parked.
  const settle = await gw.deferredUser.cancel_order(raced.id);
  const expire = await awaitNonRetrieveOutcall(gw);
  await answerOutcall(gw, expire, 200, JSON.stringify({ id: raced.stripeSessionId[0], status: 'expired' }));
  expectOk(await settle());
  expect(await orderStatus(gw, raced.id)).toBe('cancelled');

  // Now answer "expired" — which is true of the session, because cancelling expired it.
  await answerOutcall(gw, parked, 200, JSON.stringify({ id: raced.stripeSessionId[0], object: 'checkout.session', status: 'expired' }));
  await gw.pic.tick(5);

  // ⚠️ **Still `#cancelled`.** `#cancelled → #expired` is absent from the matrix, so the
  // sweep's `expireWithCause` no-ops for free — which is what keeps a system expiry from
  // overwriting the buyer's own decision and the `expiredBy` provenance that records
  // which of the two happened. This is the race the whole post-await re-read exists for.
  expect(await orderStatus(gw, raced.id)).toBe('cancelled');
  await setCmcRate(gw);
  await ensureRates(gw);
});

test('85 — inside the grace, Stripe is not asked at all', async () => {
  await setCmcRate(gw);
  await ensureRates(gw);
  // ⚠️ **A 2-hour deadline, and the clock advanced past the SCAN's cadence.** This
  // scenario was vacuous on its first write: it used the default 35-minute deadline and
  // advanced 40 minutes, so the scan had not come due on its hourly cadence and no
  // retrieve happened **for that reason** rather than because of the grace. A mutation
  // that removed the grace entirely still passed it.
  //
  // Now the cadence is satisfied (130 min > 60) and the order is only 10 minutes past its
  // own deadline, so the grace is the sole thing suppressing the ask — which is what this
  // scenario claims to test.
  const deadline = Number(await nowSeconds(gw.pic)) + 7_200; // +2 h
  const created = expectOk(await createOrderWithSession(
    gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_fresh_85', expiresAtSeconds: deadline },
  ));
  const fresh = created.order;

  await gw.pic.advanceTime(130 * 60 * 1_000);
  await gw.pic.tick(10);

  // ⚠️ **No outcall.** Stripe fires the expiry event within seconds of the deadline, so a
  // healthy gateway is already `#expired` before the sweep would look. The grace is what
  // makes the outcall count zero in normal operation and every firing a real missed
  // event — it is the difference between a signal and noise.
  // ⚠️ Targeted at THIS session. By here the file's own earlier scenarios have left
  // orders `#created` well past their deadlines, so an untargeted "no retrieve at all"
  // check fails on a neighbour — which is how the first rewrite of this scenario broke.
  expect(await maybeSweepRetrieveFor(gw, fresh.stripeSessionId[0]!)).toBeUndefined();
  expect(await orderStatus(gw, fresh.id)).toBe('created');
  await setCmcRate(gw);
  await ensureRates(gw);
});

test('86 — expire_order is admin-only and refuses anything but a #created order', async () => {
  await setCmcRate(gw);
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_admin_86' }));
  const target = created.order;
  const promisedBefore = (await gw.asAnon.reserve_status()).promisedTotal;

  await expect(gw.asUser.expire_order(target.id)).rejects.toThrow(/not an admin/);

  // The admin path expires the Stripe session FIRST — nothing is ever half-expired.
  //
  // ⚠️ **Through `deferredAdmin`.** A plain `asAdmin` call cannot be awaited later: the
  // ingress blocks until the method returns, the method blocks on its outcall, and pic-js
  // gives up after 100 rounds with `BadIngressMessage` — which says nothing about the
  // outcall nobody answered.
  const run = await gw.deferredAdmin.expire_order(target.id);
  const outcall = await awaitNonRetrieveOutcall(gw);
  expect(outcall.url).toContain('/expire');
  await answerOutcall(gw, outcall, 200, JSON.stringify({ id: target.stripeSessionId[0], status: 'expired' }));
  expectOk(await run());

  expect(await orderStatus(gw, target.id)).toBe('expired');
  expect((await gw.asAnon.reserve_status()).promisedTotal).toBe(promisedBefore - target.lockedCycles);
  // Idempotent on an already-expired order.
  expectOk(await gw.asAdmin.expire_order(target.id));

  // And refuses anything that is not `#created` — a delivered order built here rather
  // than borrowed, because this file has no neighbours to borrow from.
  const delivered = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_admin_86b' }));
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_86', paymentIntent: 'pi_86',
    clientReferenceId: clientReferenceFor(delivered.order.id), amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, delivered.order.id, ['delivered'])).toBe('delivered');
  expectErr(await gw.asAdmin.expire_order(delivered.order.id));
  await setCmcRate(gw);
  await ensureRates(gw);
});
