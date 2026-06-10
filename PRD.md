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
| 6 | ☐ | **Order Candid API** (`Main.mo` wiring): `create_order` (II caller, tier, destination → locks cycle quantity, random `raw_rand` order ID, `client_reference_id = <principal>_<orderId>`), `get_order` / order history (`caller == owner` authz, `principalsToOrders`), fixed card tiers config; PocketIC or unit tests for authz + ID randomness handling. |
| 7 | ☐ | **Forex subsystem** (`Forex.mo`, spec §3.1): USD↔XDR via HTTPS outcall with coarse-rounding `transform`, stable `{rate, ts}` cache, lazy refresh, single-flight guard, in-call retry cap, **fail-closed order creation** on stale+failed refresh; fee formula (≈2.9% + $0.30, configurable) and net-of-fees pricing (§3); unit tests for rounding/fee/staleness logic with mocked outcall. |
| 8 | ☐ | **Stripe webhook ingestion** (`rails/Card.mo` complete): parse `checkout.session.completed` + `charge.refunded` JSON, claimed-not-trusted `client_reference_id` resolution, dedup (`event.id` + `payment_intent`), amount honored at actual paid value → `Paid`; unmatched/duplicate → Type 1; `charge.refunded` auto-resolves Type 1; unit tests with crafted signed payloads. |
| 9 | ☐ | **CMC mint pipeline** (`Cmc.mo`, spec §5/§5.1): candid bindings for ICP ledger + CMC, write-intent-before-call with `created_at_time` dedup, `icrc1_transfer` → record `block_index` → `notify_top_up`/`notify_mint_cycles`, mint-to-self-then-forward delivery, failed forward → Type 2; rate derivation w/ CMC staleness guard (§5); unit tests for intent/replay logic. |
| 10 | ☐ | **Treasury + burn cap** (`Treasury.mo`, spec §5.3): ICP float accounting, `AwaitingTreasury` hold + max-wait → error queue, low-float soft gate + balance-alert query, **per-period rolling ICP burn cap** with pause + manual override; unit tests for cap window math. |
| 11 | ☐ | **Recovery timer** (spec §5.2): `recurringTimer` sweep of `Minting`/`IcpAtCMC`/`AwaitingTreasury`, single-flight guard, re-arm in `postupgrade` (transient timer id), 24h-window guard (stale intent w/o block_index → error queue, never auto-replayed). |
| 12 | ☐ | **PocketIC integration suite — Card go-live bar** (spec §9): real ledger/CMC Wasms, crafted HMAC-signed webhooks, mocked forex outcall, time control; covers happy path, duplicate/replay, ambiguous-transfer recovery, AwaitingTreasury, Type 1/Type 2, forex fail-closed, upgrade-mid-flight, postupgrade re-arm. |
| 13 | ☐ | **Frontend M1** (asset canister): Astro/JS SPA, II login, rail selector, Card flow (tier links + `client_reference_id`), order status polling by `order_id`, order history. |

### M2 — ck-USDC rail

| # | Status | Task |
|---|--------|------|
| 14 | ☐ | **ck-USDC rail** (`rails/CkUsdc.mo`, spec §6.2): ICRC-1/2 bindings, `icrc2_transfer_from` pull after user `icrc2_approve` (Candid, II caller), `block_index` dedup, amount-short mismatch handling, hold-ckUSDC treasury posture; unit tests. |
| 15 | ☐ | **PocketIC suite — ck-USDC go-live bar**: approve/pull happy path, dedup, mismatch, treasury interplay. |
| 16 | ☐ | **Frontend M2**: ck-USDC panel (approve → purchase flow). |

### M3 — Verifiability & ship

| # | Status | Task |
|---|--------|------|
| 17 | ☐ | **Reproducible build + release** (spec §8): Docker-pinned build, `ic-wasm` deterministic optimize + metadata, committed `.did`, published expected module hash per tagged release, asset-canister certified frontend. |
| 18 | ☐ | **Ops runbook**: secret provisioning/rotation, error-queue resolution (Stripe Dashboard refunds), float refill, burn-cap override, confidential-subnet checklist (spec §7 caveats, §11.1). |

## Changelog

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
