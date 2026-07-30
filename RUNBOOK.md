# Operations runbook

Day-2 operations for the cycles gateway: provisioning, money levers, error
triage, incident response. Build/upgrade/verify procedure lives in
`RELEASE.md`; design rationale in `design-docs/ONCHAIN_GATEWAY_SPEC.md`
(spec v2.1 — section references below are to it).

## 0. Operating model

**The admin allowlist IS the canister controller set** (§7): every admin
method runs `requireAdmin`, which accepts exactly `caller ∈ controllers`
(anonymous always rejected, even if `2vxsx-fae` were a controller) and
**traps** otherwise — an unauthorized call never looks like a handled error.
All controllers are equal: any one can upgrade, withdraw, rotate the secret,
resolve errors, change every config. That is the honest trust model
("any controller can upgrade-then-drain"); the hardening path is a
multisig canister as *sole* controller (IC controllers are OR-semantics, so
true M-of-N requires it) or SNS — see §11.

Edit the controller set with canister settings, not app code:

```bash
icp canister settings update backend --add-controller <principal> -e ic
icp canister status backend -e ic        # lists current controllers
```

**Calling convention** for everything below (admin calls must use a
controller identity — never anonymous):

```bash
icp canister call backend <method> '(<candid args>)' -e ic --identity <operator>
```

**Always pass an explicit `'()'` for zero-argument methods.** Omitting the
argument makes `icp canister call` ask *"Do you want to send this message?
[y/N]"* and read stdin — which hangs any script, cron job, or CI step.

Public queries (`treasury_status`, `forex_status`, `recovery_status`,
`card_tiers`, `ck_usdc_config`, `lifecycle_config`, `retention_status`,
`can_purchase`, `was_swept`, `health`) work from any identity and are the
monitoring surface (§9 transparency stance — operational state is public,
the webhook secret is the only secret in the system).

**Units used throughout:** ICP amounts are e8s (1 ICP = 10⁸ e8s); ck-USDC
amounts are units (1 USDC = 10⁶ units, so 1¢ = 10⁴ units); durations are
nanoseconds (1 h = `3_600_000_000_000`, 24 h = `86_400_000_000_000`,
72 h = `259_200_000_000_000`); cycle prices are XDR-pegged (1 XDR = 1 T
cycles).

## 1. Go-live checklist (fresh deployment)

Everything money-touching **fails closed by default** — a freshly deployed
gateway accepts no orders and mints nothing until each lever below is
consciously set. Work the list in order:

1. **Deploy + verify** per `RELEASE.md` (module hash gate).
2. **Fund the ICP float**: send ICP to the backend's default ICRC-1 account
   (`owner = <backend canister id>`, no subaccount). Confirm with
   `refresh_float` (returns the observed e8s).
3. **Provision the webhook secret** (§2 below). Until set, the webhook
   route answers 503 and Stripe retries.
4. **Register card tiers** (§3 below). Until set, the tier list is empty
   and no card order can be created.
5. **Size the burn cap** (§5 below). Until raised from the default 0,
   every mint holds in `awaitingTreasury` — cap 0 is the pause lever.
6. **Arm the low-float alert**: include a non-zero `lowFloatThresholdE8s`
   in the same `set_treasury_config` call.
7. **(Optional) enable the ck-USDC rail** (§7 below). Default
   `maxUsdCents = 0` keeps it disabled.
8. **Configure the Stripe webhook endpoint**: in the Stripe Dashboard, add
   a webhook destination `https://<backend-canister-id>.icp0.io/webhook/stripe`
   sending exactly the events `checkout.session.completed` and
   `charge.refunded`. (Other event types are acked and ignored.)
9. **Review the admission gate** (§5a below). The defaults are non-zero and
   usable, but `maxPurchaseUsdCents` should sit just above your largest tier,
   and `minCanisterCycles` should suit how closely you monitor this canister.
