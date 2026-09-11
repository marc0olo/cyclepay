# Demo playbook

The running order for a recorded walkthrough, for an audience that knows the IC. The
operational setup is **already done** on the live deployment, so it is narrated rather
than performed: the demo is the buyer's flow, with the interesting mechanics explained at
the point they happen. Closes #100.

```
backend  saz2a-riaaa-aaaay-aadha-cai      frontend  shy4u-4qaaa-aaaay-aadhq-cai
subnet   re2t4-… (confidential, 7 nodes)  divisor   1000 (simulation)
```

⚠️ **Before recording:** `unset STRIPE_API_KEY STRIPE_WEBHOOK_SECRET`, and keep
`scripts/.local-dev.env` off screen. Both secrets are unreadable from the canister, so the
only place they can leak is your terminal.

## 1. What CyclePay is

Buy cycles with a credit card. No wallet, no exchange account, no ICP to hold first.
One canister does pricing, payment, delivery and the audit trail; there is no server.

## 2. What an operator had to set up (narrate, already done)

- **Deploy to a confidential SEV-SNP subnet.**
- **A Stripe sandbox, and a restricted API key** scoped to Checkout Sessions = Write and
  nothing else. A leaked write-sessions key can only create sessions that pay *us*.
- **A webhook endpoint in Stripe**, which is how Stripe tells the canister what happened
  (payment completed, session expired).
- **Both secrets set on the backend**, sealed with vetKeys: the client derives the
  canister's public key offline and encrypts to it, so no plaintext ever appears in an
  ingress message, a shell history or a CI log. The canister decrypts and holds the
  plaintext in its heap.
- **Fund the cycles reserve** by transferring cycles to the canister's own cycles-ledger
  account.

⚠️ **Say the whole thing, because this audience will press on it.** SEV-SNP encrypts
memory, **and** checkpoint-to-disk and state-sync between nodes are confidential on this
subnet too — which is the part that matters: either one in the clear would leak the
plaintext and make SEV worthless. That was the spec's "verify this hardest" item and it is
closed. Still open, and worth saying if asked: **attestation coverage**, since one
unattested replica is one node provider who can read the secret. And the control that does
not depend on SEV at all is the **reserve size**, which bounds what any leak could cost.

## 3. Simulation mode

Real card charge in Stripe's sandbox, real exchange-rate arithmetic, **cycles divided by
1000**. One number does it: `pricing_status().config.divisor`.

- A principal must be **allow-listed by a controller** (not a delegated admin —
  `add_allowed_buyer` is `requireController`) before it can buy. Test payments are free
  and unlimited, so without that list a funded gateway is a faucet, and it refuses to
  sell in that state rather than warning.
- The reserve was funded with **1 T**, and one demo purchase already ran end to end
  before this recording — visible as `totalOrders` and a floor that has moved.

## 4. The buying flow

**Pick an amount.** Three presets, or a custom amount between $10 and $100.

**The quote, before committing.** The buyer sees the cycles they will get and the
processing fee (2.9% + 30¢) up front. Two rates feed it:

| | source | supplies |
|---|---|---|
| ICP/USD | Exchange Rate Canister | `usdPerIcpMicros` |
| XDR/ICP | Cycles Minting Canister | `xdrPermyriadPerIcp` |

Both refresh on a timer, never on demand — no caller can drive our XRC spend.

⚠️ **Worth 15 seconds for this audience: ICP cancels.** Both rates are *per ICP*, so the
quotient is XDR per USD and the ICP price drops out. **A cycle is XDR-pegged**, and the
gateway carries no ICP exposure per order. The implied rate can be checked against the
IMF's published SDR rate on screen, which is the strongest claim the demo can make,
because the number is not ours.

**Creating the order** does two things:

1. **Locks the terms and reserves the cycles**, so the promised quantity can always be
   delivered. Admission is decided against `floor − promised` with no ledger call on the
   hot path.
2. **Creates a Stripe Checkout session via HTTPS outcall**, with the order id as the
   `Idempotency-Key` so a retried outcall cannot create a second session.

**After payment, Stripe calls the canister's webhook.**

```
Stripe → POST /webhook/stripe → http_request_update (an UPDATE call, through consensus)
       → verify HMAC → dedup on event id → deliver → mark delivered
```

⚠️ **This is the security crux.** The endpoint is public and the caller is **anonymous** —
the boundary node terminates TLS, so nothing about the transport authenticates Stripe.
HMAC over the request body with the signing secret is the **entire** trust root, which is
why that secret must never leak: whoever holds it can sign a completed-payment event for
an order they created and be delivered cycles having paid nothing.

**Delivery is a plain `icrc1_transfer` on the cycles ledger** to the buyer's principal —
spendable cycles, not a canister top-up.

## 5. Using the cycles

The page walks the buyer through linking their browser identity to `icp-cli`, so the CLI
acts as the same principal the cycles were delivered to, and `icp deploy` just works.

## 6. Close on the evidence

- **The admin audit log in the app** — every operator action and every audited read.
- **The Stripe dashboard**, including the webhook events it sent and their delivery
  status, so both sides of the boundary are visible.

## If asked

- **"Where do the card details go?"** Stripe's hosted Checkout. They never touch this
  system.
- **"What if delivery fails?"** The order does not silently die: a paid order that has not
  delivered escalates to the operator worklist, and the recovery sweep asks Stripe about
  orders stuck past their deadline. The principle is *stop taking on new obligations,
  leave every path that discharges existing ones open*.
- **"`availableToSell` looks wrong."** It stays in **real** cycles while quotes are
  scaled, because only the promise is scaled. And the floor only rises by observation, so
  a ledger balance above `availableToSell` means a top-up nobody ran `refresh_reserve` for.
- **"Can a controller steal the reserve?"** Yes — every controller can upgrade the
  canister, so "upgrade-then-drain" holds. The hardening path is a multisig canister as
  *sole* controller, because IC controllers are OR-semantics.
