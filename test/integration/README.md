# PocketIC integration suite — the Card and ck-USDC go-live bars (spec §9)

> **Looking for what is tested where, across all suites?** See
> `docs/TEST-COVERAGE.md`. This file documents the PocketIC suite specifically.

End-to-end scenarios against PocketIC instances running the **real**
canisters: the ICP ledger, the cycles minting canister, and the cycles ledger
are deployed at their mainnet IDs by PocketIC's `icpFeatures` (the same Wasms
mainnet runs, kept in sync with the instance topology by the server), and the
ck-USDC suite installs the real `ic-icrc1-ledger` at the exact mainnet ck-USDC id
on the fiduciary subnet, whose canister range mirrors mainnet's. Both that ledger
and the **released XRC mock** are pinned by sha256 and fetched by
`scripts/fetch-wasms.mjs` in pretest. The suite plays every external role
itself:

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
- **The ck-USDC user's wallet** — `icrc2_approve` calls straight to the
  installed ledger (including deliberately short approvals for the §6.2
  amount-short mismatch), with balance/allowance audits around every pull.
- **Time** — staleness windows, the recovery timer, and the treasury
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

## CI

`ci/integration.yml` is a ready GitHub Actions job (ubuntu-latest is
x86_64, so PocketIC runs natively). It lives here rather than in
`.github/workflows/` only because the sandbox's deploy token lacks the
`workflow` scope; to enable it:

```sh
git mv test/integration/ci/integration.yml .github/workflows/integration.yml
git commit && git push   # needs a workflow-scoped token (a normal `gh auth` token is fine)
```

## Scenario map (spec §9 coverage)

| # | Scenario | §9 item |
|---|----------|---------|
| 01 | 503 before secret provisioning, controller-gated admin API | — |
| 02 | tier config gating | — |
| 03 | empty cache + a failing XRC → `#rateUnavailable`; every rate guard rejects in isolation | pricing fail-closed |
| 04 | XRC + CMC through the real derivation; §3 pricing vector; order authz | happy path (pricing half) |
| 05 | signature/window/404/405/413 guards on the live route table | duplicate/replay (guards) |
| 06 | default burn cap 0 holds the mint | AwaitingTreasury |
| 07 | cap sized → resume → real ledger transfer → CMC mint → forward | happy path |
| 08 | event-id dedup, intent dedup, Type 1 `#duplicate`, refund auto-resolve | duplicate/replay, Type 1 |
| 09 | claimed-not-trusted attribution → Type 1 `#unattributed` | Type 1 |
| 10 | delivery to a real cycles-ledger account | happy path (2nd forward arm) |
| 11 | forward to a nonexistent canister → Type 2, cycles refunded to app balance | Type 2 |
| 12 | upgrade mid-transfer → §5.1 intent replay, exactly-one ledger debit, timer re-arm | upgrade-mid-flight, ambiguous-transfer recovery, postupgrade re-arm |
| 13 | upgrade mid-forward → the stop-first procedure drains the forward, delivering exactly once | upgrade-mid-flight |
| 14 | treasury max-wait → `treasuryWaitExceeded` escalation | AwaitingTreasury |
| 15 | audit-log seq monotonicity + error-queue accounting | — |
| 16 | admission gate: no burn-cap headroom refuses the quote; `can_purchase` agrees; restoring headroom re-opens the rail | pre-creation gate |
| 17 | per-purchase ceiling bounds both tier registration and the amount | pre-creation gate |
| 18 | expiry: created → expired, survives a simulated year, and **still honours a late payment** | retention |
| 19 | owner-only `receipt`; recomputes `net × P × 10¹² / U == lockedCycles` from it | price verifiability |

### Added with the pricing-transparency work

| # | Scenario | Coverage |
|---|----------|----------|
| 40 | `quote_previews` fee split, §3 vector, deposit fee, and an order locking exactly the previewed figure | quote/lock agreement |
| 41 | a +40% ICP move → `#quoteChanged` naming the new figure, nothing created; the new figure is accepted; a favourable move never refuses; `null` opts out | server-side quote pinning |
| 42 | owner-only `cancel_order` frees a slot, is idempotent, refuses a paid order, and a payment racing the cancel **still delivers** | buyer never locked out |

### Added from the code review

