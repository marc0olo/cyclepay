# PRD — Fully On-Chain Cycles Gateway

Working task list for the autonomous build loop. Requirements and all design
decisions live in `design-docs/ONCHAIN_GATEWAY_SPEC.md` (spec v2.1, the
decision record); this file tracks **what to build, in what order, and what is
done**. Update the status column and the changelog as tasks complete.

**Scope (M1 = Card rail GA, M2 = ck-USDC rail GA):** single verifiable Motoko
backend canister + asset canister. Two rails — Card (Stripe webhook, inbound
only, no `sk_live`) and ck-USDC (ICRC-2) — converging on a unified CMC mint
from an operator ICP float. II-authenticated, one-shot purchases only.
Base/x402 deferred (spec §11), but the four seams in spec §11.1 are **binding**:
`Owner` variant, `Http.mo` route table, ownership captured at the API edge,
per-rail expiry semantics.

**Tooling:** `icp-cli` (never `dfx`), `mops` (`mo:core`, no `mo:base`),
`persistent actor` + orthogonal persistence, unit tests per module +
PocketIC integration suite as the go-live bar (spec §9).

## Task list (priority order)

Status: ☐ todo · ◐ in progress · ☑ done

### M0 — Foundation

| # | Status | Task |
|---|--------|------|
| 0 | ☑ | **Scaffold**: PRD, `mops.toml` (pinned moc 1.9.0 + lintoko, core 2.5.0, test), `icp.yaml` (`@dfinity/motoko` recipe, port-0 local network), minimal `persistent actor` in `src/backend/Main.mo`, smoke test green, `mops check`/`build` green. |
| 1 | ☑ | **Core types + Order state machine** (`Types.mo`, `Orders.mo`): `Owner = { #ii : Principal }` variant (binding seam §11.1.1), `Destination = { #canister; #cyclesLedgerAccount }`, `OrderStatus` (`Created/Expired/Paid/Minting/IcpAtCMC/Delivered/AwaitingTreasury/ErrorQueue`), `Order`, `JournalEntry`; legal-transition function with owner passed as a parameter (seam §11.1.3); locked cycle *quantity* at creation (§3); unit tests for every legal/illegal transition. |
| 2 | ☑ | **Idempotency + error queue** (`Idempotency.mo`, `ErrorQueue.mo`): per-rail dedup sets (`processedStripeEvents` w/ ~7-day pruning, `processedIntents`, `processedCkUsdcBlocks`), bounded error queue with exactly Type 1 `{Duplicate|Unattributed}` (fiat-only) and Type 2 `{Undeliverable}` (cycles in app balance), bounded audit-log ring buffer; unit tests incl. pruning + bounds. |
| 3 | ☑ | **HMAC-SHA256 + Stripe signature** (`Hmac.mo` or mops sha2 pkg, `rails/Card.mo` verify half): constant-time-compare HMAC over `timestamp.body`, `Stripe-Signature` header parse (`t=`, `v1=` list), timestamp-window replay guard; unit tests against known HMAC vectors + crafted Stripe signatures. |
| 4 | ☑ | **Hand-rolled `Http.mo`** (spec §6.0): parse `HttpRequest`, case-insensitive header lookup, query-string strip, body-size guard, dispatch off a `[(method, path, handler)]` route table with per-route `upgrade` flag (binding seam §11.1.2) — one entry: `POST /webhook/stripe`; `http_request` returns `upgrade = ?true`, `http_request_update` dispatches; unit tests for parser + routing. |
| 5 | ☑ | **Auth + secret** (`Auth.mo`, `Secret.mo`): controller allowlist (flat, equal privileges, §7), reject anonymous principal on user API, admin-set/rotate plaintext webhook secret (SEV-SNP posture documented, §7); unit tests. |

### M1 — Card rail (Stripe), money-in → money-out

| # | Status | Task |
|---|--------|------|
| 6 | ☑ | **Order Candid API** (`Main.mo` wiring): `create_order` (II caller, tier, destination → locks cycle quantity, random `raw_rand` order ID, `client_reference_id = <principal>_<orderId>`), `get_order` / order history (`caller == owner` authz, `principalsToOrders`), fixed card tiers config; PocketIC or unit tests for authz + ID randomness handling. |
| 7 | ☑ | **Forex subsystem** (`Forex.mo`, spec §3.1): USD↔XDR via HTTPS outcall with coarse-rounding `transform`, stable `{rate, ts}` cache, lazy refresh, single-flight guard, in-call retry cap, **fail-closed order creation** on stale+failed refresh; fee formula (≈2.9% + $0.30, configurable) and net-of-fees pricing (§3); unit tests for rounding/fee/staleness logic with mocked outcall. |
| 8 | ☑ | **Stripe webhook ingestion** (`rails/Card.mo` complete): parse `checkout.session.completed` + `charge.refunded` JSON, claimed-not-trusted `client_reference_id` resolution, dedup (`event.id` + `payment_intent`), amount honored at actual paid value → `Paid`; unmatched/duplicate → Type 1; `charge.refunded` auto-resolves Type 1; unit tests with crafted signed payloads. |
| 9 | ☑ | **CMC mint pipeline** (`Cmc.mo`, spec §5/§5.1): candid bindings for ICP ledger + CMC, write-intent-before-call with `created_at_time` dedup, `icrc1_transfer` → record `block_index` → `notify_top_up`/`notify_mint_cycles`, mint-to-self-then-forward delivery, failed forward → Type 2; rate derivation w/ CMC staleness guard (§5); unit tests for intent/replay logic. |
| 10 | ☑ | **Treasury + burn cap** (`Treasury.mo`, spec §5.3): ICP float accounting, `AwaitingTreasury` hold + max-wait → error queue, low-float soft gate + balance-alert query, **per-period rolling ICP burn cap** with pause + manual override; unit tests for cap window math. |
| 11 | ☑ | **Recovery timer** (spec §5.2): `recurringTimer` sweep of `Minting`/`IcpAtCMC`/`AwaitingTreasury`, single-flight guard, re-arm in `postupgrade` (transient timer id), 24h-window guard (stale intent w/o block_index → error queue, never auto-replayed). |
| 12 | ◐ | **PocketIC integration suite — Card go-live bar** (spec §9): real ledger/CMC Wasms, crafted HMAC-signed webhooks, mocked forex outcall, time control; covers happy path, duplicate/replay, ambiguous-transfer recovery, AwaitingTreasury, Type 1/Type 2, forex fail-closed, upgrade-mid-flight, postupgrade re-arm. *Suite fully implemented (`test/integration`, 15 scenarios) and typechecked; **execution pending a 4 KiB-page host** (macOS / x86_64 CI — the replica cannot run in this 16 KiB-page arm64 sandbox; see README + changelog). Go-live bar is green only when it has actually run.* |
| 13 | ☑ | **Frontend M1** (asset canister): Astro/JS SPA, II login, rail selector, Card flow (tier links + `client_reference_id`), order status polling by `order_id`, order history. *Built as a Vite + vanilla-TS SPA (decision: Astro rejected — SSG machinery for a one-page app; same Vite underneath).* |

