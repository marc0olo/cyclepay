# Cycle.Express — Architecture Analysis & Comparison

> A walkthrough of how Cycle.Express works, the failure scenarios it does not
> account for, how it compares to the larger CyclePay system, and what a
> fully on-chain architecture would take. Captured from a design review session.

---

## 1. Overview: how Cycle.Express works

**One line:** Cycle.Express lets developers buy Internet Computer *cycles* (the
gas that powers canisters) with **fiat via Stripe** — no cryptocurrency required.
You give it a canister ID, pay with a card, and it tops up your canister.

The defining trait: **the entire app — frontend, backend, and the Stripe
webhook endpoint — lives inside a single IC canister.** No separate web server,
no database. The canister *is* the website and the API.

### Components

**Backend (Motoko) — `src/backend/`**

| File | Role |
|------|------|
| `Main.mo` (615 lines) | Actor class `CycleExpress`. Holds all state, the HTTP server, the transaction processor, the persistent log, and asset-store endpoints. |
| `Util.mo` | Parsing Stripe webhook JSON, client/session IDs, Stripe HMAC signature verification, dynamic cycle-price calculation. |
| `Hmac.mo` | SHA-256 HMAC (Stripe signs webhooks with HMAC-SHA256). |
| `Account.mo` | ICRC-1 account encode/decode. Vendored from dfinity/ICRC-1. |
| `CyclesLedger.mo` | Auto-generated Candid bindings for the Cycles Ledger canister. |

The backend embeds **`mo:server`** (Motoko Http Server), which lets a canister
serve HTTP and host static assets — the trick that makes one canister act as
both client and server.

**Frontend (JS + SCSS) — `src/frontend/`** — vanilla-JS single-page app with a
3-step wizard (Input → Payment → Receipt), bundled by Webpack into `dist/` and
uploaded into the canister as assets.

**Docs & assets** — Markdown converted to HTML by `pandoc`; `.well-known/ic-domains`
registers the custom domain `cycle.express`.

**External actors** — Stripe (payment gateway), the IC Management Canister
(`aaaaa-aa`, for plain canister top-ups), and the Cycles Ledger
(`um5iw-...`, for ICRC deposits with a subaccount).

### Init parameters & economic model

The canister is instantiated with (`Main.mo:30-35`):

- `prodKey` / `testKey` — Stripe **webhook signing secrets** (for `/checkout` and `/test-checkout`).
- `margin` — profit margin (percent).
- `defaultPrice` — fallback cycles-per-USD when there is no deposit history.

**Pricing is dynamic** (`Util.calculatePrice`): the canister tracks `deposits`
(cycles bought + USD cost) and `shippings` (cycles sold + USD earned); the
current price = remaining cycles ÷ remaining margin-adjusted cost. A
`MIN_CYCLE_RESERVE` of 100T and a flat `FEE_USD = 30¢` apply.

### Data flow — payment lifecycle

1. **Load** — browser hits the canister; `mo:server` serves the SPA from the in-canister asset store.
2. **Validate recipient** — JS validates the canister/account ID; for a plain canister it does a `read_state` call directly against the IC (`icp0.io`).
3. **Fetch price** — SPA calls `GET /status` → `{ normal: { cyclesPerUsd } }`.
4. **Create payment link** — SPA builds a Stripe link embedding `client_reference_id = <account>_<timestamp>-<nonce>`; QR code shown. `<timestamp>-<nonce>` is the **session ID** used for polling.
5. **Pay on Stripe** — card entered on Stripe's hosted page; the canister never sees card data.
6. **Webhook** — Stripe POSTs `checkout.session.completed` to `POST /checkout`; the handler verifies the HMAC over `timestamp.body` using `prodKey`, appends the body to the persistent log, and calls `processNextLogs()`.
7. **Process** — `processNextLogs()` parses new log entries; `"paid"` entries enqueue `(client, amount)` to `pending`, then `pump()` deposits cycles (Management canister for plain canisters, Cycles Ledger for subaccounts), moving items to `processed`/`failed`.
8. **Poll** — SPA polls `GET /status?sessionId=...` every 4s; `lookupSession()` matches by `(timestamp, nonce)`.
9. **Receipt** — on `done` the SPA shows the receipt and stops polling.

