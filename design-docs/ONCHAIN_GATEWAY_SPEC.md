# Fully On-Chain Cycles Gateway — Spec v2 (decision record)

> Supersedes the open questions in `NEW_ONCHAIN_APP_DESIGN.md`. This document is
> the **decision record** from a grilling session: every branch we resolved, the
> choice, and the rationale. Where we **deviated** from the original design doc,
> it is called out explicitly (⚠️ **Override**). Read `ARCHITECTURE_ANALYSIS.md`
> for the reasoning that led to the original design, and `NEW_ONCHAIN_APP_DESIGN.md`
> for the locked rail/topology decisions that still stand.

---

## 0. What this is

A fully on-chain "buy cycles with fiat or stablecoins" service: a single
verifiable Motoko backend canister + an asset canister. **Two rails in scope —
Card (Stripe, inbound) and ck-USDC (ICRC-2)** — converging on a unified CMC
mint. (USDC-on-Base/x402 is **deferred**, see §11.) Successor in spirit to
Cycle.Express with CyclePay's capability surface, but run as one auditable Wasm.

**Tooling:** `icp-cli` (never `dfx`), `mops` for Motoko deps, Motoko with
`persistent actor` + orthogonal persistence.

---

## 1. Product scope & sequencing

| # | Decision | Rationale |
|---|---|---|
| 1 | **v1 = production money-handler.** Full idempotency + recovery on day one; every rail must be safe to lose funds on. | Highest correctness bar; this is real money, not a demo. |
| 2 | ⚠️ **Rails ship sequenced, each GA'd independently:** **Card → ck-USDC.** **Base/x402 dropped from scope for now** (see §11). | Card first for revenue; ck-USDC is pure on-chain. Base deferred — unclear consumer (a generic x402 agent wouldn't use II, a different model) and it carried *all* the EVM-crypto risk. Order state machine stays rail-pluggable so Base can return later. |
| 3 | **Scope = human, one-shot, II-authenticated purchases only.** | Tightest audit surface. |
| 3a | ⚠️ **Override — OUT OF SCOPE entirely:** subscriptions, auto-refill, GitHub OIDC CI top-ups, delegation/agent HTTP API, **Base/x402 rail**. | The original doc listed these. Subscriptions/auto-refill are impossible on card (need outbound `sk_live`) and only ever rode on a ck-USDC standing allowance, which is also cut. OIDC/delegation cut for scope. Base/x402 deferred (§11). **Consequence: the product makes _almost_ no outbound HTTPS** (see §3 forex exception). |
| 4 | **Destinations:** any canister (`notify_top_up`, `TPUP` memo) **or** a cycles-ledger account (`notify_mint_cycles`, `MINT` memo). | Full parity with cycle-express's two delivery modes. Note asymmetry: only canister destinations can become `Undeliverable`. |

---

## 2. Identity & ownership

- **Internet Identity required for all purchases**, every rail.
- This does **not** sacrifice anonymity: II is pseudonymous (passkey, no PII) and
  hands out a **per-origin principal** unlinkable to the user's identity on other
  dapps. Destinations are arbitrary (you can fund any canister). So "anonymous
  top-up" is preserved in spirit; login only governs **ownership/history**, not
  what you may fund.
- **Single ownership model:** order keyed to owner principal; query authz is
  `caller == order.owner`; `principalsToOrders` for history (fixes the
  lost-receipt problem). No bearer-secret order handles.
- ⚠️ **`Owner` is a single-case variant from day one** — `type Owner = { #ii :
  Principal }` — even though II is the only case in scope. Rationale: if
  Base/x402 returns, its consumer is an agent owning orders by EVM address;
  adding `#evmAddress : Blob` to a stable variant is a **migration-free,
  compatible extension**, whereas widening a bare `Principal` field would force
  a stable-state migration plus an audit of every authz site. The compiler then
  makes every authz check pattern-match instead of silently assuming Principal.
  (See §11 "Seams kept for Base".)
