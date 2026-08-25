import { afterAll, beforeAll, expect, test } from 'vitest';
import {
  ICP_FEE_E8S, ORDER_E8S, TIER_LOCKED_CYCLES, TIER_USD_CENTS, WEBHOOK_SECRET,
  checkoutSessionBody, ensureRates, expectOk, fundFloat, orderStatus, setCmcRate,
  setupGateway, setXrcRate, stripeSignature, teardownGateway, tickUntilStatus, user,
  clientReferenceFor, createOrderWithSession,
  type Gateway,
} from './harness';

const WORKING_TREASURY = {
  burnCapE8s: 50_000_000_000n, burnWindowNs: 86_400_000_000_000n,
  alertAfterNs: 7_200_000_000_000n, maxHoldNs: 259_200_000_000_000n,
  lowFloatThresholdE8s: 0n,
};

let gw: Gateway;
beforeAll(async () => { gw = await setupGateway(); }, 180_000);
afterAll(async () => { await teardownGateway(gw); });

// A separate PocketIC instance on purpose: `makeLive` enables auto-progress, which
// is incompatible with the time control every other scenario depends on. Vitest
// runs spec files sequentially, so this cannot disturb them.
//
// What this proves, and nothing else in the repo does: the webhook route works over
// **real HTTP through a real gateway**, not only through a Candid call to
// `http_request_update`. That is the transport `stripe listen` uses, so once this
// passes, pointing the Stripe CLI at the same URL is the only remaining step —
// see docs/SANDBOX-TESTPLAN.md.
test('55 — the webhook route serves real HTTP end to end, and delivers', async () => {
  // 1. Align the instance clock with real time so a REAL Stripe signature
  //    timestamp lands inside the canister's ±300 s tolerance. Without this the
  //    instance starts years off and every genuine Stripe signature 400s.
  await gw.pic.setCertifiedTime(new Date());
  await gw.pic.setTime(new Date());
  await gw.pic.tick(2);

  // 2. A working XRC (mock, installed at the mainnet id) and a FRESH CMC rate.
  //    Both are things a local `icp network` cannot provide: it has no XRC at all,
  //    and its seeded CMC rate is stamped 2021 with only governance able to
  //    update it. This is why PocketIC — not a local network — is where a full
  //    end-to-end Stripe run belongs.
  await setXrcRate(gw);
  await setCmcRate(gw);
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_treasury_config(WORKING_TREASURY));
  expectOk(await gw.asAdmin.set_webhook_secret(WEBHOOK_SECRET));
  // #33: both secrets, or `create_order` cannot produce a payable session.
  expectOk(await gw.asAdmin.set_stripe_api_key('rk_test_live_gateway_spec'));
  expectOk(await gw.asAdmin.set_stripe_origin('https://live.example'));
  // Same reason as the main suite: the §3 vector is a $5 tier, and #33's shipped
  // floor is $10. Lowering it here keeps the vector exact; the shipped default is
  // asserted in gateway.spec scenario 01.
  const { gate } = await gw.asAnon.lifecycle_config();
  expectOk(await gw.asAdmin.set_gate_config({ ...gate, minPurchaseUsdCents: 100n }));
  expectOk(await gw.asAdmin.set_card_tiers([
    { id: 'tier5', usdCents: TIER_USD_CENTS },
  ]));
  await fundFloat(gw, ORDER_E8S * 2n + ICP_FEE_E8S * 2n);
  // One destination, and the gateway refuses any other (#29).
  // Created BEFORE `makeLive()`, deliberately: the session outcall is answered
  // deterministically here. Once the instance is live it auto-progresses, so a
  // parked outcall could be picked up by the real network instead of the test.
  const created = expectOk(
    await createOrderWithSession(
      gw,
      { tier: 'tier5' },
      { cyclesLedgerAccount: { owner: user.getPrincipal(), subaccount: [] } },
      [],
    ),
  );

  // 3. Go live: a real HTTP gateway on a real port. Log the URL so a human can
  //    point `stripe listen --forward-to <url>` at it during a manual run.
  const port = await gw.pic.makeLive();
  expect(port).toBeGreaterThan(0);
  const url = `http://127.0.0.1:${port}/webhook/stripe?canisterId=${gw.backendId.toText()}`;
  // eslint-disable-next-line no-console
  console.log(`live webhook endpoint: ${url}`);

  // 4. POST a signed webhook over real HTTP — exactly what `stripe listen` does.
  const body = checkoutSessionBody({
    eventId: 'evt_live', paymentIntent: 'pi_live',
    clientReferenceId: clientReferenceFor(created.order.id), amountCents: TIER_USD_CENTS,
  });
  const t = BigInt(Math.floor(Date.now() / 1000));
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Stripe-Signature': stripeSignature(WEBHOOK_SECRET, t, body) },
    body,
  });
  expect(res.status).toBe(200);

  // 5. Auto-progress off, time control back — and the order actually delivers
  //    through the real CMC to a real destination canister.
  await gw.pic.stopLive();
  expect(await tickUntilStatus(gw, created.order.id, ['delivered'])).toBe('delivered');
  expect((await gw.asUser.get_order(created.order.id))[0]!.lockedCycles).toBe(TIER_LOCKED_CYCLES);
}, 180_000);