10. **Raise the freezing threshold.** This canister holds money-bearing state,
   so the 30-day default is thin — losing it to a cycle drain destroys the
   order store, journals, and dedup sets:
   ```bash
   icp canister settings update backend --freezing-threshold 7776000 -e ic  # 90 days
   ```
11. **Add a backup controller.** A single controller identity with no backup
   means a lost key makes the canister permanently un-upgradeable; there is no
   recovery path (§0 covers the trust model this implies).
12. **Smoke-check the public surface**: `forex_status` (rate populates on
   the first order attempt — creation before the first successful refresh
   correctly answers `rateUnavailable`), `treasury_status`,
   `recovery_status` (sweep timer armed), `card_tiers`,
   `can_purchase '(<your smallest tier's cents>)'` — the last one should
   answer `ok` before you announce the service.

## 2. Webhook secret — provisioning & rotation (§7)

The Stripe signing secret is the **only stored secret**: HMAC is symmetric,
so verify = forge — anyone holding it can mint cycles at operator expense
until the burn cap stops them. It is stored **plaintext by design**
(`Secret.mo` documents the SEV-SNP posture; §10 below is the checklist).

**Provision / rotate:**

```bash
icp canister call backend set_webhook_secret '("whsec_…")' -e ic --identity <operator>
icp canister call backend webhook_secret_status '()' -e ic --identity <operator>
```

- Pass the **full `whsec_…` string** from the Stripe Dashboard — the whole
  string, prefix included, is the HMAC key (matches Stripe's reference
  verifiers).
- `set` rejects anything under 16 bytes (`#tooShort`) and leaves the
  working secret untouched on rejection — a fat-fingered rotation can't
  brick the webhook.
- `webhook_secret_status` returns `{isSet; generation; setAtNs}` —
  `generation` increments per successful set, so ops can confirm a rotation
  landed **without any read-back path existing** (not even for
  controllers).

**Rotation procedure** (Stripe-side overlap makes it zero-downtime):

1. In the Stripe Dashboard, roll the endpoint's secret with an overlap
   window. During overlap Stripe signs each delivery with **one `v1=` per
   active secret**, and the canister's verifier accepts *any* matching
   `v1` — so order of operations is forgiving.
2. `set_webhook_secret` with the new `whsec_…`; confirm `generation`
   bumped.
3. Expire the old secret in Stripe after confirming deliveries succeed.

**Provisioning exposure** (§7): the argument transits the TLS-terminating
boundary node as ordinary ingress. Provision from a trusted network path,
and treat the first secret set over any untrusted path as burned — rotate
it once the endpoint is confirmed working.

**Suspected leak — immediate actions** (in this order):

1. Pause minting: `set_treasury_config` with `burnCapE8s = 0` (§5). The
   cap is the blast-radius bound — this stops the drain even while forged
   webhooks keep arriving.
2. Roll the secret in Stripe + `set_webhook_secret` (steps above).
3. Reconcile: compare `audit_log` / order store against the Stripe
   Dashboard's event log; forged "payments" have no matching Stripe
   payment_intent. Refund nothing that has no real charge.
4. `reset_burn_window`, restore the sized cap, and let held legitimate
   orders resume on the next sweep.

## 3. Card tiers & Payment Links (§3, §6.1)

The canister never calls Stripe. Controllers create **permanent Payment
Links** in the Stripe Dashboard (one per price point, USD) and register
them:

```bash
icp canister call backend set_card_tiers \
  '(vec { record { id = "t10"; usdCents = 1_000; paymentLinkUrl = "https://buy.stripe.com/…" } })' \
  -e ic --identity <operator>
```

Validation is atomic — non-empty unique ids, non-zero amounts, every amount
within `maxPurchaseUsdCents` (§5a), or the whole call rejects and the live tier
list is untouched. `card_tiers` is the public
query the frontend renders. Setting an **empty vector disables card order
creation** (the rail-level pause lever; in-flight orders are unaffected).