- **Order IDs:** random, `raw_rand`-derived (not a monotonic counter) — the ID
  sits in the public `client_reference_id`, so randomness avoids enumeration and
  leaking order volume. It is **not** a bearer secret (authz is `caller == owner`).

---

## 3. Economics & pricing

- ⚠️ **At-cost, net-of-fees.** `locked_rate` applies to the **net** amount
  received (gross − Stripe fee), so no structural per-order loss. The original
  doc said "margin optional"; we chose at-cost. The fee is computed from a
  **configurable fee formula** (≈2.9% + $0.30); the operator absorbs the small
  variance on international/FX cards (the canister can't fetch Stripe's actual
  fee without `sk_live`).
- **Lock the cycle _quantity_ at order creation** (not just a rate). At mint
  time, compute whatever ICP is needed to mint that many cycles at the
  then-current CMC rate; the **operator absorbs ICP-cost movement.** This makes
  "no quote drift" literally true.
- **Card amounts: fixed tiers**, one permanent static Payment Link each. The
  paid amount is structurally pinned by which tier link was used, giving
  deterministic amount-match. (We deliver on the **actual** paid amount, so a
  mismatched claim is honored at what was really paid.)

### 3.1 Forex rate subsystem (the one outbound-HTTPS exception)

USD→cycles needs a USD↔XDR forex input. CMC provides only ICP↔XDR. There is no
on-chain XDR/USD oracle, and we chose a **direct HTTPS outcall** over XRC.

- ⚠️ **This reintroduces outbound HTTPS** (a `transform` fn, ×replica cost,
  IPv6 requirement). Accepted deliberately. The XRC inter-canister option was
  rejected; the manual-constant option was rejected.
- **Determinism:** the live rate is the hard case for consensus (each replica
  samples a different value). Mitigated by a **coarse-rounding `transform`** so
  replicas converge. Rounding *reduces, never eliminates*, boundary-split
  failures.
- **Cadence:** cache `{rate, ts}` in stable state; **lazy refresh** — orders
  read the cache; only a **stale** cache triggers an outcall. **Single-flight**
  guard so a burst doesn't fire concurrent outcalls. **In-call retry cap**
  (boundary-splits often clear on retry).
- ⚠️ **Fail-closed:** if a stale-triggered refresh fails (consensus or API
  down), **block order creation** ("rate temporarily unavailable, retry") rather
  than price on a stale rate. Safe because this happens at order *creation*,
  before any money moves. **Extended outage ⇒ no new orders, but in-flight paid
  orders still fulfill** (fulfillment uses the locked cycle quantity, not a fresh
  rate).
- **Keyless, IPv6-reachable source** required — a keyed API would add a *second*
  node-provider-readable secret and break the "one secret" property.

---

## 4. Core: one Order, one state machine

```
Created ──(never paid; advisory)──▶ Expired
   │                                   │
   │  (webhook verified, deduped,      │ (late real payment)
   │   amount honored)                 ▼
   └──────────────▶ Paid ◀────────────┘
                      │
                 [enough ICP float?]
                  ├─ yes ─▶ Minting ─▶ IcpAtCMC ─▶ Delivered
                  └─ no  ─▶ AwaitingTreasury ─(refill)─▶ Minting
                                  └─(max-wait exceeded)─▶ ErrorQueue
```

- **Money-in differs per rail; money-out is unified** (all converge on CMC mint
  from the shared ICP float).
- **`Created`** locks the cycle quantity (see §3). **Expiry is advisory only** —
  a genuine first payment always follows the happy path at the locked quantity;
  expiry only affects the live polling/QR UX.

### 4.1 Error queue — exactly two types

| Type | Trigger | State at queueing | Resolution |
|---|---|---|---|
| **Type 1 `{Duplicate \| Unattributed}`** | Genuine 2nd/distinct payment for an already-handled order, OR `client_reference_id` resolves to no order. | **Fiat exists, nothing minted** (dedup gates the mint). | ⚠️ **Operator refunds in the Stripe Dashboard** (manual, off-chain, no `sk_live`). The `charge.refunded` webhook auto-marks the entry resolved. |
| **Type 2 `{Undeliverable}`** | ICP→cycles minted, but delivery failed (e.g. target canister deleted). | **Cycles exist, in the app canister's own balance.** | Operator refunds or re-delivers; undeliverable cycles subsidize the canister's own gas in the meantime. |

