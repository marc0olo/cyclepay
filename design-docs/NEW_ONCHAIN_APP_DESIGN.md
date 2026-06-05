# Fully On-Chain Cycles Gateway — Design Spec (v1)

> Greenfield design for a fully on-chain "buy cycles with fiat or stablecoins"
> service. Successor in spirit to Cycle.Express, with the capability surface of
> CyclePay but run as a single verifiable canister. See `ARCHITECTURE_ANALYSIS.md`
> for the reasoning that led here.

## Locked decisions

| Decision | Choice | Consequence |
|---|---|---|
| Rails in v1 | **Card + ck-USDC + USDC-on-Base (x402)** | Full parity; Base rail is the hard part |
| Card rail | **Inbound-only** | No `sk_live` on-chain; cycles-ledger credit instead of fiat refunds |
| Language | **Motoko** | Clean HTTP serving via `mo:server`; thinner EVM tooling |
| Topology | **Single backend + asset canister** | One verifiable Wasm; ECDSA key not isolated (future hardening) |

**Zero stored plaintext secrets** except the Stripe *webhook signing* secret →
no vetKeys / SEV-SNP dependency for v1.

**Where the risk concentrates:** the Base/x402 rail (threshold ECDSA + EVM RPC +
EIP-3009/keccak/RLP in Motoko) and the unisolated signing key.

---

## Topology

```
┌──────────────────────┐        ┌────────────────────────────────────────────┐
│ Frontend asset        │       │            Backend canister (Motoko)         │
│ canister              │──HTTP─▶│  mo:server  : serve SPA + API + webhooks     │
│ (Astro/JS, II login)  │       │  Orders     : durable state machine (stable) │
└──────────────────────┘        │  Rails      : card / ck-USDC / Base          │
                                 │  Mint       : CMC notify_top_up / mint       │
       Stripe ──webhook──────────▶  Auth       : II / delegation / OIDC          │
       (inbound, HMAC on-chain)  │  Timers     : recovery + subscriptions       │
                                 └──┬─────┬───────┬──────────┬──────────┬───────┘
                                ICP ledger CMC  ck-USDC   mgmt(aaaaa-aa) │
                                                (ICRC-2)                 │
                                                  ┌──────────────────────▼─────┐
                                                  │ IC mgmt sign_with_ecdsa +   │
                                                  │ EVM RPC canister (Base RPC) │
                                                  └─────────────────────────────┘
```

---

## Core: one Order, one state machine

Every payment on every rail becomes a durable `Order` in stable storage, keyed
by a generated `order_id`, owned by a **principal** (Internet Identity), driven
by an idempotent journal:

```
Created ─▶ Paid ─▶ Minting ─▶ IcpAtCMC ─▶ Delivered
   │         │                    │
   ├─Expired ├─AmountMismatch     └─ recovery timer resumes (idempotent on block_index)
   │         │
   └─────────┴─▶ Failed ─▶ CyclesCredited (ledger fallback)  [or Refunded, future]
```

- **Money-in differs per rail; money-out is unified** (all converge on the CMC mint).
- **Idempotency:** dedup keys per rail in stable sets —
  - Card: Stripe `event.id` + `payment_intent`
  - ck-USDC: ICRC-2 transfer `block_index`
  - Base: on-chain tx hash
- **Recovery:** `recurringTimer` sweeps stuck `Minting`/`IcpAtCMC` entries and
  resumes; CMC notify is idempotent on `block_index`, so resume can't double-mint.
  Timer re-armed in `postupgrade`. No `pumping`-style deadlock.

### Data model (stable)

- `orders : Map<OrderId, Order>`
- `journal : Map<OrderId, JournalEntry>` (status, icp block_index, cycles_minted, retries, timestamps, destination)
- `processedStripeEvents : Set<Text>`, `processedIntents : Set<Text>`
- `processedCkUsdcBlocks : Set<Nat>`, `processedBaseTx : Set<Text>`
- `subscriptions : Map<SubId, Subscription>`
- `auditLog : append-bounded log` (queryable by principal)
- `principalsToOrders : Map<Principal, [OrderId]>` (order history → fixes the lost-receipt UX)

Use a stable map library (`mo:map`) or Region-backed ordered maps; **bound** the
audit log and any failure lists (no unbounded append-only growth).

---

## Money-in rails

### 1. Card (Stripe) — inbound-only

- Frontend uses a **static Stripe Payment Link** with `client_reference_id = <principal/account>_<orderId>`.
- Stripe POSTs `checkout.session.completed` to the canister's `/webhook/stripe` (via the IC HTTP gateway + `upgrade=?true`).
- On-chain **HMAC-SHA256** verification of `timestamp.body` against the webhook signing secret.
- Amount-mismatch check vs. the order; dedup on event id + payment intent → `Order = Paid`.
- **No outbound Stripe calls. No `sk_live`.** Terminal failures credit cycles to the user's Cycles-Ledger balance rather than refunding fiat.

### 2. ck-USDC (ICRC-2) — pure in-canister, no secrets

- User calls `icrc2_approve` granting the backend an allowance for `amount + fee`.
- Backend `icrc2_transfer_from` pulls ck-USDC → `Order = Paid`. Dedup on `block_index`.
- Convert ck-USDC → ICP (DEX call) or hold; then mint. Auto-refill can reuse the standing allowance — **no card-on-file needed**.

