# Demo playbook

A speaker's outline for a recorded walkthrough of the **payment flow**. Setup is already
done on whatever deployment you show, so it is narrated, not performed.

## Before recording

- ⚠️ **No number is written in this file** — read them off the screen. An earlier version
  put the reserve balance and the order count in prose and both were wrong within three
  days, on the two screens the demo points at.
  ```bash
  icp canister call backend pricing_status '()' -e ic   # divisor: 1 is live, >1 simulation
  icp canister call backend reserve_status '()' -e ic   # availableToSell, totalOrders
  ```
- ⚠️ `unset STRIPE_API_KEY STRIPE_WEBHOOK_SECRET`, and keep `scripts/.local-dev.env` off
  screen. The canister cannot leak them; your terminal can.
- ⚠️ **One open order per principal.** Cancel every rehearsal order, or the next one is
  refused until Stripe expires the session (~35 min).

## Goal

- Let a customer **buy cycles with a credit card** — from a card to spendable cycles,
  without solving crypto onboarding first. No wallet, no exchange account, no ICP to hold.

## The application

- Runs **entirely on ICP**: one Motoko backend canister, one certified-assets frontend.
  No server.
- **No external dependency but Stripe.** Pricing reads two *canisters*, not an HTTP
  oracle.
- **Both canisters run on a confidential SEV-SNP subnet.**

## Roles

### Operator

- **Funds the cycles reserve** the gateway sells from — the canister's own account on the
  cycles ledger, not its gas balance.
- **Provisions the two Stripe secrets**, sealed with vetKeys — encrypted offline to a key
  derived from the canister's id, so no plaintext reaches an ingress message, a shell
  history or a log.
- **Allow-lists customers** while the gateway takes sandbox payments.

### Customer

- Creates an order, pays on Stripe's hosted page.
- Receives cycles on the cycles ledger, **to the principal the signed-in page shows**.

### Backend canister

- Quotes and **locks the cycle quantity**, and reserves it so a paid order can always be
  delivered.
- Verifies the webhook, then **delivers cycles** — one `icrc1_transfer` out of its own
  cycles-ledger account.
- Writes an audit line for every Stripe event it acts on.

## The demo

Open the page, show the balance and the completed-order count on screen, then narrate one
live purchase:

1. **Pick the amount.** The quote shows the cycles and the processing fee before
   committing. The USD→cycles rate comes from two on-chain sources: **USD/ICP** from the
   Exchange Rate Canister and **XDR/ICP** from the CMC.
2. **Create the order.** Locks the quote, reserves the cycles, and makes an **HTTPS
   outcall** to Stripe for a Checkout Session. Stripe's deadline is ~35 minutes.
3. **Pay.** Card details go to Stripe's page and never touch this system.
4. **Stripe calls the webhook** — `http_request_update`, an *update* call, so it goes
   through consensus.
5. **The canister verifies the HMAC** against the Stripe signing secret, then **transfers
   the cycles** to the customer's principal.

- ⚠️ **Step 5 moves cycles, never fiat.** The money stays at Stripe; this canister
  custodies none of it.
- ⚠️ **The HMAC is the entire trust root.** The endpoint is public and the caller is
  anonymous — the boundary node terminates TLS, so nothing about the transport
  authenticates Stripe. Whoever holds that signing secret gets cycles for free, which is
  why the reserve balance is the blast radius and why the secret is sealed rather than
  pasted.
- ⚠️ **ICP cancels out of the price.** Both rates are *per ICP*, so a cycle is XDR-pegged
  and the gateway holds no ICP. Cross-checkable against the IMF's published SDR rate.

## Considerations

- **Running out of cycles.** The gate refuses the order **before the customer pays**, so
  no money is taken for cycles that cannot be delivered. A promise is held from creation,
  so a paid order is always deliverable.
- **An expired session.** Stripe tells the canister, the order is marked expired, and the
  reserved cycles go back to what is sellable.
- **A dispute.** One audit line — *reconcile in Stripe; cycles cannot be recovered* — and
  no automated response, deliberately: the cycles are delivered and irreversible while the
  card network pulls the fiat back. The operator sees it happened and reconciles in the
  Dashboard. A **refund** is different: it files an obligation on the order.
- **Anything unexpected.** Every Stripe event the canister acts on is audited, so an
  order in a state nobody expected is visible to the operator — who can check the
  Dashboard and refund if that is the right answer.
- **This is a demo.** You must be **allow-listed** — sandbox payments are free, so an open
  list on a funded gateway would be a faucet, and it refuses to sell in that state rather
  than warning. Cycles are divided by the divisor, quote and delivery alike.

## Try it

- Send me **the principal the signed-in page shows you** and I will allow-list it.
  Internet Identity derives one per origin, so a principal copied from another app is a
  different account.
- The rest is in the repo: [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md) for the diagram,
  [`docs/VERIFY.md`](./VERIFY.md) for what anyone can check and what they cannot.