⚠️ **Override of the original doc**, which credited the *user's* cycles-ledger
balance and deferred fiat refunds. We do the opposite: **no automatic user
credit**; off-happy-path money is **human-resolved**, and the operator **does**
issue manual fiat refunds.

**Key invariants:**
- **Dedup gates the mint** — never mint for a payment that can't be cleanly
  attributed to an open, undelivered order. This keeps Type 1 "fiat-only."
- **Stripe dedup ≠ double-pay protection.** `event.id`/`payment_intent` dedup
  only catches Stripe *redelivering one event* (at-least-once delivery). A user
  genuinely paying twice produces two distinct events/payment_intents = two real
  payments → the second is Type 1.
- A permanent Payment Link is **always live**; `client_reference_id` is an
  attacker-editable URL param → **claimed, not trusted.** Every dollar that
  arrives must resolve to delivery, Type 1, or Type 2.

### 4.2 Data model (stable, persistent actor)

- `orders : Map<OrderId, Order>`
- `journal : Map<OrderId, JournalEntry>` (status, transfer intent, block_index, cycles, retries, timestamps, destination)
- per-rail dedup: `processedStripeEvents`, `processedIntents`, `processedCkUsdcBlocks : Set<Nat>` (a `processedBaseTx` set joins if/when Base returns, §11)
- `errorQueue` (Type 1 + Type 2, bounded)
- `principalsToOrders : Map<Principal, [OrderId]>`
- `auditLog` — **bounded ring buffer**

**Retention:** keep financial records (orders, journal, crypto `block_index`/tx
dedup — small, last for years); ring-buffer the audit log (hard cap); prune
Stripe dedup after **~7 days** (Stripe redelivers ≤3d). Archival pipeline
deferred.

**Persistence:** `persistent actor` + orthogonal persistence; shape changes via
explicit `(with migration = ...)` functions (see migrating-motoko skills).

---

## 5. Money-out: unified CMC mint + recovery

- All rails mint from **one operator-funded ICP float.** Each rail's money-in
  accrues as **revenue**; operator converts revenue→ICP off-chain and refills the
  float.
- **Delivery pattern: mint-to-self-then-forward.** Mint cycles to the app
  canister first, then forward to the destination. A failed forward (deleted
  target) leaves cycles in the app balance (→ Type 2) rather than failing
  atomically inside CMC — this is what makes the Type-2 fallback possible.
- **No pre-validation of the destination canister** (decided): a bad/deleted
  `Canister` destination just becomes a Type-2 the operator resolves.
  `CyclesLedgerAccount` destinations essentially never fail, so users wanting
  guaranteed delivery can use those.
- Flow: `icrc1_transfer` ICP → CMC subaccount (memo `TPUP`/`MINT`) → record
  `block_index` → `notify_top_up`/`notify_mint_cycles`. Idempotent on `block_index`.
- **Rate derivation** mirrors CyclePay's `derive_icp_e8s_from_usd_cents`: CMC
  ICP/XDR rate with a **staleness guard** (CyclePay used 15 min, post-incident);
  combined with the §3.1 USD/XDR.

### 5.1 Ambiguous-transfer protection (the hard correctness corner)

⚠️ **Write-intent-before-call + `created_at_time` ledger dedup:**
1. Persist deterministic transfer args `{created_at_time, amount, CMC target, memo}` **before** transferring.
2. Execute `icrc1_transfer`; on success persist `block_index`.
3. On recovery, **replay the identical transfer** — the ledger either performs it
   once or returns `Duplicate{block_index}`. Either way the `block_index` is
   recovered with **no double-spend.**