Note the §3 invariant: a tier's *cycle* quantity is locked per-order at
creation time from the live forex rate; changing tier prices never reprices
existing orders. The actual paid amount is honored — a Stripe-side price
edit mid-flight reprices from the order's own creation-time snapshot, never
from a fresh rate.

## 4. Forex (§3.1)

```bash
icp canister call backend forex_status '()' -e ic   # public: cached rate + config
icp canister call backend set_forex_config \
  '(record { url = "https://open.er-api.com/v6/latest/USD"; feeBps = 290; feeFixedCents = 30; maxAgeNs = 3_600_000_000_000 })' \
  -e ic --identity <operator>
```

Defaults: `open.er-api.com` (keyless — a keyed API would be a second
node-provider-readable secret), 290 bps + 30¢ (Stripe's fee, recovered
net-of-fees per §3), 1 h staleness window. Validation: `feeBps < 10_000`,
positive window, https-only.

**Failure mode is fail-closed and self-healing**: a stale cache triggers a
lazy refresh on the next `create_order`; if the refresh fails (or another
is already in flight), creation answers `rateUnavailable` and **no money
moved** — there is nothing to clean up. Persistent `rateUnavailable` means
the rate source is down or blocked: check `forex_status.rate` timestamp,
try the URL yourself, and point `url` at another USD-base source whose JSON
carries an `"XDR"` key if the outage persists. The plausibility band
(0.1–10 XDR/USD) and coarse rounding are not configurable — a source
serving implausible values is rejected as if down.

## 5. Treasury: float, burn cap, holds (§5.3)

**Status (public):** `treasury_status` returns
`{config; burnedInWindowE8s; lastObservedFloat; lowFloat; heldOrders}`.
The float observation is as-of `atNs` (it refreshes as a side effect of
every mint pre-gate); `refresh_float` (admin) forces a fresh ledger read.

**Float refill** is a plain ICP transfer to the backend's default account —
no method call needed; the next pre-gate or `refresh_float` observes it,
and held orders resume on the next sweep (≤ 1 sweep interval) or
immediately via `process_order`.

**Burn cap** — the §7 blast-radius bound. Per rolling window, the gateway
refuses to *start* mints once the window's started-mint total would exceed
`burnCapE8s`. Consumption commits before the ledger call and is **never
refunded on failure** (over-counting pauses early — the fail-safe
direction), and the cap is checked **before** float sufficiency (a
leaked-secret drain has a full float).

```bash
icp canister call backend set_treasury_config \
  '(record { burnCapE8s = 50_000_000_000; burnWindowNs = 86_400_000_000_000; maxHoldNs = 259_200_000_000_000; lowFloatThresholdE8s = 20_000_000_000 })' \
  -e ic --identity <operator>
```

**Sizing guidance**: the cap is the most ICP a fully-leaked webhook secret
can drain per window before you notice. Set it to expected legitimate
volume per window plus modest headroom — a too-small cap merely *delays*
real orders (they hold, then resume when the window rolls); a too-large
cap is unbounded loss. Start tight.

**Levers:**

- **Pause all minting**: `set_treasury_config` with `burnCapE8s = 0`
  (the fail-closed default doubles as the pause switch). Money-in keeps
  working; everything holds in `awaitingTreasury`.
- **Manual override / resume after a legitimate burst**:
  `reset_burn_window` clears the window's consumption (returns the e8s
  cleared, audited). Held orders resume on the next sweep — the pre-gate
  stays the single decision point.
- **Held too long**: an order held past `maxHoldNs` (default 72 h)
  escalates to the error queue as `stuckMint{stage = "treasuryWaitExceeded"}`
  — position is *certain* (fiat in, nothing minted): refund in the Stripe
  Dashboard, then `resolve_error` (§6).

`lowFloat` (threshold crossed, or armed-but-never-observed) drives the
frontend's soft gate and an audit-log alert on the crossing. It never
blocks mints by itself — the hard float check is in the pre-gate.

## 5a. Admission gate: who is allowed to start an order

