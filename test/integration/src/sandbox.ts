// A fully local Stripe sandbox: PocketIC in live mode + the real Stripe CLI.
//
// No mainnet, no real ICP, no real cycles — and yet the whole money path runs for
// real: a real cycles ledger the gateway transfers out of, a real CMC for its rate, driven by
// genuine signed Stripe events over a genuine HTTP gateway.
//
//   npm --prefix test/integration run sandbox
//
// Then, in a second terminal, forward real Stripe events at the printed URL:
//
//   stripe login                    # a SANDBOX account, never live
//   stripe listen --forward-to '<the URL this prints>'
//
// The signing secret must match. Easiest is to let this script read it:
//
//   STRIPE_WEBHOOK_SECRET="$(stripe listen --print-secret)" \
//     npm --prefix test/integration run sandbox
//
// Ctrl-C to tear down.
import {
  TIER_USD_CENTS, WEBHOOK_SECRET,
  ensureRates, expectOk, setCmcRate, setXrcRate, setupGateway, user,
  clientReferenceFor, allowTestBuyers } from './harness';

const SECRET = process.env.STRIPE_WEBHOOK_SECRET ?? WEBHOOK_SECRET;

async function main(): Promise<void> {
  console.log('booting PocketIC (real ICP ledger, CMC, cycles ledger + pinned XRC mock)…');
  const gw = await setupGateway();

  // Align the clock with real time, or every genuine Stripe signature is rejected:
  // the canister checks the signature timestamp against its own clock with a ±300 s
  // tolerance, and a PocketIC instance starts years away from now.
  await gw.pic.setTime(new Date());
  await gw.pic.setCertifiedTime(new Date());
  await gw.pic.tick(2);

  // Working price inputs. Neither is available on a local `icp network`: it has no
  // XRC at all, and its seeded CMC rate is stamped 2021 with only governance able
  // to change it.
  await setXrcRate(gw);
  await setCmcRate(gw);
  await ensureRates(gw);
  expectOk(await gw.asAdmin.set_webhook_secret(SECRET));

  // ⚠️ **Lower the floor before registering the tier, or nothing here works.** The
  // gate's `minPurchaseUsdCents` default is $10 and `TIER_USD_CENTS` is $5, so
  // `set_card_tiers` refuses with `#belowFloor` and the harness dies before it prints
  // anything. `gateway.spec.ts` does the same thing for the same reason.
  //
  // The $5 figure is not arbitrary and is not worth changing: 500¢ gross − 45¢ fee =
  // 455¢ net = **exactly one ICP** at $4.55, worth exactly 3.5 T cycles at the seeded
  // CMC rate. Every number a human checks in this harness comes off that vector, so
  // the floor moves rather than the amount.
  const gateDefaults = (await gw.asAnon.lifecycle_config()).gate;
  expectOk(await gw.asAdmin.set_gate_config({ ...gateDefaults, minPurchaseUsdCents: 100n }));
  expectOk(await gw.asAdmin.set_card_tiers([
    { id: 'tier5', usdCents: TIER_USD_CENTS },
  ]));
  await gw.asAdmin.set_expected_livemode([false]);

  // ⚠️ **A 2-minute alert threshold, deliberately not the mainnet 2 h.** The delay
  // path is the one thing in this harness a human cannot reach by waiting: at the
  // default an operator would have to keep the session open for two hours to see a
  // delayed delivery appear in `delayed_deliveries`. The max hold stays at 72 h — an escalation
  // during a demo would be a false alarm, and 35/47/80 cover that path in CI.
  //
  // ⚠️ **A config a harness declares but never sends is worse than no config**: the
  // comment promising a short threshold becomes the only trace, and the harness quietly
  // runs on the default. That has happened here twice — check that a config object in
  // this directory is actually passed to a setter, not merely defined.
  expectOk(await gw.asAdmin.set_delivery_config({
    alertAfterNs: 120_000_000_000n,
    maxHoldNs: 259_200_000_000_000n,
  }));

  const port = await gw.pic.makeLive();
  const backendId = gw.backendId.toText();
  const webhookUrl = `http://127.0.0.1:${port}/webhook/stripe?canisterId=${backendId}`;

  console.log(`
────────────────────────────────────────────────────────────────────────
  LOCAL STRIPE SANDBOX — everything below is fake money, real plumbing
────────────────────────────────────────────────────────────────────────

  backend canister   ${backendId}
  gateway            http://127.0.0.1:${port}
  cycles credited to ${user.getPrincipal().toText()}   (the buyer's own account)

  1. Forward real Stripe events here:

     stripe listen --forward-to '${webhookUrl}'

     ⚠ The secret must match. Either export it before starting this script:
         STRIPE_WEBHOOK_SECRET="$(stripe listen --print-secret)" npm run sandbox
       or the built-in test secret is in use (crafted events only).

  2. Create an order (as the test user identity):

     printed stripeSessionUrl → open it. That IS the payment page: the canister
     created a Checkout Session and set client_reference_id on it through the
     API, so there is nothing to append. Or drive it headlessly:

     stripe trigger checkout.session.completed \\
       --override checkout_session:client_reference_id=<ref>

  3. Watch it deliver. The recovery timer is armed; money-out runs for real
     against the CMC.

  4. Clicking through the real UI against this instance is NOT wired up yet.
     The frontend signs in with mainnet Internet Identity, which this instance
     trusts — but the page also needs the backend id and root key, which the
     asset canister normally supplies via an ic_env cookie and PocketIC does not
     set. A local II (the 'ii' ICP feature) currently breaks instance creation;
     see the note in harness.ts. Until that is resolved, UI click-through is the
     one part of the plan that needs a mainnet deploy in Stripe TEST mode.

     VITE_II_URL already exists as the override for when a local II works.

  Config in effect (DEV values — never mainnet): delivery alert after 2 min
  (mainnet: 2 h), max hold 72 h, expected livemode = false. There is no order
  TTL of ours — the deadline is the Stripe session's own ~35 minutes.
`);

  // ⚠️ **An order cannot be created without the Stripe API key.** Since the rail
  // creates a Checkout Session per order, `create_order` calls Stripe and fails with
  // `#sessionUnavailable` when no key is provisioned — so this harness cannot
  // pre-create an order the way it used to, and used to die here with a raw
  // `expected #ok, got {"err":{"sessionUnavailable":...}}`.
  //
  // The key comes from the environment, never from source and never from a command
  // line: it must be a **restricted** key (`rk_...`) with Checkout Sessions = Write
  // (which also grants the read the recovery sweep needs) and everything else None. A leaked write-sessions key can only create sessions that pay
  // *us*; an unrestricted `sk_` can issue refunds, which is materially worse to leak.
  //
  //   STRIPE_API_KEY=rk_... npm run sandbox
  //
  // Without it the harness still boots and everything except paying works — which is
  // most of what it is for (the banner, the config, the webhook forwarder target).
  const apiKey = process.env.STRIPE_API_KEY;
  if (apiKey && apiKey.length > 0) {
    expectOk(await gw.asAdmin.set_stripe_api_key(apiKey));
    // #99: these suites fund a reserve and accept test payments, so without an
    // allow-list every create_order refuses as the faucet state.
    await allowTestBuyers(gw);
    const created = expectOk(
      // One destination, and the gateway refuses any other (#29): the caller's own
      // cycles-ledger account, default subaccount.
      await gw.asUser.create_order(
        { tier: 'tier5' },
        { cyclesLedgerAccount: { owner: user.getPrincipal(), subaccount: [] } },
        [],
      ),
    );
    console.log(`  ready-made order      ${created.order.id}`);
    console.log(`  clientReferenceId     ${clientReferenceFor(created.order.id)}\n`);
  } else {
    console.log(`  ⚠️  no STRIPE_API_KEY in the environment, so no order was created.
      Everything except paying works. To make a payable order:
        STRIPE_API_KEY=rk_... npm run sandbox
      Use a RESTRICTED key with Checkout Sessions = Write, everything else None.\n`);
  }

  // Live mode auto-progresses, so nothing needs ticking. Hold the process open.
  console.log('running — Ctrl-C to tear down\n');
  process.on('SIGINT', () => {
    void (async () => {
      console.log('\ntearing down…');
      await gw.pic.stopLive().catch(() => undefined);
      await gw.pic.tearDown().catch(() => undefined);
      await gw.server.stop().catch(() => undefined);
      process.exit(0);
    })();
  });
  await new Promise(() => undefined);
}

void main();