- **Bounded by the ledger's ~24h dedup window** → recovery cadence **≪ 24h**.
  An intent older than the window **without** a known `block_index` must **not**
  be auto-replayed → escalate to the error queue.

### 5.2 Recovery timer

- `recurringTimer` sweeps stuck `Minting` / `IcpAtCMC` / `AwaitingTreasury`.
- **Single-flight** `RECOVERY_IN_PROGRESS` guard; **re-armed in `postupgrade`**
  (no `pumping`-style deadlock).
- `notify_*` is idempotent on `block_index`, so resume can't double-mint.

### 5.3 Treasury management + ICP burn cap

- **`AwaitingTreasury`**: a Paid order the float can't yet fund sits here; the
  recovery timer retries until refill; **soft UI gate** disables tiers when the
  float is low; **balance alerts** via a query method + audit log; a **max-wait
  bound** escalates to the error queue (operator refunds).
- ⚠️ **Per-period ICP burn cap** (decided): a hard, operator-configured ceiling on
  total ICP the canister will convert to cycles within a rolling window. This is
  the **primary blast-radius bound** if the webhook secret leaks (forged "paid"
  webhooks can't drain more than the cap before detection + rotation) — and it
  doubles as a safety limit against any mint-path bug. When the cap is hit, new
  mints pause (orders sit in `AwaitingTreasury`-style hold) + alert; resets next
  window or on manual override. Independent of SEV — works on any subnet.

---

## 6. Rails

### 6.0 Ingress — two paths (decided)

HTTP requests reach a canister via the IC boundary node, which packages them into
a Candid `HttpRequest` and calls `http_request` (query) → if the handler returns
`upgrade = ?true`, it re-issues to `http_request_update` (update, through
consensus). **Crucially, HTTP requests arrive as the _anonymous_ principal** —
the boundary node does not propagate Internet Identity. So HTTP routes can only be
authenticated by their **payload**, never by `caller == owner`. This forces two
ingress paths:

- **Candid calls (agent-js, II-authenticated)** — the entire app API: create
  order (locks rate, captures owner), query status, order history, admin /
  error-queue resolution, **and the ck-USDC `approve`/pull flow**. Caller = the
  real II principal.
- **HTTP route (anonymous, payload-authed)** — **exactly one: `POST /webhook/stripe`**,
  authenticated by the HMAC. Stripe can't make Candid calls, so this is
  irreducible; nothing else needs HTTP ingress now that Base/x402 is deferred.

⚠️ **Hand-rolled `Http.mo` on `mo:core`, not `mo:server`** (decided): `mo:server`
carries the deprecated `mo:base` and asset-store / caching / certification
machinery we don't need (assets live on a separate canister; this canister only
POSTs). With a single POST route that **always** returns `upgrade = ?true`,
response certification is moot (the gateway discards the query response and re-runs
the update through consensus). The minimal surface: parse `HttpRequest`,
**case-insensitive header lookup** (for `Stripe-Signature`), strip the query
string, match the one path, body-size guard, sane status codes.

### 6.1 Card (Stripe) — inbound-only, no `sk_live`

- Static Payment Link per tier; URL carries `client_reference_id = <principal>_<orderId>`.
- Stripe POSTs `checkout.session.completed` to `/webhook/stripe` (IC gateway +
  `upgrade=?true`). Also handle `charge.refunded` for Type-1 reconciliation.
- On-chain **HMAC-SHA256** verification of `timestamp.body` against the webhook
  signing secret; timestamp-window replay guard; dedup on `event.id` +
  `payment_intent`; amount honored on actual paid value → `Paid`.

### 6.2 ck-USDC (ICRC-2) — pure in-canister

- `icrc2_approve` → backend `icrc2_transfer_from` (amount + fee). Dedup on
  `block_index`. Amount-short → mismatch handling.
- ⚠️ **Hold ck-USDC, mint from the shared ICP float** (not per-order DEX). Operator
  converts accrued ck-USDC→ICP off-chain to refill. Consistent with the card rail.

### 6.3 USDC on Base (x402) — ⚠️ DEFERRED / OUT OF SCOPE FOR NOW