| # | Scenario | Coverage |
|---|----------|----------|
| 43 | a partial `charge.refunded` leaves the Type 1 obligation **open**; completing it settles | refund amount fidelity |
| 44 | a verified-but-unprocessable event is acked 200 and queued once; unverifiable input still 400s | endpoint-disable avoidance |
| 45 | `checkout.session.async_payment_succeeded` mints a payment that `completed` reported unpaid | delayed payment methods |
| 46 | a test-mode event cannot mint on a gateway declared live; a live one still does | livemode gate |
| 47 | a `#deliveryDelayed` alert is resolved when the order **escalates**, not only when it delivers | no orphan worklist entries |
| 48 | the alert/terminate timeline covers every in-flight status; a delivered order is never caught by it; the terminal stage matches the money position | notify stage bounded by time |
| 49 | `async_payment_succeeded` arriving **before** `completed` still mints once; the later event raises no obligation | out-of-order events |
| 50 | the bounded retention sweep expires **every** lapsed order across ticks, settles to `scanned == 0`, and an expired order is still payable | cursor completeness |
| 51 | a CMC outage stalls the mint in `#paid`, audits the fetch failure, alerts at 2 h, and **delivers for real** once restored | rate-source outage |
| 52 | an ICP ledger outage moves no money and records no block; recovery debits the float **exactly once** | ledger outage + §5.1 replay |
| 53 | CMC stopped *after* the transfer → order parks at `#icpAtCmc` with a block and no minted cycles → `notifyDelayed` alert → terminates as `retriesExhausted` **carrying the real block index** | notify stall, end to end |
| 54 | the CMC rate halves between transfer and notify → `mintShortfall` escalation, minted quantity preserved, buyer not subsidised from canister gas | rate move mid-mint |

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
await stopNns(gw, CMC_ID);      // calls into it are now rejected
await startNns(gw, CMC_ID);     // service restored
```

`tickUntilStatus(gw, id, ['minting'])` is the companion trick: it returns with the
intent journaled and the ledger call in flight, so stopping the **CMC** at that
point lets the transfer succeed and the notify fail — which is the only way to park
an order at `#icpAtCmc`. Together these make almost every money-out failure path
reachable end to end (scenarios 51–54).

**What genuinely remains out of reach:**

- **`#ambiguousForward` end to end.** It needs a callback dropped between the
  pre-forward marker and delivery, and `stopCanister` *drains* outstanding
  callbacks rather than dropping them. Unit-pinned in the `Cmc.terminationFor`
  suite is the honest ceiling.
- **`stageOf`'s `#escalate` arm.** Reaching `retriesExhausted` through it needs
  `maxMintRetries` (2,000) sweeps to elapse, which is impractical in a test. The
  terminate route reaches the same money positions and *is* covered (53), and the
  decision function is exhaustively unit-pinned — but the `#escalate` arm's own
  two-line wiring is exercised by nothing.
- **A recorded real Stripe event.** Every payload here is hand-crafted JSON. Only
  the `docs/STRIPE.md` §15 sandbox run closes that.

## Scenario map — ck-USDC go-live bar (`ckusdc.spec.ts`, task 15)

⚠️ **The ck-USDC rail ships disabled** (`maxUsdCents = 0`) and receives no new
feature work — the Card rail is the product. This suite is maintained so the rail
stays a working fallback if Stripe ever restricts the account; ck-01 asserts the
disabled default, and every other scenario enables the rail first.

Own instance (vitest runs spec files sequentially); real `ic-icrc1-ledger`
at `xevnm-gaaaa-aaaar-qafnq-cai` with ICRC-2 enabled and a 10_000-unit fee.

| # | Scenario | Coverage |
|---|----------|----------|
| ck-01 | `maxUsdCents = 0` default rejects orders; config admin-gated, validated, public | fail-closed rail config |
| ck-02 | zero / below-min / above-max rejected before any quote | amount bounds |
| ck-03 | 500¢ order through the shared §3 quote path with the rail's 0/0 fee formula | pricing |
| ck-04 | anonymous/non-owner/unknown/wrong-rail claim guards; no-approval claim drops the intent | claim guards |
| ck-05 | short approval → `insufficientAllowance` with `required`; full approve → pull → `Paid`; exact ledger accounting; cap-0 hold | amount-short mismatch, approve/pull happy path, treasury interplay |
| ck-06 | cap sized → held ck order resumes → real CMC mint → delivery; settled pull never resettable | treasury interplay, shared money-out |
| ck-07 | balance short of the pull → definite rejection, order stays claimable | amount-short (funds arm) |
| ck-08 | upgrade mid-pull → the stop drains the pull, debited exactly once, re-claim refused | dedup/replay (§5.1 money-in) |
| ck-09 | 24 h stale intent → once-only `stalePullIntent` escalation, order stays `Created`; `reset_ck_usdc_pull` re-opens; settles after | stale-intent escalation + ops levers |
| ck-10 | `withdraw_ck_usdc` moves the accrued balance; over-withdraw surfaces the ledger error | hold-ckUSDC posture |
| ck-11 | audit tags + error-queue accounting across the rail | — |
