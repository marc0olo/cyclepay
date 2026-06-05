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
verifiable Motoko backend canister + an asset canister. Card (Stripe, inbound),
ck-USDC (ICRC-2), and USDC-on-Base (x402) rails all converge on a unified
CMC mint. Successor in spirit to Cycle.Express with CyclePay's capability
surface, but run as one auditable Wasm.

**Tooling:** `icp-cli` (never `dfx`), `mops` for Motoko deps, Motoko with
`persistent actor` + orthogonal persistence.

---

## 1. Product scope & sequencing

| # | Decision | Rationale |
|---|---|---|
| 1 | **v1 = production money-handler.** Full idempotency + recovery on day one; every rail must be safe to lose funds on. | Highest correctness bar; this is real money, not a demo. |
| 2 | **Rails ship sequenced, each GA'd independently:** Card → ck-USDC → Base. | Real users/revenue while the Base (hardest) rail is still being hardened; Base bugs can't endanger proven rails. The order state machine is rail-pluggable from day one. |
| 3 | **Scope = human, one-shot, II-authenticated purchases only.** | Tightest audit surface. |
| 3a | ⚠️ **Override — OUT OF SCOPE entirely:** subscriptions, auto-refill, GitHub OIDC CI top-ups, delegation/agent HTTP API. | The original doc listed these. Subscriptions/auto-refill are impossible on card (need outbound `sk_live`) and only ever rode on a ck-USDC standing allowance, which is also cut. OIDC/delegation cut for scope. **Consequence: the product makes _almost_ no outbound HTTPS** (see §3 forex exception). |
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
- per-rail dedup: `processedStripeEvents`, `processedIntents`, `processedCkUsdcBlocks : Set<Nat>`, `processedBaseTx : Set<Text>`
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

### 5.3 Treasury management

- **`AwaitingTreasury`**: a Paid order the float can't yet fund sits here; the
  recovery timer retries until refill; **soft UI gate** disables tiers when the
  float is low; **balance alerts** via a query method + audit log; a **max-wait
  bound** escalates to the error queue (operator refunds).

---

## 6. Rails

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

### 6.3 USDC on Base (x402) — threshold ECDSA + EVM RPC *(release 3, biggest unknown)*

- First `/x402/topup` → `402` + payment requirements; user signs **EIP-3009
  `transferWithAuthorization`** off-chain (gasless for them), reposts with
  `X-PAYMENT`.
- ⚠️ **Verify the authorization locally first** (decided): the canister runs
  **secp256k1 `ecrecover` + EIP-712 typed-data hashing** in Motoko to confirm the
  signature recovers to the claimed `from` before spending any gas (rejects bad
  auths instantly, no wasted gas). Also check `validAfter`/`validBefore` window +
  nonce-unseen.
- Then **as relayer** submits `transferWithAuthorization` on Base: derive Base
  address from threshold-ECDSA pubkey (keccak) → ABI-encode the call → build +
  RLP-encode + keccak-hash the tx → `sign_with_ecdsa` → broadcast via the **EVM
  RPC canister** → settlement.
- **Settlement → `Paid`** only when `eth_getTransactionReceipt` shows
  `status=success` **and** recipient/amount/`from` match, after a small
  **confirmation buffer** (Base can reorg). **Dedup on tx hash**; EIP-3009 nonce
  replay guard.
- **EVM RPC multi-provider consensus** used for both broadcast and receipt reads.
- ⚠️ **Gas tank:** the canister-as-relayer **must hold ETH on Base** to pay gas
  (operator-funded). USDC settles to the same hot address and accrues as revenue.
  Gas-low → fail-closed/soft-gate the Base tier + alert (no money lost; the
  signed authorization simply isn't submitted until refilled).

#### Crypto: all-Motoko (decided)

⚠️ **All EVM crypto in Motoko**, not a Rust helper canister — preserves the
single-Wasm thesis. We rejected delegating to a Rust/Alloy signer canister
despite its maturity. **New `mops` packages will be written as needed.**

- **Surface:** keccak256, RLP encode/decode, ABI-encoding, EIP-712 typed-data
  hashing, **secp256k1 `ecrecover`** (the gnarly one), pubkey→address. (Outer-tx
  signing is IC threshold ECDSA, not a package.)
- **Validation gate (all green before Base go-live):** (1) Ethereum/EIP-712/
  EIP-3009 **known-answer test vectors**; (2) **differential/property testing**
  vs a reference impl (ethers.js/Alloy) — randomized inputs, assert byte-equality
  (catches `ecrecover` malleability / recovery-id edge cases); (3) **Base Sepolia
  end-to-end** (digest→ecrecover→sign→broadcast→receipt). External crypto audit
  not gated but strongly advisable (easy to add).

---

## 7. Security & trust

- ⚠️ **Webhook signing secret protected with vetKeys** (reverses the locked
  "no vetKeys for v1"). The only stored secret; HMAC is symmetric, so "verify" =
  "forge" → it must be confidential.
  - **Client-side IBE provisioning:** operator encrypts the secret against the
    canister's vetKD master public key; only **ciphertext** transits the boundary
    node / lives in stable memory + checkpoints.
  - **Derive-per-webhook + zeroize in-message** (no plaintext caching) so the
    decrypted secret **never persists into a checkpoint.**
  - **Honest limit:** a brief in-use RAM exposure remains during HMAC
    computation (SEV-SNP would close it; out of scope). Blast radius if leaked is
    bounded — forge "paid" webhooks → free cycles at operator expense; Stripe
    account/PII untouched; detectable via reconciliation; rotatable.
- **Governance:** ⚠️ **flat controller allowlist, equal privileges** — any
  controller can upgrade, withdraw funds/cycles, provision/rotate the secret,
  resolve error-queue entries, set tiers, adjust forex params, pause, edit the
  controller set. Admin authz = caller ∈ controllers. Honest trust model: "trust
  the operator set; any one can upgrade-then-drain." M-of-N (note: IC controllers
  are OR-semantics, so true M-of-N upgrades need a multisig-canister controller)
  and SNS are the documented hardening path.