Dropped from current requirements (see §11 for the full rationale + the prior
design work that's parked there). In short: unclear consumer (a generic x402
client is an agent, which wouldn't use II — a different ownership model), and it
carried *all* the EVM-crypto risk (keccak/RLP/ABI/EIP-712/`ecrecover`, threshold
ECDSA, EVM RPC, ETH gas tank). The order state machine remains rail-pluggable so
it can return cleanly later.

---

## 7. Security & trust

- ⚠️ **Webhook signing secret: SEV-SNP for confidentiality + ICP burn cap for
  blast-radius** (reverses the earlier "pull vetKeys in" decision — **no vetKeys
  at all**). The only stored secret; HMAC is symmetric, so "verify" = "forge" → it
  must be kept confidential. Stored **plaintext** in canister state; protected by
  the hardware, not by cryptography in the canister. Set via an admin method.

  **Why this is acceptable (the documented tradeoff):** even in the worst case
  where the secret leaks, an attacker can only forge "paid" webhooks → mint free
  cycles at operator expense, and a **per-period ICP burn cap** (see §5.3) bounds
  how much can be drained before detection + secret rotation. Stripe account/PII
  are untouched (no `sk_live`); forged orders are detectable via off-chain
  reconciliation; the secret is rotatable. So the loss is **bounded, detectable,
  and recoverable** regardless of whether SEV holds.

  **SEV-SNP caveats that MUST be tracked (per `ARCHITECTURE_ANALYSIS.md` §8 —
  documenting honestly, not assuming "safe"):**
  - **Confidentiality rests on hardware + attestation**, not math: SEV-SNP
    unbroken *and* every replica in the subnet running attested SEV-SNP. Trust
    shifts to AMD; SEV-SNP has a published side-channel CVE history.
  - ⚠️ **Memory encryption ≠ state-at-rest encryption.** SEV-SNP protects RAM, but
    canister state is also **checkpointed to disk and state-synced** between nodes.
    **If checkpoints/state-sync are not also confidential on the target subnet, a
    plaintext secret leaks through that path and SEV buys nothing.** *Verify this
    hardest before relying on it.*
  - **Provisioning exposure:** setting the secret via an update call means the
    argument **transits the boundary node** (TLS-terminated there) and is processed
    as an ingress message — exposed at provisioning unless an attestation-tied
    confidential channel is used.
  - **Maturity / availability:** depends on an attested SEV-SNP confidential subnet
    being production-ready and the canister actually deployed there. **If no such
    subnet is available when M1 ships, the secret is plaintext on a normal subnet
    and the ICP burn cap + accountable node providers are the *only* protections.**
    The burn cap is the robust, available-today backstop; SEV is the confidentiality
    layer that may or may not be available — design so launch doesn't *block* on it.
- **Governance:** ⚠️ **flat controller allowlist, equal privileges** — any
  controller can upgrade, withdraw funds/cycles, provision/rotate the secret,
  resolve error-queue entries, set tiers, adjust forex params, pause, edit the
  controller set. Admin authz = caller ∈ controllers. Honest trust model: "trust
  the operator set; any one can upgrade-then-drain." M-of-N (note: IC controllers
  are OR-semantics, so true M-of-N upgrades need a multisig-canister controller)
  and SNS are the documented hardening path.
- **Base key isolation:** n/a while Base/x402 is deferred (§11). No threshold-ECDSA
  signing key exists in scope; the only secret in the system is the plaintext
  Stripe webhook signing secret (§7, first bullet).

---

## 8. Verifiability (the thesis)

- **Docker-pinned reproducible build:** `moc` pinned in `mops.toml [toolchain]`,
  recipe versions pinned in `icp.yaml` (icp-cli rejects unpinned), `mops.lock`
  committed, `ic-wasm` for deterministic optimization + metadata.
- Each tagged release **publishes the expected module hash**; anyone verifies via
  `icp canister status <canister>` and diffs.
- Frontend via `@dfinity/asset-canister` recipe — **certified assets**, committed
  `.did`, reproducible asset build.
