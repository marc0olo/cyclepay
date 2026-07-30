# Stripe sandbox test plan (manual, human-in-the-browser)

Every Stripe payload in this repo is hand-crafted JSON written from the API docs.
That is the last significant unknown on the Card rail: the automated suites prove
the canister behaves as designed against *our* idea of Stripe, not against Stripe.
This plan closes that gap and captures real fixtures while doing it.

**Read §"What this cannot tell you" at the end before treating a green run as
go-live approval.** It is not one.

---

## Where to run it: PocketIC, not a local network

**One environment covers essentially everything: PocketIC in live mode + the Stripe
CLI.** No local `icp network`, no mainnet, no real ICP. Proven by integration
scenario 55, which POSTs a signed webhook over a real HTTP gateway and watches the
order reach `#delivered`.

Why PocketIC and not a local network — both verified, not assumed:

| | PocketIC | local `icp network` |
|---|---|---|
| ICP ledger / CMC / cycles ledger | ✅ real wasms | ✅ present and seeded |
| **XRC** | ✅ pinned `xrc_mock` at the mainnet id | ❌ **absent** → `create_order` = `rateUnavailable` |
| **CMC rate settable** | ✅ (governance impersonation) | ❌ seeded at **May 2021**, governance-only → permanently stale |
| Clock | ✅ `setTime` to now, then `advanceTime` | ❌ real time only |
| Real HTTP gateway | ✅ `makeLive()` | ✅ |
| Stop the ledger/CMC to force outages | ✅ | ❌ |

A local network therefore cannot create an order at all, and even with one the mint
would block on `mint.rateStale`. PocketIC has neither limitation *and* keeps time
control, which is what makes the 2 h alert and 72 h terminate reachable in seconds.

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

Everything is fake money and real plumbing: real ICP ledger, real CMC mint, real
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
| **Frontend click-through** (group H) | ⚠️ **mainnet + Stripe test mode** | see below |
| Live-mode behaviour: Radar, 3DS, payouts, disputes, account restrictions | mainnet + Stripe **live**, tight caps | unmockable |

⚠️ **Why the UI still needs a mainnet deploy.** Two things are missing locally, and
neither is Stripe's fault. The page needs the backend id and root key, which the
asset canister normally supplies through an `ic_env` cookie that PocketIC does not
set. And a local Internet Identity — the `ii` ICP feature — currently makes PocketIC
close the connection during instance creation, so it is disabled with the error
recorded in `harness.ts`. (Mainnet II itself is fine: both a local network and
PocketIC trust mainnet signatures. `VITE_II_URL` is already wired as the override
for when a local II works.)

Group H is therefore the one part of this plan that wants a mainnet canister in
**Stripe test mode** — real cycles, but test payments, and cheap at one $5 tier.
The frontend *state logic* is separately covered headlessly by
`src/frontend/src/main.test.ts` (13 jsdom tests), so what a browser adds is
rendering and the real login, not behaviour.

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
icp canister call backend mint_journal '("<orderId>")'
icp canister call backend receipt '("<orderId>")'           # owner identity only
```

---

## A. Signature and transport

| # | Scenario | How | Expect |
|---|---|---|---|
| A1 | Valid signature accepted | any real forwarded event | `200`; event appears in `audit_log` |
| A2 | Tampered body rejected | `stripe listen` + edit the body in a replayed `curl` with the original signature | `400`, nothing in state |
| A3 | Missing signature header | `curl` the route with no `Stripe-Signature` | `400` |
| A4 | **Unprovisioned secret → Stripe retries and later succeeds** | deploy fresh, do **not** set the secret, pay; then set the secret and wait for Stripe's retry | first delivery `503`; the retry mints. Proves the retry contract we rely on |
| A5 | Secret rotation overlap | `set_webhook_secret` with a new value while a delivery is in flight | no lost event; `webhook_secret_status.generation` increments |
| A6 | Clock drift rejected | skew the host clock >5 min, deliver | `400`. Restore the clock afterwards |

## B. Attribution (claimed, not trusted)

| # | Scenario | How | Expect |
|---|---|---|---|
| B1 | Happy path | your link + `?client_reference_id=<ref>` from `create_order`, card `4242 4242 4242 4242` | order → `#paid`; → `#delivered` |
| B2 | No reference | `stripe trigger checkout.session.completed` | `200`; Type 1 `#unattributed`, `claimedRef` empty |
| B3 | Forged owner | hand-edit the ref to another principal, same order id | Type 1 — "claimed owner does not match" |
| B4 | Malformed reference | ref = `garbage` | Type 1 — "malformed" |
| B5 | Payment for an **expired** order | shorten the TTL (dev bootstrap uses 10 min), let the order expire, then pay | **honoured** at the locked quantity — expiry is advisory |
| B6 | Payment for a **cancelled** order | `cancel_order`, then pay the link | **honoured** — cancelling must never strand a payment |

