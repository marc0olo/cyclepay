# Stripe sandbox test plan (manual, human-in-the-browser)

Most Stripe payloads in the automated suites are hand-crafted JSON written from the
API docs, so those suites prove the canister behaves as designed against *our* idea
of Stripe rather than against Stripe. This plan closes that gap and captures real
fixtures while doing it.

**Read §"What this cannot tell you" at the end before treating a green run as
go-live approval.** It is not one.

## Status: the good path has NOT been run on the current money-out path

⚠️ **Read this before treating anything below as evidence.** The browser flow has been
completed end to end once, on **2026-08-13** — but that run delivered by minting
through the Cycles Minting Canister against an ICP float, and money-out is now a
single `icrc1_transfer` out of a reserve the operator funds. The ICP machinery is
deleted. So the run splits into a half that still counts and a half that does not:

| Still evidence | No longer evidence |
|---|---|
| Real Internet Identity sign-in, the asset canister's `ic_env` cookie, the hosted Stripe Checkout page, a genuinely signed webhook reaching the canister, the frontend's 3 s poll reaching a delivered view, `cancel_order` | **Delivery itself** — every figure below came from a CMC mint against an ICP float. No cycles have been transferred out of a reserve in a manual browser run |

**What the 2026-08-13 run recorded** (kept because the Stripe-side figures are the
only real-payload evidence there is, not because the delivery half still holds): two
purchases, $5 and $20, both credited to the buyer's cycles-ledger account and
spendable — `icp cycles balance --of-principal <buyer>` → **18,207,492,307,692**;
error queue empty, so every dollar resolved to a delivery with no Type 1 or Type 2
obligation left open; nothing stuck mid-pipeline; `cancel_order` exercised twice.

**What is owed before go-live**, over and above the gaps that were already open:

| Gap | Where |
|---|---|
| ⚠️ **A fresh good-path run against reserve delivery** — pay, and watch cycles leave the reserve rather than come into existence. `reserve_status` before and after is the check the old run had no equivalent of | the procedure below, which is already written for this path |
| The CLI handoff — `icp identity link web` was never run, so "the cycles are reachable from the CLI" is still unproven | group H below |
| Fixture capture — **3 of 8** real payloads are committed (`ab5281c`); the run added none, so five integration tests stay skipped | group I, #4 |
| Refunds, async payment methods, disputes | groups E, F, G |
| Anything live-mode | not local-testable by construction |

---

## Two places to run it, and both do the whole good path

**Either works end to end. Neither needs mainnet or real money.**

| | PocketIC suite | local `icp network` |
|---|---|---|
| Cycles ledger + CMC (rate only) | ✅ real wasms | ✅ seeded |
| XRC | ✅ pinned `xrc_mock` | ✅ the `xrc` canister in `icp.yaml` |
| Fresh CMC rate | ✅ built in | ✅ via the PocketIC API (below) |
| Real Stripe events | ✅ `makeLive()` + `stripe listen` | ✅ `stripe listen` at the gateway |
| Time travel / outage injection | ✅ first-class | ✅ via the PocketIC API |
| **Frontend in a browser** | ❌ no `ic_env` cookie | ✅ **only here** |
| Repeatable, scripted, in CI | ✅ | ❌ manual |

Pick the **PocketIC suite** for anything you want to keep (it is committed, scripted
and runs in CI). Pick a **local network** when you need the real UI in a browser,
which is the one thing PocketIC cannot serve.

⚠️ Earlier versions of this file claimed a local network could not do this — twice,
both wrong. What makes it work: `icp network start` runs **PocketIC**, and its
control API is reachable. `lsof` on the launcher shows two listening ports — the HTTP
gateway that `icp network status` reports, and the PocketIC API alongside it. So a
local network has the two powers that look like they should be missing: **arbitrary
sender impersonation** and **time control**.

⚠️ **That is not a supported `icp` interface.** It depends on the launcher being
PocketIC and on that port being open, and either could change between releases. The
committed suites deliberately do not rely on it — it is a manual-testing convenience.

### The whole flow, in order, in a browser

This is **the** procedure. Everything below it in this file is either a group of
scenarios to work through or a by-hand reference for one of these steps.