Order creation is refused before any quote when fulfilment is already
impossible. This is separate from, and in addition to, the mint-time pre-gate in
§5 — the point is to refuse *before* the customer pays Stripe.

```bash
icp canister call backend lifecycle_config '()' -e ic     # public: current bounds
icp canister call backend can_purchase '(500 : nat)' -e ic  # public: would this be admitted?
icp canister call backend set_gate_config \
  '(record { maxOpenOrdersPerPrincipal = 20 : nat; minCanisterCycles = 5_000_000_000_000 : nat; maxPurchaseUsdCents = 100_000 : nat })' \
  -e ic --identity <operator>
```

| Lever | Default | What it protects | Sizing |
|---|---|---|---|
| `maxOpenOrdersPerPrincipal` | 20 | Unbounded state growth. Abandoned orders are the only thing a user can create for free, so this is the real bound — retention sweeping (§5b) is cleanup, not protection. | Raise for legitimate power users. Must be > 0; 0 is rejected as config. |
| `minCanisterCycles` | 5 T | **This canister's own gas.** Below the freezing threshold it stops accepting updates; at zero it is uninstalled and its state is gone. | Keep well above the freezing threshold (default ~30 days of idle burn) so there is room to notice and top up. `0` disables the check. |
| `maxPurchaseUsdCents` | 100 000 (\$1 000) | Operator typo in a tier, and the webhook's upward repricing path. | Set just above your largest tier. `set_card_tiers` rejects any tier above it, and the webhook refuses to mint a payment above it. |

**These three deliberately default to non-zero**, unlike the burn cap and the
ck-USDC bound. Those are money decisions that must ship dark; these are safety
limits where a 0 default would brick the canister rather than protect it. The
card rail's actual on/off switch remains the tier list.

`can_purchase` returns the same decision `create_order` would make, so it is
both the frontend's button-gating call and the operator's "would a purchase go
through right now?" check. Two operational gotchas:

- **`floatLow` with no observation.** Once `lowFloatThresholdE8s > 0`, a float
  that has *never been read* fails the check — "enforce this" plus "I have never
  looked" is not a state to sell into. Call `refresh_float` after funding. This
  is why it is step 2 of the go-live checklist.
- **`burnCapExhausted` is the most likely reason the rail goes quiet.** A cap
  that fills mid-window silently stops new sales until the window rolls. Watch
  `treasury_status.burnedInWindowE8s` against `burnCapE8s`, and note that
  `reset_burn_window` re-opens sales immediately.

## 5b. Order retention: expiry and sweeping

```bash
icp canister call backend retention_status '()' -e ic      # public counters
icp canister call backend was_swept '("<orderId>")' -e ic  # public
icp canister call backend set_retention_config \
  '(record { orderTtlNs = 172_800_000_000_000 : nat; retentionHorizonNs = 7_776_000_000_000_000 : nat })' \
  -e ic --identity <operator>
icp canister call backend run_retention '()' -e ic --identity <operator>
```

Three bands, keyed on age from **creation**:

| Band | Status | Age | Payable? |
|---|---|---|---|
| 1 — live | `created` | < `orderTtlNs` (default 48 h) | yes |
| 2 — expired | `expired` | TTL → horizon | **yes** — expiry is advisory (§4) |
| 3 — swept | record deleted, id tombstoned | > `retentionHorizonNs` (default 90 d) | becomes Type 1 |

Sizing rules:

- **`orderTtlNs` must exceed the Stripe Checkout Session lifetime (24 h)**, or a
  customer can watch their order expire while still on the payment page. The
  48 h default is 2×.
- **The horizon must exceed the TTL** — config validation enforces it. Equal
  values would delete orders the moment they expired, destroying the §4
  late-payment guarantee.
- A Payment Link is permanent, so a payment can arrive for a swept order forever.
  It lands as Type 1 with a detail saying **"was SWEPT as abandoned"** (§6) —
  a refund, never a loss.

The sweep runs inside the recovery timer (hourly by default). `run_retention`
applies retuned bands immediately instead of waiting a cycle; it is safe to
spam, since the bands are absolute ages.