### M2 — ck-USDC rail

| # | Status | Task |
|---|--------|------|
| 14 | ☑ | **ck-USDC rail** (`rails/CkUsdc.mo`, spec §6.2): ICRC-1/2 bindings, `icrc2_transfer_from` pull after user `icrc2_approve` (Candid, II caller), `block_index` dedup, amount-short mismatch handling, hold-ckUSDC treasury posture; unit tests. |
| 15 | ☐ | **PocketIC suite — ck-USDC go-live bar**: approve/pull happy path, dedup, mismatch, treasury interplay. |
| 16 | ☐ | **Frontend M2**: ck-USDC panel (approve → purchase flow). |

### M3 — Verifiability & ship

| # | Status | Task |
|---|--------|------|
| 17 | ☐ | **Reproducible build + release** (spec §8): Docker-pinned build, `ic-wasm` deterministic optimize + metadata, committed `.did`, published expected module hash per tagged release, asset-canister certified frontend. |
| 18 | ☐ | **Ops runbook**: secret provisioning/rotation, error-queue resolution (Stripe Dashboard refunds), float refill, burn-cap override, confidential-subnet checklist (spec §7 caveats, §11.1). |

## Changelog

- **2026-06-10 — Task 14 done.** ck-USDC rail (§6.2). `rails/CkUsdc.mo` is the
  pure half — ICRC-1/2 Candid types (ledger `xevnm-gaaaa-aaaar-qafnq-cai`,
  6 decimals ⇒ 1¢ = 10⁴ units exactly, the 1:1 peg makes `usdCents` pricing
  exact on the money-in side), deterministic pull-intent construction, result
  interpretation, the pull journal, and the claim resume decision — all
  unit-tested without an IC env; Main.mo owns the awaits. **The pull is
  money-IN with the §5.1 write-intent-before-call treatment**:
  `icrc2_transfer_from` debits the *user*, so the args (incl.
  `created_at_time`; memo = the order ID's UTF-8, exactly the 32-byte ICRC-1
  bound, tying ledger tx → order) are frozen and persisted in one sync block
  before the ledger await. A lost response (upgrade mid-pull) replays the
  *identical* args — the ledger pulls once or answers `#Duplicate` with the
  original block; an intent at/past the 24 h dedup window without a block
  escalates as `#stuckMint{stage = "stalePullIntent"}` and is **never rebuilt
  fresh** (fresh args after an executed-but-unrecorded pull would debit the
  user twice). The order deliberately stays `#created` on escalation (no
  legal pre-payment edge to `#errorQueue`, and the position may be "nothing
  happened"); the journal's escalation mark blocks further claims, queues
  exactly once, and the operator reads the ck-USDC ledger then either refunds
  via `withdraw_ck_usdc` or clears the intent via `reset_ck_usdc_pull`
  (refuses when a block is recorded). **Definite-rejection rule**: ic-icrc1
  ledgers check `created_at_time` dedup *before* balance/allowance, so
  `InsufficientAllowance`/`InsufficientFunds`/`BadFee` prove no attempt with
  these args ever moved money — the intent is dropped and the error surfaces
  user-actionably; that is what turns the §6.2 **amount-short mismatch**
  (approval < amount + ledger fee) into a clean "approve at least
  `required`, retry" instead of a stuck order. `TooOld` is the uncertainty
  case (escalate); `TemporarilyUnavailable`/`CreatedInFuture`/`GenericError`
  keep the intent for replay. **Success path** commits block-dedup
  (`processedCkUsdcBlocks`, §4.2, never pruned) + journal block + `#paid` in
  one sync block, then kicks the shared mint pipeline as a detached
  self-message — money-out is rail-agnostic from `#paid` on. **No fixed
  tiers**: nothing structural pins the amount the way a card Payment Link
  does and the canister pulls the exact price itself, so
  `create_ck_usdc_order(usdCents, destination)` takes a user-chosen amount
  inside operator bounds; **defaults fail closed** (`maxUsdCents = 0` keeps
  the rail disabled until the operator sizes it — the empty-tier-list
  stance). Rail fee formula defaults 0 bps/0¢ (no structural processor fee;
  ledger fees are user-paid; the operator absorbs off-chain conversion per
  §3 at-cost) and is admin-settable. Quote path refactored once for both
  rails: `quoteCents` (rail fee formula over the one shared §3.1 rate cache,
  one epoch per quote) + `quoteWithRefresh` (lazy refresh, fail-closed) +
  `createOrderWithFreshId` (raw_rand re-draw loop); card `create_order`
  delegates to them unchanged in behavior. **Hold-ckUSDC treasury posture**
  (§6.2): pulled ck-USDC accrues in the canister's own ledger account (its
  balance is public — no query method needed); admin `withdraw_ck_usdc` is
  the off-chain ckUSDC→ICP→float conversion lever (attended; no
  created_at_time, doc says check the ledger before retrying an ambiguous
  failure). Per-order transient `pullsInFlight` single-flight guards the
  check-await-credit window; `claim_ck_usdc_order` requires `caller ==
  owner` (no existence leak), rail match, and claimable status (`#expired`
  stays claimable — §4 expiry is advisory). 32 new tests (units/config/
  amount boundary matrices incl. exactly-min/max; pinned intent + wire-form
  vectors incl. 32-byte memo; full interpretPull matrix; journal patch
  semantics; claimStage pinned over all 8 statuses with the
  exactly-window-vs-−1 ns boundary, once-only escalation, block-beats-
  escalation heal); 390 total green; `mops check` lint-clean, `mops build` +
  `icp build` green; `.did` gains exactly `create_ck_usdc_order`/
  `claim_ck_usdc_order`/`set_ck_usdc_config`/`ck_usdc_config`/`ck_usdc_pull`/
  `reset_ck_usdc_pull`/`withdraw_ck_usdc`; frontend rebuilt against the new
  committed `.did` (tsc strict + vite build + 21 vitest green — M2 UI itself
  is task 16). Live approve→pull against a deployed ck-USDC ledger is task
  15's PocketIC go-live bar.
