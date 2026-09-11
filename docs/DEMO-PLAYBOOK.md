# Demo playbook: the checkout, and what runs under it

For an audience that knows the IC. The interesting parts are not "a card form works" but
**where the trust boundaries sit**, **how a cycle quantity is derived**, and **what the
reserve accounting guarantees when a step fails**. Closes #100.

Anchored on the live mainnet deployment:

```
backend    saz2a-riaaa-aaaay-aadha-cai      frontend   shy4u-4qaaa-aaaay-aadhq-cai
subnet     re2t4-… (confidential, 7 nodes)  divisor    1000 (simulation)
```

## Before recording

⚠️ **Nothing on screen may show a secret.** Both Stripe values are sealed and unreadable
from the canister, so the risk is your terminal: `scripts/.local-dev.env`, shell history,
and any `export`. `unset STRIPE_API_KEY STRIPE_WEBHOOK_SECRET` in the recording shell.

Check the starting state so the numbers you narrate are the ones on screen:

```bash
icp canister call backend reserve_status  '()' -e ic     # availableToSell, promisedTotal
icp canister call backend pricing_status  '()' -e ic     # the two rates, and the XRC id
icp canister call backend card_tiers      '()' -e ic
icp canister call backend refusal_counts  '()' -e ic     # every refusingNow flag false
```

Have a second terminal for the audit trail; it is the narration device for acts 3 and 4:

```bash
icp canister call backend audit_log_recent '(null, 10 : nat)' -e ic
```

## Act 1 — the surface, 60 seconds

Show the buy view and the simulation banner. Say the one thing that frames everything
after it: **the card charge is real in Stripe's sandbox, and the cycles delivered are
1/1000 of what the same purchase buys in production.**

Point out what is *absent*: no wallet, no ICP, no exchange account, no separate token.
A buyer signs in with Internet Identity and pays with a card.

⚠️ Worth saying explicitly for this audience: **the browser never holds a controller key.**
Operator actions are copy-paste `icp canister call` commands rendered by the console with
arguments pre-filled from the row you are looking at. The page reads; the terminal writes.

## Act 2 — the price, derived on screen

The deepest part, and the part most likely to surprise. Show `quote_previews`:

```bash
icp canister call backend quote_previews '(vec { 1_000 : nat })' -e ic
```

Then derive it. Two integer steps, no floats anywhere:

```
1.  net = gross − (ceil(gross × feeBps / 10_000) + feeFixedCents)
       = 1000 − (ceil(1000 × 290 / 10_000) + 30)  =  941 cents

2.  cycles = net × xdrPermyriadPerIcp × 10^12 / usdPerIcpMicros
           = 941 × 20_272 × 10^12 / 2_802_299  =  6.806 T

3.  / divisor (1000)  =  6.806 G       ← what a $10 purchase locks here
```

⚠️ **The headline point: ICP cancels.** Both rates are *per ICP* —
`xdrPermyriadPerIcp` from the CMC, `usdPerIcpMicros` from the XRC — so the quotient is
XDR per USD and the ICP price drops out entirely. **A cycle is XDR-pegged** (1 T = 1 XDR),
so this gateway carries no ICP price exposure per order. Derive the implied rate live:

```
2.0272 XDR/ICP ÷ $2.8023/ICP  =  0.7234 XDR/USD  →  1 XDR = $1.3823
```

Cross-check it against the IMF's published SDR rate on screen. They will agree to well
under a percent, and that agreement is the demo's strongest claim: the price is not ours.

**Two rate sources, and why both:**

| | canister | supplies |
|---|---|---|
| XRC | `uf6dk-hyaaa-aaaaq-qaaaq-cai` | USD/ICP, from 8 exchange sources |
| CMC | `rkp4c-7iaaa-aaaaa-aaaca-cai` | XDR/ICP, the protocol's own conversion rate |

`minRateSources = 2` rejects a quote built on one exchange, and
`plausibleImpliedXdrPerUsd` cross-checks the *pair*: two individually fresh rates that
disagree about XDR/USD are refused rather than averaged. Show `pricing_status.quality`
(`queriedSources`, `receivedRates`).