**Nothing that touched money is ever deleted.** Only `expired` orders with no
mint journal entry and no ck-USDC pull entry are removed; `delivered` and
`errorQueue` are financial records kept indefinitely, and their volume is
bounded by real sales (which the burn cap bounds).

Monitor `retention_status.openOrders` — climbing while `delivered` orders do not
is the signature of order-creation abuse, and the lever is
`maxOpenOrdersPerPrincipal` (§5a).

## 6. Error queue — triage (§4.1)

```bash
icp canister call backend error_queue '()' -e ic --identity <operator>
icp canister call backend resolve_error '(42)' -e ic --identity <operator>
icp canister call backend mint_journal '("<orderId>")' -e ic --identity <operator>
```

The queue is the **operator worklist** — resolution lives on the entry and
never transitions an order (`errorQueue` status is terminal). Bounded at
1,000 entries; eviction prefers oldest-resolved and audit-logs anything
dropped — keep it near-empty so nothing unresolved is ever at risk.
`charge.refunded` webhooks auto-resolve Type 1 entries by payment_intent;
everything else is manual.

| Kind / stage | Money position | Action |
|---|---|---|
| `#duplicate {orderId; paymentRef}` (Type 1) | Fiat in twice for one order; first payment minted, second did not | Refund `paymentRef` in the Stripe Dashboard (search by payment_intent). The `charge.refunded` webhook auto-resolves the entry; `resolve_error` is the fallback. |
| `#unattributed {claimedRef; paymentRef}` (Type 1) | Fiat in, no resolvable order (bad/missing `client_reference_id`, owner/rail/currency mismatch, below-fee-floor payment) | Inspect the session in Stripe by `paymentRef`. If you can identify the customer and they want the cycles, there is no attach-payment-to-order lever — refund and have them re-order. Refund → auto-resolve (or `resolve_error`). |
| `#undeliverable {orderId; cycles}` (Type 2) | Cycles minted, forward *cleanly rejected* — the cycles sit in the backend's own cycle balance | Fix the destination problem (e.g. the target canister was deleted/frozen). There is no automatic re-forward lever; either deliver manually from operator funds (`icp canister top-up <canister> --amount …` for a canister destination, a cycles-ledger transfer for an account destination — the stranded balance reimburses you) or refund the fiat in Stripe. Then `resolve_error`. |
| `#stuckMint{stage="treasuryWaitExceeded"}` | Certain: fiat in, nothing minted | Refund in the Stripe Dashboard → `resolve_error`. |
| `#stuckMint{stage="staleIntent"}` | Uncertain: ICP transfer intent aged past the 24 h ledger dedup window with no recorded block — the original transfer's fate is unknowable, auto-replay risks double-spend (§5.1) | Read `mint_journal(orderId)` for the intent (amount, `created_at_time`, CMC top-up subaccount). Check the ICP ledger for a matching transfer from the backend account. **Executed** → the ICP sits at the CMC under the backend's top-up subaccount; call `notify_top_up` on the CMC with the found block index (anyone may notify; if the CMC refuses an old block, contact DFINITY ops — the ICP is parked, not lost) and reconcile. **Not executed** → fiat in, nothing moved: refund in Stripe. Either way `resolve_error`; never rebuild a fresh intent. |
| `#stuckMint{stage="retriesExhausted"}` | ICP transferred to the CMC (block recorded), `notify_top_up` failed 25 times | Almost certainly a prolonged CMC outage. The block index is in `mint_journal`; the order is terminal (`process_order` will not retry an escalated order) — notify the CMC manually with the journaled block once the outage clears, or contact DFINITY ops. The ICP is parked at the CMC top-up subaccount, not lost. |
| `#stuckMint{stage="ambiguousForward"}` | Cycles minted; forward may or may not have reached the destination (died between the pre-forward marker and delivery) | Check the destination: canister cycle balance delta / cycles-ledger account balance vs `mint_journal.cyclesMinted`. **Arrived** → done, `resolve_error`. **Not arrived** → cycles are in the backend's balance; deliver manually as for Type 2. Never re-forwarded automatically — double delivery is the risk being avoided. |
| `#stuckMint{stage="missingJournal"}` | Order status implies money-out state the journal doesn't have | Invariant breach — should be unreachable. Reconstruct from `audit_log` + ledgers; treat as a bug, file it. |
| `#stuckMint{stage="stalePullIntent"}` (ck-USDC) | Uncertain, money-IN: a `icrc2_transfer_from` pull intent aged past 24 h with no recorded block; the order deliberately stays `created` and further claims are blocked | See §7 below — this one has dedicated levers. |
| `#refundAfterDelivery {orderId; paymentRef; cycles}` | **A loss, not a recoverable position**: the fiat was refunded (or charged back) *after* the cycles were forwarded to an arbitrary destination. Cycles cannot be clawed back. | There is nothing to recover on-chain. Reconcile in the Stripe Dashboard by `paymentRef` to see whether this was your own refund (a support decision — expected) or a customer-initiated dispute (fraud signal). For repeated disputes, tighten Stripe Radar rules and lower the per-purchase ceiling (§5a); the burn cap does **not** bound this, because each payment is individually legitimate. `resolve_error` once reconciled — nothing auto-resolves it, deliberately: the refund is what created the entry. |

