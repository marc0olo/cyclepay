# The Stripe (Card) rail, end to end

How fiat becomes cycles. Written from the code — every claim names the module it
came from, so you can check it. (Module names, not line numbers: a stale line
number is worse than no line number, and they drift on every edit.) The *why* behind the design decisions lives in
`design-docs/ONCHAIN_GATEWAY_SPEC.md` (spec v2.1); this document is the *what*.

- [1. The one-sentence version](#1-the-one-sentence-version)
- [2. Why the canister never calls Stripe](#2-why-the-canister-never-calls-stripe)
- [3. The full happy path](#3-the-full-happy-path)
- [4. Ingress: two paths, and why the webhook can't be caller-authenticated](#4-ingress-two-paths-and-why-the-webhook-cant-be-caller-authenticated)
- [5. Signature verification](#5-signature-verification)
- [6. Attribution: claimed, not trusted](#6-attribution-claimed-not-trusted)
- [7. Dedup: two layers, and what they do not protect against](#7-dedup-two-layers-and-what-they-do-not-protect-against)
- [8. Amount honouring](#8-amount-honouring)
- [8a. What the buyer sees before paying](#8a-what-the-buyer-sees-before-paying)
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
| Payment amounts are pinned by URL | The canister cannot create prices, so tiers are permanent Payment Links the operator makes in the Dashboard and registers on-chain. The pin is only as good as the link's configuration — see RUNBOOK §3 for the four settings that break it. |

**The canister makes no outbound HTTPS at all.** Not to Stripe, and not to
anything else: pricing reads two on-chain canisters — the Exchange Rate Canister
for USD/ICP and the CMC for XDR/ICP (§8) — so every outbound call is an
inter-canister call. There is no `transform` function, no replica-divergence
problem, and no operator-settable rate source to audit.

## 3. The full happy path

```
                        ┌─────────────────────── off-chain ────────────────────────┐
 operator (Dashboard) ──┤ create one permanent Payment Link per price point        │
                        └──────────────────────────┬───────────────────────────────┘
                                                   │ set_card_tiers (admin, on-chain)
                                                   ▼
 user ──II login──▶ create_order(tierId, destination)         Main.mo
                       │  admission gate                       Main.mo → Gate.mo
                       │  quote: lock the CYCLE QUANTITY       Pricing.mo (cached XRC+CMC)
                       │  raw_rand order id                    Orders.mo
                       ▼
                    #created  +  clientReferenceId = <principal>_<orderId>
                       │
 frontend ─────────────┤ opens  <paymentLinkUrl>?client_reference_id=<ref>
                       ▼
 user pays Stripe (card data never touches the canister)
                       │
 Stripe ───────────────┤ POST /webhook/stripe   (anonymous principal)
                       ▼
                    http_request  → upgrade = ?true            Main.mo
                    http_request_update → route table          Main.mo
                       ▼
                    Card.handleWebhook                          Card.mo
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

Money-out is rail-agnostic from `#paid` onward — the code is keyed by
`Types.Rail`, which is a single-case variant today (#35).

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
(`Main.mo`). The query half returns `upgrade = ?true` **without running the
handler** — the gateway discards that response and re-issues the request to
`http_request_update` through consensus, so response certification is moot.

Two details that matter:

- `http_request_update` is **callable directly via Candid by anyone**, so the
  dispatcher re-applies every guard rather than trusting that the query half ran
  first (`Main.mo`).
- `Http.pathOf` strips the query string before matching (`Http.mo`), so a
  gateway URL carrying `?canisterId=…` still routes — which is what makes §15's
  local setup work.

Guards on the route, all asserted in `test/integration/src/gateway.spec.ts`
scenario 05: unknown path → 404, wrong method → 405 with a lowercase `allow`
header, body over 64 KiB → 413 (checked *before* the upgrade decision, so
oversized payloads never pay for consensus).

## 5. Signature verification

`Card.verify` (`Card.mo`) implements Stripe's scheme exactly:

1. **Parse `Stripe-Signature`** (`Card.mo`) — comma-separated `key=value`
   elements, e.g. `t=1492774577,v1=5257a8…,v0=6ffbb5…`. Per Stripe's reference
   parsers: only the first `t=` counts, unknown schemes (`v0=`) are ignored, and
   unparseable elements are skipped. **Multiple `v1=` values are collected** —
   Stripe sends one per active secret during a rotation overlap, and any single
   match verifies. That is what makes rotation zero-downtime with only one
   secret stored.
2. **Timestamp window** — `|now − t| > 300 s` → reject (`Card.mo` for the
   tolerance). `t` is signed into the payload, so it cannot be forged to defeat
   this. Stripe re-signs on every retry with a fresh `t`, so retries are never
   rejected by the window.
3. **MAC** over `"<t>." ++ raw_body` (`Card.mo`). The body must be the
   **exact bytes received** — re-serialised JSON will not verify.
4. **Constant-time compare** (`Hmac.mo`) — accumulates XOR across all bytes
   instead of returning at the first difference. A short-circuiting compare
   would be a timing oracle that leaks the expected MAC byte by byte and lets an
   attacker forge "paid" webhooks *without* the secret.

Header names are matched case-insensitively (`Http.mo`) because proxies
re-case them.

Only after verification is the body parsed, and it is parsed as a **tree**
(`Json.mo`), never scanned for substrings (`Card.mo`) — the JSON is authentic
Stripe output, but string values inside it still carry user-influenced content.

The canister subscribes to exactly two event types. Anything else is
acknowledged 200 and dropped, so an extra subscription in the Dashboard does not
look like a delivery failure.

## 6. Attribution: claimed, not trusted

`client_reference_id` is a **URL parameter the user can edit.** A permanent
Payment Link is always live, so anyone can pay it with any reference they like.
Every dollar that arrives must therefore resolve to one of: delivery, Type 1, or
Type 2 — never to a silent accept.

It is a **pointer, not a credential**, and that is what makes it safe to put in a
URL. The order id is 16 bytes of `raw_rand`, so a reference cannot be guessed; and
forging one gains nothing, because the claimed principal must equal the order's
stored owner, so the best an attacker achieves is paying for somebody else's order.

The value is appended **by the frontend, per order** — it is never configured
anywhere. The Stripe Dashboard's URL-parameter dialog can bake a static one into a
link, which would break attribution for every buyer; RUNBOOK §3 says to leave it
empty.

`handleCheckout` (`Card.mo`) re-derives and checks everything:

| Check | Failure |
|---|---|
| reference present | Type 1 `#unattributed` — "missing client_reference_id" |
| parses as `<principal>_<orderId>` | Type 1 — "malformed" |
| order exists | Type 1 — "no order X". Orders are never deleted (§10), so this means the reference never resolved: a forged, mistyped, or stripped URL parameter |
| claimed principal **matches the stored owner** | Type 1 — "claimed owner does not match" |
| order's rail is `#card` | Type 1 — "is not a card order" |
| status is `#created` or `#expired` | Type 1 `#duplicate` otherwise |
| currency is `usd` | Type 1 — "unexpected currency" |
| amount within the ceiling | Type 1 — "exceeds the per-purchase ceiling" |

Note the owner check: the reference *claims* a principal, and it must equal the
order's actual owner. `Orders.parseClientReferenceId` compares principal text
rather than calling `Principal.fromText`, because that traps on garbage and a
trapped webhook is a 5xx that Stripe would retry forever (`Orders.mo`).

Type 1 entries are always answered **HTTP 200**. The payment *is* handled — by
the operator's refund queue rather than by delivery — and a non-2xx would make
Stripe redeliver an event that has already been routed (`Card.mo`).

The stored `claimedRef` is length-capped at 128 bytes
(`ErrorQueue.maxClaimedRefBytes`) so an attacker cannot stuff arbitrary data
into admin-visible stable state one webhook at a time.

## 7. Dedup: two layers, and what they do not protect against

In order (`Card.mo`):

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
cents, **both rate inputs** (`usdPerIcpMicros` from the XRC, `xdrPermyriadPerIcp`
from the CMC) with the XRC quality signal, and the fee formula. The webhook
honours the **actual paid amount** (`Card.mo`):

- Paid amount **equals** the quoted tier → deliver `lockedCycles` verbatim.
- Paid amount **differs** → reprice from the order's own snapshot, never from a
  fresh rate. So "no quote drift" holds even off the happy path.
- Paid amount **below the fee floor** → Type 1 (the fee formula would swallow it).
- Paid amount **above the per-purchase ceiling** → Type 1, not minted.

That last case exists because repricing is an *upward* path: without a ceiling, a
tampered link or a misconfigured Stripe price would mint an arbitrary quantity.

**What was actually paid is stored on the order** (`paidUsdCents`), not only in
the audit log. The audit ring buffer drops its oldest entries, so a fact about
money cannot live only there — "what did this buyer pay?" has to be answerable
from state for the life of the canister.

The same honouring logic serves `attach_payment`, the admin lever that credits an
order for a payment the webhook could not attribute (§12). One code path, so a
rescued payment is priced exactly as a normal one would have been — from the
order's own snapshot, however long ago it was created.

## 8a. What the buyer sees before paying

Three guarantees, in the order they matter.

### The cycle quantity is shown before anything is committed

`quote_previews(rail, amounts)` is a **public query** returning, per amount, the
fee, the net, and the cycle quantity — plus the rate pair it used and the cycles
ledger's deposit fee. The tier grid is one round trip.

⚠️ **It calls the same `quoteCents` that `create_order` calls.** Not the same
formula reimplemented — the same function. A client computing its own estimate
would be one refactor away from displaying a number the gateway does not honour,
and the buyer would have no way to tell which side was wrong.

Being a query, it costs nothing and needs no login: you can see exactly what your
money buys before signing in. It takes no cap on the input array, deliberately —
work is constant per element the caller already had to transmit, so the only
thing a cap would buy is silent truncation.

### The rate is locked at creation, and the lock is enforced

`create_order(tierId, destination, minCycles)` takes an **optional minimum**.
If the current rate no longer clears it, the call returns
`#quoteChanged {quoted; minimum}` and **creates nothing** — no half-finished
order to clean up — carrying what the amount buys now so the client can show a
real figure rather than a bare failure.

⚠️ **Why this must be in the update and not the client.** A client-side re-check
is a *query*; the creation is an *update*. Two messages, so the rate can refresh
between them. Pinning the expectation inside the same call that locks the price
is the only way to close that window, and it makes the guarantee hold for every
caller rather than for one polite frontend.

⚠️ **A minimum, not an equality.** A move in the buyer's favour passes through
and they keep the extra cycles. The guard can only ever protect the buyer, never
the operator. Passing `null` opts out.

The **tolerance is the client's choice, not the backend's** — the backend enforces
exactly the minimum it is handed, so a script that needs an exact quantity can
pin one. The frontend's policy is **5%**: rates refresh on a timer, so an exact
match would bounce purchases over moves too small to care about, and every bounce
is a buyer wondering whether their card was charged. Inside tolerance the order
is created and the UI **states the actual locked figure**, including when it
drifted in the buyer's favour. Silence would be the surprise.

Once locked, nothing re-reads a rate: money-out uses the stored snapshot, so
market movement after creation changes nothing, however long the buyer takes to
pay (§10 — even a year).

### The cycles-ledger deposit fee is disclosed, not absorbed

A `#cyclesLedgerAccount` destination loses **100 M cycles** to the ledger's
deposit fee; a `#canister` top-up loses nothing. The estimate follows the
destination toggle and names the deduction.

⚠️ **Deliberately not grossed up into the price.** Minting extra to cover a
per-order fee would let anyone drain the operator by opening account-destination
orders — a griefable gas drain. Disclosure is the honest fix.

### Afterwards: a receipt the buyer can check

`receipt(orderId)` is owner-scoped (§14) and returns both rate inputs, so the
price recomputes on the buyer's machine from canisters they query themselves. See
spec §8 — a gateway confirming its own arithmetic proves nothing.

## 9. Admission: the pre-creation gate

`create_order` refuses before quoting when fulfilment is already impossible
(`Main.mo` → `Gate.mo`). Checked cheapest-first, before any pricing work:

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

**Orders are never deleted.** `Retention.mo` has exactly one effect: a `#created`
order past `orderTtlNs` flips to `#expired`.

| Status | Age | Payable? | Record |
|---|---|---|---|
| `#created` | < `orderTtlNs` (default 48 h) | yes | kept forever |
| `#expired` | ≥ TTL, forever | **yes** | kept forever |

**Expiry is advisory.** An `#expired` order is still fully payable and a late
genuine payment is honoured at the locked quantity (`Card.mo` accepts
`#created or #expired`; `Orders.mo` allows `#expired → #paid`). The flip is
bookkeeping — it makes an abandoned attempt visibly stale rather than
indistinguishable from a live one.

**The "we lost track" worry, resolved by not losing track.** A Payment Link is
permanent, so a payment can arrive for an order abandoned months or years ago
from a bookmarked URL. Because the record is still there, that payment is
**delivered** — at the quantity locked when the order was created. It does not
degrade to a refund, because there is nothing to degrade: the §4 late-payment
guarantee holds for the life of the canister.

Deleting records past a horizon — even with a tombstone set, so a late payment
could at least be *diagnosed* before being refunded — would contradict the
standard applied everywhere else here: unresolved obligations are never evicted,
and money facts live on permanent records. It would also create orphans,
`paidIntents` entries pointing at records that no longer exist.

### A buyer can give up on an unpaid order

`cancel_order(id)` is owner-scoped and marks a `#created` order `#expired`. It is
idempotent, and it is refused for a paid order — that one is going to deliver, and
offering a cancel would promise something untrue.

⚠️ **It exists because the open-order cap counts unpaid orders.** The gate's
refusal tells the user to pay or abandon one, and `abandon_order` is admin-only
and only accepts a *paid* order — so without this, someone who opened the cap's
worth of checkouts and finished none would be locked out until the 48 h TTL
expired them, reading advice they could not follow.

⚠️ **Cancelling can never strand a payment.** `#expired` stays payable, so a
payment already in flight when they clicked cancel still delivers at the locked
quantity. No error-queue entry is created either: nothing is owed, and an entry
with no obligation behind it is exactly the orphan the queue must not accumulate.
The audit trail carries `order.cancelled`.

**Growth is bounded at its source, which is why retention never needed to bound
it.** `Gate.maxOpenOrdersPerPrincipal` (default 20) bounds the records a user can
create for free — abandoned orders are the only ones that cost them nothing — and
the burn cap bounds legitimate volume. An order is a few hundred bytes, so a
million is a few hundred MB, and a million orders is millions of dollars of
volume. If retention ever genuinely binds, archival to a separate canister
preserves the record; deletion does not.

**Sweeping is cleanup, not protection.** The bound that actually stops unbounded
state growth is `maxOpenOrdersPerPrincipal`, because abandoned orders are the
only thing an attacker can create for free.

The sweep runs inside the existing recovery timer (hourly by default),
synchronously and before the money sweep so it cannot interleave with an await.
`run_retention()` is the admin lever to apply retuned bands immediately.

## 11. Refunds, disputes, and what is not automated

**Refunds are always manual, in the Stripe Dashboard.** No `sk_live` means the
canister cannot issue one. What the canister does is *react* to
`charge.refunded` (`Card.mo`).

⚠️ **Only a *full* refund settles an obligation.** Stripe fires `charge.refunded`
for **any** refund, and the event carries a *charge*: `amount` is the charge total
and `amount_refunded` is the cumulative amount returned. A refund is complete only
when the second reaches the first (`Card.isFullRefund`).

A partial refund therefore leaves the Type 1 entry **open** and audits
`stripe.refundPartial`. Reading it as settled would auto-resolve a $500
obligation on a $5 courtesy refund, and the unrefunded $495 would exist nowhere
but the audit ring — which drops. `#refundAfterDelivery` likewise records
`refundedCents` and `fullRefund`, because a partial refund after delivery is a
partial loss and reconciliation happens by amount.

⚠️ **Prefer delivering to refunding whenever the buyer is identifiable.** A
refund makes the customer start over, and a customer who has paid and received
nothing files a chargeback — which costs more than the refund and counts against
the Stripe account. For a payment that arrived but could not be attributed,
`attach_payment` credits the order the buyer meant, at that order's own
creation-time price (§8). Refund only when you cannot tell what they bought.

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

`RUNBOOK.md` §6 is the authoritative operator triage table. This is the
rail-specific summary:

| Outcome | HTTP | Money position | Resolution |
|---|---|---|---|
| Secret not provisioned | 503 | nothing happened | provision; Stripe retries |
| Missing/bad signature, stale `t` | 400 | nothing happened | none — not from Stripe |
| Unparseable body | 400 | nothing happened | visible in the Dashboard's delivery log |
| Unhandled event type | 200 | nothing happened | audited `stripe.unhandledType` — an unsubscribed type arriving is a Dashboard-config surprise worth seeing |
| Verified but unprocessable (e.g. no `payment_intent`) | **200** | unknown — inspect in Stripe | queued `#unprocessable`; see below |
| `checkout.session.async_payment_succeeded` | 200 | **fiat in** | mints exactly like `completed` |
| `checkout.session.async_payment_failed` | 200 | nothing happened | audited; the order stays payable |
| livemode mismatch | 200 | depends which way | audited `stripe.livemodeMismatch`; a *live* payment on a test-configured gateway is queued as an obligation |
| Redelivered `event.id` / `payment_intent` | 200 | already handled | none |
| `payment_status ≠ paid` | 200 | no money yet | audited `stripe.unpaidSession`; check the link is card-only |
| Type 1 `#unattributed` | 200 | **fiat in, nothing minted** | `attach_payment` if you can identify the order; refund if not |
| Type 1 `#duplicate` | 200 | **fiat in ×2, minted ×1** | refund the second charge |
| Type 2 `#undeliverable` | 200 | **cycles minted, in the app's own balance** | re-deliver or refund |
| `#stuckMint` | 200 | **uncertain** — see the stage | per-stage rules in RUNBOOK §6 |
| `#refundAfterDelivery` | 200 | **fiat out, cycles out** — a loss | reconcile; consider restricting the payer |
| `#deliveryDelayed` | 200 | **fiat in, mint still retrying** — nothing lost | an alert at 2 h, not a failure: clear the cause (float, burn cap) and it **self-resolves on delivery** |

**The buyer is never left waiting indefinitely.** A paid order that cannot
progress alerts the operator at 2 h while the position is still fully recoverable
and terminates at 72 h, and this holds for **every** in-flight status — not just
`#paid`. `#minting` and `#icpAtCmc` are equally capable of sitting still, and a
retry *count* is not a time bound: bounding the notify stage by retries alone let
an order sit paid-and-undelivered for as long as the budget lasted, with no alert
and no escalation.

The terminal escalation names the stage, and the stage is derived from the **mint
journal** rather than the order status: the status says where the order stopped,
the journal says where the money is, and only the money position determines the
recovery. `RUNBOOK.md` §5 carries the full mapping.

⚠️ The clocks are **per state**, not per order — each transition resets the age —
so total time to resolution can exceed 72 h even though no single state does. The
2 h alert is what an operator works against.

### Why a verified event is never answered with a 4xx

Once the MAC verifies, the event genuinely came from Stripe. If we then cannot
process it — a session with no `payment_intent`, reachable via a subscription-mode
link or a 100%-off promo code — parsing will fail **identically on every retry**,
for Stripe's full ~3-day horizon. Stripe warns about, and can **disable**, an
endpoint that keeps failing; a disabled endpoint then loses every *legitimate*
webhook after it. Trading a permanent outage for a refusal that can never succeed
is strictly worse, so these are acked 200 and queued as `#unprocessable`.

Non-2xx is reserved for the two cases where retrying is exactly what we want:
input we cannot authenticate (400) and an unprovisioned secret (503).

⚠️ `RUNBOOK.md`'s "nothing is lost while you fix it" holds for *transient*
failures. A permanent one used to be the dangerous case; it is now acked.

### Async payment methods

A Payment Link can offer delayed methods, and several are enabled by default in
the Dashboard — which the canister cannot enforce. The sequence is:
`checkout.session.completed` with `payment_status != "paid"` (no money yet), then
`checkout.session.async_payment_succeeded` when it settles.

Both parse into the same shape and run the same handler, so a delayed payment
mints correctly. Handling only `completed` would mean fiat arriving with nothing
minted and nothing on the worklist. **Still pin the link to card-only** (§14
checklist) — this handles the case, it does not make it desirable.

### Test-mode/live-mode confusion

`set_expected_livemode(?Bool)` declares which Stripe world this gateway serves.
A test-mode signing secret pasted into a canister holding a real ICP float would
otherwise mint real cycles for payments that never happened, and the secret is the
only thing separating the two. Unset by default so a sandbox works without
configuration; the go-live checklist sets it to `?true`.

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

Interface (`Main.mo`):

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
| `set_retention_config` | order TTL (the expiry flip; nothing is deleted) |
| `set_pricing_config` | fee formula, staleness window (capped at 1 h), delta bound, minimum rate sources |
| `refresh_rates` | force a rate tick now instead of waiting for the timer |
| `set_treasury_config` | burn cap, window, alert-after, max hold, low-float threshold |
| `error_queue` / `resolve_error` | the operator worklist |
| `order_for_payment` | reconciliation: Stripe charge → order it funded |
| `mint_journal` | money-out record for one order |
| `audit_log` | operational trail; gaps in `seq` mean ring-buffer drops |
| `process_order` | manual mint kick; safe to spam |
| `run_retention` | apply a retuned TTL now |
| `attach_payment` | credit an unattributable payment to the order it was meant for (§12) |
| `set_pricing_config` | fee formula, staleness window, delta bound, minimum rate sources |
| `abandon_order` | void an unpaid order, with the reason recorded in the audit trail |
| `recount_orders` | rebuild the O(1) per-status counters from the store |
| `refresh_float` | refresh the float observation the gate reads |
| `reset_burn_window` | clear window consumption after verifying traffic |

Public queries (transparency is the product thesis): `card_tiers`,
`pricing_status`, `quote_previews`, `treasury_status`, `recovery_status`,
`lifecycle_config`, `retention_status`, `can_purchase`, `cycles_status`,
`error_queue_depth`, `health`.

**Owner-scoped, not admin-scoped:** `get_order`, `list_orders`, `cancel_order`,
and `receipt(orderId)` answer only for `caller == order.owner` — not even a
controller can read someone else's receipt. The receipt returns the paid amount,
the ICP block index that funded the mint, the cycles minted, and both rate inputs
with their XRC quality signal, so a buyer can recompute
`netCents × xdrPermyriadPerIcp × 10¹² / usdPerIcpMicros` from canisters they
query themselves and confirm they were charged correctly.

### Stripe Dashboard setup

1. Create one **Payment Link** per price point: a Product, a fixed **one-time**
   Price in USD, and a card-only link with adjustable quantity, promotion codes and
   automatic tax all **off**. Those four settings are what keep
   `amount_total == tier.usdCents`, and the failure mode is not an error — the order
   delivers a different cycle quantity and looks successful. **RUNBOOK §3 is the
   reference**: how to create them, what each setting does if enabled, and why
   test-mode links cannot be reused in live mode.
2. Register them with `set_card_tiers`. The URL is **not validated** (Stripe custom
   checkout domains make a host allowlist wrong), so click each tile once on the
   deployed site: a wrong link still creates an order, locks a rate and consumes an
   open-order slot before dead-ending.
3. Create a webhook endpoint pointing at
   `https://<canister-id>.icp0.io/webhook/stripe`, subscribed to exactly
   **`checkout.session.completed`** and **`charge.refunded`**.
4. Copy the endpoint's signing secret into `set_webhook_secret`.
5. Size the burn cap (`set_treasury_config`) — until then the gate refuses every
   order.
6. `refresh_float` after funding, so the gate has an observation.

## 15. Local development against a Stripe sandbox

`scripts/stripe-dev.sh` automates this; the mechanics are below.

📋 **For the go-live verification pass, follow `docs/SANDBOX-TESTPLAN.md`** — the
enumerated scenario list (signatures, attribution, amounts, dedup, refunds
including the partial-refund case, async methods, the frontend) plus what a green
run does *not* prove.

The precondition that makes it work: `Http.pathOf` strips the query string
(`Http.mo`), so the local gateway's `?canisterId=…` parameter does not break
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

⚠️ **Two setup steps this script does not do**, without which `create_order` fails:
top up the backend past the admission gate's own-cycles floor, and give the local CMC
a current rate (its seeded rate is stamped 2021 and only governance may change it).
Both are in `docs/SANDBOX-TESTPLAN.md`, which has a verified end-to-end walkthrough —
a local network *can* run the whole good path, including the real CMC mint and cycles
delivery, with local cycles and no mainnet.

Two further caveats:

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
