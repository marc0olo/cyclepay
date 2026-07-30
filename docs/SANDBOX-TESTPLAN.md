# Stripe sandbox test plan (manual, human-in-the-browser)

Every Stripe payload in this repo is hand-crafted JSON written from the API docs.
That is the last significant unknown on the Card rail: the automated suites prove
the canister behaves as designed against *our* idea of Stripe, not against Stripe.
This plan closes that gap and captures real fixtures while doing it.

**Read §"What this cannot tell you" at the end before treating a green run as
go-live approval.** It is not one.

---

## Phases, and why there are three

| Phase | Setup | Covers | Cost |
|---|---|---|---|
| **A** | local `icp network` + Stripe **test** mode via `stripe listen` | signatures, transport, and every error-queue path that needs **no order** — see the box below | free |
| **B** | backend on **mainnet** + Stripe **test** mode (`set_expected_livemode '(opt false)'`) | the **full** flow: real CMC mint, real cycles delivered, receipts, refund-after-delivery | real ICP (small) |
| **C** | mainnet + Stripe **live**, tight caps, one real card | payouts, Radar, 3DS, account restrictions | real money |

### ⚠️ What a local network actually provides (verified, not assumed)

An earlier version of this file claimed a local network "runs only this project's
canisters — no ICP ledger, no CMC, no cycles ledger". **That is wrong.** Probed
against `icp network start -d` on icp-cli 0.3.x:

| Canister | Local | Notes |
|---|---|---|
| ICP ledger `ryjl3-…` | ✅ present, seeded | answers `icrc1_name` → "Internet Computer" |
| Cycles ledger `um5iw-…` | ✅ present | answers `icrc1_name` → "Trillion Cycles" |
| CMC `rkp4c-…` | ✅ present | returns a rate — but see below |
| **XRC `uf6dk-…`** | ❌ **absent** | `refresh_rates` → `"xrc call rejected: Canister uf6dk-… not found"` |

So the local ceiling is **lower** than the old claim, for two independent reasons:

1. **No XRC ⇒ no price ⇒ no order.** `create_order` answers `rateUnavailable`, so
   nothing that needs an *existing order* can be tested locally at all. And
   icp-cli 0.3.x has no `--specified-id`, so the sha256-pinned `xrc_mock` the
   PocketIC suite uses cannot be installed at that id to work around it.
2. **The seeded CMC rate is stamped May 2021** (`timestamp_seconds = 1_620_633_601`)
   and only the governance principal `rrkah-fqaaa-aaaaa-aaaaq-cai` may update it —
   which cannot be impersonated on a real replica (that is a PocketIC-only
   capability). Against the 15-minute staleness guard the rate is permanently
   stale, so even with an order the mint would block on `mint.rateStale`.

**What Phase A therefore covers:** everything that does *not* require an order —
signature and transport (A1–A3, A6), unattributed payments (B2), unhandled and
unprocessable events (G1–G2), and refunds of unattributed entries (E1–E4). That is
still the entire signature/transport and error-queue-without-an-order surface.

**Everything else needs Phase B.** Stripe test mode against a mainnet canister is
the only configuration with a working XRC and a live CMC rate, so it is the only
place the full flow runs. Use a test-mode Payment Link and point the Dashboard
endpoint straight at `https://<backend-id>.raw.icp0.io/webhook/stripe` — no CLI
forwarding needed. Scenarios marked **[B]** require it; so does anything in B1,
B3–B6, C, D and F.

### Phase A setup

```sh
brew install stripe/stripe-cli/stripe jq
stripe login                       # choose a SANDBOX account, never live
icp network start -d && icp deploy backend
scripts/stripe-dev.sh              # bootstraps config, wires the session secret, forwards
```

You also need **your own test-mode Payment Link** for the happy path — `stripe
trigger` builds a synthetic session with no `client_reference_id` and cannot test
attribution success.

### Verification commands used throughout

```sh
icp canister call backend audit_log '()'
icp canister call backend error_queue_unresolved '(null, 50)'
icp canister call backend get_order '("<orderId>")'
icp canister call backend order_for_payment '("pi_...")'
icp canister call backend mint_journal '("<orderId>")'      # [B]
icp canister call backend receipt '("<orderId>")'           # [B], owner identity only
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
| B1 | Happy path | your link + `?client_reference_id=<ref>` from `create_order`, card `4242 4242 4242 4242` | order → `#paid`; **[B]** → `#delivered` |
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
| E5 | Refund **after delivery** **[B]** | deliver an order, then refund | `#refundAfterDelivery` with `refundedCents` and `fullRefund` set; never auto-resolves |
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
| H7 | Receipt **[B]** | after delivery, the verification line recomputes and reports ✓ |
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
   mechanics, no account-restriction behaviour. Phase C is the only place those
   appear, and disputes cannot be rehearsed at all.
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
