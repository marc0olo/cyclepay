# The Stripe (Card) rail, end to end

How fiat becomes cycles. Written from the code — every claim here has a
`file:line` anchor you can check. The *why* behind the design decisions lives in
`design-docs/ONCHAIN_GATEWAY_SPEC.md` (spec v2.1); this document is the *what*.

- [1. The one-sentence version](#1-the-one-sentence-version)
- [2. Why the canister never calls Stripe](#2-why-the-canister-never-calls-stripe)
- [3. The full happy path](#3-the-full-happy-path)
- [4. Ingress: two paths, and why the webhook can't be caller-authenticated](#4-ingress-two-paths-and-why-the-webhook-cant-be-caller-authenticated)
- [5. Signature verification](#5-signature-verification)
- [6. Attribution: claimed, not trusted](#6-attribution-claimed-not-trusted)
- [7. Dedup: two layers, and what they do not protect against](#7-dedup-two-layers-and-what-they-do-not-protect-against)
- [8. Amount honouring](#8-amount-honouring)
- [9. Admission: the pre-creation gate](#9-admission-the-pre-creation-gate)
- [10. Order lifecycle and retention](#10-order-lifecycle-and-retention)
- [11. Refunds, disputes, and what is not automated](#11-refunds-disputes-and-what-is-not-automated)
- [12. Every failure and its money position](#12-every-failure-and-its-money-position)
- [13. The secret](#13-the-secret)
- [14. Operator surface](#14-operator-surface)
- [15. Local development against a Stripe sandbox](#15-local-development-against-a-stripe-sandbox)

---

## 1. The one-sentence version

A user picks a fixed-price tier, is sent to a permanent Stripe Payment Link
carrying `client_reference_id = <principal>_<orderId>`, pays Stripe directly, and
Stripe POSTs a signed `checkout.session.completed` webhook to the canister, which
verifies the HMAC on-chain, attributes the payment to the order, and mints the
cycle quantity that was locked at order creation.

## 2. Why the canister never calls Stripe

There is **no Stripe API key anywhere in the system.** No `sk_live`, no HTTP
client for Stripe, no outbound request to Stripe at all. The rail is
**inbound-only**: Stripe talks to us, never the reverse.

This is the decision the rest of the design hangs off:

| Consequence | Detail |
|---|---|
| Nothing to steal | A full compromise of canister state yields no Stripe credential. The only secret is the webhook *signing* secret, which can forge inbound webhooks but cannot touch the Stripe account, customers, or payouts (§13). |
| Refunds are manual | The canister structurally cannot issue a refund. Every refund is a human action in the Stripe Dashboard (§11). |
| No subscriptions or auto-refill | Both require charging a stored payment method, i.e. an outbound API key. Explicitly out of scope. |
| Payment amounts are pinned by URL | The canister cannot create prices, so tiers are permanent Payment Links the operator makes in the Dashboard and registers on-chain. |

The only outbound HTTPS the canister makes at all is the USD↔XDR forex fetch
(`Forex.mo`), and that is a keyless public endpoint.

## 3. The full happy path

```
                        ┌─────────────────────── off-chain ────────────────────────┐
 operator (Dashboard) ──┤ create one permanent Payment Link per price point        │
                        └──────────────────────────┬───────────────────────────────┘
                                                   │ set_card_tiers (admin, on-chain)
                                                   ▼
 user ──II login──▶ create_order(tierId, destination)         Main.mo:339
                       │  admission gate                       Main.mo:278 → Gate.mo
                       │  quote: lock the CYCLE QUANTITY       Forex.mo
                       │  raw_rand order id                    Orders.mo:30
                       ▼
                    #created  +  clientReferenceId = <principal>_<orderId>
                       │
 frontend ─────────────┤ opens  <paymentLinkUrl>?client_reference_id=<ref>
                       ▼
 user pays Stripe (card data never touches the canister)
                       │
 Stripe ───────────────┤ POST /webhook/stripe   (anonymous principal)
                       ▼
                    http_request  → upgrade = ?true            Main.mo:1395
                    http_request_update → route table          Main.mo:1402, 1377
                       ▼
                    Card.handleWebhook                          Card.mo:417
                       │ 1. secret provisioned?      → else 503 (Stripe retries)
                       │ 2. HMAC verify + ±300 s     → else 400
                       │ 3. parse event (tree parse) → else 400
                       │ 4. dedup on event.id        → else 200 "duplicate event"
                       │ 5. dedup on payment_intent  → else 200 "duplicate payment intent"
                       │ 6. attribute the reference  → else Type 1 #unattributed
                       │ 7. ceiling + amount honour  → else Type 1
                       ▼
                    markPaid → #paid, paidIntents[intent] = orderId
                       │
                       │ detached self-message kicks money-out
                       ▼
   #paid ─ burn cap + float pre-gate ─▶ #minting ─▶ #icpAtCmc ─▶ #delivered
              └─ no headroom ─▶ #awaitingTreasury ─(refill)─┘
                                     └─ past max wait ─▶ #errorQueue
```

Money-out is rail-agnostic from `#paid` onward and is shared with the ck-USDC
rail; it is out of scope for this document beyond the diagram.

## 4. Ingress: two paths, and why the webhook can't be caller-authenticated

HTTP requests reach a canister through the IC HTTP gateway, which packages them
into a Candid `HttpRequest`. **They arrive as the anonymous principal** — the
gateway does not and cannot propagate Internet Identity. So an HTTP route can
only ever be authenticated by its *payload*, never by `caller`.

That forces exactly two ingress paths:

| Path | Auth | What uses it |
|---|---|---|
| **Candid calls** | `caller` is the real II principal | The whole app API: `create_order`, `get_order`, `list_orders`, every admin method |
| **One HTTP route** | HMAC over the payload | `POST /webhook/stripe` only |

`Http.mo` dispatches off a route *table* with a per-route `upgrade` flag
(`Main.mo:1377`). The query half returns `upgrade = ?true` **without running the
handler** — the gateway discards that response and re-issues the request to
`http_request_update` through consensus, so response certification is moot.

Two details that matter:

- `http_request_update` is **callable directly via Candid by anyone**, so the
  dispatcher re-applies every guard rather than trusting that the query half ran
  first (`Main.mo:1402`).
- `Http.pathOf` strips the query string before matching (`Http.mo:53`), so a
  gateway URL carrying `?canisterId=…` still routes — which is what makes §15's
  local setup work.

Guards on the route, all asserted in `test/integration/src/gateway.spec.ts`
scenario 05: unknown path → 404, wrong method → 405 with a lowercase `allow`
header, body over 64 KiB → 413 (checked *before* the upgrade decision, so
oversized payloads never pay for consensus).

## 5. Signature verification

`Card.verify` (`Card.mo:101`) implements Stripe's scheme exactly:

1. **Parse `Stripe-Signature`** (`Card.mo:69`) — comma-separated `key=value`
   elements, e.g. `t=1492774577,v1=5257a8…,v0=6ffbb5…`. Per Stripe's reference
   parsers: only the first `t=` counts, unknown schemes (`v0=`) are ignored, and
   unparseable elements are skipped. **Multiple `v1=` values are collected** —
   Stripe sends one per active secret during a rotation overlap, and any single
   match verifies. That is what makes rotation zero-downtime with only one
   secret stored.
2. **Timestamp window** — `|now − t| > 300 s` → reject (`Card.mo:43` for the
   tolerance). `t` is signed into the payload, so it cannot be forged to defeat
   this. Stripe re-signs on every retry with a fresh `t`, so retries are never
   rejected by the window.
3. **MAC** over `"<t>." ++ raw_body` (`Card.mo:95`). The body must be the
   **exact bytes received** — re-serialised JSON will not verify.
4. **Constant-time compare** (`Hmac.mo:34`) — accumulates XOR across all bytes
   instead of returning at the first difference. A short-circuiting compare
   would be a timing oracle that leaks the expected MAC byte by byte and lets an
   attacker forge "paid" webhooks *without* the secret.

Header names are matched case-insensitively (`Http.mo:63`) because proxies
re-case them.

Only after verification is the body parsed, and it is parsed as a **tree**
(`Json.mo`), never scanned for substrings (`Card.mo:159`) — the JSON is authentic
Stripe output, but string values inside it still carry user-influenced content.

The canister subscribes to exactly two event types. Anything else is
acknowledged 200 and dropped, so an extra subscription in the Dashboard does not
look like a delivery failure.

## 6. Attribution: claimed, not trusted

`client_reference_id` is a **URL parameter the user can edit.** A permanent
Payment Link is always live, so anyone can pay it with any reference they like.
Every dollar that arrives must therefore resolve to one of: delivery, Type 1, or
Type 2 — never to a silent accept.

`handleCheckout` (`Card.mo:314`) re-derives and checks everything:

| Check | Failure |
|---|---|
| reference present | Type 1 `#unattributed` — "missing client_reference_id" |
| parses as `<principal>_<orderId>` | Type 1 — "malformed" |
| order exists | Type 1 — "no order X", or **"was SWEPT as abandoned"** if the id is tombstoned (§10) |
| claimed principal **matches the stored owner** | Type 1 — "claimed owner does not match" |
| order's rail is `#card` | Type 1 — "is not a card order" |
| status is `#created` or `#expired` | Type 1 `#duplicate` otherwise |
| currency is `usd` | Type 1 — "unexpected currency" |
| amount within the ceiling | Type 1 — "exceeds the per-purchase ceiling" |

Note the owner check: the reference *claims* a principal, and it must equal the
order's actual owner. `Orders.parseClientReferenceId` compares principal text
rather than calling `Principal.fromText`, because that traps on garbage and a
trapped webhook is a 5xx that Stripe would retry forever (`Orders.mo:52`).

Type 1 entries are always answered **HTTP 200**. The payment *is* handled — by
the operator's refund queue rather than by delivery — and a non-2xx would make
Stripe redeliver an event that has already been routed (`Card.mo:241`).

The stored `claimedRef` is length-capped at 128 bytes
(`ErrorQueue.maxClaimedRefBytes`) so an attacker cannot stuff arbitrary data
into admin-visible stable state one webhook at a time.

## 7. Dedup: two layers, and what they do not protect against

In order (`Card.mo:314`):

1. **`event.id`** — catches Stripe *redelivering one event*. Stripe's delivery is
   at-least-once and it retries for ~3 days.
2. **`payment_intent`** — one mint per payment, even across distinct event
   deliveries that reference the same intent.

Both live in `Idempotency.mo` and are pruned after ~7 days on the webhook path
(Stripe stops retrying well before that).

**Stripe dedup is not double-pay protection.** A user who genuinely pays twice
produces two distinct `event.id`s *and* two distinct `payment_intent`s — two real
payments. The second one passes both dedup layers, finds the order already past
`#created`, and becomes Type 1 `#duplicate`: fiat exists, nothing extra was
minted, operator refunds. This is the single most important thing to understand
about the rail, and it is why **dedup gates the mint** rather than gating the
webhook.

## 8. Amount honouring

The order stores a **pricing snapshot** at creation (`Types.Pricing`): the gross
cents, the XDR/USD rate in micros, and the fee formula. The webhook honours the
**actual paid amount** (`Card.mo:314`):

- Paid amount **equals** the quoted tier → deliver `lockedCycles` verbatim.
- Paid amount **differs** → reprice from the order's own snapshot, never from a
  fresh rate. So "no quote drift" holds even off the happy path.
- Paid amount **below the fee floor** → Type 1 (the fee formula would swallow it).
- Paid amount **above the per-purchase ceiling** → Type 1, not minted.

That last case exists because repricing is an *upward* path: without a ceiling, a
tampered link or a misconfigured Stripe price would mint an arbitrary quantity.

## 9. Admission: the pre-creation gate

`create_order` refuses before quoting when fulfilment is already impossible
(`Main.mo:278` → `Gate.mo`). Checked cheapest-first, and **before** the forex
quote so a spamming principal cannot make the canister spend cycles on outcalls:

| Check | Refusal | Meaning |
|---|---|---|
| amount ≤ `maxPurchaseUsdCents` | `#amountAboveMax` | permanent — the user must change the amount |
| open `#created` orders < `maxOpenOrdersPerPrincipal` | `#tooManyOpenOrders` | the caller must finish or abandon one |
| `Cycles.balance()` ≥ `minCanisterCycles` | `#canisterCyclesLow` | the canister's own gas is low |
| burn window has headroom | `#burnCapExhausted` | minting is paused for this window |
| observed float ≥ `lowFloatThresholdE8s` | `#floatLow` | operator must refill |

Two things worth being precise about:

- **The two "cycles" are different resources.** `minCanisterCycles` is *this
  canister's own gas* — if it runs out the canister freezes and then is
  uninstalled. The ICP float is what buys cycles *for customers*. They have
  different failure modes and different fixes.
- **Float gating is opt-in.** `lowFloatThresholdE8s = 0` disables it. Once a
  threshold is set, a *missing* observation also fails the check — "enforce this"
  plus "I have never looked" is not a state to sell into. Call `refresh_float`
  after funding.
- **The burn cap defaults to 0**, which means the card rail cannot sell anything
  until the operator sizes it. That is deliberate: cap 0 means "no minting", and
  quoting into it would only ever produce a hold and then a manual refund.

`Treasury.gate` at mint time remains the authoritative money check. The
admission gate is about refusing *before* the user pays, not about replacing it.

`can_purchase(usdCents)` is a public query that returns the same decision, so the
frontend can disable the button with a real reason instead of failing at submit.

## 10. Order lifecycle and retention

`Retention.mo` defines three bands, keyed on age from **creation**:

| Band | Status | Age | Payable? | Record |
|---|---|---|---|---|
| 1 — live | `#created` | < `orderTtlNs` (default 48 h) | yes | intact |
| 2 — expired | `#expired` | TTL → `retentionHorizonNs` (default 90 d) | **yes** | intact |
| 3 — swept | deleted | > horizon | becomes Type 1 | id tombstoned |

**Expiry is advisory.** An `#expired` order is still fully payable and a late
genuine payment is honoured at the locked quantity (`Card.mo:314` accepts
`#created or #expired`; `Orders.mo` allows `#expired → #paid`). The flip exists
to make state legible and to define what eventually becomes sweepable.

**Band 3 and the "we lost track" worry.** A Payment Link is permanent, so a
payment can arrive for an order abandoned months ago from a bookmarked URL.
Deleting the record cannot lose money: the payment resolves to no order and
becomes Type 1 `#unattributed`, acked 200, sitting in the error queue with its
`payment_intent` for the operator to refund — which `charge.refunded` then
auto-resolves. It degrades to **a refund, not a loss.**

The `sweptOrders` tombstone set makes that diagnosis certain rather than
ambiguous: 32 bytes per id turns "no such order" (indistinguishable from a forged
parameter) into "we deliberately deleted this one". `was_swept(id)` is a public
query so a user can see why their order vanished from history.

**The binding rule on deletion** (`Main.mo:958`): only orders that are
`#expired`, have **no mint journal entry**, and have **no ck-USDC pull entry**
are ever removed. `#delivered` and `#errorQueue` are financial records kept
forever — their volume is bounded by real sales, which the burn cap bounds, so
they can never be a growth vector.

**Sweeping is cleanup, not protection.** The bound that actually stops unbounded
state growth is `maxOpenOrdersPerPrincipal`, because abandoned orders are the
only thing an attacker can create for free.

The sweep runs inside the existing recovery timer (hourly by default),
synchronously and before the money sweep so it cannot interleave with an await.
`run_retention()` is the admin lever to apply retuned bands immediately.

## 11. Refunds, disputes, and what is not automated

**Refunds are always manual, in the Stripe Dashboard.** No `sk_live` means the
canister cannot issue one. What the canister does is *react* to
`charge.refunded` (`Card.mo:257`):

1. Resolve every unresolved **Type 1** entry carrying that `payment_intent`. This
   closes the normal loop: duplicate/unattributed payment → operator refunds →
   entry auto-resolves.
2. If nothing resolved, look the intent up in `paidIntents` (the
   `payment_intent → orderId` index, written at `markPaid`):
   - **order is `#delivered`** → queue `#refundAfterDelivery` and audit
     `stripe.refundAfterDelivery`. Fiat went back to the payer and the cycles are
     irreversibly gone. This is a **recorded loss**, not a recovery flow.
   - **order is paid but not yet delivered** → audit
     `stripe.refundBeforeDelivery`. Money-out may still be mid-flight, so this is
     a race for the operator to inspect.
   - **intent unknown** → audit `stripe.refundUnmatched`. Benign: operators may
     refund payments that never queued.

`#refundAfterDelivery` deliberately does **not** expose a `paymentRef` to
`resolveByPaymentRef` (`ErrorQueue.paymentRefOf`), because the refund is what
created the entry — auto-resolving on it would close the loss the instant it was
recorded. Only a human closes that one.

### Disputes and chargebacks are not handled on-chain

`charge.dispute.created` is **not subscribed**, by decision. The canister cannot
claw back cycles already forwarded to an arbitrary destination, so no amount of
on-chain plumbing changes the outcome. Chargeback risk is managed where it can
be: **Stripe Radar rules and 3DS** on the Stripe side, and the **per-purchase
ceiling** plus the **burn cap** on ours.

Note that the burn cap does *not* bound chargeback losses — the payments are
real and individually legitimate. Sizing the per-purchase ceiling is the lever
that limits exposure per fraudulent transaction.

## 12. Every failure and its money position

`RUNBOOK.md` §8 is the operator triage table. This is the rail-specific summary:

| Outcome | HTTP | Money position | Resolution |
|---|---|---|---|
| Secret not provisioned | 503 | nothing happened | provision; Stripe retries |
| Missing/bad signature, stale `t` | 400 | nothing happened | none — not from Stripe |
| Unparseable body | 400 | nothing happened | visible in the Dashboard's delivery log |
| Unhandled event type | 200 | nothing happened | none |
| Redelivered `event.id` / `payment_intent` | 200 | already handled | none |
| `payment_status ≠ paid` | 200 | no money yet | audited `stripe.unpaidSession`; check the link is card-only |
| Type 1 `#unattributed` | 200 | **fiat in, nothing minted** | refund in Dashboard |
| Type 1 `#duplicate` | 200 | **fiat in ×2, minted ×1** | refund the second charge |
| Type 2 `#undeliverable` | 200 | **cycles minted, in the app's own balance** | re-deliver or refund |
| `#stuckMint` | 200 | **uncertain** — see the stage | per-stage rules in RUNBOOK §8 |
| `#refundAfterDelivery` | 200 | **fiat out, cycles out** — a loss | reconcile; consider restricting the payer |

## 13. The secret

The Stripe **webhook signing secret** (`whsec_…`) is the only secret in the
system. It is stored **plaintext in canister state, by design** (`Secret.mo`).

HMAC is symmetric, so *verify = forge*: anything that can check a signature can
mint one. Encrypting the stored blob would only move the problem to a key the
canister also needs at verify time, so it buys nothing.

What actually protects it:

| Layer | Status |
|---|---|
| **SEV-SNP confidential subnet** | The deployment target. Confidentiality rests on hardware and attestation, not on cryptography in the canister. |
| **Checkpoint / state-sync confidentiality** | **Must be verified separately.** Memory encryption does not cover state written to disk and state-synced between nodes. If those are not also confidential, a plaintext secret leaks through that path. |
| **Provisioning channel** | Known-exposed: `set_webhook_secret`'s argument transits the TLS-terminating boundary node as ordinary ingress. Treat the first set over any untrusted path as burned and rotate. |
| **ICP burn cap** | The always-on backstop, independent of SEV. Bounds how much a forger can drain per window. |

Interface (`Main.mo:63`):

- `set_webhook_secret(text)` — controller-only, traps otherwise. Rejects under
  16 bytes and leaves a working secret untouched on rejection, so a
  fat-fingered rotation cannot brick the webhook. Pass the **whole `whsec_…`
  string**, prefix included — that is the HMAC key.
- `webhook_secret_status()` — `{isSet, generation, setAtNs}`. **There is no
  read-back path, not even for controllers.** `generation` increments per
  successful set, which is how ops confirms a rotation landed.

If the secret leaks, an attacker can forge "paid" webhooks and mint cycles at
operator expense — bounded by the burn cap, detectable by reconciling against
Stripe's event log (forged payments have no matching `payment_intent` there), and
recoverable by rotation. The Stripe account, customers, and cardholder data are
untouched, because there is no API key to steal. See `RUNBOOK.md` §2 for the
leak procedure — **cap to 0 first**, then rotate.

> This is a deliberate departure from `canister-security` pitfall 9 ("never store
> secrets in canister state"). The reasoning above is the justification; do not
> "fix" it without reading it.

## 14. Operator surface

Card-rail levers, all controller-gated (`Auth.mo`, flat allowlist, equal
privileges — any controller can do any of this):

| Method | Purpose |
|---|---|
| `set_webhook_secret` | provision / rotate (§13) |
| `webhook_secret_status` | confirm a rotation landed |
| `set_card_tiers` | register Payment Links; **empty vector disables the rail** |
| `set_gate_config` | open-order cap, own-cycles floor, per-purchase ceiling |
| `set_retention_config` | TTL and delete horizon |
| `set_forex_config` | fee formula, staleness window, rate source |
| `set_treasury_config` | burn cap, window, max hold, low-float threshold |
| `error_queue` / `resolve_error` | the operator worklist |
| `order_for_payment` | reconciliation: Stripe charge → order it funded |
| `mint_journal` | money-out record for one order |
| `audit_log` | operational trail; gaps in `seq` mean ring-buffer drops |
| `process_order` | manual mint kick; safe to spam |
| `run_retention` | apply retuned retention bands now |
| `refresh_float` | refresh the float observation the gate reads |
| `reset_burn_window` | clear window consumption after verifying traffic |

Public queries (transparency is the product thesis): `card_tiers`,
`forex_status`, `treasury_status`, `recovery_status`, `lifecycle_config`,
`retention_status`, `can_purchase`, `was_swept`, `health`.

### Stripe Dashboard setup

1. Create one **Payment Link** per price point, in USD, card-only.
2. Register them with `set_card_tiers`.
3. Create a webhook endpoint pointing at
   `https://<canister-id>.icp0.io/webhook/stripe`, subscribed to exactly
   **`checkout.session.completed`** and **`charge.refunded`**.
4. Copy the endpoint's signing secret into `set_webhook_secret`.
5. Size the burn cap (`set_treasury_config`) — until then the gate refuses every
   order.
6. `refresh_float` after funding, so the gate has an observation.

## 15. Local development against a Stripe sandbox

`scripts/stripe-dev.sh` automates this; the mechanics are below.

The precondition that makes it work: `Http.pathOf` strips the query string
(`Http.mo:53`), so the local gateway's `?canisterId=…` parameter does not break
route matching.

```sh
brew install stripe/stripe-cli/stripe   # once
stripe login                            # once, pick a SANDBOX account

icp network start -d
icp deploy
scripts/stripe-dev.sh                   # prints the forward URL + wires the secret
```

`stripe listen` prints a **signing secret for the forwarding session**
(`whsec_…`), which is what must go into `set_webhook_secret` — it is not the same
as the Dashboard endpoint's secret.

```sh
stripe listen --forward-to "http://127.0.0.1:<port>/webhook/stripe?canisterId=<backend-id>"
stripe trigger checkout.session.completed
```

This exercises the genuine path: real Stripe signatures, real event JSON, real
retry behaviour on non-2xx.

Two caveats:

- `stripe trigger` builds a *synthetic* session with **no
  `client_reference_id`**, so it lands as Type 1 `#unattributed` — which is
  itself a useful test. To exercise the happy path, create a real order, open
  the sandbox Payment Link with `?client_reference_id=<ref>` appended, and pay
  with test card `4242 4242 4242 4242`.
- The canister compares the signature timestamp against **its own clock**. A
  local replica whose time has drifted more than 300 s from real time will
  reject every live webhook with a 400.

For deterministic coverage without Stripe in the loop, the PocketIC suite crafts
its own HMAC-signed payloads (`test/integration/src/harness.ts`) — that is the
go-live bar, and it does not need network access or an account.