**Why a persistent log sits in the middle:** the canister records the raw webhook
to an append-only log in stable `Region` memory, then processes it separately.
This decouples receipt-of-payment from delivery-of-cycles: webhooks get a fast
200, processing can be retried, and the log is the durable source of truth that
survives upgrades.

### Trust & admin model

- Creator-only methods (`assert(caller == creator)`): `stats`, `view_logs`, `deposit`, `resetAuthorized`, `pumpFailed`, `resetProcessed`, `invalidate_cache`, log-processing helpers.
- Asset methods authorized via `mo:server`'s authorization list (seeded `[creator]`).
- Webhook authenticity rests entirely on the Stripe HMAC secret.
- Verifiability: deployed Wasm hash + frontend assets can be checked against the GitHub release.

---

## 2. Failure scenarios not accounted for

Ordered by severity. The code itself flags some (`Main.mo:399` has a literal TODO).

### A. Double-deposit / missing idempotency (operator fund loss)

No dedup anywhere. The code admits it:

```motoko
// Main.mo:399
// TODO:
// 1. Reject expired requests
// 2. Dedup non-expired requests
```

1. **Stripe at-least-once delivery.** Stripe may deliver the same event more than once; you must dedup on event ID. Here every valid webhook is appended to the log (`Main.mo:413`) and `process()` (`326`) blindly enqueues any `"paid"` entry → a duplicate delivery is a second deposit.
2. **Replay.** No expiry check (TODO #1), no event dedup (TODO #2). A captured signed body can be re-POSTed. The full `stripe-signature` header is logged on every request (`Main.mo:383`), so replay material lives in `view_logs`.
3. **Ambiguous inter-canister call.** If `ledger.deposit` / `mgmt.deposit_cycles` succeeds on the callee but the reply is lost/traps (`Main.mo:269/274`), the `catch` records `failed` (`288-292`) — cycles gone, but `pumpFailed()` re-deposits.
4. **`resetProcessed()` is a loaded gun** (`Main.mo:219`). Sets `processedCount := 0` → the next `processNextLogs()` re-enqueues *every historical paid webhook* → mass double-deposit.

### B. Payment taken, cycles never delivered (user fund loss)

- **`InsufficientCycles`** (`Main.mo:256-261`): user already paid; canister out of cycles; goes to `failed`; **no automated refund**.
- **Malformed body silently dropped.** `process()` `case _ {}` (`Main.mo:334`) discards unparseable webhooks — not even recorded in `failed`. `lookupSession` returns `404` forever and the SPA polls indefinitely. Paid, no cycles, no trace except the raw log.
- **Recipient deleted between validation and payment** → `mgmt.deposit_cycles` rejects → `failed`, manual refund.

### C. Liveness / deadlock

- **`pumping` flag survives upgrade as `true`.** `pumping` is a `stable var` (`Main.mo:237`). If the canister is upgraded mid-`pump()`, the flag stays `true`, `postupgrade` only prunes the cache (`607-609`), and there is **no `resetPumping` method** → the processor is permanently wedged (`240`).
- **Head-of-line blocking.** Both `InsufficientCycles` (`260`) and any transient `catch` (`292`) do `break LOOP`, halting the entire `pending` queue rather than skipping the one bad item.

### D. Unbounded growth

- The Region log only appends (`Main.mo:100`), never pruned. The `processed` queue is capped at 333 (`285`) but the log and the **`failed` queue have no cap** (`208`).

### E. Price / quote inconsistency

- No price lock per session. The user sees `cyclesPerUsd` at quote time (`index.js:254`); `pump()` uses `currentPrice()` at processing time (`Main.mo:255`). An operator `deposit()` in between shifts the delivered amount.

### F. Security / privacy

- **`processNextLogs()` is `public` with no caller check** (`Main.mo:351`). Anyone can invoke it. Limited impact (only logged webhooks are parsed), but an unintended external mutator.
- **Guessable session IDs leak info.** `sessionId = timestamp-<8-digit Math.random nonce>` (`index.js:31`). Guessing one lets anyone query `/status?sessionId=` and learn another user's recipient, amount, and cycles (`Main.mo:442-452`).

### G. Business-logic assumptions

- **Stripe fee modeled as flat $0.30** (`FEE_USD = 30`, `Main.mo:206`); the real fee is ~2.9% + 30¢.
- **Currency assumed USD cents.** `extractAmount` reads `amount_subtotal` (`Util.mo:144`) with no currency check.

**Recurring theme:** the system is *at-least-once at the Stripe boundary but
treats everything downstream as exactly-once.* The highest-leverage fix is an
idempotency key (dedup on the Stripe event ID or the `(timestamp, nonce)`
session), which closes most of section A. Second is a `resetPumping` path (or
resetting `pumping` in `postupgrade`) to remove the deadlock in C.

---

## 3. What happens if the user closes their browser?

**The user still gets their cycles** — delivery is driven entirely by the
Stripe→canister webhook, not by the browser. What's lost is the *ability to
track or confirm* the purchase.

- **The session lives only in the browser.** `sessionId` is a module-level JS var, regenerated each page load and **never persisted** (`index.js:27, 30`); only the dark-mode flag is in `localStorage`. The canister has no record of a session until the webhook arrives.
- **Closed before paying:** nothing happened server-side. Pure abandonment.
- **Closed with Stripe window open / payment in progress:** Stripe checkout is a separate window; payment can still complete → webhook fires → cycles deposited.
- **Closed after paying, before the receipt:** the webhook is server-to-server; the whole log-driven processor runs with zero browser involvement. Cycles arrive regardless.

**What's lost:** the confirmation is unrecoverable from the UI — on reopening,
`sessionId` is `null` and a fresh one is minted; the completed payment sits in
`processed` keyed by the *old* `(timestamp, nonce)`, and `lookupSession` only
finds it with that original id. No "look up my past purchase" flow, no email,
no account. The only persisted handle is whatever the user copied — which is why
the error UI says *"record your session id … and contact support"*
(`index.js:449-453`).

**The genuinely bad combination:** browser-close coinciding with a delivery
failure (silent drop at `Main.mo:334`, or `InsufficientCycles` at `256`). Then
cycles were not delivered, the payment went through, and the user has also lost
their only tracking key. Recovery requires the operator scanning `view_logs`.

---

## 4. How can a canister handle the POST from Stripe?

A canister has no TCP socket or listener. The bridge is the **IC HTTP gateway**
(boundary nodes) plus a standard canister interface.

1. **DNS + boundary node.** `cycle.express` resolves to IC boundary nodes. The boundary node maps the host to the canister via `/.well-known/ic-domains` (which contains `cycle.express`).
2. **HTTP → canister call.** The boundary node packages the raw request into a Candid `HttpRequest` (`{ method; url; headers; body }`) and calls the canister's standard methods (`Main.mo:589, 594`):
   ```motoko
   public query func http_request(req : HttpRequest) : async HttpResponse { ... };
   public func http_request_update(req : HttpRequest) : async HttpResponse { ... };
   ```
3. **Query first, then "upgrade" to an update.** The gateway tries `http_request` (a query) first — cheap, no consensus, but **cannot durably change state**. The webhook needs to mutate state (log, process), so the handler returns `upgrade = ?true` (`Main.mo:421-426`). The gateway then re-issues the identical request to `http_request_update` (a real update through consensus), where `add_log(...)` and `processNextLogs()` actually persist.
4. **`mo:server` routes.** `http_request`/`http_request_update` hand off to the embedded `mo:server`; route registrations like `server.post("/checkout", ...)` (`Main.mo:431`) map method+path to the handler — Express-style, but fed by the gateway's Candid record instead of a socket.

The punchline: **the canister never "listens" for Stripe.** The boundary node
accepts the HTTPS POST and converts it into an `http_request_update` call that
consensus executes. The `upgrade = ?true` flag is what lets a read-only query
path escalate into a state-changing update.

---

## 5. Comparison with CyclePay

`/Users/raymond/dev/dfinity/cyclepay` solves the same problem (fiat/crypto → IC
cycles) but sits at the opposite end of the architecture spectrum.

| | **cycle-express** | **cyclepay** |
|---|---|---|
| Philosophy | Radical on-chain minimalism | Production hybrid (off-chain orchestrator + on-chain trust anchor) |
| What runs it | **One** Motoko canister does everything | Node/Hono server + Postgres + Rust canister + Astro asset canister + budget canister |
| Size | ~1,600 lines backend, 3 files | `lib.rs` 2,217 lines; ~60 server files; ~40 test files; RUNBOOK |
| Payment rails | Stripe card only | Stripe card, USDC on Base (x402), ck-USDC on ICP (ICRC-2) |
| Identity | None — anonymous, ephemeral session id | Internet Identity, teams/projects, delegation chains, GitHub OIDC, agent API |
| Cycle sourcing | Operator pre-buys cycles; canister sells from its **own balance** at a margin | Canister holds **ICP**, mints on demand via **CMC** at protocol rate; zero markup |
| Webhook target | Stripe → IC gateway → **canister directly** | Stripe → **Railway Node server** → canister |
| Correctness | Best-effort, manual support | Idempotency at 3 layers + journaling + recovery + auto-refund + reconcilers |

### Core divergence: where the logic lives

- **cycle-express** is the purest "everything on-chain" — one canister is the website, HTTP server, Stripe webhook endpoint, transaction processor, and cycle inventory. Stripe POSTs *directly* to the canister via the gateway. Anyone can verify the Wasm hash.
- **cyclepay** is a deliberate **hybrid**. The Node server + Postgres holds all business/payment orchestration; the Rust canister is small in scope — only the trust-critical, irreversible ICP→cycles step via the CMC, done with paranoid care. Stripe's webhook hits the Node server (HMAC-verified by the Stripe SDK, `webhooks.ts:163`), which then calls the canister's `fulfill_order` as an authorized principal.

### How cycles are sourced

- **cycle-express** holds a literal **cycle inventory** — `pump()` does `Cycles.add()` from the canister's own balance (`Main.mo:268`). Can run dry (`InsufficientCycles`).
- **cyclepay** holds **ICP** and mints per-order through the **CMC**: `derive_icp_e8s_from_usd_cents` (`lib.rs:1466`) computes the ICP at protocol XDR rate, transfers ICP to the CMC with a `TPUP`/`MINT` memo, then `notify_top_up` / `notify_mint_cycles`. Zero markup, no inventory to deplete. The canister **ignores the server-supplied rate** (`lib.rs:704`) — the off-chain server is not trusted as price oracle.

### cyclepay is, almost line-for-line, "cycle-express with every failure fixed"

| cycle-express gap | cyclepay's answer |
|---|---|
| No idempotency / replay / Stripe duplicate | Three layers: event id (`webhooks.ts:183`), payment-intent in Postgres (`:208`), `PROCESSED_INTENTS` in canister (`lib.rs:733`) |
| Ambiguous inter-canister call | Journaling state machine (`Pending→IcpTransferred→CyclesDelivered`), idempotent on `block_index` (`lib.rs:947`) |
| Payment taken, cycles not delivered | Automatic refund, write-before-call (`order-fulfillment.ts:203`), refund reconcilers |
| `pumping` deadlocks across upgrade | `RECOVERY_IN_PROGRESS` guard + timer-based recovery re-armed in `post_upgrade` (`lib.rs:580`) |
| Silent drop of malformed payloads | Durable order rows; "order not yet visible" → 503 so Stripe redelivers (`webhooks.ts:220-229`) |
| Unbounded log growth | Scheduled idempotency-table cleanup (`index.ts:545`); bounded journal, not append-only log |
| Price not locked / quote drift | On-chain rate derivation; `RATE_STALE` long-backoff then auto-refund (`order-fulfillment.ts:60-88`) |
| Guessable session-id disclosure | Real auth (II principals, delegation verification), per-principal authorization |
| Stripe fee modeled as flat $0.30 | Actual 2.9% + $0.30 netting (`order-fulfillment.ts:18`) |
| No amount verification | Amount-mismatch check on every webhook branch (`webhooks.ts:243, 326, 610`) |

It also adds chargeback/dispute handling, async (bank-transfer) payment states,
subscription auto-refill with monthly caps, GitHub OIDC trust policies, treasury
rebalancing, and reconcilers as belt-and-suspenders.

### Trade-offs

- **cycle-express wins on:** verifiability & trust minimization (one auditable Wasm, no off-chain server/DB/wallet), operational simplicity, pedagogical clarity.
- **cyclepay wins on:** correctness under failure, capability (3 rails, identity, subscriptions, CI/agent), scalability (mint-on-demand vs. cycle inventory) — at the cost of re-introducing centralized trust (Railway server, Postgres, ICP hot wallet). The Rust canister is the minimal on-chain trust anchor that keeps the off-chain pieces "dumb."

**Summary:** cycle-express asks *"how much can we do with only a canister?"*;
cyclepay asks *"what's the minimum that must be on-chain so the rest can be
safely off-chain?"*

---

## 6. Options for a fully on-chain architecture

### The fiat asterisk

Stripe is irreducibly off-chain and centralized — you can't put Visa settlement
on a blockchain. For the **card rail**, "fully on-chain" can only mean *"the
canister is the only thing the operator runs"* — not *"no trusted third party."*
The **crypto rails (ck-USDC, USDC-on-Base) can be made genuinely trust-minimized
end to end.**

### The key insight from cycle-express

cycle-express is already fully on-chain — and it pulls this off by doing **only
inbound** Stripe communication. The payment page is a *static Stripe Payment
Link* (`index.js:40`); the canister never calls Stripe's API. That single choice
is what makes one canister possible — and also why it **can't refund, create
dynamic sessions, or do off-session charges** (all require *outbound* calls). So
the real question is: *can a canister make the outbound calls cyclepay needs?*

### Component → on-chain primitive

| cyclepay off-chain piece | On-chain replacement | Feasibility |
|---|---|---|
| Node orchestration server | Canister HTTP server | ✅ Proven (cycle-express) |
| Postgres | `StableBTreeMap` / stable memory | ✅ Proven (cyclepay canister) |
| Inbound Stripe webhook | Canister HTTP endpoint + on-chain HMAC | ✅ Proven |
| **Outbound Stripe** (session/refund/charge) | **HTTPS outcalls** + Stripe idempotency keys + `transform` fn | ⚠️ Feasible, caveats |
| Stripe secret storage | **vetKeys (vetKD)** for on-chain secrets | ⚠️ Emerging |
| USDC-on-Base hot wallet | **Threshold ECDSA (chain-key)** + **EVM RPC canister** | ✅ More decentralizable than today |
| ck-USDC pull (ICRC-2) | Canister calls `icrc2_transfer_from` directly | ✅ Already on-chain |
| ICP → cycles (CMC) | Already on-chain | ✅ |
| Treasury rebalance (DEX) | On-chain DEX canister calls | ✅ |
| Background workers | **Canister timers** (`ic_cdk_timers`) | ✅ Proven |
| II / delegation auth | Client crypto + in-canister verification | ✅ |
| GitHub OIDC verify | HTTPS outcall for JWKS + in-canister JWT verify | ⚠️ Feasible |

The crypto rails can be made fully on-chain *and more trustless than today*
(threshold ECDSA custodies Base USDC — no operator key; ck-USDC is already pure
ICRC-2). Ironically the "advanced" rails are the easiest to decentralize.

### Genuinely hard edges

1. **Secret management** is the sharpest blocker for the card rail. Outbound Stripe needs `sk_live` in canister state, which node providers can read. **vetKeys** is the intended fix; it's newer.
2. **HTTPS outcalls for outbound POSTs** have three corners: replication multiplication (every replica calls → use Stripe **idempotency keys**), determinism (need a `transform` fn), and reachability/cost (IPv6 requirement, response-size limits, per-call cycles).
3. **Re-implementing Stripe flows** over raw HTTP instead of using the SDK = more code, more audit surface.
4. **Regulatory** — even fully on-chain, the operator has PCI/KYC obligations for fiat.

### The emerging sweet spot

Keep the *crypto* rails fully on-chain and trustless (threshold ECDSA + ck-USDC,
no hot wallet), and accept a thin off-chain shim *only* for the Stripe card rail
where the fiat trust root lives anyway.

---

## 7. Does the credit card hit your servers?

**No.** With Stripe Checkout, Payment Links, or embedded Elements, the card PAN
goes **browser → Stripe**, never through your backend:

1. You create a Checkout Session (server→Stripe call, no card) — or use a static Payment Link.
2. Customer enters the card on Stripe's domain (or Stripe-hosted iframes). Card data goes straight to Stripe.
3. Stripe charges, redirects to your `success_url`, and sends a server-to-server **webhook**.
4. Your endpoint verifies the signature and fulfills.

Because the card is offloaded to Stripe, you're in minimal PCI scope (SAQ A).
**No cardholder data is ever on your server — or on-chain.**

### Refining the "on-chain secret" concern

The risk was never card data — it's the **Stripe bearer credential** in
node-provider-readable canister state. *Which* secret depends on direction:

- **cycle-express (inbound-only):** holds only the **webhook signing secret** (`prodKey`/`testKey`). If a node provider reads it, they could **forge "paid" webhooks → mint free cycles** — bad, but bounded to this service; the Stripe account is untouched.
- **cyclepay (outbound):** holds the full **secret API key** (`STRIPE_SECRET_KEY`). Leak = full account compromise (charge saved cards, refund to self, read PII). That's the one you really don't want in readable canister memory — a key reason cyclepay keeps Stripe off-chain.

**Net:** the cleanest fully-on-chain card design receives webhooks on-chain but
*avoids holding `sk_live`* — by using static Payment Links and forgoing
programmatic refunds — or protects the secret with vetKeys before trusting it to
canister memory.

---

## 8. What about an SEV-SNP (confidential computing) subnet?

AMD SEV-SNP encrypts a VM's memory with keys in the CPU's secure processor,
inaccessible to the host, plus integrity protection and attestation. On the IC
this targets exactly our threat: today a node provider with host access can
inspect a replica's RAM and read canister state. A confidential subnet would
encrypt that memory at the hardware level — arguably **the enabling technology
for a fully on-chain card rail**, making it defensible to hold `sk_live` in
canister state and do outbound Stripe from the canister.

### Caveats — "raises the bar a lot," not "solved"

1. **Replication** — the secret is plaintext inside *every* replica's enclave. Security now rests on SEV-SNP being unbroken *and* every node running attested SEV-SNP.
2. **Memory encryption ≠ state-at-rest encryption.** SEV-SNP protects RAM; canister state is also **checkpointed to disk** and **state-synced** to other nodes. Confirm those are covered, or a secret in stable memory can leak through the checkpoint path. *(Check this hardest.)*
3. **Secret injection** — setting the key via an update call means the argument transits the boundary node and is processed by nodes; you need a confidential, attestation-tied provisioning channel.
4. **Trust shifts to AMD + attestation**, and SEV-SNP has a published-CVE history (cache/fault-injection/voltage-glitch attacks). Hardware confidentiality, not a math guarantee.
5. **Maturity** — Gen-2 IC nodes have SEV-SNP-capable hardware and confidential replicas are the IC's direction, but verify current production status (which subnets; whether checkpoints/state-sync are covered) before betting a live key on it.

### SEV-SNP vs vetKeys (complementary)

| | **SEV-SNP (hardware)** | **vetKeys (cryptographic)** |
|---|---|---|
| Mechanism | Encrypts replica RAM; host can't read | Secret encrypted; only the canister can derive the key |
| Code change | None — transparent | You design encrypt-at-rest + derive-on-use |
| Covers state-at-rest? | Only if disk/state-sync also confidential | Yes — ciphertext safe in stable memory *and* checkpoints |
| Trust root | AMD CPU + attestation; hardware side-channels | Threshold crypto + subnet not colluding above threshold |
| Granularity | Subnet-wide, all-or-nothing | Per-secret, any subnet |

vetKeys protects the secret *at rest and during provisioning*; SEV-SNP protects
the *whole runtime* transparently but leans on hardware. Strongest posture: both.

### Net effect

- **Without confidential computing:** keep `sk_live` outbound off-chain, or go inbound-only (only a webhook signing secret on-chain), or use vetKeys for the at-rest secret.
- **With an attested SEV-SNP subnet you trust (and confirmed checkpoint/state-sync confidentiality):** holding `sk_live` in the canister becomes defensible — the missing piece for a genuinely fully on-chain card rail.

It still doesn't remove the irreducible bits: Stripe/Visa remain the off-chain
fiat trust root, and you still need HTTPS outcalls (idempotency keys + transform
+ IPv6/cost) for outbound calls. SEV-SNP solves the *confidentiality* of the
credential, not the *existence* of the off-chain dependency.