- External security audit **not gated** for v1 (easy to add per rail GA later).

---

## 9. Tech stack & layout

- **Motoko** (`persistent actor`, `mo:core` 2.0.0+), **hand-rolled `Http.mo`**
  (not `mo:server`, see §6.0) + separate asset canister, `Timer`.
- Candid bindings: ICP ledger, CMC, ck-USDC (ICRC-1/2), cycles ledger.
  (No vetKD / IC-management ECDSA — neither vetKeys nor Base in scope.)
- `mops` packages: HMAC/SHA-256, JSON, hex. (No EVM crypto — Base deferred.)
- `icp-cli` build/deploy; reproducible release.
- Tests — **go-live bar** (decided): **unit tests wherever logic is isolable**
  (HMAC, fee math, rate derivation, parsers, state-machine transitions, dedup)
  **+ a full PocketIC integration suite green before each rail's go-live**.
  PocketIC suite covers: happy path, duplicate/replay, ambiguous-transfer
  recovery, `AwaitingTreasury`, error queue Type1/Type2, forex fail-closed,
  upgrade-mid-flight, `postupgrade` re-arm. External simulation: real ledger/CMC
  Wasms; **crafted HMAC-signed Stripe webhooks**; **mocked HTTPS outcall** for
  forex; PocketIC time-control for timers.

```
src/backend/
  Main.mo        # actor: http_request(_update), order Candid API, timer, migration hooks
  Http.mo        # hand-rolled minimal HTTP: parse, case-insensitive headers, one route
  Orders.mo      # Order + JournalEntry types, state machine, stable store
  Idempotency.mo # per-rail dedup sets + retention/pruning
  ErrorQueue.mo  # Type1/Type2 entries, bounded
  rails/Card.mo  # Stripe webhook HMAC verify + parse + charge.refunded
  rails/CkUsdc.mo# ICRC-2 approve/transfer_from flow (Candid)
  Cmc.mo         # ICP transfer (write-intent + created_at_time) + notify_*
  Secret.mo      # webhook secret: admin-set, plaintext (SEV-protected), rotation
  Forex.mo       # cached rate + lazy refresh outcall + transform
  Treasury.mo    # ICP float, AwaitingTreasury, alerts
  Auth.mo        # II ownership + controller allowlist
  Util.mo, Hmac.mo, Account.mo
src/frontend/    # Astro/JS SPA, II login, Card + ck-USDC UI, order history
```

(Base-rail modules — `rails/Base.mo`, `Ecdsa.mo`, `EvmRpc.mo` — and EVM `mops`
crypto are parked until/unless Base returns; see §11.)

---

## 10. Resolved since v2 draft

- **Ingress (decided):** two-path model — II Candid for the whole app API +
  ck-USDC; **one anonymous HTTP route** (`/webhook/stripe`). **Hand-rolled
  `Http.mo` on `mo:core`**, not `mo:server` (§6.0).
- **Base/x402 dropped from scope for now** (§6.3, §11) — removed all EVM crypto,
  threshold ECDSA, EVM RPC, ETH gas tank, and the EVM-address ownership variant;
  **single II ownership restored**.
- **vetKeys dropped** (§7) — webhook secret kept confidential by **SEV-SNP**
  (hardware) with documented caveats, and blast-radius bounded by a **per-period
  ICP burn cap** (§5.3). No vetKD dependency.
- **Frontend:** polling order-status by `order_id` + order-history view; **no
  destination pre-validation** (Type-2 is the catch-all). M1 builds the shell +
  Card flow + history + rail selector; M2 adds the ck-USDC panel.
- **Go-live test bar:** unit-where-possible + full PocketIC suite per rail (§9).
- **Seams kept for Base (§11.1, binding on M1):** `Owner` single-case variant
  (§2), `Http.mo` route table, ownership captured at the API edge, expiry
  semantics per-rail. Keeps a future Base return additive, not a refactor.

## 10a. Resolved since v2.1 (the spec's own gaps, now closed)

