# PocketIC integration suite — the Card rail go-live bar (spec §9)

> **Looking for what is tested where, across all suites?** See
> `docs/TEST-COVERAGE.md`. This file documents the PocketIC suite specifically.

End-to-end scenarios against PocketIC instances running the **real**
canisters: the cycles ledger, and the cycles minting canister for its rate query
are deployed at their mainnet IDs by PocketIC's `icpFeatures` (the same Wasms
mainnet runs, kept in sync with the instance topology by the server), and the

- **Stripe** — crafted `checkout.session.completed` / `charge.refunded`
  payloads, HMAC-SHA256-signed exactly per the `Stripe-Signature` scheme,
  delivered through the canister's real HTTP ingress path.
- **The Exchange Rate Canister** — the **released `xrc_mock` Wasm** is installed
  at the mainnet XRC id (`uf6dk-hyaaa-aaaaq-qaaaq-cai`, whose range lives on the
  **II subnet** — found by searching the topology rather than assumed, see
  `subnetHosting`). `setXrcResponse` drives it to return a specific rate, quality
  signal, or any of the 16 error variants. ⚠️ **The mock's response is
  init-only**, so changing it means a *reinstall*, which `setXrcResponse` does.
  There is no HTTPS outcall to intercept: pricing is entirely inter-canister.
- **NNS governance** — the CMC's ICP/XDR conversion rate is set by calling
  `set_icp_xdr_conversion_rate` with the governance canister principal as
  sender (PocketIC permits arbitrary senders).
- **Time** — staleness windows, the recovery timer, and the delivery
  max-wait are driven with PocketIC time control; mid-flight interruption
  tests step rounds one tick at a time and upgrade the canister inside the
  §5.1 ambiguity windows.

## Running

```sh
cd test/integration
npm ci
npm test        # pretest fetches the pinned ledger wasm + builds the backend
```

Requirements: Node ≥ 20.11 and `mops` on PATH. The PocketIC server binary
ships with the `@dfinity/pic` npm package.

Two API traps this suite has to work around, both easy to hit again:

- **Upgrading requires stopping first, and an explicit EOP option.** A canister
  with outstanding message callbacks cannot be upgraded, and Motoko's enhanced
  orthogonal persistence requires
  `upgradeModeOptions: { wasm_memory_persistence: [{ keep: null }] }`. Both are
  handled by `upgradeBackendMidFlight`. (The Rust `pocket-ic` crate has an
  `upgrade_eop_canister` helper for the second half; the TS client at 0.22.0
  does not, so the option is set explicitly.)
- ⚠️ **`stopCanister` drains outstanding callbacks rather than discarding
  them.** That is what makes the stop-then-upgrade sequence work at all, and it
  means an upgrade cannot be used to interrupt a call mid-await. The mid-flight
  scenarios therefore assert the *stronger* property — that state after the drain
  is consistent and the §5.1 ambiguity rules still hold — rather than pretending
  a callback vanished.
- **Run `npm test`, never `npx vitest run`.** The latter skips `pretest`, so the
  suite silently runs against a **stale backend Wasm** — a green suite that proves
  nothing about the code you just changed.

**The host must run a 4 KiB-page kernel** — macOS (Intel or Apple Silicon)
and x86_64 Linux are fine. The IC replica's memory tracker hard-asserts
4096-byte pages, so the suite cannot run inside arm64 Linux VMs with 16 KiB
kernels (notably Apple-Silicon Docker/sandbox guests); the server crashes at
instance creation. Run it on the host or in CI instead.

## Mutation-checking a scenario: use `npm test`, never bare `vitest`

⚠️ **`npx vitest run` does not rebuild the backend.** The wasm PocketIC installs is
built by the `pretest` hook (`npm run build:backend`), which fires for `npm test` and
not for a direct `vitest` invocation. Mutate a `.mo` file, run `npx vitest run`, and
the suite loads the **previous** wasm — so the mutation appears not to break anything
and you conclude the scenario is vacuous when it is fine, or that a guard is untested
when it is covered.

`mops check` does not save you: it typechecks and lints, and a lint-clean mutation is
exactly the kind you want to test. The tell is a suspiciously *complete* pass — every
scenario green including ones that assert the mutated behaviour directly.

