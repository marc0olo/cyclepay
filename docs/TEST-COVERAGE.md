# What is tested, how, and what is not

One place to answer "is X covered?". Run everything with `scripts/test-all.sh`.

## The automated suites

Counts are deliberately absent: they drifted in three separate documents over one
week of work, and a wrong number is worse than no number. Run
`scripts/test-all.sh` for the live figures, and see `test/integration/README.md`
for the scenario map by id — ids are stable, counts are not.

| Suite | What it covers | How |
|---|---|---|
| **Motoko unit** (`test/*.test.mo`) | pure logic: HMAC, the Stripe signature scheme, JSON parsing, fee/rate arithmetic, the §4 state machine, dedup, the error queue, every money position `Cmc.terminationFor` can report (including the delivery ones #30 PR-A added), `stageOf`'s resume decisions, and reserve solvency | `mops test`. No IC environment — every module takes its dependencies as a record (`Card.Deps`), which is why the whole ingestion path is unit-testable |
| **Frontend pure** (`format.test.ts`) | status mapping, cycle/USD formatting, the §3 pricing vector, slippage flooring, deposit-fee subtraction, receipt verification, every error-message mapping | `vitest` |
| **Frontend DOM** (`main.test.ts`) | the real `index.html` body in jsdom with a stubbed backend: tier estimates, fee split, the single route into the buy form, the destination it sends (read from the session, never the form), the acknowledge-then-confirm quote flow, cancel visibility, the receipt render, the view machine (including the poll's own arrival at `delivered`, under fake timers) | `vitest` + jsdom |
| **Browser** (`test/browser/*.spec.ts`) | what jsdom is structurally blind to: the cascade, layout, reachability, and — via committed screenshot baselines — paint. Runs against a production build served statically, with an unreachable gateway by default and a canned one where a spec needs answers | `npm --prefix test/browser test` (Playwright, Chromium) |
| **PocketIC** (`test/integration/src/*.spec.ts`) | end-to-end against the **real** ICP ledger, CMC and cycles ledger, plus a sha256-pinned XRC mock at the mainnet id | `npm --prefix test/integration test` |

### What makes the PocketIC suite the real bar

- **Real NNS wasms**, at their mainnet ids, deployed by `icpFeatures`.
- **Real HMAC-signed Stripe payloads**, signed by an independent Node
  implementation — so it is not testing our signer against our verifier.
- **Time control**: the 2 h delay alert and the 72 h terminate bound are reachable
  in seconds; the ledger's 24 h dedup window likewise.
- **HTTPS outcalls are PARKED, not performed** (#33). Every `create_order` and
  `cancel_order` blocks on one, and the suite answers it — which for the request
  *shape* is better coverage than a live call, because the exact bytes the
  canister built can be read back (scenario 63 does). Three things it cannot tell
  you, and the third was measured rather than assumed:
  - the real cycle cost;
  - whether `max_response_bytes` is big enough for a real Stripe response;
  - **whether the transform strips enough for consensus.** pic-js can answer with
    one response per replica, which looks like a way to test this — a scenario
    was written on that basis, then `Session.strip` was mutated to leak every
    header and the whole suite still passed. The mock does not enforce consensus
    the way a subnet does. That failure is first observable against real Stripe,
    where it takes the rail down; `Session.classifyFailure` labels it so the audit
    log points at the transform.
- **Failure injection**: the NNS canisters can be *stopped* (`stopNns`,
  impersonating NNS root) to force real outages. Since #30 PR-A the one that
  matters is the **cycles ledger**, and stopping it is how scenarios 11, 33, 35 and
  47 hold an order undelivered — it replaced a stale CMC rate and a zero burn cap,
  neither of which can stall delivery any more.
  ⚠️ Read balances **before** stopping and put the stop in `try`/`finally`: a throw
  in between leaves the ledger stopped for the rest of the run. See the coupling
  note in `test/integration/README.md`.
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
| Amount honouring (exact → delivers; any other amount → Type 1, minting nothing; ceiling; currency) | unit + PocketIC | the mismatch branch is mutation-checked: disabling the equality check fails the suite |
| Dedup / replay (event id, payment intent, post-prune resend, credited-elsewhere) | unit + PocketIC | |
| Refunds (full, partial, cumulative partials, after delivery, of an escalated order) | unit + PocketIC | |
| Async payment methods (settle, fail, out-of-order) | unit + PocketIC | |
| Pricing guards (plausibility, delta, source count, implied XDR/USD, staleness) | unit + PocketIC | every guard rejects in isolation |
| Money-out: **one transfer** out of the reserve, exactly-once, journal replay | PocketIC | incl. across real upgrades. `transfer → notify → forward` was three steps until #30 PR-A |
| Outages: the **cycles ledger** down — delivery retries, strands nothing, then delivers | PocketIC | 11, 33, 35, 47 |
| Outages: ICP ledger down, CMC down, notify stalled, rate moved mid-mint | **gone with the mint path** (#30 PR-A) | the exposures no longer exist; see the deletion table in `test/integration/README.md` |
| Escalation → the right money position and instruction | unit (all 8 arms) + PocketIC | see the gap below |
| Delay alerts and terminal bounds per in-flight status | PocketIC | |
| Buyer never stuck: cancel, expiry, late payment, quote pinning | PocketIC | |
| Frontend state machine and reactions | jsdom (`main.test.ts`) | real `index.html` body, stubbed backend |
| Frontend **rendering**: cascade, layout, reachability, paint | browser (`test/browser`) | screenshot baselines for paint; see below for what is still uncovered |

## What is not covered, and why

### 1. The frontend against a real backend, and real Internet Identity

Two layers cover the frontend, and the split is deliberate.

`main.test.ts` runs the **real `index.html` body** in jsdom with a stubbed backend,
so a renamed id fails the test. The stub is not a weakness: the backend's behaviour
is already proven by the PocketIC suite, and a stub is the only way to drive a
`#quoteChanged`, a delivered receipt, or a poll transition on demand.

`test/browser` runs a **production build in Chromium**, because jsdom has neither a
cascade nor a layout and is therefore blind to a whole class of bug that has shipped
here twice: `el.hidden` reads `true` for an element a class selector is keeping on
screen. It covers reachability (can a person actually get from here to the next
step), and — through committed `toHaveScreenshot()` baselines — paint, which no
assertion reaches. The pulse in the hero figure painting *over* the step numbers was
found that way, after every visibility, opacity and font assertion passed.

A **test-only fixture hook** (`src/frontend/src/fixtures.ts`) is what makes the
post-purchase surfaces reachable at all. It replaces the backend and nothing else,
so sign-in, routing, the view machine and the 3 s poll are the app's own code; it is
absent from a production build (`__FIXTURES__` is a `define`d literal, and
`scripts/test-all.sh` greps the shipping bundle to keep that checked rather than
claimed). Before it existed the delivered view could only be photographed by
injecting DOM state, which is how it shipped broken twice.

**Both of those were done by hand on 2026-08-13** against a local network and a
Stripe sandbox, and no mainnet deploy was needed: real Internet Identity login (the
local II the network deploys), the deployed asset canister's real `ic_env` cookie,
the real hosted Checkout page, a genuinely signed webhook, the real CMC mint, and
cycles credited to the buyer's account. Twice. Verified from the canister — two
`mint.delivered` entries, 18.2 T spendable at the buyer's principal, an empty error
queue, nothing held. The evidence and the exact figures are in
`docs/SANDBOX-TESTPLAN.md` → "Status: the good path has been run, once".

**Three things that run did not close**, and no suite closes either:

- **The CLI handoff.** `icp identity link web` was never run, so "the cycles are
  reachable from the CLI" — the last step the product promises — is unproven. Group
  H4.
- **Real Stripe payload capture.** 3 of 8 fixtures are committed; five integration
  tests stay skipped until the rest are captured (#4, group I). The suite prints
  which are missing on every run rather than hiding it.
- **Refunds, async payment methods, disputes, and anything live-mode.** Groups E, F,
  G, and a separate decision respectively.

### 1b. Mutations that ARE caught — run, not assumed

The rows below this one record gaps. These record the opposite, because "no test catches
it" is only meaningful next to a list of what does. Each was applied to the tree and the
suite run:

| Mutation | Caught by |
|---|---|
| drop the `#paid` clause from `unsettledDelivery` (the escalation-freeze bug, which shipped into the branch once) | scenarios **73** and **76** — 76 by design, 73 because a frozen reconcile stops adopting a top-up |
| credit the floor back on `#delivered` — a **real** debit, i.e. breaking rule 2/3's asymmetry in the optimistic direction | scenario **73**'s opening `reserveFloor ≤ reserveBalance`. ⚠️ Worth knowing *which* line: the bound is enforced by one assertion against the suite's whole accumulated history, not by the scenario's own subject |
| `openEntry` recording a hardcoded status instead of the order's | `test/cmc.test.mo`'s coupling test, added after the bug — and scenario **75**, which found it originally by asserting a set was non-empty |

### 2. Structural limits in PocketIC — verified, not assumed

| Not covered | Why |
|---|---|
| **the reserve decision pairing a stale balance with a live tally** | ⚠️ **Verified by mutation that nothing caught it — and then the design removed the defect rather than testing it.** With the awaited-balance design still in place, replacing `Reserve.promisedForDecision` (since deleted) by a live-only read left the entire suite green: catching it needed a delivery continuation scheduled inside `create_order`'s balance-read gap, and PocketIC gives no way to force that ordering. The decision is now synchronous against `reserveFloor` — a maintained lower bound moved only by our own outflows — so there are no two values to pair. Scenario 72 stays as a guard on the invariant (`promisedTotal ≤ balance`), and the row stays because it is the record of how the untestable bug was closed: by deleting the pairing, not by covering it |
| **the reserve floor adopting a balance across an in-flight outflow** | The floor's soundness rests on adoption happening only in a quiet window, and the window is established across an `await` — so reproducing the unsafe interleaving needs a transfer issued inside a reconcile's balance-read gap, which PocketIC cannot schedule on demand. What **is** covered: `test/reserve.test.mo` pins that a non-quiet observation is refused, and scenario 76 covers the failure this produced in practice — one escalated order making the window permanently unsatisfiable, which is the direction that actually shipped into the branch. ⚠️ **And the untestable direction is exactly where a second bug hid**: `Cmc.openEntry` hardcoded `status = #minting`, so the predicate matched nothing and the window was *always* satisfied. Nothing here caught it and scenario 76 passed vacuously — it was found by a test written for `pending_deliveries`, and the guard is now a unit test on the coupling (`test/cmc.test.mo`) plus comments at both ends. Read this row as: the interleaving is untestable, so the predicate's INPUTS have to be pinned instead |
| **the delivery replay sending the intent's ORIGINAL fee** | ⚠️ **Verified by mutation that nothing catches this.** Re-reading `icrc1_fee()` on the replay path passes every Motoko assertion and the whole PocketIC suite: the unit tests pin the arithmetic (`locked - amount` recovers the fee), and the integration suite runs against a real cycles ledger whose fee has never moved. Catching it needs a fee change *inside* the 24 h dedup window. It matters because if the ledger's dedup key includes the fee, a replay after a fee change is a distinct transaction and the buyer is paid twice — so the code comment is the guard, and this row exists so its absence is not mistaken for coverage |
| **the stored ledger fee PERSISTING after `#BadFee`** | Staging it needs the stored fee to differ from the ledger's, and since #30 PR-B deleted `set_cycles_ledger_fee` (self-justifying: the only state it fixed was one it could create, and its typo shorted buyers) there is no seam to make them differ — the PocketIC cycles ledger's fee never moves. ⚠️ **Deliberate trade**: shipping an admin money lever to production so a test can stage a state is worse than the gap. The gap is one line (`cyclesLedgerFee := expected`) whose failure is **loud** — the fee does not stick, so `delivery.feeChanged` fires on every delivery instead of once, which RUNBOOK §9 carries as a P3 row. The ledger's report is still unit-pinned (`interpretTransfer(#Err(#BadFee))`), and scenario 74 was deleted with the lever rather than left asserting a mechanism it could no longer reach |
| `#ambiguousForward` end to end | ⚠️ **Now unreachable rather than untested**: it needed a callback dropped between the pre-forward marker and the forward, and #30 PR-A deleted the two-step (delivery is one call). The row stays until #36 removes the variant, so nobody reads its absence as a coverage gap |
| a **trapping** daily reconcile | the reconcile is detached into its own message precisely so a trap cannot stop the sweep, but nothing can inject that trap: it would take an order store large enough to exhaust the instruction limit. What *is* covered is that the detached message runs, commits, and is cadence-gated in both directions (scenario 58); the isolation itself rests on the message boundary, not on a test |
| `stageOf`'s `#escalate` arm wiring | reaching `retriesExhausted` through it needs `maxMintRetries` (2,000) sweeps — and since #30 PR-B deleted the cap on the **delivery** path, it is reachable only from the two legacy mint stages that #36 removes. The *terminate* route reaches the queue the same way and **is** covered — by scenario **35** since #30 PR-A deleted 53, which this row used to cite. ⚠️ The claim is narrower than it was: 35 reaches the `deliveryWaitExceeded` position, not the four mint positions 53 also touched, and those are unreachable rather than untested. The decision function stays exhaustively unit-pinned |

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
- **`rates` stays null until the local gateway is seeded.** Caching a pair needs a
  fresh CMC rate as well as the XRC, and the CMC's rate is settable only by NNS
  governance. `scripts/local-dev-seed.sh` does that through the PocketIC control
  API (see docs/SANDBOX-TESTPLAN.md), so local orders **can** be priced — the smoke
  test just does not depend on it, because that control port is not a supported
  `icp` interface.

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