- **Base key isolation:** unisolated per the locked topology, with blast-radius
  mitigations — periodic **sweep hot→cold** (keep only a working gas balance),
  signing factored into `Ecdsa.mo` (cheap to isolate later), **per-tx/per-period
  signing caps**.

---

## 8. Verifiability (the thesis)

- **Docker-pinned reproducible build:** `moc` pinned in `mops.toml [toolchain]`,
  recipe versions pinned in `icp.yaml` (icp-cli rejects unpinned), `mops.lock`
  committed, `ic-wasm` for deterministic optimization + metadata.
- Each tagged release **publishes the expected module hash**; anyone verifies via
  `icp canister status <canister>` and diffs.
- Frontend via `@dfinity/asset-canister` recipe — **certified assets**, committed
  `.did`, reproducible asset build.
- External security audit **not gated** for v1 (easy to add per rail GA later;
  Base crypto would be the priority target).

---

## 9. Tech stack & layout

- **Motoko** (`persistent actor`), `mo:server` + asset canister, `Timer`.
- Candid bindings: ICP ledger, CMC, ck-USDC (ICRC-1/2), cycles ledger, EVM RPC
  canister, IC management (ECDSA + vetKD).
- `mops` packages: HMAC/SHA-256, keccak256, RLP, secp256k1, JSON, hex.
- `icp-cli` build/deploy; reproducible release.
- Tests — **go-live bar** (decided): **unit tests wherever logic is isolable**
  (crypto primitives, fee math, rate derivation, parsers, state-machine
  transitions, dedup) **+ a full PocketIC integration suite green before each
  rail's go-live**. PocketIC suite covers: happy path, duplicate/replay,
  ambiguous-transfer recovery, `AwaitingTreasury`, error queue Type1/Type2,
  forex fail-closed, upgrade-mid-flight, `postupgrade` re-arm. External
  simulation: real ledger/CMC Wasms; **crafted HMAC-signed Stripe webhooks**;
  **mocked EVM RPC canister**; **mocked HTTPS outcall** for forex; PocketIC
  time-control for timers.

```
src/backend/
  Main.mo        # actor: HTTP routes, order API, timer, upgrade/migration hooks
  Orders.mo      # Order + JournalEntry types, state machine, stable store
  Idempotency.mo # per-rail dedup sets + retention/pruning
  ErrorQueue.mo  # Type1/Type2 entries, bounded
  rails/Card.mo  # Stripe webhook HMAC verify + parse + charge.refunded
  rails/CkUsdc.mo# ICRC-2 approve/transfer_from flow
  rails/Base.mo  # EIP-3009 verify, EVM tx build/sign/broadcast, receipt
  Cmc.mo         # ICP transfer (write-intent + created_at_time) + notify_*
  Ecdsa.mo       # threshold ECDSA: address derivation + signing (isolation-ready)
  EvmRpc.mo      # EVM RPC canister bindings + helpers
  Secret.mo      # vetKD IBE provisioning + derive-per-webhook decrypt
  Forex.mo       # cached rate + lazy refresh outcall + transform
  Treasury.mo    # ICP float, AwaitingTreasury, alerts, sweeps
  Auth.mo        # II ownership + controller allowlist
  Util.mo, Hmac.mo, Account.mo
src/frontend/    # Astro/JS SPA, II login, multi-rail UI, order history
```

---

## 10. Resolved since v2 draft

- **Frontend:** polling order-status by `order_id` + order-history view; **no
  destination pre-validation** (Type-2 is the catch-all).
- **Go-live test bar:** unit-where-possible + full PocketIC suite per rail (§9).
- **Base build:** **all-Motoko**, write new `mops` crypto packages as needed
  (§6.3); **local EIP-3009 verification** (full crypto surface incl. `ecrecover`);
  validation via test vectors + differential + Base Sepolia e2e.

## 11. Hardening roadmap (deferred, non-blocking)

- M-of-N / SNS governance (note: true M-of-N upgrades need a multisig-canister
  controller, since IC controllers are OR-semantics).
- Base signer-canister isolation (the `Ecdsa.mo` boundary keeps this cheap).
- vetKeys + SEV-SNP for full secret confidentiality (closes the in-use RAM gap).
- Retention/archival pipeline once order volume warrants.
- External security audits (Base crypto = priority target).
```