So: `npm test` for anything where the backend changed, and read the first run's
timing — a mutation run that finishes as fast as a no-op run did not rebuild.

## CI

`ci/integration.yml` is a ready GitHub Actions job (ubuntu-latest is
x86_64, so PocketIC runs natively). It lives here rather than in
`.github/workflows/` only because the sandbox's deploy token lacks the
`workflow` scope; to enable it:

```sh
git mv test/integration/ci/integration.yml .github/workflows/integration.yml
git commit && git push   # needs a workflow-scoped token (a normal `gh auth` token is fine)
```

## ⚠️ The suite is ORDER-COUPLED by design — read this before diagnosing a failure

One gateway, one PocketIC instance, orders shared across scenarios (`orderA`…
`orderF`), one mutable XRC mock, one clock that only moves forward. That is
deliberate — it is what makes the scenarios cheap and what lets later ones assert
against state earlier ones built — but it has a consequence worth knowing before
you spend an afternoon on the wrong scenario:

**When a scenario fails, suspect a neighbour's state before you suspect its
subject.** Three measured instances, all from #30 PR-A:

- One stale assertion in scenario 32 (`cyclesMinted` was `lockedCycles`, and had
  become `lockedCycles - fee`) made it fail before it restored the XRC mock's
  rate. The next **23** scenarios then failed in `ensureRates` with
  `InconsistentRatesReceived` — twenty-three rate errors from one arithmetic
  change, none of them about rates.
- Scenario 39 failed with *"no HTTPS outcall was made"* and 41 with a wrong
  locked quantity. Neither was about its own subject; both were neighbours whose
  outcall accounting and rate state shifted when an earlier scenario's parking
  mechanism changed.
- Scenario 12 failed only because 11 failed ahead of it.

Practical rules that follow:

- **Every fix needs a full run.** Scenarios cannot be run in isolation — `-t` on
  one of them skips the state it depends on. Budget ~4 minutes per verification.
- **Read the failure list top-down and fix the FIRST one.** Durations are the
  tell: a genuine failure takes hundreds of milliseconds to seconds because it
  does work, while cascade victims fail in ~20–90 ms in `beforeAll`-ish setup.
- **`advanceTime` is global and irreversible.** A scenario that advances the
  clock changes the world for every scenario after it, which is why several carry
  an explicit `ensureRates` / `setCmcRate` re-arm at their end rather than their
  start.