⚠️ **Rates refresh on a TIMER, never on demand** — `maxAgeNs / 2`, so 150s here. No
user-facing method can trigger an XRC call, so no caller can drive our cycle spend. The
cost is that a live gateway pays continuously, which is why `railsLive()` gates the timer:
a gateway with no secrets provisioned spends nothing. That is also why a fresh deployment
shows `xrcCanisterId = null` — it has never asked.

## Act 3 — the Stripe leg, and where the trust boundary is

Two directions, and they are not symmetric.

**Outbound: session creation is an HTTPS outcall.**

```
create_order → Gate.admit → Pricing.quote → HTTPS outcall to api.stripe.com
             → session id + URL stored on the order → buyer redirected
```

Points worth making:

- The restricted key is **Checkout Sessions = Write and nothing else**. A leaked
  write-sessions key can only create sessions that pay *us*; one that could issue refunds
  is a different class of problem.
- `Idempotency-Key` is the **order id**, so a retried outcall cannot create a second
  session for one order. On the IC an outcall can be retried by the platform, so this is
  not belt-and-braces.
- `max_response_bytes` is pinned, because an outcall is charged on the *reserved* size.
- The session pins `payment_method_types[]=card` and `mode=payment` with inline
  `price_data`. What is **absent** is what makes `amount_total == usdCents` hold — no
  coupons, no tax, no adjustable quantity. `test/session.test.mo` asserts their absence.

**Inbound: the webhook is an ingress message to the canister.**

```
Stripe → POST https://saz2a-….icp.net/webhook/stripe
       → boundary node → http_request_update  (an UPDATE call, through consensus)
       → verify HMAC → dedup on event id → route
```

⚠️ **This is the part an IC audience will want**: the POST lands on
`http_request_update`, so it is replicated and consensus-backed, not a query. And the
caller is **anonymous** — the boundary node terminates TLS, so nothing about the transport
authenticates Stripe. **HMAC-SHA256 over `timestamp.body` with the signing secret is the
entire trust root**, which is why that secret is the most dangerous value in the system:
whoever holds it can sign a `checkout.session.completed` for an order they created and
have cycles delivered having paid nothing.

Show the six subscribed events and name the one that is load-bearing and least obvious:
**`checkout.session.expired` is the only event that moves an order to `#expired` and
releases its reserve promise.** Unsubscribed, orders sit `#created` past their deadline
for ever — and a stuck `#created` order is the signal the design uses to detect a broken
gateway, so the omission poisons its own alarm.

**The secrets themselves never travelled in the clear.** Both are vetKD-sealed: the
provisioning script derives the canister's IBE public key *offline* from a master public
key plus the canister id, encrypts to it, and sends ciphertext. No plaintext in an ingress
message, a shell history, or a CI log. Mainnet and a local network both call their key
`key_1` and are backed by different master keys, so the script derives the choice from the
environment rather than accepting it as a flag — sealing against the wrong one produces a
ciphertext nobody can ever open, and nothing detects it until the canister tries.

## Act 4 — cycles distribution, and what survives a failure

This is the accounting act. Run the purchase, then show the audit trail beside
`reserve_status`.

**Delivery is an `icrc1_transfer` on the cycles ledger** (`um5iw-rqaaa-aaaaq-qaaba-cai`)
from the gateway's own account to the buyer's principal. Not a canister top-up: the buyer
receives *spendable* cycles, which is what makes `icp canister create` work for them
afterwards.

**The reserve is a maintained lower bound, not a balance.** Three rules, and the reason
each one is where it is:

| when | what moves | why |
|---|---|---|
| order created | `promisedTotal += lockedCycles` | admission is decided synchronously against `floor − promised`, with no ledger call on the hot path |
| transfer **issued** | `floor -= amount + fee` | decremented *before* the await, by the figure actually debited. If our reply callback traps, the ledger's debit stands while the journal patch rolls back — so erring early is erring safe |
| definitive rejection (`#BadFee`) | `floor += debited`, then re-issue | the ledger processed and refused, so nothing moved. A rejection with *no reply* keeps the larger decrement, deliberately |