Decisions taken after v2.1 shipped, recorded here because they change behaviour
the sections above describe. Implementation and operator procedure live in
`docs/STRIPE.md` and `RUNBOOK.md`.

- **Order expiry is enforced, not just legal.** §4 defined
  `#created → #expired` and made expiry advisory, but nothing ever performed the
  transition. `Retention.mo` now owns three bands: live (`#created`, < TTL,
  default 48 h), **expired-but-honoured** (`#expired`, still fully payable — the
  §4 guarantee is unchanged), and **swept** (past a 90-day horizon the record is
  deleted and the id kept in a permanent `sweptOrders` tombstone set).
  - A payment for a swept order is Type 1 `#unattributed` with an explicit
    "was SWEPT" reason, preserving the §4.1 invariant that every verified dollar
    resolves to delivery, Type 1, or Type 2. It degrades to a **refund, not a
    loss**.
  - **Nothing that touched money is ever deleted**: an order with a mint journal
    entry or a ck-USDC pull entry is retained regardless of age, and
    `#delivered`/`#errorQueue` are records kept indefinitely. Their volume is
    bounded by real sales, which the burn cap bounds.
  - Sweeping is cleanup, not protection — see the admission gate below for the
    bound that actually stops state growth.

- **Admission gate before quoting (`Gate.mo`).** §3 and §5.3 checked float and
  burn-cap headroom only at *mint* time, i.e. after the customer had paid.
  `create_order` (both rails) now refuses first, carrying the observed value and
  the bound so the frontend can explain the refusal: per-principal open-order
  cap, this canister's **own** cycle-balance floor, burn-cap window headroom,
  ICP float threshold, and a per-purchase ceiling. `Treasury.gate` remains the
  authoritative money check at mint time.
  - ⚠️ **Deliberately an admission gate, not a capacity reservation.** A
    reservation would need reserved-but-unpaid accounting plus a release path for
    abandoned orders, and it still could not guarantee delivery (the operator can
    withdraw the float; the CMC rate moves). Nothing is escrowed at creation —
    `lockedCycles` is a **price, not a hold** — so a lapsed order releases
    nothing.
  - ⚠️ **These three defaults are non-zero**, unlike the burn cap and the
    ck-USDC bound. Those are money decisions that must ship dark; these are
    safety limits where a 0 default would brick the canister rather than protect
    it. The card rail's on/off switch remains the empty tier list.
  - **Two distinct resources.** The canister's own cycle balance (its gas —
    exhaustion freezes then uninstalls it) was previously never read at all. It
    is unrelated to the ICP float, which buys cycles for customers.

- **Per-purchase ceiling.** `Tiers.validate` rejects a tier above it (the
  operator-typo guard), and webhook amount-honouring refuses to mint a payment
  above it — §6.1's repricing is an *upward* path, so an untampered ceiling is
  what keeps a tampered link or a mis-set Stripe price from minting an arbitrary
  quantity.

- **Refund-after-delivery is recorded (`#refundAfterDelivery`).** §4.1 covered
  refunds only as the *resolution* of a Type 1 entry. A `charge.refunded` for an
  order already `#delivered` is a fourth position — fiat out **and** cycles out —
  and is now queued and audited via a `payment_intent → orderId` index. It is
  neither Type 1 nor Type 2, is never auto-resolved (the refund is what created
  it), and is **not recoverable**: the canister cannot claw back forwarded cycles.
  - ⚠️ **`charge.dispute.*` remains unsubscribed, by decision.** Feasible but not
    actionable for the same reason. Chargeback exposure is managed by Stripe
    Radar/3DS and by the per-purchase ceiling; the burn cap does **not** bound it,
    because each payment is individually legitimate.