- ⚠️ **And since #52, advancing the clock past ~65 minutes has a SECOND side
  effect: it provokes background HTTPS outcalls.** Every order this suite creates
  gets a 35-minute deadline (`now + 2100`, Stripe's real minimum), so once the
  clock passes that deadline plus the sweep's 30-minute grace, every lingering
  `#created` order becomes due for a session **retrieve**. The recovery sweep is
  therefore a *second, background producer* of parked outcalls, alongside
  `create_order` and `cancel_order`.

  This is why `awaitPendingOutcall` filters instead of returning the first parked
  call: it answers any sweep retrieve it meets with `{"status":"open"}` — a no-op
  for the sweep — and keeps looking for the one the scenario asked for. It used to
  return `pending[0]`, which was correct only while there was exactly one
  producer. `afterEach` drains as a backstop, and **a drain count above one there
  is a signal**: it means a scenario provoked more background retrieves than
  anyone expected, which is worth understanding rather than absorbing.

  The failure this prevents looks exactly like the cascades above — a scenario
  asserting on a request it did not make — so it would cost the next person a
  four-minute run per surprise to attribute correctly.
- **Read ledger balances BEFORE `stopNns`, and put the stop inside `try`/`finally`.**
  A balance query against a stopped canister throws, and a throw between the stop
  and the `try` skips the `finally` — leaving the ledger stopped for the whole
  rest of the run. One misplaced line produced nine unrelated-looking failures,
  twice.
- If a scenario needs isolation badly enough to justify a second gateway, that is
  its own issue with its own cost argument — not something to bolt on mid-change.

## Scenario map (spec §9 coverage)

⚠️ **Partial by construction, and it drifts.** This maps §9 coverage plus each
later batch of additions; scenarios **20–39** were never added to it, and rows go
stale when a scenario's contract changes — row 42 described the pre-#34
"a payment racing the cancel still delivers" behaviour for three review rounds
after the branch inverted it. `grep -oE "^test\('[0-9]+" src/gateway.spec.ts` is
the authoritative list. If you change what a scenario asserts, change its row.

| # | Scenario | §9 item |
|---|----------|---------|
| 01 | 503 before secret provisioning, controller-gated admin API | — |
| 02 | tier config gating | — |
| 03 | empty cache + a failing XRC → `#rateUnavailable`; every rate guard rejects in isolation | pricing fail-closed |
| 04 | XRC + CMC through the real derivation; §3 pricing vector; order authz | happy path (pricing half) |
| 05 | signature/window/404/405/413 guards on the live route table | duplicate/replay (guards) |
| 06 | the money-out path is ONE transfer out of the reserve, exact in both directions | delivery arithmetic |
| 07 | the transfer memo is the ORDER id, so two identical orders both deliver | happy path |
| 08 | event-id dedup, intent dedup, `#duplicate`, refund auto-resolve | duplicate/replay |
| 09 | claimed-not-trusted attribution → `#unattributed` | refund obligations |
| 10 | delivery to a real cycles-ledger account | happy path (2nd forward arm) |
| 11 | a cycles-ledger outage strands **nothing**: the order stays `#paid`, no obligation is filed, and the sweep replays the same intent and delivers | reserve delivery under outage |
| 12 | an upgrade concurrent with delivery pays **exactly once**, and the timer re-arms | upgrade-mid-flight, §5.1 replay, postupgrade re-arm |
| 15 | audit-log seq monotonicity, the delivery path's **tag contract**, and error-queue accounting: a failed delivery files **nothing**, because only fiat can be stranded | — |
| 16 | admission gate: no burn-cap headroom refuses the quote; `can_purchase` agrees; restoring headroom re-opens the rail | pre-creation gate |
| 17 | per-purchase ceiling bounds both tier registration and the amount | pre-creation gate |
| 18 | expiry: only `checkout.session.expired` moves an order there — time alone never does — it survives a simulated year undeleted, and a late payment files a refund obligation instead of delivering (#33, #34) | Stripe owns the deadline |
| 19 | owner-only `receipt`; recomputes `net × P × 10¹² / U == lockedCycles` from it | price verifiability |

### Added with the pricing-transparency work

| # | Scenario | Coverage |
|---|----------|----------|
| 39 | a payment against a **cancelled** order files a refund obligation and never traps — the surviving half of scenarios 36–39, which #33 deleted with `attach_payment` | the guard that keeps `markPaid`'s trap unreachable |
| 40 | `quote_previews` fee split, §3 vector, deposit fee, and an order locking exactly the previewed figure | quote/lock agreement |
| 41 | a +40% ICP move → `#quoteChanged` naming the new figure, nothing created; the new figure is accepted; a favourable move never refuses; `null` opts out | server-side quote pinning |
| 42 | owner-only `cancel_order` produces `#cancelled` and frees a slot, is idempotent, refuses a paid order, and a payment racing the cancel is **refunded, not converted** — one obligation carrying the intent (#34) | buyer never locked out, buyer's decision wins |

### Added from the code review

| # | Scenario | Coverage |
|---|----------|----------|
| 43 | a partial `charge.refunded` leaves the refund obligation obligation **open**; completing it settles | refund amount fidelity |
| 44 | a verified-but-unprocessable event is acked 200 and queued once; unverifiable input still 400s | endpoint-disable avoidance |
| 45 | `checkout.session.async_payment_succeeded` delivers a payment that `completed` reported unpaid | delayed payment methods |
| 46 | a test-mode event cannot deliver on a gateway declared live; a live one still does | livemode gate |
| 47 | a `#deliveryDelayed` alert is resolved when the order **escalates**, not only when it delivers, and its audit tag exists | no orphan worklist entries |

### Changed by #30 PR-A (the reserve settlement swap)

Delivery transfers out of the reserve rather than creating cycles, so every
scenario whose *mechanism* was the mint pipeline changed or went. **Five were
deleted** — 13, 14, 48, and 51–54 collapsed into that set — and each names its
heir where the deletion happened in `gateway.spec.ts`, so what it proved is not
lost:

| Deleted | Subject | Where the property lives now |
|---|---|---|
| 13 | upgrade mid-**forward** (the pre-forward window) | 12 — one transfer, so there is no window; "exactly once across an upgrade" survives |
| 14 | a treasury hold alerts, waits, then delivers | 33 — re-expressed against a cycles-ledger outage |
| 48 | the **notify** stage is bounded by time, not only retries | 35 — delivery's time bound. Its "a delivered order is never caught by the timeline" assertion was **salvaged into 35** |
| 51, 53 | CMC outage stalls / parks at `#icpAtCmc` / escalates | 33, 35, 47 — alert then terminate, against a real outage |
| 52 | an ICP ledger outage cannot fabricate a block | 11, 12 — the §5.1 replay contract, now delivery's |
| 54 | a rate move between transfer and notify escalates instead of subsidising | **no heir, and none is needed**: `lockedCycles` is fixed at creation and no rate is read between payment and delivery, so the exposure is gone rather than handled |

Rewritten rather than deleted: **06** (the reserve arithmetic, exact in both
directions), **07** (the `memo = orderId` collision property), **11**, **12**,
**20**, **33**, **34**, **35**, **47**.
| 49 | `async_payment_succeeded` arriving **before** `completed` still delivers once; the later event raises no obligation | out-of-order events |
| 56 | the per-purchase ceiling cannot be lowered under a live tier | config safety |
| 57 | an already-credited intent is caught **before** attribution, not after | double-credit protection |
| 58 | the sweep reconciles the status tallies on its own cadence and reports no drift | tally integrity |
| 59 | a Stripe resend past the dedup window does not file a second unprocessable | redelivery vs double-pay |
| 60 | a stall that moves to a different stage re-raises the alert instead of leaving stale wording | alert accuracy |
| 61 | a crafted `create_order` for another principal's account, or a non-default subaccount, is refused by the **canister** — the refusal no UI test can demonstrate (#29) | destination enforcement |
| 62 | the four new order fields and `ratesFetchedAtNs` survive a real stop → upgrade → start; `ratesFetchedAtNs < createdAtNs`; a `#cancelled` order decodes as itself and stays unpayable across the upgrade (#34) | durable order record |

### Added by #33 (per-order Checkout Sessions) and #30 PR-B (solvency)

⚠️ **63–72 had no rows until now.** They were added across #33's three PRs and #30
PR-A/PR-B while this table was not updated, which is exactly the drift the heading
above warns about. Backfilled here rather than left as a claim of authority the file
did not have. (64 and 70 do not exist — numbers reserved by scenarios that were cut
before landing.)

| # | Scenario | Coverage |
|---|----------|----------|
| 63 | the Checkout Session request is byte-for-byte what Stripe needs (#33) | outcall payload fidelity |
| 65 | a session that cannot be created fails the order **in the same call** (#33) | no order without a payable URL |
| 66 | cancelling is atomic with Stripe — never half-cancelled (#33) | `#cancelled` means unpayable |
| 67 | `checkout.session.expired` is the only thing that expires an order (#33) | Stripe owns the deadline |
| 68 | a cancel racing session creation cannot leave a payable URL behind (#33) | no orphaned session |
| 69 | a **failed** session creation racing a cancel does not double-release (#33) | tally integrity under a race |
| 71 | a custom amount is bounded by the gate in both directions (#33) | floor and ceiling on typed input |
| 72 | a delivery completing during a create cannot manufacture capacity (#30 PR-B) | guard on `promisedTotal ≤ balance` |
| 73 | a funded reserve sells **nothing** until the gateway observes it; one quiet observation adopts the ledger's truth outright (#30 PR-B) | rule 1, and the trap the design accepts |
| ~~74~~ | **deleted with the `set_cycles_ledger_fee` lever it depended on.** The lever was the only seam for making the stored fee differ from the ledger's, and it was removed as self-justifying — the one state it fixed was one it could create, and its typo silently shorted buyers. Shipping an admin money lever so a test can stage a state is the wrong trade | heirs: `interpretTransfer(#Err(#BadFee))` in `test/cmc.test.mo`, the `delivery.feeChanged` P3 row in RUNBOOK §9, and scenarios 06/10 for the fee arithmetic |
| 75 | a buyer heals their **own** stuck delivery; a stranger and the anonymous principal cannot; the admin lever still works and is the only one audited (#30 PR-B) | owner-scoped `process_order` |
| 76 | one escalated order must not freeze the reserve reconcile forever (#30 PR-B) | regression test for a shipped bug |
| 77 | an escalated order whose cycles **did** arrive is recorded as delivered rather than filed as abandoned (#30 PR-B) | `#needsReview → #delivered` |
| 78 | an order whose delivery is unsettled cannot be abandoned into a double payout (#30 PR-B) | the guard a reviewer found; scenarios 34 and 47 were codifying the hole |
| ~~79~~ | **deleted with the states it asserted about (#36).** It checked that no order had ever entered `#minting`/`#icpAtCmc`/`#awaitingTreasury` — a claim that stopped being makeable when `OrderStatus` lost those cases | heir: **the deletion itself**. Unreachability became unrepresentability, which is stronger than any test. The measurement it carried: routing `#beginDelivery` into `#minting` failed 06/07/08/10/11/12, and every other insertion point was refused by the transition matrix |

⚠️ **76 and 77 both consume the order scenario 35 escalates**, through the
suite-global `orderEscalated`, because reproducing that state costs another 72 h of
clock advance plus the two rate re-arms that follow it. They assert the shape they
depend on (`needsReview`, intent journalled, no block) rather than assuming it, so a
change in 35 fails there instead of passing vacuously. 76 must stay **before** 77:
77 fills in the block index, which settles the entry 76 needs unsettled.

### Live HTTP gateway (`live-gateway.spec.ts`)

`pic.makeLive()` starts a **real HTTP gateway** on a real port, so the webhook route
can be exercised over genuine HTTP rather than only through a Candid call to
`http_request_update`. Scenario 55 does exactly that and then watches the order
reach `#delivered`.

That is also the setup for a manual Stripe run: `setTime(new Date())` so real
signature timestamps verify, then
`stripe listen --forward-to http://127.0.0.1:<port>/webhook/stripe?canisterId=<id>`.
The spec logs the URL. **So a full end-to-end Stripe test needs no local network and
no mainnet** — see `docs/SANDBOX-TESTPLAN.md`.

⚠️ Its own instance and its own spec file, because `makeLive` enables auto-progress,
which is incompatible with the `advanceTime` control every other scenario uses.
Call `stopLive()` before any time travel.

### Failure injection against the real NNS canisters

⚠️ **Correction.** This file previously claimed PocketIC "cannot stall the real
NNS ledger or CMC", and used that to justify leaving the money-out failure paths
uncovered. **That was wrong.** NNS root controls the canisters `icpFeatures`
deploys, and PocketIC accepts any impersonated sender — the same mechanism
`setCmcRate` already used to impersonate governance. So:

```ts
await stopNns(gw, CYCLES_LEDGER_ID);   // calls into it are now rejected
await startNns(gw, CYCLES_LEDGER_ID);  // service restored
```

⚠️ **Read the balance BEFORE the stop.** Reading it after throws, and a throw between
`stopNns` and the `try` skips the `finally` — which leaves the ledger stopped for every
scenario after this one. That is how one mistake became nine failures elsewhere.

Stopping the cycles ledger is what makes the delivery failure paths reachable end to
end: an order parks at `#paid` with a journalled intent and no block, which is the
shape every unknown-position scenario needs (11, 35, 47, 75, 76, 78).

**What genuinely remains out of reach:**

- **A reserve observation adopted across an in-flight outflow.** The quiet window is
  established across an `await`, so the unsafe interleaving needs a transfer issued
  inside a reconcile's balance-read gap — the same ordering PocketIC will not
  schedule on demand. The refusal side is unit-pinned, and scenario 76 covers the
  failure that actually shipped into the branch (one escalated order freezing
  adoption forever), which is the direction a real system reaches.
- **A recorded real Stripe event.** Every payload here is hand-crafted JSON. Only
  the `docs/STRIPE.md` §15 sandbox run closes that.