## C. Amount honouring

| # | Scenario | How | Expect |
|---|---|---|---|
| C1 | Exact tier amount | pay the tier price | `lockedCycles` verbatim; `paidUsdCents == pricing.usdCents` |
| C2 | **Different amount** | apply a partial-discount promo code to the link | repriced from the order's own snapshot, **not** today's rate |
| C3 | Below the fee floor | a link priced at e.g. $0.31 | Type 1 — the fee would swallow it |
| C4 | Above the per-purchase ceiling | lower `maxPurchaseUsdCents` below the tier, then pay | Type 1, **not** minted |
| C5 | Wrong currency | a EUR-priced link | Type 1 — "unexpected currency" |

## D. Dedup and replay

| # | Scenario | How | Expect |
|---|---|---|---|
| D1 | Dashboard resend | Dashboard → the event → "Resend" | `200 duplicate event`; **no** second credit |
| D2 | Two genuine payments | pay the same link twice (two intents) | second → Type 1 `#duplicate` |
| D3 | Same intent, new event id | resend after >7 days if you can arrange it, else trust D1 | `200 already credited`, `stripe.replayedAfterPruning` |
| D4 | Credited elsewhere | `attach_payment` an intent to order X, then let the real webhook for order Y arrive | not minted; `stripe.creditedElsewhere` + a `#duplicate` naming both |

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
| F3 | Out-of-order arrival | if you can force settlement before `completed` | still mints exactly once |

## G. Event types and configuration

| # | Scenario | How | Expect |
|---|---|---|---|
| G1 | Unhandled type | subscribe `charge.dispute.created`, trigger it | `200 ignored` + `stripe.unhandledType`. **Never** 4xx |
| G2 | **No `payment_intent`** | a 100%-off promo code, or a subscription-mode link | `200` + `#unprocessable`; a resend does **not** duplicate it |
| G3 | Livemode mismatch | point a **test** secret at a canister set to `opt true` | not minted; `stripe.livemodeMismatch`; no obligation queued |
| G4 | Live-on-test | the reverse | not minted, but an obligation **is** queued, keeping the real reference |
| G5 | Mode unset | clear it with `set_expected_livemode '(null)'`, pay | mints, plus `stripe.livemodeUnset` on every payment |

## H. Frontend (never yet rendered by a human)

`main.ts` has **no automated coverage** — all 69 frontend tests are pure functions.
Everything here is genuinely unverified.

| # | Scenario | Expect |
|---|---|---|
| H1 | Tier buttons | show a **cycle estimate**, not a tier id (the bug this fixed) |
| H2 | Destination toggle | estimate changes; the cycles-ledger note names the 100 M deposit fee |
| H3 | Fee breakdown | accounts for every cent; says "operator margin: none" |
| H4 | ck-USDC panel | disabled notice shown (the rail ships off) |
| H5 | Quote moved | lower `maxRateDeltaBps`/force a rate move between page load and submit → "Confirm at the new rate", then a second click succeeds |
| H6 | Cancel | button appears only pre-payment; frees the slot |
| H7 | Receipt | after delivery, the verification line recomputes and reports ✓ |
| H8 | Order history | survives sign-out/in; a reopened order still shows its timeline |

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
`scripts/stripe-dev.sh` bootstraps *dev* values — 10-minute TTL, 2-minute alert
threshold, float gating off, `expected_livemode = false` — so failure modes are
reachable inside a session. **None of them are safe on mainnet.** `RUNBOOK.md` §1
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
   ICP float has to be *pushed* rather than polled. Wire it before taking money.
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