- **2026-06-10 — Task 13 done.** Frontend M1 (`src/frontend/`), deployed as a
  second canister via the `@dfinity/asset-canister@v2.2.1` recipe (v2.1.0 is
  incompatible with icp-cli 0.3.x — its `assets` sync step type was removed in
  favor of a plugin; pinned with a comment in `icp.yaml`). **Stack decision**:
  Vite + vanilla TypeScript SPA, not Astro — Astro is static-site machinery
  around the same Vite for what is one interactive page; same
  dependency-minimal stance as the `mo:server`/`hmac`/`json` rejections.
  **Bindings, not hand-written IDL**: `@icp-sdk/bindgen`'s Vite plugin
  regenerates `src/bindings/backend.ts` from the *committed* `backend.did` on
  every build, so the typed actor cannot drift from the canister interface
  without a type error; `.gitignore` now un-ignores
  `src/backend/dist/backend.did` (spec §8 "committed `.did`" — every
  `mops build` refreshes it, so the committed interface self-maintains).
  Frontend types are derived structurally from the actor
  (`Awaited<ReturnType<…>>`), immune to bindgen's export naming. **II login**
  (`@icp-sdk/auth` 7.x): mainnet `https://id.ai/authorize` unconditionally —
  the local network trusts mainnet subnet signatures since icp-cli 0.2.4, so
  there is no environment branching; canister id + root key come from the
  `ic_env` cookie (`safeGetCanisterEnv`), never a runtime root-key fetch (MITM
  vector). 8 h delegation TTL. **Card flow**: tier picker rendered from the
  public `card_tiers` query; destination form covers both `Destination` arms
  (canister principal / cycles-ledger account with optional left-padded-hex
  subaccount); `create_order` errors map to user-facing messages
  (`rateUnavailable` says "nothing was charged" — the §3.1 fail-closed answer);
  the Stripe Payment Link is `tier.paymentLinkUrl` +
  `client_reference_id=<CreatedOrder.clientReferenceId>` (§6.1), opened in a
  new tab while the SPA polls. Payment links are session-local (keyed by order
  id) — the backend stores no link, and a reopened historical order in
  `created` shows status, not a pay button. **Status polling by order id**:
  3 s `get_order` polling drives a 4-step timeline
  (Awaiting payment → Paid → Minting → Delivered); exactly the two §4 terminal
  states stop the poll (pinned by test); `expired` stays pollable and reads as
  a warning (§4: expiry is advisory — a late real payment still completes);
  `awaitingTreasury` renders as "queued", and the §5.3 `treasury_status.lowFloat`
  soft gate shows the low-float notice up front. **Order history**:
  `list_orders` table, newest first, row click re-opens polling. **Rail
  selector** is the §11.1 seam in UI form: Card live, ck-USDC a disabled tab
  (M2 adds a panel, not a refactor). Asset posture (`.ic-assets.json5`):
  `allow_raw_access: false` everywhere (raw domain = tamperable responses,
  against the verifiability thesis), standard security policy, immutable
  caching for content-hashed `assets/`, SPA aliasing. Pure logic
  (status→step/terminal/tone map, payment-link composition, cycles/USD
  formatting, subaccount hex parsing, error-message mapping) lives in
  dependency-free `format.ts` with 21 vitest tests; `tsc --noEmit` strict
  clean; `vite build` green; `mops check`/`test` (358) untouched-green;
  `icp build` builds both canisters. Live II popup flow + asset certification
  need a browser + deployed canister — exercised on the dev host alongside the
  task 12 suite (same 4 KiB-page constraint for the local network).
