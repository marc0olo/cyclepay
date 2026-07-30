# PocketIC integration suite — the Card and ck-USDC go-live bars (spec §9)

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

⚠️ Scenario 41 moves the rate **40%, not 100%**. A bigger jump is rejected by
§3.1's own guards (`maxRateDeltaBps` caps a move at 50%; the implied-XDR/USD
cross-check floors at 0.5), which would leave the previous quote serving and make
the test pass vacuously. It asserts the exact repriced quantity rather than
"smaller than before", so a silently-rejected refresh fails instead of hiding.

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