⚠️ So `availableToSell = floor − promised` **understates** the balance by design, and the
floor only rises by observation (`refresh_reserve` or the hourly sweep). **The ledger
reading 1 T while `availableToSell` reads 0 is the expected appearance of a top-up nobody
observed** — a good live demonstration, and the single most common operational confusion.

Show the three balances and name them, because conflating them is the classic error:

```
gas     the canister's own cycles          icp canister status backend -e ic
stock   the reserve it sells               icp cycles balance --of-principal saz2a-… -n ic
yours   the operator's ledger account      icp cycles balance -n ic
```

**What happens when delivery fails.** Worth showing because it is the part a demo usually
skips: the order does not silently die. A paid order that has not delivered past
`maxHoldNs` escalates to `#needsReview` and appears on the operator worklist; the recovery
sweep asks Stripe about `#created` orders past their deadline and settles them; every
admin read of one buyer's order is itself audited. The design principle to state: **stop
taking on new obligations, leave every path that discharges the existing ones open** —
which is why the own-gas floor gates *admission* only, and `cancel_order`,
`withdraw_reserve` and every admin setter keep working below it.

## Act 5 — simulation mode is one number

```bash
icp canister call backend pricing_status '()' -e ic     # config.divisor = 1_000
```

**There is deliberately no second boolean.** The mode signal, the banner and the receipt's
extra terms all key off `divisor`, because two places answering "are we simulating?" could
disagree. `divisor == 1` makes the arithmetic bit-identical to having no divisor at all.

The four guards, and what each prevents:

| guard | prevents |
|---|---|
| `divisor > 1` requires `expected_livemode == ?false` **exactly** | real money in, scaled cycles out. `null` means *either mode* and is the fresh-install default |
| `set_expected_livemode` refuses anything but `?false` while `divisor > 1` | the same state from the other direction. Mutual, so no ordering reaches it |
| a divisor **change** is refused once any order is stored | earlier receipts would recompute against the new divisor and each report a mismatch. Reinstall to change it |
| a scaled quote must clear the ledger fee **ten times over** | the one delivery state with no recovery lever: a flat fee above a whole order's locked quantity means nothing reaches the ledger, so no `#BadFee` ever arrives to correct the stored copy |

⚠️ **Do not scale at delivery.** The floor decrements at issue by the full locked amount,
so a scaled transfer against an unscaled decrement would surface as an unexplained
shortfall on every reconcile — the one signal that means an outflow we did not cause.

Two things to call out because they look wrong on screen:

- **`availableToSell` stays in REAL cycles while quotes are scaled** (only `promised` is
  scaled), so it can read 993 G while $10 buys 6.8 G.
- **The receipt shows both legs.** `checkReceipt`'s `recomputed` stays the *unscaled*
  quantity, recomputed from the two rate inputs the order carries — so a simulation receipt
  states what production would have locked, the divisor, the locked quantity and the ledger
  fee: four numbers that reconcile.

## Closing: what is on-chain and what is not

Say it plainly, because it is the question this audience will ask:

- **On-chain:** pricing, admission, the order store, the reserve accounting, session
  creation, webhook verification, delivery, the audit trail. One canister, no server.
- **Not on-chain:** the card details, which never touch this system — the buyer is
  redirected to Stripe's hosted Checkout. Stripe is the payment processor and the trust
  assumption; HMAC over the webhook body is the only thing that carries its authority
  across the boundary.
- **The honest trust model:** every controller can upgrade the canister, so "any
  controller can upgrade-then-drain" holds. The hardening path is a multisig canister as
  *sole* controller, because IC controllers are OR-semantics.

## A 10-minute cut

| | act | minutes |
|---|---|---|
| 1 | the surface, and the simulation banner | 1 |
| 2 | the price derived, and ICP cancelling | 3 |
| 3 | both Stripe directions, and the HMAC trust root | 3 |
| 4 | the reserve's three rules, live against the audit trail | 2 |
| 5 | the divisor and its four guards | 1 |