- **2026-06-10 — Task 12 implemented (execution pending a 4 KiB-page host).**
  PocketIC integration suite, `test/integration/` (TypeScript, vitest +
  `@dfinity/pic` 0.22 / pocket-ic server 14). **Real-canister posture**: the
  server's `icpFeatures` deploy the *actual* NNS ICP ledger, CMC, and cycles
  ledger at their mainnet IDs (`icpToken` also funds the anonymous principal,
  which the suite uses as the operator's ICP source) — exactly §9's "real
  ledger/CMC Wasms" with no hand-pinned wasm downloads or init-arg encoding to
  drift. The CMC's ICP/XDR rate is driven through the real governance-gated
  `set_icp_xdr_conversion_rate` by impersonating the governance principal as
  sender (a PocketIC capability), re-armed after every time jump because the
  backend's 15-min CMC-rate guard is a hard constant. Webhooks are crafted
  bodies HMAC-signed per Stripe's scheme in node:crypto and delivered through
  `http_request_update`; forex outcalls are intercepted with the
  pending-outcall API (deferred-actor submit → mock → resume) so the
  canister's own `forex_transform` still runs replica-side; the §3 pricing
  vector (500¢ → 3_353_350_000_000 cycles at 0.737 XDR/USD) is asserted
  end-to-end. 15 sequential scenarios on one instance (state accumulates like
  a live gateway's): unprovisioned-secret 503; admin gating; forex
  fail-closed (3 rejected outcalls → `#rateUnavailable`); priced order +
  authz; ingress guards (bad MAC, stale `t`, 404/405/413) on the live route
  table; AwaitingTreasury under the fail-closed cap-0 default; the happy path
  (cap sized → resume → ledger transfer → `notify_top_up` → forward, with
  *exactly-one-debit* float assertions and destination cycle-balance deltas);
  duplicate/replay through every dedup layer + Type 1 `#duplicate` + refund
  auto-resolve; Type 1 `#unattributed`; delivery to a real cycles-ledger
  account (second forward arm); Type 2 `#undeliverable` (forward to a
  never-allocated canister id from the app subnet's range top — cycles refund
  to the app balance, asserted); **upgrade-mid-transfer** (tick-stepped to
  the instant `#minting` commits, then upgrade — callback dropped, §5.1
  intent persisted; the post-upgrade transient-initializer timer fires after
  `advanceTime(1 h)` and the replay recovers the block with the float debited
  exactly once); **upgrade-mid-forward** (caught between the `cyclesMinted`
  pre-forward marker and delivery → `#ambiguousForward` escalation, never
  re-forwarded); treasury max-wait escalation at 73 h; audit-log seq
  monotonicity + error-queue accounting. **Execution environment finding**:
  the IC replica's memory tracker hard-asserts 4096-byte pages; this sandbox
  is a 16 KiB-page arm64 VM (no KVM, and qemu-user x86_64 emulation dies in
  jemalloc on >47-bit guest addresses), so the suite *cannot execute here* —
  it runs natively on the developer's macOS host and on x86_64 CI. A ready
  GitHub Actions job sits at `test/integration/ci/integration.yml` (parked
  outside `.github/workflows/` because the sandbox token lacks the `workflow`
  scope; `git mv` + push with a normal token enables it). Verified in-sandbox:
  `tsc --noEmit`, vitest collection of all 15 scenarios, `mops check`/`test`
  (358), `mops build`, `icp build`. Task stays ◐ until the suite has actually
  run green — that, plus fixing whatever it reveals, is the next loop's first
  order of business.
- **2026-06-10 — Task 11 done.** Recovery timer (§5.2). `Recovery.mo` is the
  pure half — cadence policy + sweep eligibility, unit-tested without an IC
  env; Main.mo owns the `recurringTimer` arming. **Cadence bound**:
  `validateInterval` enforces interval ≤ ledger-dedup-window / 4 (§5.1 —
  recovery cadence ≪ 24 h means a stuck `#minting` order gets *several*
  replay attempts while its intent still dedups; one sweep per window would
  burn the only chance on a single transient failure). Default 1 h — legal
  against the real window, and it sizes task 9's retry budget: 25 retries ×
  1 h > 24 h, so an outage shorter than a day never exhausts the notify
  loop (both claims pinned by tests). `isSweepable` extracts the sweep
  predicate `sweepMintable` had inline (#paid/#minting/#icpAtCmc/
  #awaitingTreasury; `#created` waits on the user — expiry stays per-rail,
  seam §11.1.4). **Re-arm across upgrades**: the timer id is a `transient`
  initializer, so EOP re-runs it on install *and* every upgrade — a deploy
  can never leave recovery dead, and since the IC drops timers across
  upgrades there's no stale duplicate to cancel; the operator-tuned
  `recoverySweepIntervalNs` is persistent, so the re-arm uses the
  configured cadence, not the default. **Single-flight**: a transient
  `recoverySweepInFlight` flag makes a sweep slower than the interval skip
  the next firing rather than pile up (transient = an upgrade mid-sweep
  can't deadlock recovery — the §5.2 `pumping` warning); correctness under
  concurrency stays with processMint's per-order single-flight. The
  webhook kick deliberately *bypasses* the sweep flag: an in-flight sweep
  enumerated `pending` before the just-verified order turned `#paid`, so a
  guarded kick could make a paying user wait a full interval. The §5.1
  24 h stale-intent guard needed no new code — `Cmc.stageOf` (task 9)
  already escalates an over-window intent without a block_index and never
  auto-replays it; the timer just drives orders into it on a cadence.
  Admin `set_recovery_interval` (validated, re-arms immediately, audited) +
  public `recovery_status` (cadence, last *completed* sweep, in-flight
  flag — the timer is the backstop for every detached webhook kick that
  dies, so liveness must be observable). 8 new tests (zero/min/exactly-
  window-÷4/+1 ns boundaries, default-vs-real-window, retry-budget pin,
  sweepable-state matrix pinned exhaustive 4-of-8); 358 total green;
  `mops check` lint-clean, `mops build` + `icp build` green; `.did` gains
  exactly `set_recovery_interval`/`recovery_status`. Live timer firing,
  postupgrade re-arm, and single-flight under fire are PocketIC coverage
  (task 12).
- **2026-06-10 — Task 10 done.** Treasury + burn cap (§5.3). `Treasury.mo`
  is the pure half — rolling-window burn accounting, the pre-gate decision,
  the hold max-wait, and the soft-gate signal — all unit-tested without an
  IC env; Main.mo owns the `icrc1_balance_of` call and persistent state.
  **Burn cap**: a `Queue`-backed time-ordered ledger of cap-consuming mints;
  `burnedInWindow` counts burns with age < window (house staleness
  convention), so consumption "resets next window" (§5.3) by aging out with
  no timer; `recordBurn` prunes aged entries from the front. Consumption is
  **conservative by construction**: it commits in the same §5.1 sync block
  as the transfer intent (before the ledger await) and is never refunded on
  a later failure — over-counting pauses mints early, the fail-safe
  direction for a blast-radius bound. Manual override =
  `reset_burn_window()` (admin, audited, returns cleared e8s).
  **Pre-gate** (in the driver's `#begin`, after the CMC-rate and
  `icrc1_balance_of` awaits, decided synchronously): the burn cap is checked
  **before** float sufficiency — it must hold mints even when the float
  could fund them (a leaked-secret drain has a full float); proceed iff
  burned + mint ≤ cap (reaching exactly is allowed) AND float ≥ mint +
  transfer fee. A held `#paid` order transitions to `#awaitingTreasury`
  (audited); an already-held order re-holds silently so its max-wait clock
  (`updatedAtNs`) and the ring buffer survive repeated sweeps.
  **Hold/resume**: `driveMint` intercepts `#awaitingTreasury` before
  `Cmc.stageOf` (which stays untouched) — within the wait bound the order
  retries `#begin`, so the pre-gate is the single decision point and a
  refill or rolled window clears the hold with no second code path; at/past
  `maxHoldNs` it escalates as `#stuckMint{stage = "treasuryWaitExceeded"}`
  (position certain — fiat in, nothing minted — operator refunds in the
  Stripe Dashboard; ErrorQueue doc widened). `sweepMintable` now includes
  `#awaitingTreasury`. **Defaults fail closed**: `burnCapE8s = 0` — every
  mint holds until the operator consciously sizes the bound (the
  empty-tier-list stance: a default cap in ICP would be an invented money
  decision); cap 0 doubles as an explicit pause lever; 24 h window, 72 h max
  hold, alert disarmed. **Float observability**: every pre-gate balance read
  (and admin `refresh_float()`) updates a persistent observation;
  `observeFloat` audit-alerts on the *crossing* into low (never per-sweep
  spam); public `treasury_status` query = config + window consumption +
  last observation + `lowFloat` (armed-but-never-observed reads low) + held
  order count — the frontend's §5.3 soft UI gate disables tiers off it.
  `set_treasury_config` validated atomically (positive window/max-hold).
  16 new tests (window math incl. exactly-window-old boundary and
  front-pruning, gate matrix incl. exact cap/float boundaries and
  cap-beats-float ordering, window roll frees cap, max-wait boundary,
  soft-gate signal matrix); 350 total green; `mops check` lint-clean,
  `mops build` + `icp build` green; `.did` gains exactly
  `set_treasury_config`/`reset_burn_window`/`refresh_float`/
  `treasury_status`. Live balance/hold flow under PocketIC is task 12.
- **2026-06-10 — Task 9 done.** CMC mint pipeline (§5/§5.1). `Cmc.mo` is the
  pure half — Candid interfaces (ICP ledger `icrc1_transfer`, CMC
  `notify_top_up` + `get_icp_xdr_conversion_rate`, cycles ledger `deposit`),
  deterministic intent construction, result interpretation, and the
  resume/replay decision — all unit-tested without an IC env. Decisions:
  **one notify path** — delivery is mint-to-self-then-forward via
  `notify_top_up(self)` + TPUP memo for *both* destination kinds; the
  `notify_mint_cycles`/MINT path is deliberately unused because it would
  strand value in the app's cycles-*ledger* balance, splitting the §4.1
  Type-2 invariant ("cycles in the app canister's own balance"). E8s
  derivation: one e8s mints exactly `xdr_permyriad_per_icp` cycles, so
  `e8s = ⌈cycles / permyriad⌉` (round up: the mint covers the locked
  quantity, dust overshoot stays operator-side §3); CMC rate guarded by the
  CyclePay post-incident **15 min staleness window** (age ≥ window = stale,
  the house convention) and a zero-rate refusal. §5.1 is encoded
  structurally: `stageOf(status, journalEntry, now, window, maxRetries)` is
  a pure function deciding the driver's next move, and **the first transfer
  attempt and every recovery replay are the same `#replayTransfer` stage**
  off the persisted intent (`transferArgs` is a pure projection → replay is
  bit-identical); intent + `#minting` commit in one sync block before the
  transfer await; `#Ok` and `#Err(#Duplicate)` both recover the
  block_index; an intent at/past the 24 h dedup window without a block
  escalates, never replays. Errors split *retriable* (nothing recorded,
  identical args can succeed later: TemporarilyUnavailable,
  InsufficientFunds — the float-refill case until task 10's pre-gate,
  CreatedInFuture, GenericError, CMC Processing/Other) vs *escalate*
  (replay can never succeed: TooOld, BadFee, BadBurn, CMC
  Refunded/InvalidTransaction/TransactionTooOld); a `maxRetries` cap bounds
  the notify loop the 24 h window doesn't. **Forward is at-most-once**:
  `cyclesMinted` doubles as a pre-forward marker committed before the
  forward await — a death mid-forward resumes as `#ambiguousForward`
  (operator checks the destination) rather than risking double delivery; a
  *failed* forward (deposit rejected → cycles auto-refunded to the app
  balance) is the clean Type 2 `#undeliverable`. `ErrorQueue.Kind` gains
  `#stuckMint {orderId; stage}` for the §5.1 escalations — deliberately
  neither Type 1 nor Type 2 (money position uncertain; no paymentRef, so
  `charge.refunded` auto-resolve never touches it). §4.2 `journal` map
  (persistent, never pruned) records intent/block_index/cyclesMinted/
  retries per order. `Main.mo`: per-order transient single-flight set,
  `sweepMintable()` over `#paid/#minting/#icpAtCmc` (the §5.2 timer reuses
  it in task 11), webhook kick as a **detached self-message** after
  `http_request_update` dispatch (Stripe's ack never waits on ledger/CMC
  latency), admin `process_order` (manual kick, safe to spam) +
  `mint_journal` query. 39 new tests (pinned-vector TPUP memo + top-up
  subaccount layout + e8s math computed externally in python; staleness and
  24 h boundaries; full transfer/notify interpretation matrices; journal
  patch semantics; 13-case stageOf matrix incl. ambiguity-beats-retries;
  stuckMint never refund-resolved); 334 total green; `mops check`
  lint-clean, `mops build` + `icp build` green; `.did` gains exactly
  `process_order`/`mint_journal`. Live ledger/CMC behavior (notify
  idempotency shape, PocketIC NNS Wasms) is task 12's go-live bar.
- **2026-06-10 — Task 8 done.** Stripe webhook ingestion — `rails/Card.mo`
  is complete (§6.1). `Json.mo`: hand-rolled strict JSON tree parser (the
  mops `json` package depends on deprecated `base` — same dependency-split
  rejection as `hmac` in task 3); scope = parse one document + read
  text/Nat fields by dotted path; numbers kept as raw lexemes and
  interpreted integer-only; hard-fails on lone surrogates, unescaped
  control chars, trailing garbage; 64-level depth cap. A *tree* parse, not
  key-scanning, because verified Stripe JSON still carries
  attacker-influenced string values — a substring scan for
  `"payment_intent"` could be steered by a value containing that text.
  `Card.parseEvent`: `checkout.session.completed` (payment_intent,
  claimed `client_reference_id` where JSON-null = absent, `amount_total`,
  currency, `payment_status`) + `charge.refunded` + `#unhandled` (acked,
  never a delivery failure); a handled type missing a required field 400s
  (visible in the Stripe dashboard, e.g. subscription-mode session with
  null payment_intent). `Card.handleWebhook` = the whole POST
  /webhook/stripe path, synchronous end-to-end (no awaits → no
  check/write interleaving), state injected via `Deps` so it unit-tests
  without an IC env: verify (unprovisioned secret → 503 so Stripe
  retries) → opportunistic 7-day dedup pruning → route. Checkout:
  `event.id` dedup, then `payment_status` check (unpaid sessions ack
  *without* consuming the intent), then `payment_intent` dedup (§4.2 one
  mint per payment), then claimed-not-trusted attribution
  (`Orders.parseClientReferenceId` — claimed principal compared as text,
  never `fromText`-ed: garbage must not trap into a 5xx-retry loop; owner
  + rail + currency verified against the stored order) — failures queue
  Type 1 `#unattributed` and answer 200 (payment *is* handled: by the
  operator). Already-handled order + fresh intent = genuine double-pay →
  Type 1 `#duplicate` (§4.1). **Actual paid amount honored** (§3): tier
  match uses the locked quantity verbatim; a mismatch is repriced from
  the order's new `Types.Pricing` creation snapshot
  (`Orders.markPaid` swaps in the honored quantity) — never from a fresh
  rate, so "no quote drift" holds off the happy path; below-fee-floor
  payments are Type 1. `charge.refunded` auto-resolves Type 1 entries by
  payment_intent. Unresolved error-queue evictions and amount mismatches
  go on the audit log. `Forex.netCents` widened to take any
  `{feeBps; feeFixedCents}` (live config or pricing snapshot);
  `Forex.quote` `#ok` now also returns the rate so `Main.quoteTier` can
  persist the snapshot from the same epoch as the quote. `Main.mo` wires
  persistent `dedup`/`errorQueue`/`auditLog` stores, `Card.Deps`, the
  real webhook handler, and admin `error_queue`/`resolve_error`/
  `audit_log` methods. 58 new tests (json parser matrix incl. surrogate
  pairs, depth cap boundary 63 vs 64, inert-string-values;
  parseClientReferenceId incl. no-trap-on-garbage-principal; markPaid;
  parseEvent matrix; handleWebhook end-to-end over *signed* crafted
  payloads — envelope guards, dedup layers, every Type 1 path, repriced
  mismatch vector cross-checked by hand, refund auto-resolve); 295 total
  green; `mops check` lint-clean, `mops build` + `icp build` green;
  `.did` gains exactly the three admin methods. Live-gateway delivery +
  upgrade-mid-flight replay are PocketIC coverage (task 12).
- **2026-06-10 — Task 7 done.** Forex subsystem (§3.1). New dep: `ic@4.0.0`
  (caffeinelabs management-canister bindings — shares our exact `core@2.5.0`,
  no version split; `Call.httpRequest` computes and attaches outcall cycles
  via the `ic0` cost API). `Forex.mo` is the *pure* half, so everything
  unit-tests with mocked bodies: rate is **XDR-per-USD in micros** (the shape
  USD-base APIs serve; 1 XDR = 1T cycles ⇒
  `cycles = netCents·micros·10_000`); default source
  `https://open.er-api.com/v6/latest/USD` (keyless §3.1 — a keyed API would
  be a second node-provider-readable secret); `extractXdrPerUsdMicros`
  (first `"XDR"` key wins, plain positive JSON number, >6 frac digits
  truncated); `coarseRound` to 1_000 micros (~0.14% — §3.1 determinism,
  far below fee variance); **plausibility band 0.1–10 XDR/USD** (a
  decimal-point bug at the source can never price orders free or 1000×);
  `transformBody` = the outcall transform: raw body → canonical rounded
  micros text, any failure → empty body so replicas reach consensus on
  failure too; `parseCanonicalMicros` re-applies the band; fee formula
  `⌈gross·bps/10_000⌉ + fixed` (**percentage rounds up** — overestimating
  the fee means never over-delivering; net must be > 0); `quote` snapshots
  fee config + cached rate in one call → `#ok/#stale/#unpriceable`;
  `hostOf` derives the outcall `Host` header from the configured URL.
  `Main.mo`: persistent `forexCache` (`{rate, ts}`, survives upgrades) +
  `forexConfig` (defaults 290 bps / 30¢ / 1 h window; admin
  `set_forex_config`, validated atomically: bps < 100%, positive window,
  https-only); **transient** single-flight flag (a persistent flag stuck
  true by an upgrade mid-outcall would deadlock refreshes forever) with
  `try/finally` reset; in-call retry cap (3 attempts — boundary splits clear
  on retry, API-down doesn't); `max_response_bytes = 16_000` (cycles charge
  on the ceiling, not actual size); `forex_transform` query;
  `create_order` now quotes off the cache, lazily refreshes on `#stale`,
  re-quotes, and **fails closed** `#rateUnavailable` when the refresh fails
  or another is in flight (§3.1); new `#tierBelowFees` error distinguishes
  "fee swallows the tier" (operator config problem) from rate outages.
  `forex_status` query is public (rate + fee params are market data, and
  transparency is the thesis). 43 new tests (parser matrix incl.
  key-inside-string and first-key-wins, rounding/band boundaries incl.
  rounding *into* the band, transform fail-to-empty, fee vectors
  cross-checked externally in python, freshness boundary at exactly-window,
  quote composite, config validation); 237 total green; `mops check`
  lint-clean, `mops build` + `icp build` green; `.did` gains
  `forex_status`/`forex_transform`/`set_forex_config`. The live outcall +
  single-flight under burst is PocketIC coverage (task 12).
- **2026-06-10 — Task 6 done.** Order Candid API wired into `Main.mo`.
  `Tiers.mo` (§3): fixed card tiers as operator config —
  `{id; usdCents; paymentLinkUrl}` (controllers create the permanent Payment
  Links in the Stripe Dashboard and register them here; the canister never
  calls Stripe); `validate` (non-empty unique ids, non-zero amounts) +
  `find`. `Orders.mo` additions: `idFromEntropy` (first 16 raw_rand bytes →
  32 lowercase hex chars, §2 — random so the public `client_reference_id`
  can't be enumerated or leak volume; null on short entropy = broken source,
  not bad luck) and `clientReferenceId(owner, id)` = `<principal>_<orderId>`
  (§6.1; unambiguous split — principal text is `[a-z0-9-]`, the id is hex,
  so the single `_` is the separator; task 8 re-resolves it claimed-not-
  trusted). `Main.mo`: persistent `orderStore` + `cardTiers` (empty until
  first `set_card_tiers` — no invented default prices); `create_order(tierId,
  destination)` — `Auth.checkUser` rejects anonymous, tier lookup, quote,
  then `raw_rand` → `Orders.create` with up to 3 re-draws on id collision;
  ownership captured at the API edge as `#ii(caller)` (seam §11.1.3); tier +
  quote are read *before* the await so a mid-call config change can't mix
  two pricings. **Pricing seam fails closed (§3.1):** `quoteCyclesForUsdCents`
  is a transient stub returning null until Forex (task 7), so `create_order`
  answers `#rateUnavailable` rather than pricing on an invented rate — same
  answer a real stale-rate outage gives. `get_order` (getOwned: null for
  non-owners, existence not revealed) + `list_orders` (history) +
  `set_card_tiers` (admin, validated atomically) + public `card_tiers`
  query. 13 new tests (tier validation/lookup incl. duplicate/zero/empty;
  pinned id hex vector, 16-byte boundary vs 15, distinct entropy → distinct
  ids, collision-then-fresh-draw re-creates, client_reference_id exact
  format); 194 total green; `mops check` lint-clean, `mops build` +
  `icp build` green; `.did` gains exactly `create_order`/`get_order`/
  `list_orders`/`set_card_tiers`/`card_tiers`. The `create_order` happy path
  end-to-end (raw_rand + isController in an IC env) is PocketIC-suite
  coverage (task 12).
- **2026-06-10 — Task 5 done.** `Auth.mo` (§7): the flat allowlist IS the
  canister controller set (IC OR-semantics, equal privileges; editing it =
  `canister settings update`, M-of-N hardening = a multisig canister as sole
  controller). `checkAdmin(caller, isController)` takes the controller check
  as an injected predicate so the module is pure and unit-testable —
  `Main.mo` passes `Principal.isController` (ic0.is_controller, available in
  query context too); anonymous is rejected *before* the predicate, so
  `2vxsx-fae` can never be an admin even if it lands in the controller set.
  `checkUser` is the II user-API gate (anonymous = shared identity → its
  orders would be anyone's; wired in task 6 — the webhook route stays
  anonymous-by-design, payload-authed). `Secret.mo` (§7): the system's only
  stored secret, **plaintext by design** — SEV-SNP posture documented on the
  module (memory encryption ≠ checkpoint/state-sync confidentiality — verify
  hardest; provisioning transits the TLS-terminating boundary node; burn cap
  §5.3 is the always-on backstop, launch never blocks on SEV). Store keeps
  the UTF-8 bytes of the *full* `whsec_...` string (prefix included = the
  HMAC key, matching Stripe's reference verifiers), `setAtNs`, and a
  `generation` counter so ops can confirm a rotation landed without reading
  the secret back; `set` rejects < 16 bytes (`#tooShort`) and leaves the
  store untouched on rejection — a bad rotation never clobbers a working
  secret. No dual-secret window needed: during Stripe's rotation overlap the
  header carries one `v1=` per active secret and Card.verify (task 3)
  accepts any match. `Main.mo`: persistent `webhookSecret` store;
  `requireAdmin` traps (never a handled-looking error); `set_webhook_secret`
  (Text → Result with `SetError`) + `webhook_secret_status` query
  (admin-gated; exposes everything *about* the secret, never the secret —
  no read-back even for controllers). 13 new tests (predicate-injected admin
  matrix, anonymous-beats-predicate, min-length boundary at exactly 16 vs
  15, rejected-rotation-preserves-store, rotation generations); 181 total
  green; `mops check`/`build` + `icp build` green; `.did` gains the two
  admin methods. `Principal.isController` itself needs an IC env — its
  wiring is PocketIC-suite coverage (task 12).
- **2026-06-10 — Task 4 done.** `Http.mo` (§6.0, hand-rolled — not
  `mo:server`): gateway `Request`/`Response` types (`certificate_version`
  omitted — Candid record subtyping drops it; nothing is certified since
  every M1 response is discarded pre-upgrade or an error); `pathOf` strips
  from the first `?` (routing never sees the query string); `headerValue`
  folds header *names* ASCII-case-insensitively (RFC 9110 — values
  untouched, first match wins); dispatch off a `[Route]` table with
  per-route `upgrade : Bool` (binding seam §11.1.2 — "one route" stays
  policy, not architecture). Semantics: unknown path → 404; known path,
  wrong method → 405 + `Allow` listing the path's methods; body over cap →
  413 *before* the upgrade decision, so oversized payloads never pay for
  consensus; on the query half an upgrade route answers `upgrade = ?true`
  without running its handler, a non-upgrade route runs right there; the
  update half re-applies every guard because `http_request_update` is
  directly callable via Candid. `Main.mo` wires `http_request` /
  `http_request_update` + the one-entry table (`POST /webhook/stripe`,
  `upgrade = true`); routes and the 64 KiB body cap are `transient`
  (closures aren't stable, and a persistent `let` would freeze the
  first-deploy config across upgrades). The stripe handler is a 503 stub —
  Stripe treats non-2xx as retry-later — until secret (task 5) + ingestion
  (task 8). 25 new tests (parse/lookup/404-405-413/at-cap vs over-cap
  boundary/handler-not-run-on-query-upgrade/echo-proves-dispatch); 168
  total green; `mops check`/`build` + `icp build` green; generated `.did`
  matches the HTTP-gateway protocol.
- **2026-06-10 — Task 3 done.** Dependency: `sha2@0.2.1` (research-ag,
  depends on our exact `core@2.5.0`); the `hmac` mops package was rejected —
  it drags in `core@1.0.0` + `sha2@0.1.6` alongside ours. `Hmac.mo`: RFC 2104
  HMAC-SHA256 over the sha2 digest API with a multi-part message argument (so
  Card MACs `"<t>."` + raw body without copying), and `constantTimeEqual`
  (XOR-OR accumulate over all bytes — a short-circuiting compare is a timing
  oracle that leaks the expected MAC, and HMAC "verify" = "forge", §7; length
  mismatch may return early, MAC width isn't secret). `Util.mo`: hex codec
  (lowercase encode = Stripe wire format; decode accepts either case, rejects
  odd length / non-hex). `rails/Card.mo` (verify half, §6.1):
  `parseSignatureHeader` per Stripe's reference parsers — first `t=` wins,
  unknown schemes (`v0=`) and unparseable elements ignored, `v1=` candidates
  hex-decoded and filtered to 32 bytes, no usable `t`/`v1` → null;
  `signedPayloadMac` over `"<t>.<raw body>"`; `verify` enforces an *absolute*
  timestamp window (|now − t| ≤ tolerance, default 300 s per Stripe; t is
  inside the MAC so it can't be forged to defeat the window) *before* MAC
  work, then constant-time-compares every `v1` candidate (multiple v1 = secret
  rotation). Tests: RFC 4231 vectors 1–4, 6, 7 + externally computed (python
  hmac) boundary vectors (empty key, key = 64 B used as-is, key = 65 B
  hashed) + a pinned crafted Stripe vector — so the implementation is checked
  against Stripe's actual scheme, not against itself; tamper/rotation/window
  boundary (±tolerance exact vs +1 s)/malformed-header matrix. 38 new tests,
  143 total green; `mops check`/`build` + `icp build` green. Event JSON
  parsing + order resolution = task 8; wiring into HTTP ingress = task 4.
- **2026-06-10 — Task 2 done.** `Idempotency.mo` (§4.2): `stripeEvents` /
  `stripeIntents` as `Map<Text, Int>` (key → first-seen ns, timestamp never
  refreshed on replay) + `ckUsdcBlocks : Set<Nat>` (never pruned — financial
  record); `record*` returns false on duplicate (ack-and-drop semantics, §4.1
  "dedup gates the mint"); `pruneStripe` drops keys ≥7 days old.
  `ErrorQueue.mo` (§4.1): `Kind` payloads make the two types structural —
  Type 1 `#duplicate`/`#unattributed` always carry `paymentRef`
  (payment_intent), Type 2 `#undeliverable` carries stranded `cycles`;
  bounded `add` (monotonic ids = age order; evicts oldest *resolved* first,
  oldest unresolved only as a last resort, evictions returned for the caller
  to audit-log); manual `resolve` + `resolveByPaymentRef` for the
  `charge.refunded` auto-resolve; resolution lives on the entry, never
  transitions an order (`#errorQueue` is terminal). `AuditLog.mo` (§4.2):
  Queue-backed ring buffer, hard cap, monotonic never-reused `seq` for gap
  detection. 24 new unit tests (pruning boundary at exactly 7d, set
  independence, eviction preference, id non-reuse, auto-resolve skips
  resolved/Type 2, ring drop + seq monotonicity) — 105 total green;
  `mops check`/`build` + `icp build` green. Capacity limits are call-site
  parameters (config lands in Main.mo wiring, task 6).
- **2026-06-10 — Task 1 done.** `Types.mo` (Owner single-case variant seam
  §11.1.1 + `isOwnedBy` pattern-match authz helper, `Rail`, `Destination`
  with ICRC-1 `Account`, `OrderStatus` ×8, immutable `Order` with
  `lockedCycles` quantity per §3, `TransferIntent` per §5.1, `JournalEntry`
  per §4.2) and `Orders.mo` (Store = `orders` map + `principalsToOrders`
  history; `isLegalTransition` encoding the §4 diagram — 11 legal edges incl.
  `Minting→ErrorQueue` (§5.1 stale intent) and `IcpAtCMC→ErrorQueue` (§4.1
  Type 2); pure `transition` returning an updated copy; `create` taking owner
  as a parameter per seam §11.1.3, rejecting duplicate IDs; `applyTransition`,
  `getOwned`, `ordersFor`). `test/orders.test.mo`: exhaustive 8×8 matrix (64
  cases) + terminality, transition-count pin (11), store/create/authz/history
  suites — 80 tests green. `mops check`/`test`/`build` + `icp build` green.
  Expiry policy deliberately *not* in the state machine (seam §11.1.4 — it is
  per-rail money-in behavior, lands with rails). Journal map joins the store
  in task 9 (CMC pipeline) where entries are first written.
- **2026-06-10 — Task 0 done.** Toolchain installed (mops 2.13.2, icp-cli 0.3.2);
  `mops.toml` pinned (moc 1.9.0, lintoko 0.10.0, core 2.5.0, test 2.1.2;
  `--default-persistent-actors`, style warnings on); `icp.yaml` with
  `@dfinity/motoko@v4.1.0` recipe + port-0 managed local network;
  `src/backend/Main.mo` minimal `persistent actor CyclesGateway` with `health`
  query; smoke test. `mops check`, `mops test`, `mops build` all green. PRD
  created (this file) with full task breakdown derived from spec v2.1.
