# What is tested, how, and what is not

One place to answer "is X covered?". Run everything with `scripts/test-all.sh`.

## The automated suites

Counts are deliberately absent: they drifted in three separate documents over one
week of work, and a wrong number is worse than no number. Run
`scripts/test-all.sh` for the live figures, and see `test/integration/README.md`
for the scenario map by id — ids are stable, counts are not.

| Suite | What it covers | How |
|---|---|---|
| **Motoko unit** (`test/*.test.mo`) | pure logic: HMAC, the Stripe signature scheme, JSON parsing, fee/rate arithmetic, the §4 state machine, dedup, retention bands, the error queue, `Cmc.terminationFor`'s eight money positions, `stageOf`'s resume decisions | `mops test`. No IC environment — every module takes its dependencies as a record (`Card.Deps`), which is why the whole ingestion path is unit-testable |
| **Frontend pure** (`format.test.ts`) | status mapping, cycle/USD formatting, the §3 pricing vector, slippage flooring, deposit-fee subtraction, receipt verification, every error-message mapping | `vitest` |
| **Frontend DOM** (`main.test.ts`) | the real `index.html` body in jsdom with a stubbed backend: tier estimates, fee split, destination switch, the acknowledge-then-confirm quote flow, cancel visibility, the receipt render, the disabled ck panel | `vitest` + jsdom |
| **PocketIC** (`test/integration/src/*.spec.ts`) | end-to-end against the **real** ICP ledger, CMC and cycles ledger, plus a sha256-pinned XRC mock at the mainnet id | `npm --prefix test/integration test` |

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

`main.ts` now has jsdom tests (`main.test.ts`) covering its state machine — the
quote-confirm flow, cancel visibility, the receipt render, destination switching —
against the **real `index.html` body**, so a renamed id fails the test. The backend
is stubbed deliberately: its behaviour is already proven by the PocketIC suite,
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
| a **trapping** daily reconcile | the reconcile is detached into its own message precisely so a trap cannot stop the sweep, but nothing can inject that trap: it would take an order store large enough to exhaust the instruction limit. What *is* covered is that the detached message runs, commits, and is cadence-gated in both directions (scenario 58); the isolation itself rests on the message boundary, not on a test |
| `stageOf`'s `#escalate` arm wiring | reaching `retriesExhausted` through it needs `maxMintRetries` (2,000) sweeps. The *terminate* route reaches the same money positions and is covered (53); the decision function is exhaustively unit-pinned. What no test exercises is the two-line expression handing it to the queue |

### 3. The deployment layer — covered separately by `scripts/e2e-local.sh`

The PocketIC suite installs wasms directly and **never runs `icp deploy`**, so
nothing it does exercises the deploy pipeline. `scripts/e2e-local.sh` covers that
against a real local network (`icp network start`), and is not part of
`scripts/test-all.sh` because it needs one running:

| What only this can prove | Why the PocketIC suite cannot |
|---|---|
| the deploy pipeline: recipes, `shrink: true`, embedded `candid:service`, the Candid compatibility check | it installs wasms directly |
| the **`PUBLIC_CANISTER_ID:xrc` override branch** | in PocketIC the mock sits *at* the mainnet id, so no env var is injected and only the fallback branch ever runs |
| the asset canister and its `ic_env` cookie (`ic_root_key` + the canister ids) | there is no asset canister and no HTTP gateway serving it |
| local Internet Identity responding | `ii: true` is a network feature, not a canister one |
| `icp.yaml` environment scoping — that `ic` lists only `backend` and `frontend`, keeping the mock off mainnet structurally | it is a config fact, not a canister behaviour |

It also reports two conditions loudly rather than papering over them, because both
look identical from inside a deploy and only one is safe: a **breaking Candid
change** against the deployed canister, and a **stable-shape change** whose upgrade
traps in `register_stable_type` (EOP refusing to reinterpret existing memory).
Locally it retries with `--yes` and `--mode reinstall`; on mainnet those are a
migration expression and a deliberate decision.

Two gotchas it encodes, both found by running it:

- The **xrc mock keeps its canned response in heap and sets it from `init_args` at
  install time**, so a routine `icp deploy` upgrades it and every later rate call
  traps with "Response has not been set". The script reinstalls it first.
- **`rates` stays null locally** and that is expected, not a failure: caching a pair
  also needs a fresh CMC rate, which needs governance impersonation through the
  PocketIC control API — an unsupported interface the script deliberately avoids.
  So local orders cannot be *priced*; the money path stays in the PocketIC suite.

### 4. Things only a real Stripe account can show

Covered by `docs/SANDBOX-TESTPLAN.md`, not by any suite:

- **The real wire format.** Every payload in the repo is hand-crafted JSON written
  from the API docs. The plan's fixture-capture step converts that into recorded
  reality — until then, the suites prove the canister matches *our reading* of
  Stripe.
- Completing a **hosted Checkout page** (no headless path exists).
- Live-mode behaviour: Radar, 3DS, payouts, account restrictions.
- **Disputes.** Only `charge.refunded` is subscribed, so a chargeback produces no
  on-chain signal at all — accepted and documented, managed in the Dashboard.

### 5. No coverage measurement

There is no instrumentation — no `c8`/istanbul for TypeScript, nothing for Motoko.
The tables above are a qualitative map, deliberately: an unmeasured percentage
would be worse than an honest inventory. If a number is ever wanted, `c8` on the
frontend would be the cheapest place to start, and it would immediately report
`main.ts` at roughly zero.

## Continuous integration

`.github/workflows/mops-test.yml` runs three jobs, all **verified green** on
`ubuntu-latest`:

- **motoko** — lint, unit suites, and that the committed `.did` is current
- **frontend** — build (regenerates bindings) → typecheck → tests
- **integration** — typecheck + the PocketIC suite

Triggers: `push` on `main`/`master`, `pull_request`, and `workflow_dispatch`. Note
that a push to a **feature branch matches none of the first two** — open a PR or
dispatch it manually.

The `integration` job needs a 4 KiB-page host, which `ubuntu-latest` satisfies (the
IC replica hard-asserts 4096-byte pages).

⚠️ **`npm ci` mismatches in `test/integration` cannot be reproduced on macOS.** The
first run of this job failed on Linux-only optional dependencies (`@emnapi/*`, pulled
in through vitest's rolldown wasm fallback) that a macOS resolve never records — so a
local `npm ci` passes while CI fails. If that job fails on install, delete
`test/integration/package-lock.json` and `node_modules` and resolve fresh; an
incremental `npm install` only narrows the gap. CI is the only test for it.