- **Upgrades require stopping the canister first.** §5.1 stated upgrades were
  safe mid-flight; the mechanism is different from what was assumed. The IC
  *rejects* an upgrade while callbacks are outstanding, and `stop_canister`
  **drains** in-flight calls rather than dropping them. The stop-first procedure
  is therefore both mandatory and the safe one: a controlled upgrade cannot
  strand money.
  - Consequence: `ambiguousForward` and `stalePullIntent` are unreachable through
    a controlled upgrade. They cover genuine faults (a callee that never replies,
    a subnet incident, cycle exhaustion mid-call) and remain unit-tested.
  - Motoko's enhanced orthogonal persistence additionally requires
    `wasm_memory_persistence = keep` on the upgrade.

- **Cycles-ledger delivery nets the ledger's deposit fee.** The two §5 forward
  arms are asymmetric: a `#canister` destination receives the full locked
  quantity, a `#cyclesLedgerAccount` destination receives it minus the ledger's
  100 M-cycle deposit fee. ⚠️ **Deliberately not grossed up** — paying it from the
  app's own balance would make every such order a subsidy, i.e. a griefable
  gas-drain vector. The user chose the delivery rail and bears its fee.

- **SEV-SNP subnet availability is confirmed.** §7 and §11 treated it as an open
  question. Two sub-caveats remain open and unchanged: whether
  **checkpoints/state-sync are also confidential** on the target subnet (memory
  encryption alone does not cover state at rest — verify this hardest), and the
  **provisioning exposure** of `set_webhook_secret` through the TLS-terminating
  boundary node. The ICP burn cap remains the always-on backstop regardless.

## 11. Deferred / future (non-blocking)

- **Base/x402 rail** — the original 3rd rail, dropped (§6.3). Open question to
  resolve before it returns: **who is the consumer?** A generic x402 client is an
  agent, which wouldn't use II — implying a different (EVM-address) ownership
  model. Parked work if it returns: EVM crypto (`mops` keccak/RLP/ABI/EIP-712/
  `ecrecover`), threshold ECDSA, EVM RPC, ETH gas tank, hot→cold sweeping,
  validation via test vectors + differential + Base Sepolia e2e.

### 11.1 Seams kept for Base (binding on M1 implementation)

Base is out of scope, but M1 must not bake in assumptions that would have to be
*unwound* (rather than added to) if it returns. Most of the architecture is
already rail-agnostic — money-out (`Paid` → float → CMC mint), recovery, the
burn cap, and per-rail dedup sets are all additive. Four seams are deliberate
and **binding** on the M1 implementation:

1. **`Owner` variant (§2):** `type Owner = { #ii : Principal }` from day one.
   Adding `#evmAddress : Blob` later is a compatible, migration-free variant
   extension; a bare `Principal` field would mean a stable-state migration and
   an audit of every authz site.
2. **`Http.mo` routes via a table, not a hardcoded path.** "Exactly one route"
   (§6.0) is *policy*, not architecture: dispatch off a `[(method, path,
   handler)]` table with one entry. x402 is also anonymous, payload-authed HTTP
   — it adds rows, not a restructure. Likewise `upgrade = ?true` is a per-route
   flag that happens to be true everywhere in M1.
3. **Ownership capture stays at the API edge.** `Orders.createOrder` takes the
   owner as a *parameter*; it never reads `msg.caller` itself. Card/ck-USDC
   orders are created by an II Candid call, but a Base order would be created by
   an anonymous HTTP request whose owner comes from the verified EIP-3009
   signature.
4. **Expiry semantics are per-rail money-in behavior — do not unify into the
   core.** "Expiry is advisory only" (§4) is a *Card* property (a late genuine
   payment is still honored). Base would need **enforced** expiry
   (`validBefore`, reorg/confirmation windows). The state machine owns
   transitions, not expiry policy.
- **Confidential-subnet verification** — confirm an attested SEV-SNP subnet is
  available and that **checkpoint/state-sync are also confidential** (§7); deploy
  there. Until then the ICP burn cap + accountable providers carry the secret.
- **M-of-N / SNS governance** (true M-of-N upgrades need a multisig-canister
  controller, since IC controllers are OR-semantics).
- **Retention/archival pipeline** once order volume warrants.
- **External security audit** (mint/idempotency + secret-handling paths).
