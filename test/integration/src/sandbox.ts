// A fully local Stripe sandbox: PocketIC in live mode + the real Stripe CLI.
//
// No mainnet, no real ICP, no real cycles — and yet the whole money path runs for
// real: real ICP ledger, real CMC mint, real cycles ledger delivery, driven by
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
import { Principal } from '@icp-sdk/core/principal';
import {
  ICP_FEE_E8S, ORDER_E8S, TIER_USD_CENTS, WEBHOOK_SECRET,
  ensureRates, expectOk, fundFloat, setCmcRate, setXrcRate, setupGateway,
} from './harness';

const SECRET = process.env.STRIPE_WEBHOOK_SECRET ?? WEBHOOK_SECRET;

/// Dev values, deliberately not mainnet values: a 2-minute alert threshold so the
/// delay path is reachable in a session, a 10-minute TTL so expiry is, and
/// `expected_livemode = false` because a sandbox forwarder sends test-mode events.
const DEV_TREASURY = {
  burnCapE8s: 100_000_000_000n,
  burnWindowNs: 86_400_000_000_000n,
  alertAfterNs: 120_000_000_000n,
  maxHoldNs: 259_200_000_000_000n,
  lowFloatThresholdE8s: 0n,
};

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

  expectOk(await gw.asAdmin.set_treasury_config(DEV_TREASURY));
  expectOk(await gw.asAdmin.set_webhook_secret(SECRET));
  expectOk(await gw.asAdmin.set_card_tiers([
    { id: 'tier5', usdCents: TIER_USD_CENTS, paymentLinkUrl: 'https://buy.stripe.com/test_REPLACE_ME' },
  ]));
  expectOk(await gw.asAdmin.set_retention_config({ orderTtlNs: 600_000_000_000n }));
  await gw.asAdmin.set_expected_livemode([false]);
  await fundFloat(gw, ORDER_E8S * 50n + ICP_FEE_E8S * 50n);

  const destination = await gw.pic.createCanister();
  const port = await gw.pic.makeLive();
  const backendId = gw.backendId.toText();
  const webhookUrl = `http://127.0.0.1:${port}/webhook/stripe?canisterId=${backendId}`;

  console.log(`
────────────────────────────────────────────────────────────────────────
  LOCAL STRIPE SANDBOX — everything below is fake money, real plumbing
────────────────────────────────────────────────────────────────────────

  backend canister   ${backendId}
  gateway            http://127.0.0.1:${port}
  a spare canister   ${destination.toText()}   (use as an order destination)

  1. Forward real Stripe events here:

     stripe listen --forward-to '${webhookUrl}'

     ⚠ The secret must match. Either export it before starting this script:
         STRIPE_WEBHOOK_SECRET="$(stripe listen --print-secret)" npm run sandbox
       or the built-in test secret is in use (crafted events only).

  2. Create an order (as the test user identity):

     printed clientReferenceId → append to your test-mode Payment Link as
     ?client_reference_id=<ref>, or drive it headlessly:

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

  Config in effect (DEV values — never mainnet): burn cap 1000 ICP/day,
  alert after 2 min, order TTL 10 min, expected livemode = false.
`);

  // Create a first order so there is something to pay immediately.
  const created = expectOk(
    await gw.asUser.create_order('tier5', { canister: destination }, []),
  );
  console.log(`  ready-made order      ${created.order.id}`);
  console.log(`  clientReferenceId     ${created.clientReferenceId}\n`);

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