Attribution failures now distinguish two cases that both surface as
`#unattributed`. If the detail says the order **"was SWEPT as abandoned"**, this
is a genuine late payment for an order the retention sweep deliberately deleted
past the horizon (§5b) — refund it; the customer did nothing wrong. Without that
wording the reference simply never resolved, which is also what a forged or
mistyped URL parameter looks like.

To go the other way — from a charge in the Stripe Dashboard to the order it
funded — use the reconciliation lookup:

```bash
icp canister call backend order_for_payment '("pi_3Q...")' -e ic --identity <operator>
```

`null` means the payment was never attributed to an order here; check the queue
for a Type 1 entry carrying it.

## 7. ck-USDC rail (§6.2)

**Enable / bound the rail** (default `maxUsdCents = 0` = disabled; also the
rail-level pause lever):

```bash
icp canister call backend set_ck_usdc_config \
  '(record { minUsdCents = 100; maxUsdCents = 100_000; feeBps = 0; feeFixedCents = 0; ledgerFeeUnits = 10_000 })' \
  -e ic --identity <operator>
```

`ledgerFeeUnits` must match the real ck-USDC ledger fee (10_000 units
today — confirm with `icrc1_fee` on `xevnm-gaaaa-aaaar-qafnq-cai` before
changing). The fee formula defaults 0/0: there is no structural processor
fee on this rail; the operator absorbs off-chain conversion cost per §3.

**`stalePullIntent` procedure** (the §6.2/§5.1 escalation — order stays
`created`, claims blocked, queued once):

1. `ck_usdc_pull '("<orderId>")'` — read the journaled intent: amount,
   `created_at_time`, and the memo (the order id's UTF-8 — every pull is
   ledger-greppable by it).
