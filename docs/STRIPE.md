# The Stripe (Card) rail, end to end

How fiat becomes cycles. Written from the code — every claim names the module it
came from, so you can check it. (Module names, not line numbers: a stale line
number is worse than no line number, and they drift on every edit.) The *why* behind the design decisions lives in
`design-docs/ONCHAIN_GATEWAY_SPEC.md` (spec v2.1); this document is the *what*.

- [1. The one-sentence version](#1-the-one-sentence-version)
- [2. What the canister calls Stripe for, and what it still cannot do](#2-what-the-canister-calls-stripe-for-and-what-it-still-cannot-do)
- [3. The full happy path](#3-the-full-happy-path)
- [4. Ingress: two paths, and why the webhook can't be caller-authenticated](#4-ingress-two-paths-and-why-the-webhook-cant-be-caller-authenticated)
- [5. Signature verification](#5-signature-verification)
- [6. Attribution: claimed, not trusted](#6-attribution-claimed-not-trusted)
- [7. Dedup: two layers, and what they do not protect against](#7-dedup-two-layers-and-what-they-do-not-protect-against)
- [8. Amount honouring — an equality check since #33](#8-amount-honouring--an-equality-check-since-33)
- [8a. What the buyer sees before paying](#8a-what-the-buyer-sees-before-paying)
- [9. Admission: the pre-creation gate](#9-admission-the-pre-creation-gate)
- [10. Order lifecycle — Stripe owns the deadline](#10-order-lifecycle--stripe-owns-the-deadline)
- [11. Refunds, disputes, and what is not automated](#11-refunds-disputes-and-what-is-not-automated)
- [12. Every failure and its money position](#12-every-failure-and-its-money-position)
- [13. The two secrets](#13-the-two-secrets)
- [14. Operator surface](#14-operator-surface)
- [15. Local development against a Stripe sandbox](#15-local-development-against-a-stripe-sandbox)

---

## 1. The one-sentence version

A user picks a preset or types an amount; the canister creates a **Stripe
Checkout Session for that one order** over an HTTPS outcall, setting
`client_reference_id = <principal>_<orderId>` itself; the buyer pays Stripe
directly on that session's URL; and Stripe POSTs a signed
`checkout.session.completed` webhook back, which the canister verifies by HMAC
on-chain, attributes to the order, and **transfers** the cycle quantity locked at
order creation out of the gateway's own cycles-ledger account. **Nothing is created
on demand**: the gateway sells cycles it already holds, so a delivery either moves
them or fails and retries.

## 2. What the canister calls Stripe for, and what it still cannot do

The rail was **inbound-only** until #33: no API key anywhere, Stripe talked to us
and never the reverse. It now makes exactly **one** kind of outbound call —
create a Checkout Session for an order, and expire one when the buyer cancels —
over an HTTPS outcall, using a **restricted** key (`rk_...`) scoped to write
Checkout Sessions and nothing else.

That scope is the whole of the change. Everything the inbound-only design bought
still holds, because the key cannot do anything else:

| Consequence | Detail |
|---|---|
| A leaked key creates sessions that pay **us** | It cannot issue refunds, read customers, touch payouts, or reach the account. That asymmetry is why the scope matters more than the storage: an `sk_` would be a materially worse thing to leak (§13). |
| Refunds are still manual | The canister structurally cannot issue one. Every refund is a human action in the Stripe Dashboard (§11). |
| No subscriptions or auto-refill | Both require charging a stored payment method. Explicitly out of scope. |
| Payment amounts are pinned by **us**, not by a link's configuration | The session carries inline `price_data` with the amount the order quoted, so `amount_total == usdCents` is a property of what the request does *not* enable rather than of what an operator remembered to switch off in a Dashboard. The list is in the code beside `Session.createBody`. |

**Two things follow from making any outbound call at all**, and both are new
failure surfaces rather than incidental details:

- **A transform is now load-bearing.** Every replica makes the request, so the
  responses must agree byte for byte; Stripe returns a unique `request-id` per
  HTTP request, so `Session.strip` discards **all** headers. A per-request value
  left in place takes the rail down with `No consensus could be reached` — and no
  suite here can catch it, because PocketIC mocks outcalls (verified by mutation).
- **`Idempotency-Key = orderId` does two jobs.** The obvious one is that Stripe
  will not create a second session for a retried request. The load-bearing one is
  that without it each replica would create a *distinct* session, so consensus
  could never be reached at all and no transform could repair it.

Pricing remains inter-canister: the Exchange Rate Canister for USD/ICP and the
CMC for XDR/ICP (§8). There is no operator-settable rate source to audit.

## 3. The full happy path

```
 operator ──▶ set_stripe_api_key + set_stripe_origin (+ optional price tiles)
                       │  no Dashboard objects exist for this rail
                       ▼
 user ──II login──▶ create_order(amount, destination)         Main.mo
                       │  rail provisioned?                    Main.mo → Secret.mo
                       │  admission gate                       Main.mo → Gate.mo
                       │  quote: lock the CYCLE QUANTITY       Pricing.mo (cached XRC+CMC)
                       │  raw_rand order id                    Orders.mo
                       │
                       │  HTTPS OUTCALL: POST /v1/checkout/sessions
                       │    Idempotency-Key = orderId          rails/Session.mo
                       │    inline price_data, expires_at ≈35m
                       │    client_reference_id set BY US
                       ▼
                    #created + stripeSessionUrl + expiresAtNs (Stripe's own)
                       │
 frontend ─────────────┤ opens  order.stripeSessionUrl
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
                       │ 6. attribute the reference  → else #unattributed (refund)
                       │ 7. ceiling + amount honour  → else #unattributed (refund)
                       ▼
                    markPaid → #paid, paidIntents[intent] = orderId
                       │
                       │ detached self-message kicks money-out
                       ▼
   #paid ─ one icrc1_transfer out of the reserve ─▶ #delivered
              ├─ retriable / no reply ─▶ stays #paid, sweep replays the SAME intent
              └─ fate unknowable, or 72 h elapsed ─▶ #needsReview
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

`client_reference_id` used to be a **URL parameter the frontend appended**, on a
permanent link anyone could pay with any reference they liked. Since #33 the
canister sets it through the API and there is no URL parameter to touch — which
removes the dominant attribution failure, and removed `attach_payment` with it
(§12).

The posture does not change: **claimed, not trusted.** Every dollar that arrives
must still resolve to delivery or to a refund obligation — never a silent accept —
because the field arrives in a webhook body and a webhook body is data. It is a
**pointer, not a credential**, which is what made it safe to expose at all. The order id is 16 bytes of `raw_rand`, so a reference cannot be guessed; and
forging one gains nothing, because the claimed principal must equal the order's
stored owner, so the best an attacker achieves is paying for somebody else's order.

The value is appended **by the frontend, per order** — it is never configured
anywhere. The Stripe Dashboard's URL-parameter dialog can bake a static one into a
link, which would break attribution for every buyer; RUNBOOK §3 says to leave it
empty.

`handleCheckout` (`Card.mo`) re-derives and checks everything:

| Check | Failure |
|---|---|
| reference present | `#unattributed` — "missing client_reference_id" |
| parses as `<principal>_<orderId>` | `#unattributed` — "malformed" |
| order exists | `#unattributed` — "no order X". Orders are never deleted (§10), so this means the reference never resolved: a forged, mistyped, or stripped URL parameter |
| claimed principal **matches the stored owner** | `#unattributed` — "claimed owner does not match" |
| order's rail is `#card` | `#unattributed` — "is not a card order" |
| status is `#created` | `#duplicate` otherwise |
| currency is `usd` | `#unattributed` — "unexpected currency" |
| amount within the ceiling | `#unattributed` — "exceeds the per-purchase ceiling" |

Note the owner check: the reference *claims* a principal, and it must equal the
order's actual owner. `Orders.parseClientReferenceId` compares principal text
rather than calling `Principal.fromText`, because that traps on garbage and a
trapped webhook is a 5xx that Stripe would retry forever (`Orders.mo`).

Refund obligations are always answered **HTTP 200**. The payment *is* handled — by
the operator's refund queue rather than by delivery — and a non-2xx would make
Stripe redeliver an event that has already been routed (`Card.mo`).

The stored `claimedRef` is length-capped at 128 bytes
(`ErrorQueue.maxClaimedRefBytes`) so an attacker cannot stuff arbitrary data
into admin-visible stable state one webhook at a time.

## 7. Dedup: two layers, and what they do not protect against

In order (`Card.mo`):

1. **`event.id`** — catches Stripe *redelivering one event*. Stripe's delivery is
   at-least-once and it retries for ~3 days.
2. **`payment_intent`** — one delivery per payment, even across distinct event
   deliveries that reference the same intent.

Both live in `Idempotency.mo` and are pruned after ~7 days on the webhook path
(Stripe stops retrying well before that).

**Stripe dedup is not double-pay protection.** A user who genuinely pays twice
produces two distinct `event.id`s *and* two distinct `payment_intent`s — two real
payments. The second one passes both dedup layers, finds the order already past
`#created`, and becomes `#duplicate`: fiat exists, nothing extra was
delivered, operator refunds. This is the single most important thing to understand
about the rail, and it is why **dedup gates delivery** rather than gating the
webhook.

## 8. Amount honouring — an equality check since #33

The order stores a **pricing snapshot** at creation (`Types.Pricing`): the gross
cents, **both rate inputs** (`usdPerIcpMicros` from the XRC, `xdrPermyriadPerIcp`
from the CMC) with the XRC quality signal, and the fee formula. `Card.mo` then
decides one thing:

- `amount_total` **equals** the order's `usdCents` → deliver `lockedCycles`
  verbatim.
- Anything else → **a refund obligation, nothing delivered**, with both figures in the detail.
- Above the per-purchase ceiling → the same, checked first (see below).

**Why this used to be a computation.** A fixed Payment Link could legitimately be
paid for an amount the order was not created for — the buyer chose the *link*, not
the order — so a mismatch was repriced from the order's own snapshot and
delivered. A per-order session carries the amount **we** set, so a mismatch now
means a Stripe feature that moves the total is enabled. That is an operator
problem to see, not a buyer's choice to honour, and repricing it would deliver
against it silently: the audit log would show an ordinary completed purchase.

Two consequences worth naming, because things downstream depend on them:

- **`lockedCycles` is immutable after creation.** Nothing on the money-in path
  writes it. #30's tally is exact rather than conservative because of that.
- **`#belowFeeFloor` and `#unusableSnapshot` are gone**, not merely unreachable —
  both existed only to bound repricing. `#aboveCeiling` stays as defence in depth,
  and it is still reachable without any tampering: an order created under a
  higher ceiling matches its own quote after the ceiling is lowered.

**What was actually paid is stored on the order** (`paidUsdCents`), not only in
the audit log. The audit ring buffer drops its oldest entries, so a fact about
money cannot live only there — "what did this buyer pay?" has to be answerable
from state for the life of the canister. It can now only equal `usdCents`, and it
is stored anyway: "what Stripe said" and "what we asked for" being the same is
worth being able to check rather than assume.

## 8a. What the buyer sees before paying

Three guarantees, in the order they matter.

### The cycle quantity is shown before anything is committed

`quote_previews(amounts)` is a **public query** returning, per amount, the fee,
the net, and the cycle quantity — plus the rate pair it used. The preset grid is
one round trip, and a typed custom amount is priced through the same query rather
than in the client.

⚠️ **It no longer discloses the cycles-ledger fee** (#30 PR-A). A query cannot
`await icrc1_fee`, so disclosing it meant the backend storing a copy and
correcting it whenever a transfer came back `#BadFee` — a stable field, a
correction path and a staleness class, for one number the caller can read itself.
The frontend asks the ledger directly (`actor.ts`) and shows `cycles − fee`.

⚠️ **It calls the same `quoteCents` that `create_order` calls.** Not the same
formula reimplemented — the same function. A client computing its own estimate
would be one refactor away from displaying a number the gateway does not honour,
and the buyer would have no way to tell which side was wrong.

Being a query, it costs nothing and needs no login: you can see exactly what your
money buys before signing in. It takes no cap on the input array, deliberately —
work is constant per element the caller already had to transmit, so the only
thing a cap would buy is silent truncation.

### The rate is locked at creation, and the lock is enforced

`create_order(amount, destination, minCycles)` takes an **optional minimum**.
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

### One destination: the buyer's own account

Cycles go to the **signed-in principal's own cycles-ledger account**, default
subaccount, and `create_order` refuses anything else with
`#destinationNotOwned`. That is a property of the canister, not of the frontend —
a hand-crafted call reaches the same method (#29).

So "the cycles come to you" needs no field, no question and no validation on the
page. A buyer funding a canister transfers on afterwards from the CLI, and pays
that second fee themselves.

### The cycles-ledger deposit fee is disclosed, not absorbed

Delivery loses **100 M cycles** to the ledger's deposit fee, on every order. The
amount tiles show what lands; the note under the destination names the fee once.

⚠️ **Deliberately not grossed up into the price.** Covering the fee by sending
extra cycles would let anyone drain the operator by opening orders. The cycles
come out of a **finite reserve** the operator funded, so the drain has a hard
floor and hits paying buyers as a refused sale — `#reserveShort`. Disclosure is
the honest fix, and the cheap one: the fee is stated once and nobody's order is
denied to pay for someone else's griefing.

### The order is the record; the audit log is the trail

**Every fact about an order's money lives on the order** (#34): its status, what
the buyer actually paid, why it expired (`expiredBy`), when its rates were read
(`pricing.ratesFetchedAtNs`), and — once #33 lands — the Stripe session it is paid
through and the deadline Stripe set for it.

`audit_log` is the *operational trail*: alerts, dedup drops, evictions. It answers
"what was happening around then", never "what happened to this order". That
division is about where a fact belongs, not about the buffer being bounded — #37
removes the ring and the division still holds.

**A refund is the one money fact not on the order.** It lives in Stripe, where it
was issued, plus the unresolved `#refundAfterDelivery` entry, which the queue
never evicts. #34 considered a `refundedUsdCents` field and dropped it: the app
does not model refunds, and a manual Stripe refund is an out-of-band operator
action. It becomes a field when there is real money to reconcile.

### Order statuses, and what each one owes

| Status | Payable? | Owes cycles? |
|---|---|---|
| `#created` | yes | not yet — the promise is held against the reserve |
| `#cancelled` | **no** — the buyer gave up, and `#cancelled → #paid` is absent from the matrix | no |
| `#expired` | **no** as of #34 | no |
| `#paid` | already paid | **yes** — one transfer out of the reserve away |
| `#delivered` | — | settled |
| `#needsReview` | — | **yes** — outcome unknown, a human checks the ledger |
| `#abandoned` | — | no — the operator ended it, having refunded by hand |

A payment that arrives for a `#cancelled` or `#expired` order is real money the
gateway cannot deliver against. It is filed as an `#unattributed` obligation carrying
the payment intent, and the operator refunds it in Stripe. Cancellation expires the
Stripe session first, so the window is narrow — but a payment already in flight can
still land in it.

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
| amount ≥ `minPurchaseUsdCents` | `#amountBelowMin` | permanent — the user must change the amount |
| `Cycles.balance()` ≥ `minCanisterCycles` | `#canisterCyclesLow` | the canister's own gas is low |
| `reserveFloor − promised ≥ lockedCycles` | `#reserveShort` | the reserve cannot cover this order on top of what it already owes. Carries both figures, so a smaller amount may still succeed |

Two things worth being precise about:

- **The two "cycles" are different pots.** `minCanisterCycles` is *this canister's own
  gas* — if it runs out the canister freezes and is then uninstalled. The **reserve**
  is what it sells to customers. Different failure modes, different fixes, and
  confusing them is the most common local-setup mistake.
- **`#reserveShort` is the only refusal a smaller amount can fix**, which is why it
  carries both figures. The others are permanent for that request (`#amountAboveMax`,
  `#amountBelowMin`), about the caller (`#tooManyOpenOrders`), or operational
  (`#canisterCyclesLow`).
- ⚠️ **`can_purchase` cannot answer the solvency half.** It is a query, and solvency is
  decided synchronously inside `create_order` against the maintained reserve floor. A
  green `can_purchase` with `availableToSell = 0` is the split working, not a bug.

The gate refuses *before* the user pays. The authoritative check is the one inside
`create_order`, in the same synchronous block as the hold it takes.

`can_purchase(usdCents)` is a public query that returns the same decision, so the
frontend can disable the button with a real reason instead of failing at submit.

## 10. Order lifecycle — Stripe owns the deadline

**Orders are never deleted, and nothing sweeps them.** #33 deleted `Retention.mo`
entirely: there is no TTL, no band, no cursor. An order's deadline is its
session's `expires_at` (~35 min; Stripe's floor is 30), stored on the order as
`expiresAtNs`, and the only thing that moves it to `#expired` is Stripe's
`checkout.session.expired`.

| Status | Payable? | Moved there by | Record |
|---|---|---|---|
| `#created` | yes, until its own `expiresAtNs` | `create_order` | kept forever |
| `#expired` | **no** (#34) | `checkout.session.expired`, or a failed session creation | kept forever |
| `#cancelled` | **no** (#34) | the buyer, via `cancel_order` | kept forever |

⚠️ **A missed expiry event leaves the order visibly `#created` past its deadline,
and that is the design.** A sweep as a backstop was specified and rejected: it
would flip the order while its reserve promise stayed held, so a broken order
would look like a correctly expired one and the reserve would leak silently. The
stuck order **is** the detection signal (#30's predicate 1).

**Expiry is terminal.** #34 deleted `#expired → #paid`, so `Card.handleWebhook`
admits `#created` alone — the only guard left, now that #33 deleted
`attach_payment` and its sibling guard. Expiry deletes nothing, but it is a real
deadline, and it frees the buyer's open-order slot.

**The "we lost track" worry, resolved by not losing track.** A session dies at
its own `expires_at`, but Stripe can still deliver a late `completed` for one
that was paid just before it, and an event can be resent from the Dashboard years
later. Because the record is still there, that payment is
**attributable** — the gateway can say whose it was and which order it names. It
is therefore **refunded**, not delivered: an `#unattributed` obligation is
filed carrying the payment intent, and a `charge.refunded` resolves it.

That is a deliberate narrowing. Until #34 the late payment was honoured at the
locked quantity for the life of the canister; the price of that guarantee was an
order that could be paid long after the buyer, the operator and the rate had all
moved on. What survives is the half that matters — **the record is never deleted,
so a late payment is never a mystery charge.** #33 narrowed the window itself:
the session and the order now die together, so a session that can still be paid
always belongs to an order that can still accept it.

Deleting records past a horizon — even with a tombstone set, so a late payment
could at least be *diagnosed* before being refunded — would contradict the
standard applied everywhere else here: unresolved obligations are never evicted,
and money facts live on permanent records. It would also create orphans,
`paidIntents` entries pointing at records that no longer exist.

### A buyer can give up on an unpaid order

`cancel_order(id)` is owner-scoped and marks a `#created` order **`#cancelled`** —
its own status since #34, so a reload no longer tells a buyer who cancelled that
their order expired. It is idempotent, and it is refused for a paid order: that one
is going to deliver, and offering a cancel would promise something untrue.

⚠️ **It exists because the open-order cap counts unpaid orders.** The gate's
refusal tells the user to pay or abandon one, and `abandon_order` is admin-only —
so without this, someone who opened the cap's worth of checkouts and finished none
would be locked out until their sessions expired, reading advice they could not
follow.

⚠️ **A payment racing a cancellation is refunded, not converted.** `#cancelled →
#paid` is absent from the transition matrix, and that absence is the guarantee.
So a payment already in flight when the buyer clicked cancel does **not** deliver:
it lands as a refund obligation carrying the payment intent, which a Stripe refund
resolves. The buyer's decision wins, and their money is recorded and refundable
rather than silently kept or converted against it.

Until #34 the opposite was true — `#expired` stayed payable, so the in-flight
payment delivered. #33 removed the window itself: `cancel_order` expires the
Stripe session **first**, and marks the order only if that succeeded, so the race
stops being possible rather than merely recorded. The audit trail carries
`order.cancelled` either way.

**Growth is bounded at its source, which is why no sweep was ever needed to bound
it.** `Gate.maxOpenOrdersPerPrincipal` (default 20) bounds the records a user can
create for free — abandoned orders are the only ones that cost them nothing — and
the reserve bounds legitimate volume — nobody buys more than it holds. An order is a few hundred bytes, so a
million is a few hundred MB, and a million orders is millions of dollars of
volume. If store size ever genuinely binds, archival to a separate canister
preserves the record; deletion does not.

## 11. Refunds, disputes, and what is not automated

**Refunds are always manual, in the Stripe Dashboard.** No `sk_live` means the
canister cannot issue one. What the canister does is *react* to
`charge.refunded` (`Card.mo`).

⚠️ **Only a *full* refund settles an obligation.** Stripe fires `charge.refunded`
for **any** refund, and the event carries a *charge*: `amount` is the charge total
and `amount_refunded` is the cumulative amount returned. A refund is complete only
when the second reaches the first (`Card.isFullRefund`).

A partial refund therefore leaves the entry **open** and audits
`stripe.refundPartial`. Reading it as settled would auto-resolve a $500
obligation on a $5 courtesy refund, and the unrefunded $495 would exist nowhere
but the audit ring — which drops. `#refundAfterDelivery` likewise records
`refundedCents` and `fullRefund`, because a partial refund after delivery is a
partial loss and reconciliation happens by amount.

⚠️ **An unattributed payment can now only be refunded** — including the ones where we
know exactly whose it is. `attach_payment`, which credited the order the buyer
meant, was deleted in #33 along with the failure it existed for: the canister
sets `client_reference_id` through the API, so there is no URL parameter for a
buyer to strip or edit.

That leaves the `#unattributed` variant named for a case it rarely covers. What
still reaches it is mostly **attributable but unpayable** — the entry names the
order and we refuse to credit it anyway:

- the per-purchase ceiling was lowered under an existing order (needs nothing to
  go wrong: the order still matches its own quote);
- `amount_total` is not the quoted amount, which means an account-level setting
  is moving the total (§8);
- the order is `#cancelled` or `#expired` (#34).

The genuinely unattributable cases — no reference, a malformed one, one naming no
order, a non-USD session — are unreachable through this app. Reaching one means a
session created outside it, a reinstalled order store, or a bug. This is the one thing
the deletion makes *harder* rather than simpler, and it was decided knowing that:
a refund makes the customer start over, and a customer who paid and received
nothing may file a chargeback, which costs more than the refund. The trade is
accepted because the failure it answered is now unreachable by construction — so
if you see one, treat it as a bug to find rather than a queue to work.

1. Resolve every unresolved refund-settleable entry carrying that `payment_intent`. This
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
claw back cycles already forwarded to the buyer's account, so no amount of
on-chain plumbing changes the outcome. Chargeback risk is managed where it can
be: **Stripe Radar rules and 3DS** on the Stripe side, and the **per-purchase
ceiling** plus the **reserve size** on ours.

Note that the reserve size does *not* bound chargeback losses — the payments are
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
| `checkout.session.async_payment_succeeded` | 200 | **fiat in** | delivers exactly like `completed` |
| `checkout.session.async_payment_failed` | 200 | nothing happened | audited; the order stays payable |
| livemode mismatch | 200 | depends which way | audited `stripe.livemodeMismatch`; a *live* payment on a test-configured gateway is queued as an obligation |
| Redelivered `event.id` / `payment_intent` | 200 | already handled | none |
| `payment_status ≠ paid` | 200 | no money yet | audited `stripe.unpaidSession`; the request asks for card-only, so check the account for a delayed method enabled at that level |
| `#unattributed` | 200 | **fiat in, nothing delivered** | refund in Stripe — the only remedy. Includes an `amount_total` that is not the quoted one, which additionally means a Stripe setting is moving the total (§8) |
| `#duplicate` | 200 | **fiat in ×2, delivered ×1** | refund the second charge |
| `#deliveryStuck` | 200 | **uncertain** — see the stage | per-stage rules in RUNBOOK §6 |
| `#refundAfterDelivery` | 200 | **fiat out, cycles out** — a loss | reconcile; consider restricting the payer |
| `#deliveryDelayed` | 200 | **fiat in, delivery still retrying** — nothing lost | an alert at 2 h, not a failure: clear the cause (usually the cycles ledger) and it **self-resolves on delivery** |

**The buyer is never left waiting indefinitely.** A paid order that cannot progress
alerts the operator at 2 h, while the position is still fully recoverable, and
terminates at 72 h. ⚠️ **Both bounds are TIME, deliberately, and there is no retry
budget** — a replay of a journalled delivery intent is provably safe (byte-identical
args, the ledger deduplicates), so capping attempts would convert a recoverable state
into a manual one while a *count* bounds nothing an operator can reason about.

The terminal escalation names the stage, and the stage is derived from the **delivery
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

A session can offer delayed methods. Ours asks for `payment_method_types[]=card`
so it does not — but an account-level setting or a future Stripe default could
still produce one, and the handler is what makes that safe rather than a support
ticket. The sequence is:
`checkout.session.completed` with `payment_status != "paid"` (no money yet), then
`checkout.session.async_payment_succeeded` when it settles.

Both parse into the same shape and run the same handler, so a delayed payment
delivers correctly. Handling only `completed` would mean fiat arriving with nothing
delivered and nothing on the worklist. The request pins card-only anyway — this
handles the case, it does not make it desirable.

### Test-mode/live-mode confusion

`set_expected_livemode(?Bool)` declares which Stripe world this gateway serves.
A test-mode signing secret pasted into a canister holding a funded reserve would
otherwise deliver real cycles for payments that never happened, and the secret is the
only thing separating the two. Unset by default so a sandbox works without
configuration; the go-live checklist sets it to `?true`.

## 13. The two secrets

There are **two** since #33: the webhook **signing secret** (`whsec_…`) and the
Stripe **API key** (`rk_…`). Both are stored **plaintext in canister state, by
design**, through the same `Secret.mo` store.

HMAC is symmetric, so for the signing secret *verify = forge*: anything that can
check a signature can forge one. Encrypting the stored blob would only move the
problem to a key the canister also needs at verify time, so it buys nothing. The
API key must be sent to Stripe on every session creation, so the same applies.

⚠️ **What a leak of each one buys an attacker is different, and it is the
argument for the key's scope:**

| Leaked | What it enables |
|---|---|
| Webhook signing secret | forge "paid" events → deliver cycles at operator expense. **Bounded by the reserve balance and nothing else**, detectable against Stripe's event log, recovered by rotation. |
| A restricted `rk_` key scoped to write Checkout Sessions | create sessions that pay **us**. Annoying, not a loss. |
| An unrestricted `sk_` (**do not use one**) | refunds, payouts, customer data — the whole account. This is why the scope, not the storage, is the control that matters. |

What actually protects it:

| Layer | Status |
|---|---|
| **SEV-SNP confidential subnet** | The deployment target. Confidentiality rests on hardware and attestation, not on cryptography in the canister. |
| **Checkpoint / state-sync confidentiality** | **Must be verified separately.** Memory encryption does not cover state written to disk and state-synced between nodes. If those are not also confidential, a plaintext secret leaks through that path. |
| **Provisioning channel** | Known-exposed: the argument to `set_webhook_secret` / `set_stripe_api_key` transits the TLS-terminating boundary node as ordinary ingress. Treat the first set over any untrusted path as burned and rotate. |
| **Reserve size** | The always-on control, independent of SEV. A forger drains at most what the reserve holds, so it is sized to what a leak could cost. |

Interface (`Main.mo`):

- `set_webhook_secret(text)` — controller-only, traps otherwise. Rejects under
  16 bytes and leaves a working secret untouched on rejection, so a
  fat-fingered rotation cannot brick the webhook. Pass the **whole `whsec_…`
  string**, prefix included — that is the HMAC key.
- `set_stripe_api_key(text)` / `set_stripe_origin(text)` — same posture. The
  origin is validated at set time: https, no query, no fragment.
- `webhook_secret_status()` / `stripe_api_key_status()` — `{isSet, generation, setAtNs}`. **There is no
  read-back path, not even for controllers.** `generation` increments per
  successful set, which is how ops confirms a rotation landed.

If the signing secret leaks, an attacker can forge "paid" webhooks and drain
cycles at operator expense — bounded by the reserve balance, detectable by reconciling
against Stripe's event log (forged payments have no matching `payment_intent`
there), and recoverable by rotation. Customers and cardholder data are untouched
either way; with a restricted key, so is the Stripe account. See `RUNBOOK.md` §2
for the leak procedure — **cap to 0 first**, then rotate.

Rotation needs no dual-secret window here: while a rolled Stripe signing secret's
predecessor is still live, Stripe sends one `v1=` per active secret and
`Card.verify` accepts any single match, so swapping the stored blob at any point
during the overlap never drops a delivery.

> This is a deliberate departure from `canister-security` pitfall 9 ("never store
> secrets in canister state"). The reasoning above is the justification; do not
> "fix" it without reading it.

## 14. Operator surface

Card-rail levers, all controller-gated (`Auth.mo`, flat allowlist, equal
privileges — any controller can do any of this):

| Method | Purpose |
|---|---|
| `set_stripe_api_key` | provision / rotate the restricted `rk_` key (§13) |
| `set_stripe_origin` | where Stripe returns the buyer; https, no query, no fragment |
| `set_webhook_secret` | provision / rotate the signing secret (§13) |
| `webhook_secret_status` / `stripe_api_key_status` | confirm a rotation landed, without reading either secret back |
| `set_card_tiers` | register the preset amounts. Since #33 an empty vector shows no tiles and does **not** disable the rail — the switch is both Stripe secrets |
| `set_gate_config` | open-order cap, own-cycles floor, per-purchase ceiling |
| `set_pricing_config` | fee formula, staleness window (capped at 1 h), delta bound, minimum rate sources |
| `refresh_rates` | force a rate tick now instead of waiting for the timer |
| `set_delivery_config` | the two delivery time bounds: alert-after (2 h) and max hold (72 h) |
| `error_queue` / `resolve_error` | the operator worklist |
| `order_for_payment` | reconciliation: Stripe charge → order it funded |
| `delivery_journal` | money-out record for one order |
| `audit_log` | operational trail; gaps in `seq` mean ring-buffer drops |
| `process_order` | manual delivery kick; safe to spam. **Admin or the order's own owner** |
| `abandon_order` | void an unpaid order, with the reason recorded in the audit trail |
| `record_delivered` | record that an escalated order's cycles DID reach the buyer, evidenced by the ledger block |
| `pending_deliveries` | every delivery with work outstanding right now, self-clearing — the live view the 2 h queue alert cannot give |
| `refresh_reserve` | observe the reserve balance now — **required after a top-up**, or the gateway sells nothing |
| `recount_orders` | rebuild the O(1) per-status counters from the store |
| `set_recovery_interval` | sweep cadence; bounded above at a quarter of the ledger's dedup window |
| `set_expected_livemode` | pin test-vs-live so a mismatched webhook is refused rather than honoured |

⚠️ **This table is the whole admin surface, and there is deliberately no lever that
moves money.** No method mints, transfers on demand, refunds, or withdraws — funding
the reserve is `icp cycles transfer` from the operator's own identity, outside the
canister. `record_delivered` records a *fact about the ledger*, it does not send.

Public queries (transparency is the product thesis): `card_tiers`,
`pricing_status`, `quote_previews`, `recovery_status`, `lifecycle_config`,
`reserve_status`, `can_purchase`, `cycles_status`, `error_queue_depth`,
`stripe_origin`, `expected_livemode`, `health`.

**Owner-scoped, not admin-scoped:** `get_order`, `list_orders`, `cancel_order`,
and `receipt(orderId)` answer only for `caller == order.owner` — not even a
controller can read someone else's receipt. The receipt returns the paid amount,
the cycles-ledger block the delivery landed in, the cycles delivered, and both rate inputs
with their XRC quality signal, so a buyer can recompute
`netCents × xdrPermyriadPerIcp × 10¹² / usdPerIcpMicros` from canisters they
query themselves and confirm they were charged correctly.

### Stripe setup

**There are no Dashboard objects to create for this rail** — no Products, no
Prices, no Payment Links. The session carries inline `price_data`, so the amount
is pinned by the request rather than by a link's configuration.

1. Create a **restricted API key** (`rk_...`) scoped to write Checkout Sessions
   and nothing else, and provision it with `set_stripe_api_key`. Not an `sk_`:
   §13 covers why the scope matters more than the storage.
2. `set_stripe_origin` — where Stripe returns the buyer, and the origin the
   session's `success_url`/`cancel_url` are built from.
3. Create a webhook endpoint pointing at
   `https://<canister-id>.icp0.io/webhook/stripe`, subscribed to
   **`checkout.session.completed`**, **`checkout.session.expired`**,
   **`charge.refunded`** and **`charge.dispute.created`**.
   ⚠️ `checkout.session.expired` is not optional: it is the *only* thing that
   expires an order and releases its reserve promise (§10).
4. Copy the endpoint's signing secret into `set_webhook_secret`. Provisioning the
   key and this secret is what **opens** the rail, so do it last.
5. Optionally register price tiles with `set_card_tiers` — a buyer can type any
   amount within the gate's bounds without them.
6. **Fund the reserve** with `icp cycles transfer <backend-id> --amount <N>t`, then
   `refresh_reserve` so the gate has an observation. Until it does, every order is
   refused with `#reserveShort` — the reserve is the stock being sold, and nothing
   in the canister can create it.
7. Optionally tune the delivery bounds with `set_delivery_config`; the defaults
   (2 h alert, 72 h max hold) are the intended production values.
8. Record the account's **Stripe API version** and treat changing it as a code
   change: webhook payload shapes follow the account default.

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
a local network *can* run the whole good path, including the real cycles-ledger
delivery, with local cycles and no mainnet.

Two further caveats:

- `stripe trigger` builds a *synthetic* session with **no
  `client_reference_id`**, so it lands as `#unattributed` — which is
  itself a useful test. To exercise the happy path, create a real order through
  the app and pay the URL it returns (`order.stripeSessionUrl`) with test card
  `4242 4242 4242 4242`. There is nothing to append: the canister already set the
  reference on that session.
- The canister compares the signature timestamp against **its own clock**. A
  local replica whose time has drifted more than 300 s from real time will
  reject every live webhook with a 400.

For deterministic coverage without Stripe in the loop, the PocketIC suite crafts
its own HMAC-signed payloads (`test/integration/src/harness.ts`) — that is the
go-live bar, and it does not need network access or an account.
