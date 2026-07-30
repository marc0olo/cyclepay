# What is tested, how, and what is not

One place to answer "is X covered?". Run everything with `scripts/test-all.sh`.

## The three automated suites

| Suite | Count | What it covers | How |
|---|---|---|---|
| **Motoko unit** (`test/*.test.mo`) | 21 files | pure logic: HMAC, the Stripe signature scheme, JSON parsing, fee/rate arithmetic, the §4 state machine, dedup, retention bands, the error queue, `Cmc.terminationFor`'s eight money positions, `stageOf`'s resume decisions | `mops test`. No IC environment — every module takes its dependencies as a record (`Card.Deps`), which is why the whole ingestion path is unit-testable |
| **Frontend pure** (`format.test.ts`) | 69 tests | status mapping, cycle/USD formatting, the §3 pricing vector, slippage flooring, deposit-fee subtraction, receipt verification, every error-message mapping | `vitest` |
| **Frontend DOM** (`main.test.ts`) | 13 tests | the real `index.html` body in jsdom with a stubbed backend: tier estimates, fee split, destination switch, the acknowledge-then-confirm quote flow, cancel visibility, the receipt render, the disabled ck panel | `vitest` + jsdom |
| **PocketIC** (`test/integration/src/*.spec.ts`) | 67 scenarios | end-to-end against the **real** ICP ledger, CMC and cycles ledger, plus a sha256-pinned XRC mock at the mainnet id | `npm --prefix test/integration test` |

### What makes the PocketIC suite the real bar

- **Real NNS wasms**, at their mainnet ids, deployed by `icpFeatures`.
- **Real HMAC-signed Stripe payloads**, signed by an independent Node
  implementation — so it is not testing our signer against our verifier.
- **Time control**: the 2 h delay alert and the 72 h terminate bound are reachable
  in seconds; the ledger's 24 h dedup window likewise.
- **Failure injection**: the ledger and CMC can be *stopped* (`stopNns`,
  impersonating NNS root) to force real outages — scenarios 51–54.
- **Real HTTP**: `pic.makeLive()` serves an actual gateway, so scenario 55 proves
  the webhook route over genuine HTTP rather than a Candid call to
  `http_request_update`.
- **Upgrade-mid-flight**: real stop→upgrade(EOP keep)→start inside the §5.1
  ambiguity windows, asserting exactly-one ledger debit.

## Coverage by concern

| Concern | Where | Note |
|---|---|---|
| Signature verification (rotation overlap, both-direction window, constant-time compare) | unit + PocketIC | externally pinned vectors |
| Attribution (claimed-not-trusted, owner mismatch, malformed, expired, cancelled) | unit + PocketIC | |
| Amount honouring (exact, repriced, fee floor, ceiling, currency) | unit + PocketIC | |
| Dedup / replay (event id, payment intent, post-prune resend, credited-elsewhere) | unit + PocketIC | |
| Refunds (full, partial, cumulative partials, after delivery, of an escalated order) | unit + PocketIC | |
| Async payment methods (settle, fail, out-of-order) | unit + PocketIC | |
| Pricing guards (plausibility, delta, source count, implied XDR/USD, staleness) | unit + PocketIC | every guard rejects in isolation |
| Money-out: transfer → notify → forward, exactly-once, journal replay | PocketIC | incl. across real upgrades |
| Outages: ledger down, CMC down, notify stalled, rate moved mid-mint | PocketIC | 51–54 |
| Escalation → the right money position and instruction | unit (all 8 arms) + PocketIC | see the gap below |
| Delay alerts and terminal bounds per in-flight status | PocketIC | |
| Buyer never stuck: cancel, expiry, late payment, quote pinning | PocketIC | |
| Frontend **rendering and interaction** | ❌ **nothing** | see below |

## What is not covered, and why

### 1. The frontend in a real browser

`main.ts` now has 13 jsdom tests (`main.test.ts`) covering its state machine — the
quote-confirm flow, cancel visibility, the receipt render, destination switching —
against the **real `index.html` body**, so a renamed id fails the test. The backend
is stubbed deliberately: its behaviour is already proven by 67 PocketIC scenarios,
and a stub is the only way to drive a `#quoteChanged` or a delivered receipt
on demand.

What jsdom cannot show: real layout and CSS, the real Internet Identity login, and
that the Candid shapes match reality in a browser. **Nobody has rendered the page
in a browser yet.** Group H of `docs/SANDBOX-TESTPLAN.md` covers that, and it needs
a mainnet deploy in Stripe test mode — PocketIC does not set the `ic_env` cookie the
page reads, and the local-II feature currently breaks instance creation (recorded in
`harness.ts`).

### 2. Structural limits in PocketIC — verified, not assumed

| Not covered | Why |
|---|---|
| `#ambiguousForward` end to end | needs a callback *dropped* between the pre-forward marker and delivery; `stopCanister` **drains** callbacks rather than dropping them. Unit-pinned is the ceiling |
| `stageOf`'s `#escalate` arm wiring | reaching `retriesExhausted` through it needs `maxMintRetries` (2,000) sweeps. The *terminate* route reaches the same money positions and is covered (53); the decision function is exhaustively unit-pinned. What no test exercises is the two-line expression handing it to the queue |

### 3. Things only a real Stripe account can show

Covered by `docs/SANDBOX-TESTPLAN.md`, not by any suite:

- **The real wire format.** Every payload in the repo is hand-crafted JSON written
  from the API docs. The plan's fixture-capture step converts that into recorded
  reality — until then, the suites prove the canister matches *our reading* of
  Stripe.
- Completing a **hosted Checkout page** (no headless path exists).
- Live-mode behaviour: Radar, 3DS, payouts, account restrictions.
- **Disputes.** Only `charge.refunded` is subscribed, so a chargeback produces no
  on-chain signal at all — accepted and documented, managed in the Dashboard.

### 4. No coverage measurement

There is no instrumentation — no `c8`/istanbul for TypeScript, nothing for Motoko.
The tables above are a qualitative map, deliberately: an unmeasured percentage
would be worse than an honest inventory. If a number is ever wanted, `c8` on the
frontend would be the cheapest place to start, and it would immediately report
`main.ts` at roughly zero.

## Continuous integration

`.github/workflows/mops-test.yml` runs three jobs on every push and PR: `motoko`
(lint, unit suites, and that the committed `.did` is current), `frontend` (build,
typecheck, tests), and `integration` (the 67 PocketIC scenarios).

⚠️ The `integration` job has **not been executed** — it was written here and the
local equivalent is what is verified. It needs a 4 KiB-page host, which
`ubuntu-latest` satisfies; expect to iterate on the first real run.