2. Check the ck-USDC ledger for a transaction matching the intent (the
   user's account → backend, that amount, that memo).
3. **No transaction** (nothing ever moved): `reset_ck_usdc_pull '("<orderId>")'`
   clears the intent; the user simply claims again. The method refuses
   (returns `false`) if a block *is* recorded — it structurally cannot
   create a double-debit.
4. **Transaction executed** (user was debited, credit never recorded): do
   NOT reset — a fresh intent would debit them twice. Refund the pulled
   amount with `withdraw_ck_usdc` to the user's account, then
   `resolve_error` the queue entry and tell the user to re-order.

**Withdraw lever** — both the refund tool above and the §6.2 hold-ckUSDC
treasury posture (pulled ck-USDC accrues in the backend's ledger account;
periodically withdraw → convert to ICP off-chain → refill the float):

```bash
icp canister call backend withdraw_ck_usdc \
  '(record { owner = principal "<operator-principal>"; subaccount = null }, 1_000_000_000)' \
  -e ic --identity <operator>
```

Returns the block index. The transfer carries **no `created_at_time`** —
this is an attended lever, so on a timeout/ambiguous failure **check the
ledger before retrying** (the backend's balance is public on the ck-USDC
ledger; no query method needed, and that's deliberate).

## 8. Recovery timer & manual kicks (§5.2)

The recurring sweep is the backstop for every detached mint kick that dies:
it re-drives all orders in `paid`/`minting`/`icpAtCmc`/`awaitingTreasury`.
It re-arms **automatically on every upgrade** (transient initializer — a
deploy can never leave recovery dead).

```bash
icp canister call backend recovery_status '()' -e ic            # public
icp canister call backend set_recovery_interval '(3_600_000_000_000)' -e ic --identity <operator>
icp canister call backend process_order '("<orderId>")' -e ic --identity <operator>
```

- Interval validation pins cadence ≤ 6 h (ledger dedup window ÷ 4 — a
  stuck transfer must get several replay attempts while its intent still
  dedups). Default 1 h; re-arms immediately on change.
- `recovery_status.lastSweep` not advancing past ~2 intervals = the timer
  is wedged — an upgrade re-arms it, but investigate first.
- `process_order` is the safe-to-spam manual kick for one order
  (per-order single-flight; `#inFlight` just means it's already being
  driven). Use it to resume a specific held order immediately after a
  float refill or cap change instead of waiting for the sweep.

## 9. Monitoring cadence

Daily (or alerting on, if you wire these queries up externally):

- `error_queue` — unresolved count should be **zero**; anything else is
  the §6 worklist.
- `treasury_status` — `lowFloat` false, `heldOrders` 0 (or transiently
  small), `burnedInWindowE8s` tracking expected volume (a jump = §2 leak
  procedure), `lastObservedFloat.atNs` recent.
- `recovery_status` — `lastSweep.atNs` within ~2 intervals.
- `retention_status` — `openOrders` climbing while `delivered` orders do not is
  order-creation abuse; the lever is `maxOpenOrdersPerPrincipal` (§5a).
- `can_purchase '(<smallest tier cents>)'` — the single best "is the rail
  actually selling?" check. It answers with the *reason* it would refuse, which
  is usually `burnCapExhausted` (window filled) or `floatLow` (needs a refill or
  a `refresh_float`).
- **Canister cycle balance** — `icp canister status backend -e ic`. Distinct
  from the ICP float: this is the canister's own gas, and losing it uninstalls
  the canister and its money-bearing state. Alert well above `minCanisterCycles`
  (§5a), since that gate stops *sales* but does not stop the burn.
- `forex_status` — rate timestamp within `maxAgeNs` of recent order
  activity (it only refreshes on demand; staleness with no orders is
  normal).
- `audit_log` — gaps in `seq` mean the 4,096-entry ring dropped events
  (read it more often or treat as a volume signal); the log is the
  operational trail, the order store + error queue are the records of
  money.
- Off-chain: Stripe Dashboard event deliveries (a stretch of failed
  deliveries = the secret got out of sync or the gateway is unhealthy —
  Stripe retries non-2xx for days, so nothing is lost while you fix it).

## 10. Confidential-subnet checklist (§7, §11.1)

The webhook secret is plaintext canister state. SEV-SNP is the intended
confidentiality layer; **the burn cap is the always-on backstop and launch
does not block on SEV**. Before relying on a confidential subnet for the
secret, verify — in this order, hardest first:

- [ ] **Checkpoint/state-sync confidentiality**: SEV-SNP protects RAM, but
  canister state is checkpointed to disk and state-synced between nodes.
  Confirm with DFINITY that both paths are encrypted on the target subnet —
  **if they aren't, a plaintext secret leaks there and SEV buys nothing**
  (§7: "verify this hardest").
- [ ] **Attestation coverage**: every replica in the subnet runs attested
  SEV-SNP (one unattested node = one node provider who can read the
  secret).
- [ ] **Production readiness**: the subnet is GA, not a beta — and check
  the current AMD SEV-SNP CVE list (it has a published side-channel
  history; trust shifts to AMD, not math).
- [ ] **Provisioning channel**: ingress still TLS-terminates at the
  boundary node. Unless an attestation-tied confidential provisioning
  channel exists, follow §2's rotate-after-provisioning rule even on the
  confidential subnet.
- [ ] **Migration**: moving subnets is a canister migration — re-verify
  the module hash after (RELEASE.md gate) and rotate the secret (it
  transited infrastructure during the move).

Until all boxes tick: the secret lives plaintext on a normal subnet, and
the protections are exactly (a) the burn cap sized tight (§5) and
(b) accountable node providers. That is the documented, accepted §7
posture — the loss is bounded, detectable, recoverable.

Related §11.1 note for future rails: the four Base seams (Owner variant,
route table, edge-captured ownership, per-rail expiry) are binding on code
changes, not operations — but any new rail lands with its own runbook
section, its own dedup set, and its own go-live checklist entry here.

## 11. Upgrades & releases

`RELEASE.md` end to end: reproducible container build → publish
`MODULE-HASHES.txt` → `icp deploy -e ic --mode upgrade` → **gate on
`icp canister status` matching the published hash**. Operational notes the
release doc doesn't cover:

- **Stop the canister before upgrading. This is mandatory, not advisory.**
  The IC rejects an upgrade while the canister has outstanding message
  callbacks:

  ```
  canister_pre_upgrade attempted with outstanding message callbacks
  (try stopping the canister before upgrade)
  ```

  So the procedure is always:

  ```bash
  icp canister stop backend -e ic --identity <operator>
  icp deploy -e ic --mode upgrade
  icp canister start backend -e ic --identity <operator>
  ```

  `icp deploy --mode upgrade` sets the `wasm_memory_persistence = keep`
  option that enhanced orthogonal persistence requires; a hand-rolled
  `install_code` without it is rejected with *"Enhanced orthogonal
  persistence requires the `wasm_memory_persistence` upgrade option"* — and
  `replace` would discard every order, journal, and dedup set.

- **Stopping drains in-flight calls, it does not drop them.** The canister
  enters `Stopping`, the IC delivers the replies to its outstanding calls,
  and only once every call context is closed does it reach `Stopped`. That
  is why the stop-first procedure is also the *safe* one: an in-flight mint
  or ck-USDC pull completes before the upgrade happens, so a controlled
  upgrade cannot strand money. Verified by `test/integration` scenarios 12
  and 13 and ck-08.

  Consequence: `ambiguousForward` and `stalePullIntent` are **not** reachable
  through a controlled upgrade. They cover genuine faults — a callee that
  never replies, a subnet incident, running out of cycles mid-call — and
  §8's triage rules still apply when they appear.

- **A call that never replies blocks the stop, and therefore the upgrade.**
  If `icp canister stop` hangs, the canister is waiting on an outstanding
  call. Check `recovery_status.sweepInFlight` and the audit log for a stage
  that keeps retrying; the money path is journalled at every step, so
  waiting is safe.

- In-flight mints resume from the persisted journal via the re-armed timer
  (§5.1), so an interrupted money movement degrades to a recoverable stage,
  never a double-spend.
- Persistent state (orders, journals, dedup sets, configs, secret, cap
  consumption) survives upgrades via orthogonal persistence. **Transient
  knobs reset on upgrade**: error-queue capacity (1,000), audit-log
  capacity (4,096), HTTP body cap (64 KiB), and both single-flight guards
  — that reset is deliberate (a guard stuck by an upgrade can't deadlock
  anything).
- After every upgrade: `health`, `recovery_status` (timer re-armed),
  `webhook_secret_status.generation` unchanged, one test order end-to-end
  if the change touched money paths.