### 3. USDC on Base (x402) — threshold ECDSA + EVM RPC *(hardest)*

- First `/x402/topup` returns `402` with payment requirements; user signs **EIP-3009 `transferWithAuthorization`**, reposts with `X-PAYMENT`.
- Canister verifies the signed authorization, then submits the `transferWithAuthorization` on Base:
  - derive the canister's Base address from its **threshold-ECDSA** public key (IC mgmt `ecdsa_public_key`)
  - build + RLP-encode + keccak-hash the EVM tx, **`sign_with_ecdsa`**, broadcast via the **EVM RPC canister**
  - verify settlement via `eth_getTransactionReceipt` (EVM RPC) → `Order = Paid`. Dedup on tx hash.
- **Motoko effort:** keccak256, RLP, secp256k1 pubkey→address, EIP-3009 digest. Pull in `mops` crypto packages; budget the most time here.

---

## Money-out: unified CMC mint

- Backend holds an **ICP** balance (operator-funded).
- Derive ICP e8s from USD/stablecoin amount at the protocol XDR rate (query CMC); margin optional on top.
- `icrc1_transfer` ICP → CMC subaccount (memo `TPUP` for canister, `MINT` for ledger) → `notify_top_up` / `notify_mint_cycles`.
- Journal transitions `Minting → IcpAtCMC → Delivered`; recovery resumes on `IcpAtCMC`.

## Failure handling / refunds

- Retries with backoff; long-backoff class for CMC rate-stale.
- Terminal failure → **credit cycles to the user's Cycles-Ledger balance** (on-chain native, no Stripe). Real fiat refund deferred (would require the outbound/`sk_live` path).

## Auth & identity

- **Internet Identity** sign-in; per-principal order ownership and history.
- **Delegation-chain** verification in-canister for agent/CLI bearer-token access.
- **GitHub OIDC** CI top-ups: HTTPS outcall for JWKS + in-canister JWT verify + trust policies (repo/branch/workflow → principal) with monthly spend caps.

## Background jobs (timers)

- `recurringTimer`: journal recovery sweep; subscription auto-refill (scan thresholds, mint when low — funded by ck-USDC allowance or ICP).
- Optional: hot-balance alerts surfaced via a query method / audit log.

---

## Tech stack & layout

- **Motoko**, `mo:server` + `mo:assets` (HTTP + asset hosting), `mo:base` `Timer`.
- Candid bindings: ICP ledger, CMC, ck-USDC (ICRC-1/2), EVM RPC canister, IC management (ECDSA).
- `mops` packages: HMAC/SHA-256, keccak256, RLP, secp256k1, JSON, hex.
- Build via `vessel`/`mops` + `moc`; assets via `icx-asset`; reproducible release like cycle-express.
- Tests: **PocketIC** integration (rails, recovery, idempotency, mint).

```
src/backend/
  Main.mo            # actor: HTTP routes, order API, timers, upgrade hooks
  Orders.mo          # Order + JournalEntry types, state machine, stable store
  Idempotency.mo     # per-rail dedup sets
  rails/Card.mo      # Stripe webhook verify (HMAC) + parse
  rails/CkUsdc.mo    # ICRC-2 approve/transfer_from flow
  rails/Base.mo      # EIP-3009 verify, EVM tx build/sign/broadcast, receipt
  Cmc.mo             # ICP transfer + notify_top_up / notify_mint_cycles
  Ecdsa.mo           # threshold ECDSA: address derivation + signing
  EvmRpc.mo          # EVM RPC canister bindings + helpers
  Auth.mo            # II / delegation / OIDC verification
  Util.mo, Hmac.mo, Account.mo
src/frontend/        # Astro/JS SPA, II login, multi-rail UI, order history
```

---

## Comparison to CyclePay (with these choices)

| Dimension | This app | CyclePay |
|---|---|---|
| Operated infra | **1 backend canister** + assets | Node + Postgres + Rust canister + assets |
| Trust model | IC consensus only | + Railway + Postgres + CDP hot wallet |
| Card rail | Inbound on-chain, no `sk_live`, no fiat refund | Outbound Stripe SDK (refunds, off-session) |
| ck-USDC | In-canister ICRC-2 | Server-orchestrated |
| Base/USDC | **Threshold ECDSA, no hot wallet** | Off-chain CDP wallet |
| Correctness | Journal + per-rail idempotency + timer recovery | Journal + 3-layer idempotency + reconcilers |
| Refunds | Cycles-ledger credit | Automatic fiat refunds |
| Subscriptions | Timer + ck-USDC allowance | Stripe off-session charges |
| Secrets on-chain | Only Stripe webhook signing secret | n/a (server holds `sk_live`) |
| Verifiability | **Single auditable Wasm** | Trust operator servers |
| Reporting | KV stable storage | SQL |
| Maturity risk | Motoko EVM/ECDSA path is newer | Battle-tested stack |

---

## Open risks / decisions to revisit

1. **Base rail in Motoko** — keccak/RLP/secp256k1/EIP-3009 maturity; biggest unknown. Consider isolating the signing wallet into its own canister once it works.
2. **No fiat refunds in v1** — cycles-ledger credit must be clearly communicated to card users.
3. **KV aggregation** — monthly spend caps / reconciliation are more awkward than SQL; design query methods deliberately.
4. **HTTPS outcall use** is limited to GitHub OIDC JWKS in v1 (no outbound Stripe) — keeps cost/determinism surface small.