What you have to supply: a **Stripe sandbox account** with the Stripe CLI logged in
to it, and a **restricted API key** (`rk_...`) scoped to **write Checkout Sessions**
and nothing else. No Payment Links, no Products, no Prices — the canister creates a
session per order through the API (#33). Nothing else, and no mainnet.

**How to create the key, and the go-live ordering, is RUNBOOK §3.**
Get it right here rather than at go-live: the four settings that break
`amount_total == tier.usdCents` produce no error, just a different cycle quantity,
so a sandbox run with automatic tax left on would "pass" while proving the wrong
thing.

```sh
# 0. Prerequisites, once.
brew install stripe/stripe-cli/stripe jq
stripe login                                    # a SANDBOX account, never live
npm --prefix test/integration run fetch:wasm    # the sha256-pinned xrc mock
npm --prefix test/browser ci                    # only if you also want the suites

# 1. A sellable local gateway. Put STRIPE_API_KEY=rk_... in scripts/.local-dev.env
#    (gitignored, sourced by the seed) so you set it once rather than per shell,
#    and so it never lands in your shell history. Without it the seed sets a
#    placeholder: everything except paying works, and create_order fails with a
#    real Stripe 401 rather than at a config check.
#    Nothing to configure in the Dashboard: the session carries inline price_data
#    with a fixed unit_amount and quantity 1, and none of the settings that could
#    move amount_total is enabled — src/backend/rails/Session.mo lists all eight
#    next to the body builder, and test/session.test.mo asserts their absence.
#    Nothing else to configure: the STRIPE_LINK_* variables went with
#    Tier.paymentLinkUrl (#33).
icp network start -d
icp deploy
scripts/local-dev-seed.sh

# 2. Wire Stripe, in its own terminal. It asserts the gateway can price before it
#    starts, and leaves the forwarder running until Ctrl-C.
scripts/stripe-dev.sh
```

Then, in the browser at the frontend URL `icp deploy` printed
(`http://frontend.local.localhost:8000/` with the default gateway port):

1. **Click "Get cycles".** The landing page has one route into the buy form, and
   the form asks nothing about where the cycles go: they go to the account of the
   principal you sign in as, and the gateway refuses any other destination (#29).
   That is what makes steps 6 and 7 meaningful.
2. **Sign in.** You get **local** Internet Identity automatically —
   `http://id.ai.localhost:8000`, deployed by `ii: true` in `icp.yaml`, chosen by
   `auth.ts` because the origin ends in `.localhost`. Nothing to configure, and a
   production origin cannot take that branch. Register a passkey; it is throwaway
   and local to this network, which is wiped by `icp network stop`.
3. **Pick an amount and create the order.** The rate is locked here, not at payment.
4. **Pay.** "Pay with card ↗" opens the order's own Checkout Session — the
   canister created it and set `client_reference_id` on it through the API (#33),
   so there is no link to configure and no parameter to append. Card
   `4242 4242 4242 4242`, any future expiry, any CVC. **You have 35 minutes**,
   enforced by Stripe; the button disappears at the deadline.
5. **Watch the page.** Leave the order tab open. The webhook arrives at the
   forwarder, delivery runs, and the page reaches **delivered** on its own 3 s poll
   with the guided tour leading. It should never need a reload.

   **If nothing happens**, work these three in order — each has produced a silent
   stall in a real run:

   | Check | Command | Wrong looks like |
   |---|---|---|
   | the secret is provisioned | `icp canister call backend webhook_secret_status '()'` | `isSet = false` — every event is dropped unverified, with no audit line and no error-queue entry |
   | the forwarder is up | `pgrep -fl "stripe listen"` | nothing — Stripe delivered to a closed door, and a resend is delivered **once**, so resending before the forwarder is up wastes it |
   | the CMC rate is fresh | `icp canister call backend audit_log '()' \| grep rates.refresh` | `rates.refreshFailed: cmc rate is stale or zero` — re-arm with `./scripts/local-dev-seed.sh --rate-only`. ⚠️ A stale rate fails at **order creation**, not at delivery: delivery reads no rate at all, so an order already `#paid` delivers regardless |

   To replay a payment the canister missed, resend the **`checkout.session.completed`**
   event — not `charge.updated`, `charge.succeeded` or `payment_intent.succeeded`,
   which Stripe lists just as prominently and none of which this canister acts on
   (see `Card.mo` for the four types it handles). A resent event of the wrong type
   logs `stripe.unhandledType` and changes nothing:

   ```sh
   stripe events list --limit 25          # find the checkout.session.completed
   stripe events resend <evt_...>
   ```

   `audit_log` is the diagnostic that separates these: a verified-but-unactionable
   event, a bad signature and an event that never arrived all look identical from
   the UI, and all three read differently there.
6. **Follow the tour.** Copy `icp identity link web dev --app <host>`, run it, then
   `icp identity principal --identity dev` and compare with the principal the page
   printed. **They must match.** A mismatch means the `--app` value did not match
   this origin, and the balance will look empty.
7. **Prove the cycles exist.**

   ```sh
   icp cycles balance --of-principal <the principal from step 6>
   ```

   This is the end of the flow the product promises, and the one thing no suite in
   this repo proves.

⚠️ **The CMC rate expires 15 minutes after seeding** and new orders are then refused
(an existing order is unaffected — its rate is locked). Refresh with
`scripts/local-dev-seed.sh --rate-only`; it needs no restart and nothing else to be
re-done.

### The same setup by hand, if you want to see each lever

```sh
icp network start -d
icp deploy
scripts/local-dev-seed.sh
```

`icp deploy` leaves a gateway that is **fail-closed on several axes at once** — no
tiers, no CMC rate, no Stripe secrets and an empty cycles reserve — plus one that
catches everyone: `minCanisterCycles` defaults to 5 T while `icp deploy` creates the
canister with less, so the admission gate refuses every purchase with "temporarily
unavailable while the gateway is topped up". That reads as a reserve problem and is
really about the canister's own **gas** — two different pots, and this is the error
that teaches the difference. The seed script tops the canister up
(`icp canister top-up backend --amount 20t`) and leaves the 5 T floor in place, so
local development exercises the same gate mainnet does.

The seed script sets all five and verifies a $5 purchase is admitted before it
reports success. **The CMC rate goes stale after 15 minutes** (`cmcRateMaxAgeNs` is
a security control, not a tuning knob); `scripts/local-dev-seed.sh --rate-only`
refreshes just that.

No restart is needed after seeding, and none of it survives a `--mode reinstall`.

### Every lever the seed script pulls, spelled out

Reference, not a second procedure: `scripts/local-dev-seed.sh` does all of this and
verifies the outcome of each step rather than the exit code. Read it when a step
fails and you need to know which lever to inspect, or when configuring something
that is not a local network.

```sh
npm --prefix test/integration run fetch:wasm    # the pinned xrc_mock
icp network start -d && icp deploy              # backend + xrc + frontend

# The admission gate checks the canister's OWN cycles before pricing, and a fresh
# deploy sits under the 5 T floor.
icp canister top-up backend --amount 20t

# Config. The webhook secret has a 16-character minimum; shorter is rejected.
icp canister call backend set_webhook_secret '("whsec_local_test_1234567890")'
icp canister call backend set_card_tiers \
  '(vec { record { id = "t10"; usdCents = 1_000 : nat } })'
icp canister call backend set_delivery_config \
  '(record { alertAfterNs = 7_200_000_000_000 : int; maxHoldNs = 259_200_000_000_000 : int })'
icp canister call backend set_expected_livemode '(opt false)'

# Fund the reserve: the cycles the gateway will SELL, in its own cycles-ledger
# account. ⚠️ This is not the canister's gas — that is the top-up above. Nothing
# creates these cycles; you transfer cycles you already have, which is also the
# mainnet procedure.
BACKEND_ID=$(icp canister status backend --json | jq -r '.id')
icp cycles transfer "$BACKEND_ID" --amount 100t
# Then let the gateway observe what arrived. Until it does, the admission gate has
# no reason to believe it can deliver and refuses with `#reserveShort`.
icp canister call backend refresh_reserve '()'
icp canister call backend reserve_status '()'   # availableToSell > 0

# Give the CMC a current rate (next section), then:
icp canister call backend refresh_rates '()'
icp canister call backend pricing_status '()' --query   # expect ok = true
```

Create an order and open the `stripeSessionUrl` on the returned order — that is
the payment page. The canister creates a **Checkout Session per order** and sets
`client_reference_id` through the API (#33), so there is no Payment Link to
configure and no URL parameter to append. Pay with `4242 4242 4242 4242` and watch
`get_order` reach `delivered`. `process_order` kicks the **delivery** without
waiting for the sweep — callable as the order's own owner as well as admin since
#30 PR-B — and `pending_deliveries` (admin) shows anything still outstanding
before the 2 h queue alert would. `delivery_journal` and `receipt` then carry the real
cycles-ledger block index and the delivered quantity.

⚠️ **Fund the reserve AND call `refresh_reserve` before creating an order**, or
every purchase is refused with `#reserveShort{available = 0}` against a funded
account: solvency is decided against a lower bound that only rises by observation
(#30 PR-B). `reserve_status.availableToSell` is the figure to check.

⚠️ **Two things that look like bugs and are not:**

- **The session expires 35 minutes after creation**, enforced by Stripe. Past that
  the pay button disappears — the UI renders expiry from `expiresAtNs`, not from
  the status, so it goes even before the `checkout.session.expired` webhook lands.
- **After paying, Stripe redirects to the configured origin**
  (`https://<frontend-id>.icp0.io`), which does **not** serve your local frontend.
  The payment completes and the webhook fires regardless; only the landing page
  fails to load. There is no local https origin to point at, and a caller-supplied
  `success_url` is deliberately impossible — it would be an open redirect Stripe
  renders after a real payment.

#### Giving the local CMC a current rate

**Why this is needed — and it is not "nobody updates the rate".** PocketIC has no
API for setting the conversion rate (`IcpFeaturesConfig` has exactly one variant,
`DefaultConfig`). It solves the problem a different way, documented on the
`cyclesMinting` feature:

> Deploys the NNS cycles minting canister, sets ICP/XDR conversion rate… **If
> enabled, the default timestamp of a PocketIC instance is set to 10 May 2021
> 10:00:01 AM CEST (the smallest value that is strictly larger than the default
> timestamp hard-coded in the CMC state).**

So the 2021 timestamp is not stale seeded data — **PocketIC deliberately pins the
instance clock to 2021 so the CMC's hard-coded rate is fresh.** That alignment is
why the committed integration suite works.

A local `icp network` breaks it by running at **real wall-clock time** (verified:
instance time reads as today while the CMC rate still reads 2021-05-10). Against the
15-minute staleness guard the rate is then permanently stale, and pricing reports
`"cmc rate is stale or zero"`.

Two ways to restore the alignment:

- **Move the rate forward** (below). Keeps real time, so real Stripe signatures
  verify. This is what you want.
- Move the *clock* back to 2021. Also works, and needs no impersonation — but then
  every real Stripe signature is rejected, because the canister checks the signature
  timestamp against its own clock with a ±300 s tolerance. It trades the CMC problem
  for the Stripe problem.

⚠️ **Impersonation itself is a first-class PocketIC feature, not a hack** — the
committed suite does exactly the same thing through `gw.cmcAsGovernance`, a
sender-scoped actor. The only unsupported part on a local network is *reaching* the
control API, because icp-cli does not publish its port.

⚠️ **The CMC requires a strictly greater timestamp** than the one it holds
("Proposed conversion rate must have greater timestamp"), so a second call inside the
same second fails. `setCmcRate` in the harness nudges time by 1 s first.

⚠️ **The PocketIC port is dynamic even with a fixed gateway port.** With
`gateway.port: 8000` the launcher listens on 8000 *and* an OS-picked port — the
latter is the control API. Discover it:

```sh
PID=$(pgrep -f 'pocket-ic --ttl' | head -1)
lsof -nP -iTCP -sTCP:LISTEN -a -p "$PID" | awk 'NR>1{print $9}' | grep -v ':8000$'
```

```js
// run from test/integration/ so the imports resolve
import { Principal } from '@icp-sdk/core/principal';
import { IDL } from '@icp-sdk/core/candid';

// Find the PocketIC port — it is the OTHER port the launcher listens on:
//   lsof -nP -iTCP -sTCP:LISTEN -a -p "$(pgrep -f 'pocket-ic --ttl')"
const PIC = 'http://127.0.0.1:<pic-port>/instances/0';
const b64 = (u8) => Buffer.from(u8).toString('base64');
const Arg = IDL.Record({
  data_source: IDL.Text, timestamp_seconds: IDL.Nat64, xdr_permyriad_per_icp: IDL.Nat64,
});
const t = await fetch(`${PIC}/read/get_time`).then((r) => r.json());
const payload = new Uint8Array(IDL.encode([Arg], [{
  data_source: 'local-dev',
  timestamp_seconds: BigInt(Math.floor(Number(t.nanos_since_epoch) / 1e9)),
  xdr_permyriad_per_icp: 35_000n,
}]));
await fetch(`${PIC}/update/submit_ingress_message`, {
  method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({
    sender: b64(Principal.fromText('rrkah-fqaaa-aaaaa-aaaaq-cai').toUint8Array()),
    canister_id: b64(Principal.fromText('rkp4c-7iaaa-aaaaa-aaaca-cai').toUint8Array()),
    method: 'set_icp_xdr_conversion_rate',
    payload: b64(payload),
    effective_principal: { None: null },
  }),
});
```

`/update/set_time`, `/update/set_certified_time` and `/update/tick` on the same
instance give time travel, so the 2 h alert and 72 h terminate are reachable locally
too.
### One command: `npm --prefix test/integration run sandbox`

Boots PocketIC with everything, aligns the clock, bootstraps dev config, goes live,
prints the webhook URL and a ready-made order, and stays up until Ctrl-C.

```sh
stripe login                                  # a SANDBOX account, never live
STRIPE_WEBHOOK_SECRET="$(stripe listen --print-secret)" \
  npm --prefix test/integration run sandbox
# then, second terminal:
stripe listen --forward-to '<the URL it prints>'
```

Everything is fake money and real plumbing: a real cycles ledger, a real CMC rate, real
cycles delivery, genuine signed Stripe events over a genuine HTTP gateway.

### The setup, if you are writing your own spec

```ts
await pic.setTime(new Date());            // so real Stripe signatures verify (±300 s)
await pic.setCertifiedTime(new Date());
await setXrcRate(gw); await setCmcRate(gw);   // working price inputs
const port = await pic.makeLive();        // real HTTP gateway
```

Then point the Stripe CLI at it:

```sh
stripe login                              # SANDBOX account, never live
stripe listen --forward-to "http://127.0.0.1:<port>/webhook/stripe?canisterId=<backendId>"
```

`src/live-gateway.spec.ts` already does the canister half and logs the exact URL —
run it, copy the line, and drive real events at it. Call `pic.stopLive()` when you
need time control back for the delay/terminate scenarios.

⚠️ **Two gotchas.** `makeLive` enables auto-progress, which is incompatible with
`advanceTime` — hence the separate spec file, and `stopLive()` before any
time-travel. And the clock alignment is not optional: a PocketIC instance starts
years away from now, so without `setTime` every genuine Stripe signature is
rejected with a 400.

### What still needs somewhere else

| Need | Where | Why |
|---|---|---|
| Completing a **hosted Checkout page** | a browser | Stripe deliberately has no headless path. `stripe trigger --override checkout_session:client_reference_id=<ref>` gets you a real *signed event* with the right reference, which covers attribution without the UI |
| **Frontend click-through** (group H) | ✅ a **local network** — see the walkthrough above | the asset canister serves the `ic_env` cookie the page needs; PocketIC does not |
| Live-mode behaviour: Radar, 3DS, payouts, disputes, account restrictions | mainnet + Stripe **live**, tight caps | unmockable |

Group H runs against a **local network**, not mainnet: the asset canister serves the
`ic_env` cookie the page reads for the backend id and root key.

Sign-in there uses **local** Internet Identity, and it does so automatically —
`identityProvider()` in `auth.ts` derives `http://id.ai.localhost:<port>/authorize`
from the page's own origin whenever the hostname ends in `.localhost`, and mainnet
`https://id.ai` otherwise. There is no environment variable to set and no way for a
production origin to take the local branch. (`VITE_II_URL` overrides both, and
exists for the PocketIC sandbox script.)

The frontend's *state logic* is covered headlessly by `main.test.ts` (jsdom) and its
*rendering* by `test/browser/` in Chromium, so what a human adds here is the real
login, the real Checkout page, the deployed-cookie path, and whether the tour's
commands land on the right principal.

**Nothing in this plan requires a mainnet deploy.** Only live-mode Stripe behaviour
does — Radar, 3DS, payouts, account restrictions — and that is a separate decision
from verifying the build.

Everything else — signatures, attribution, amounts, dedup, refunds, async methods,
event types, livemode, **and full delivery** — runs in PocketIC.

### Verification commands used throughout

Against PocketIC these are actor calls from the spec rather than `icp canister
call`; the method names and shapes are the same. Shown as CLI for readability, and
they work verbatim against a deployed canister.

```sh
icp canister call backend audit_log '()'
icp canister call backend error_queue_unresolved '(null, 50)'
icp canister call backend get_order '("<orderId>")'
icp canister call backend order_for_payment '("pi_...")'
icp canister call backend delivery_journal '("<orderId>")'
icp canister call backend receipt '("<orderId>")'           # owner identity only
```

---

## A. Signature and transport

| # | Scenario | How | Expect |
|---|---|---|---|
| A1 | Valid signature accepted | any real forwarded event | `200`; event appears in `audit_log` |
| A2 | Tampered body rejected | `stripe listen` + edit the body in a replayed `curl` with the original signature | `400`, nothing in state |
| A3 | Missing signature header | `curl` the route with no `Stripe-Signature` | `400` |
| A4 | **Unprovisioned secret → Stripe retries and later succeeds** | deploy fresh, do **not** set the secret, pay; then set the secret and wait for Stripe's retry | first delivery `503`; the retry delivers. Proves the retry contract we rely on |
| A5 | Secret rotation overlap | `set_webhook_secret` with a new value while a delivery is in flight | no lost event; `webhook_secret_status.generation` increments |
| A6 | Clock drift rejected | skew the host clock >5 min, deliver | `400`. Restore the clock afterwards |

## B. Attribution (claimed, not trusted)

| # | Scenario | How | Expect |
|---|---|---|---|
| B1 | Happy path | open the order's `stripeSessionUrl`, card `4242 4242 4242 4242` | order → `#paid`; → `#delivered` |
| B2 | No reference | `stripe trigger checkout.session.completed` | `200`; Type 1 `#unattributed`, `claimedRef` empty |
| B3 | Forged owner | hand-edit the ref to another principal, same order id | Type 1 — "claimed owner does not match" |
| B4 | Malformed reference | ref = `garbage` | Type 1 — "malformed" |
| B5 | Payment for an **expired** order | there is no TTL to shorten since #33 — open the order's session URL, expire that session in the Stripe Dashboard so `checkout.session.expired` arrives, then pay a *previously opened* copy of the page | `200`; order **stays `Expired`**, Type 1 `#unattributed` whose detail says "cannot be paid". **Refund it in Stripe.** Not honoured — #34 made expiry terminal |
| B6 | Payment for a **cancelled** order | `cancel_order`, then pay a page you opened before cancelling | `200`; order **stays `Cancelled`**, same Type 1 obligation. The buyer's decision wins; the money is refundable, never converted against it (#34). ⚠️ Hard to reach on purpose: cancel expires the session on Stripe *first*, so the payment usually cannot start at all |
| B7 | There is no rescue lever | — | `attach_payment` was deleted in #33. For B5 and B6 the only remedy is a refund in Stripe, which auto-resolves the entry |

## C. Amount honouring

| # | Scenario | How | Expect |
|---|---|---|---|
⚠️ **Rewritten by #33.** The canister sets the amount on the session, so C2 and
C3 can no longer be produced through the app at all — which is the point of the
change, and is why they are listed as *unreachable* rather than dropped. To
exercise the mismatch branch you have to create a session outside the app (a
hand-made `POST /v1/checkout/sessions` at a different `unit_amount`, carrying an
order's `client_reference_id`) — worth doing once, because it is the branch that
used to deliver silently.

| # | Scenario | How | Expect |
|---|---|---|---|
| C1 | Exact quoted amount | pay the order's own session | `lockedCycles` verbatim; `paidUsdCents == pricing.usdCents` |
| C2 | **Different amount** | not reachable through the app — hand-make a session at another `unit_amount` with the order's reference | `200`; **nothing delivered**, order stays `Created`, Type 1 naming both figures |
| C3 | Below the fee floor | same, at e.g. $0.31 | the same Type 1 as C2 — since #33 "below the floor" is not a separate outcome, it is just a different amount |
| C4 | Above the per-purchase ceiling | lower `maxPurchaseUsdCents` below an existing order's amount, then pay that order's session | Type 1, **nothing delivered**. This is the ceiling's one reachable case, and it needs no tampering |
| C5 | Wrong currency | not reachable through the app — the request pins `usd`; hand-make a EUR session | Type 1 — "unexpected currency" |

## D. Dedup and replay

| # | Scenario | How | Expect |
|---|---|---|---|
| D1 | Dashboard resend | Dashboard → the event → "Resend" | `200 duplicate event`; **no** second credit |
| D2 | Two genuine payments | pay the same link twice (two intents) | second → Type 1 `#duplicate` |
| D3 | Same intent, new event id | resend after >7 days if you can arrange it, else trust D1 | `200 already credited`, `stripe.replayedAfterPruning` |
| D4 | Credited elsewhere | not reachable through the app since #33 — nothing but the webhook writes an attribution. To force it, deliver a hand-made `completed` for order Y carrying an intent already credited to order X | nothing delivered; `stripe.creditedElsewhere` + a `#duplicate` naming both |

## E. Refunds — the highest-value group

These exercise the bug that survived three review rounds. **Use real Stripe
refunds, not crafted events** — the whole point is confirming Stripe's
`amount`/`amount_refunded` semantics match what the code assumes.

| # | Scenario | How | Expect |
|---|---|---|---|
| E1 | Full refund of an unattributed payment | B2, then refund it fully in the Dashboard | the Type 1 entry **auto-resolves** |
| E2 | **Partial refund** | refund e.g. $1 of a $5 charge | entry stays **OPEN**; `stripe.refundPartial`; **no** `refundUnmatched` line |
| E3 | Partial then completed | refund the remaining $4 | entry now resolves |
| E4 | Two partials summing to full | $2 then $3 | resolves on the second — Stripe's `amount_refunded` is cumulative |
| E5 | Refund **after delivery** | deliver an order, then refund | `#refundAfterDelivery` with `refundedCents` and `fullRefund` set; never auto-resolves |
| E6 | Refund of an escalated order | force an escalation, then refund | `stripe.refundOfEscalated`, not "pipeline may be mid-flight" |

## F. Async / delayed payment methods

The code assumes `checkout.session.completed` with `payment_status != "paid"`,
then `checkout.session.async_payment_succeeded`. **Verify Stripe really sends
that sequence** — a unit test previously encoded a wrong assumption here.

| # | Scenario | How | Expect |
|---|---|---|---|
| F1 | Delayed method settles | enable a delayed method (SEPA debit / `customer_balance`) on a test link and pay | first event `200 ignored`, order stays `#created`, `stripe.unpaidSession`; on settlement → `#paid` |
| F2 | Delayed method fails | trigger `async_payment_failed` | order stays payable; intent not consumed |
| F3 | Out-of-order arrival | if you can force settlement before `completed` | still delivers exactly once |

## G. Event types and configuration

| # | Scenario | How | Expect |
|---|---|---|---|
| G1 | Unhandled type | subscribe `charge.dispute.created`, trigger it | `200 ignored` + `stripe.unhandledType`. **Never** 4xx |
| G2 | **No `payment_intent`** | a 100%-off promo code, or a subscription-mode link | `200` + `#unprocessable`; a resend does **not** duplicate it |
| G3 | Livemode mismatch | point a **test** secret at a canister set to `opt true` | nothing delivered; `stripe.livemodeMismatch`; no obligation queued |
| G4 | Live-on-test | the reverse | nothing delivered, but an obligation **is** queued, keeping the real reference |
| G5 | Mode unset | clear it with `set_expected_livemode '(null)'`, pay | delivers, plus `stripe.livemodeUnset` on every payment |

## H. Frontend — only what a machine cannot do

**Most of this group is now automated.** `main.ts` has a jsdom suite against the
real `index.html` body, and `test/browser/` drives a production build in Chromium
with committed screenshot baselines. Re-checking those by hand is wasted time; what
is left below is the part no suite can reach.

Automated, and where — do **not** repeat these manually:

| Was | Now covered by |
|---|---|
| H1 tier buttons show a cycle estimate, not a tier id | `main.test.ts` |
| H2 the estimate names what lands, and the deposit fee is disclosed once | `main.test.ts` + `layout.spec.ts` |
| the form offers no destination question, and none of its old inputs exist | `layout.spec.ts` (`toHaveCount(0)`, so `display:none` cannot satisfy it) |
| a crafted order for someone else's account, or a non-default subaccount, is refused | `gateway.spec.ts` scenario 61 — the canister's refusal, which no UI test can show |
| H3 fee breakdown accounts for every cent, "operator margin: none" | `main.test.ts` |
| H5 a moved quote asks for confirmation, and the second click goes through | `main.test.ts` |
| H6 cancel appears only pre-payment | `main.test.ts` |
| H7 the receipt recomputes and reports a match | `main.test.ts` + `delivered.spec.ts` |
| the delivered tour, the stepper, the collapsed facts, buy-again, unknown order ids | `delivered.spec.ts`, through a fixture that replaces only the backend |
| paint: same-colour text, occlusion, opacity | five screenshot baselines, zero tolerance |

Still needs a human, and this is the list to work:

| # | Scenario | Expect | 2026-08-13 |
|---|---|---|---|
| H1 | **Real sign-in**, local Internet Identity at `http://id.ai.localhost:8000` | a passkey registers and the header shows a shortened principal. No suite can drive a passkey | ✅ |
| H2 | **The deployed asset canister**, not a static build | the page reads its backend id and root key from the real `ic_env` cookie and prices from the real canister. The browser suite serves `dist-fixtures` over a static server, so this path is only ever exercised by hand | ✅ |
| H3 | **The real Stripe hosted Checkout page** | Stripe has no headless path; `stripe trigger` gets you a signed event but never the page | ✅ |
| H4 | **The tour's commands actually work** | copy `icp identity link web dev --app <host>` from the delivered view, run it, then `icp identity principal --identity dev` and compare to the principal printed beside it. They must match, or the balance looks empty | ❌ **not run** — no `dev` identity exists |
| H5 | **The cycles are really there** | `icp cycles balance --of-principal <that principal>` shows the delivered quantity | ✅ 18.2 T for two orders |
| H6 | Order history across a **real** sign-out and sign-in | the table repopulates; a reopened order still shows its timeline | not run |
| H7 | Typography, hierarchy, and the italic rule | `brand-lint.sh` covers banned characters, vocabulary and hardcoded colour. The rest needs eyes | not run |

**H4 is the one that still matters most.** H5 proves the cycles exist at the
buyer's principal; H4 is what proves a buyer can *become* that principal from the
CLI and spend them. Until it passes, the last step of the product's promise —
"link the CLI, deploy" — is unverified end to end, and it is two commands.

## I. Fixture capture — do this while you are in there

Save the **raw request bodies** (Dashboard → event → the JSON) and commit them as
integration fixtures:

- `checkout.session.completed` — paid, with a reference
- `checkout.session.completed` — `payment_status: unpaid`
- `checkout.session.async_payment_succeeded`
- `charge.refunded` — full **and** partial
- a `payment_intent: null` session (G2)
- `charge.dispute.created`

Then assert the real bodies parse to the same values as the crafted ones. That
converts "our reading of the docs" into "the actual wire format", permanently.

---

## How this relates to `RUNBOOK.md`

They answer different questions and neither replaces the other:

| | This plan | `RUNBOOK.md` |
|---|---|---|
| Question | *Does this build behave correctly?* | *How do I operate a live system?* |
| When | **once**, before the rail carries money — and again after material changes to it | continuously, especially during incidents |
| Audience | whoever is validating the build | the on-call operator |
| Output | a green run, plus captured fixtures | a resolved incident |

The plan is a **precondition** to `RUNBOOK.md` §1: the go-live checklist assumes
the rail has already been shown to work.

⚠️ **Configuration is not duplicated, and the values differ on purpose.**
`scripts/stripe-dev.sh` bootstraps *dev* values — 2-minute alert threshold, float
gating off, `expected_livemode = false` — so failure modes are reachable inside a
session. (It set a 10-minute order TTL too, until #33 deleted retention: the
deadline is Stripe's now, and nothing local shortens it.) **None of them are safe on mainnet.** `RUNBOOK.md` §1
is the sole authority for go-live configuration.

Where this plan states an *expected outcome* (a Type 1 entry, a `#unprocessable`,
a `stripe.refundPartial`), `RUNBOOK.md` §6 states what to *do* about it. That makes
the run a useful check on the runbook itself: if a scenario here produces an entry
whose §6 row is missing, wrong, or unfollowable, the runbook is the thing to fix —
that is exactly how the "failed 25 times" and missing `transferRejected` rows were
found.

## What this cannot tell you

**A green run on this plan is not go-live approval.** It closes the biggest
*unknown*, not the remaining *known* gaps:

1. **Sandbox ≠ live.** No real Radar rules, no real 3DS challenges, no payout
   mechanics, no account-restriction behaviour. Only a mainnet deploy in **live**
   mode shows those, and disputes cannot be rehearsed at all.
2. **Disputes produce no on-chain signal.** Only `charge.refunded` is subscribed.
   A lost chargeback is invisible to the canister — accepted, documented, and
   managed by Dashboard vigilance.
3. **The SEV-SNP question is unresolved.** Memory encryption protects RAM, but
   canister state is checkpointed to disk and state-synced; if those are not
   confidential on the target subnet, the webhook secret leaks through that path
   and SEV buys nothing. The single most consequential open item, and no Stripe
   test touches it. **Owned by `RUNBOOK.md` §10** (the checklist to work through)
   and spec §7 (why it matters) — not restated here.
4. **Flat controller allowlist.** Any one controller can upgrade-then-drain. An
   honest trust model, but it is the model you would launch with.
5. **The reproducible-build gate has never run against a real deployment** —
   `RELEASE.md`'s publish-and-verify procedure is untested end to end.
6. **No monitoring exists.** Every safety mechanism here is a number someone has
   to go and look at; an alert nobody receives is not an alert. **`RUNBOOK.md` §9
   owns the plan** — metric table with thresholds and severities, and the reason the
   **reserve balance** has to be *pushed* rather than polled. Wire it before taking
   money.
7. **No external security audit** (spec §8 explicitly does not gate v1 on one).
8. **The deferred tail**, all real and none money-losing: gate-config/tier
   cross-check, `let #ii(owner)` trap, counts-map reconcile, the once-per-order
   alert keeping its first stall text.

### The honest bar

Phases A and B green ⇒ **the Stripe integration works as coded, and money-out
works against real NNS canisters.** That is the engineering bar.

Production also needs items 3 and 6 resolved — secret confidentiality and
monitoring — plus a deliberate decision to accept 1, 2, 4 and 7. Those are
judgement calls for the operator, not tests that can pass.
