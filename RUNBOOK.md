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

Public queries (`treasury_status`, `pricing_status`, `recovery_status`,
`card_tiers`, `lifecycle_config`, `reserve_status`,
`can_purchase`, `cycles_status`, `error_queue_depth`, `health`) work from any
identity and are the
monitoring surface (§9 transparency stance — operational state is public,
the webhook secret is the only secret in the system).

**Units used throughout:** ICP amounts are e8s (1 ICP = 10⁸ e8s);
amounts are units (1 USDC = 10⁶ units, so 1¢ = 10⁴ units); durations are
nanoseconds (1 h = `3_600_000_000_000`, 24 h = `86_400_000_000_000`,
72 h = `259_200_000_000_000`); cycle prices are XDR-pegged (1 XDR = 1 T
cycles).

## 1. Go-live checklist (fresh deployment)

⚠️ **Before any of this**, work `docs/SANDBOX-TESTPLAN.md` to green. Every Stripe
payload in the automated suites is hand-crafted; that plan is the only thing that
verifies the real wire format, and its closing section lists what remains open
even after a clean run.

⚠️ **Deploy only from a green `main`.** The `-Werror` gate that makes a
non-exhaustive match (M0145) a build failure runs on `mops check` in
`scripts/test-all.sh` and in CI — **not** on `mops build` or `icp deploy`, which
compile the same code without it. `mops test` passes `--hide-warnings` and moc
refuses that together with `-Werror`, so gate-side is the only place it can live.
A direct-deploy hotfix therefore bypasses it entirely: a new `Owner` case, or any
other non-exhaustive match, would ship and trap at runtime — on the webhook path
that is a 5xx Stripe retries for ~3 days.

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
5. **Fund the cycles reserve, then tell the gateway to look** (§5 below):
   `icp cycles transfer <amount> <backend-principal>` followed by
   `icp canister call backend refresh_reserve '()'`.
   Delivery transfers out of the gateway's own cycles-ledger account, so an unfunded
   reserve means orders that pay and then retry delivery forever. ⚠️ This is a
   different pot from the canister's gas (step 4) — `icp canister top-up` does not
   touch it. ⚠️ **And a funded reserve is not a sellable one until `refresh_reserve`
   runs**: solvency is decided against a maintained lower bound that starts at zero
   and only rises by observation, so without it the gateway refuses every sale with
   `#reserveShort{available = 0}` while the ledger holds the full amount.
6. **Size the reserve to your exposure.** It is the blast-radius bound for a
   leaked webhook secret (§2), and #30's per-purchase ceiling is the per-order
   exposure inside it.
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
11. **Declare the Stripe mode**:
   `icp canister call backend set_expected_livemode '(opt true)' -e ic --identity <operator>`.
   Until this is set, a test-mode webhook secret would mint **real** cycles for
   payments that never happened. Verify with `expected_livemode`.
12. **Create a LIVE restricted API key (`rk_...`) scoped to write Checkout
   Sessions**, and provision it with `set_stripe_api_key`. Your sandbox key cannot
   be reused. There are no Payment Links, Products or Prices to create: the
   session carries inline `price_data`, and `amount_total == usdCents` holds
   because of what the session does NOT enable — the eight settings are listed in
   `rails/Session.mo` beside the body builder, and `test/session.test.mo` asserts
   their absence.

   ⚠️ Also set the **origin** (`set_stripe_origin`) before the key: with either
   missing, `create_order` refuses. Provisioning both is what OPENS the rail, so do
   it last; rotating either closes it until both are valid again.

   Historically, when `amount_total != usdCents` nothing failed — the order
   silently delivered a different cycle quantity. Since #33 it mints nothing and
   files a Type 1, so a wrong amount is visible on the first order rather than as
   drift. Register any price tiles with `set_card_tiers` (optional — a buyer can
   type an amount without them), then **buy one thing on the deployed site with a
   real card**: nothing short of a live purchase exercises the key, the origin,
   the return URL and the webhook secret together.
13. **Add a backup controller.** A single controller identity with no backup
   means a lost key makes the canister permanently un-upgradeable; there is no
   recovery path (§0 covers the trust model this implies).
14. **Wire monitoring (§9) before announcing the service**, not after. The whole
   alerting layer polls public queries and needs no key; the one exception is the
   scheduled `refresh_float`, without which the float metric is stale exactly when
   the system is idle.
15. **Smoke-check the public surface**: `pricing_status` — both rates must be
   populated and `lastAttempt.ok` true. The rate timer warms itself on install,
   so this should be true within seconds; if it is not, `lastAttempt.detail`
   names the failing guard (§4) and **no order can be created until it clears**
   (creation answers `rateUnavailable`, by design). Then `treasury_status`,
   `recovery_status` (sweep timer armed), `cycles_status` (balance above
   `minCanisterCycles`, with room for the 1 B the XRC needs per refresh),
   `card_tiers`, and `can_purchase '(<your smallest tier's cents>)'` — the last
   one should answer `ok` before you announce the service.

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

1. ⚠️ **The blast-radius bound changed with #30 PR-A, and this step changed with
   it.** It used to be "pause minting: `set_treasury_config` with
   `burnCapE8s = 0`", because the cap bounded how much ICP a forger could burn.
   Nothing mints now, so the cap bounds nothing — **the bound is the reserve
   balance**. A forged webhook can drain at most what the reserve holds.
   There is deliberately no `withdraw_reserve` (#30 rejected it), so the reserve
   cannot be emptied defensively. What you can do immediately is stop *new* orders
   while you roll the secret — the rail is live iff both Stripe secrets are
   provisioned, and rotating the webhook secret (step 2) closes it until the new
   one is set. Keep the reserve sized to what you are willing to lose in the
   window between detection and rotation; #30 PR-B's promise tally makes that
   figure readable.
2. Roll the secret in Stripe + `set_webhook_secret` (steps above).
3. Reconcile: compare `audit_log` / order store against the Stripe
   Dashboard's event log; forged "payments" have no matching Stripe
   payment_intent. Refund nothing that has no real charge.
4. `reset_burn_window`, restore the sized cap, and let held legitimate
   orders resume on the next sweep.

## 3. Presets, the API key, and the settings that must stay off (§3, §6.1)

The canister creates a **Checkout Session per order** through the Stripe API,
with inline `price_data`. There are no Products, no Prices, no Payment Links and
no Dashboard objects to create — which is why this section is four commands
rather than a click path through three screens.

### Provisioning, in order

```bash
# 1. The API key. RESTRICTED (rk_), scoped to write Checkout Sessions, nothing else.
icp canister call backend set_stripe_api_key '("rk_...")' -e ic --identity <operator>

# 2. Where Stripe returns the buyer. Validated: https, no query, no fragment.
icp canister call backend set_stripe_origin '("https://<your-origin>")' -e ic --identity <operator>

# 3. The webhook signing secret (§7).
icp canister call backend set_webhook_secret '("whsec_...")' -e ic --identity <operator>

# 4. The price tiles. Optional — a buyer can type any amount within the bounds.
icp canister call backend set_card_tiers \
  '(vec { record { id = "t10"; usdCents = 1_000 : nat } })' \
  -e ic --identity <operator>
```

⚠️ **Use a restricted key, not an `sk_`.** A leaked write-sessions key can create
sessions that pay *you*; one that can issue refunds is a materially worse thing
to leak. Stripe's IP and ASN allowlists are unusable here — a subnet's replicas
have many changing addresses.

⚠️ **Neither secret can be read back out, even by a controller.** `stripe_api_key_status`
and `webhook_status` report a generation counter and a set timestamp, which is
how you confirm a rotation landed without ever exposing the value.

⚠️ **Provisioning the two secrets is what OPENS the rail** (§5b of `docs/STRIPE.md`
for why capability rather than declaration), so do them last. Rotating either
closes the rail until both are valid again — which is a deliberate ordering
property, not an outage: no API key means no payable session, no webhook secret
means a buyer can pay and cannot be credited.

⚠️ **Changing the origin later is a user-visible migration, not a config tweak**:
Internet Identity derives a principal *per origin*, so existing buyers get new
principals and cannot see their old orders.

**Record the Stripe API version the account is on, and treat changing it as a
code change.** Webhook payload shapes follow the account default, so an
account-level upgrade silently changes what `Json.mo` parses — a class of
breakage no test here can see, because the fixtures were captured under the old
version.

### Tier registration

Validation is atomic — non-empty unique ids, non-zero amounts, every amount
within `[minPurchaseUsdCents, maxPurchaseUsdCents]` (§5a), or the whole call
rejects and the live tier list is untouched. `card_tiers` is the public query the
frontend renders.

Note the §3 invariant: a tier's *cycle* quantity is locked per-order at creation
time from the cached rate pair, so changing tier prices never reprices existing
orders. And since #33 the paid amount must **equal** the quoted one — an order
delivers what it locked, or it delivers nothing and files a Type 1.

### The settings that must stay off

The whole model rests on one invariant: **the session's `amount_total` equals the
order's `usdCents`.** The canister reads `data.object.amount_total`, which Stripe
defines as the total *after discounts and taxes*, and refuses anything else.

Per-order sessions removed most of the ways that can break: the canister sends
`price_data` inline, `payment_method_types[]=card`, no promo codes, no adjustable
quantity, and `adaptive_pricing[enabled]=false` explicitly. **The authoritative
list of settings that would move the total is in the code, next to
`Session.createBody`** — that is where someone adding a Stripe feature will see
it. Two things remain account-level and are therefore yours to keep off:

| Setting | Must be | If enabled |
|---|---|---|
| **Automatic tax** (account default) | **off** | raises `amount_total`; the payment is refused as a mismatch, so nothing is minted — but every order fails until it is turned off |
| **Adaptive pricing** (Dashboard toggle) | pinned off by the request | currently harmless to `amount_total` for this shape; the request pins it anyway, and it is proof Stripe adds Dashboard-side amount changers over time |

Plus the two already in §1: **USD** (any other currency is refused as
`#unattributed`, a Type 1 obligation and a manual refund) and **card-only**
(delayed methods are handled, but they make money-in asynchronous).

⚠️ Since #33 a mismatch is no longer silent. It used to reprice from the order's
own snapshot and deliver a different quantity, with the audit log showing an
ordinary completed purchase and no alert anywhere. Now it mints nothing and files
a Type 1 whose detail names both figures — so an amount-moving setting shows up
as a queue entry on the first order, not as a slow drift in what buyers receive.

⚠️ **Test-mode and live-mode keys are different objects.** Going live means a
live-mode restricted key and a live-mode webhook secret, both re-provisioned
against the mainnet canister. Once `set_expected_livemode '(opt true)'` is set, a
stray test-mode event is refused and tagged `stripe.livemodeMismatch` (§9 alerts
on it), so this fails closed: the symptom of getting it wrong is that nobody can
buy anything, not lost money.

### What the app does with no presets

⚠️ **An empty preset list is NOT the rail's off switch any anymore** (#33). It was,
and the audit line said "CARD RAIL PAUSED". With custom amounts it stops nothing: a
buyer can order any amount between the floor and the ceiling without a preset, so
an empty list means only that no tiles are shown. `create_order` still answers
`#unknownTier` for a `#tier` id that is not registered.

**The switch is both Stripe secrets being provisioned**, which is derived from
capability rather than declared: no API key means no payable session, no webhook
secret means a buyer can pay and cannot be credited. Neither state can complete a
purchase, so neither accepts one. `railsLive` is where that lives, and it also
gates the rate-refresh timer — so a gateway with presets and no API key no longer
pays for XRC calls it cannot use.

To take the rail down deliberately, there is no lever short of rotating a secret to
a value Stripe rejects. That is a gap worth naming rather than working around;
`can_purchase` and the distinguishable `#sessionUnavailable` refusal are what an
operator has instead.

## 4. Pricing rates (§3.1)

Two rates, both read from on-chain canisters on the same timer tick — the
**XRC** (`uf6dk-hyaaa-aaaaq-qaaaq-cai`) for USD/ICP and the **CMC** for
XDR/ICP. There is no HTTPS outcall and no settable rate source.

```bash
icp canister call backend pricing_status '()' -e ic   # public: both rates, config, last refresh
icp canister call backend quote_previews '(variant { card }, vec { 500 : nat })' -e ic  # public: what an amount buys
icp canister call backend refresh_rates '()' -e ic --identity <operator>   # force a tick now
icp canister call backend set_pricing_config \
  '(record { feeBps = 290 : nat; feeFixedCents = 30 : nat; maxAgeNs = 300_000_000_000 : nat; maxRateDeltaBps = 5_000 : nat; minRateSources = 2 : nat })' \
  -e ic --identity <operator>
```

Defaults: 290 bps + 30¢ (Stripe's fee, recovered net-of-fees per §3), a **5-min**
staleness window, a 50% delta bound, and a 2-source minimum.

`quote_previews` is the fastest "is the rail actually quoting?" check — it runs
the same pricing code `create_order` runs, so a `cycles = null` there is exactly
what a buyer would hit. `pricing_status` is the one command to run first for
*why*. `rates` carries both values
plus `fetchedAtNs` and the XRC `quality` (received/queried source counts and the
spread); `lastAttempt` carries `{atNs; ok; detail}` — **`detail` names the
rejecting guard**, which is what tells you whether the XRC answered at all.
Setting the config re-arms the refresh timer immediately, since the cadence is
derived from `maxAgeNs`.

### `maxAgeNs` is a security control, not a tuning knob

Validation **caps it at 1 h** (`#maxAgeTooLong`). Timers are deactivated by any
Wasm change, and the only thing that makes a dead timer safe is that a stale
cache **refuses to price**. A long window would let orders be quoted
indefinitely off a frozen rate. Widen it to ride out an outage only with that
trade understood — and prefer letting order creation fail closed.

### Diagnosing a stale rate

`create_order` never refreshes; it reads the cache and fails closed. So
persistent `rateUnavailable` is always one of:

| `lastAttempt.detail` | Meaning | Action |
|---|---|---|
| `NotEnoughCycles` | fewer than 1 B cycles could be attached | check `cycles_status`; top up. `Gate.minCanisterCycles` must stay well above 1 B or pricing stops before the gate does |
| `RateLimited` | XRC throttling | wait; backoff already widens the interval |
| `Pending` | XRC is still collecting | resolves on its own; alert only if it persists across ticks |
| `InconsistentRatesReceived` | XRC's sources disagree beyond its own tolerance | wait it out. Never work around it |
| `CryptoBaseAssetNotFound` / `StablecoinRate*` | XRC cannot price ICP/USD right now | wait; nothing local to fix |
| `too few sources` | fewer than `minRateSources` answered | a thin market. The 2-source minimum exists because the XRC's own `InconsistentRatesReceived` **cannot fire for a single source** — do not lower it to 1 |
| `implausible rate` | outside $0.10–$10,000/ICP | a bad upstream print. Rejected as if down |
| `delta` | moved more than `maxRateDeltaBps` since the last good value | a genuine 50%+ move needs `maxRateDeltaBps` raised **once**, deliberately; otherwise it is source disagreement |
| `implied XDR/USD` | `P × 10⁸ / U` fell outside 0.5–1.2 | the two sources disagree about reality. This is the cross-check that stops us trusting the XRC alone; XDR/USD has sat in ~0.6–0.9 for decades |
| `cmc stale` | CMC rate older than 15 min | check the CMC; nothing local to fix |

A rejected refresh **keeps the previous rate serving** until it goes stale, so a
single bad tick is invisible to buyers. The plausibility band and the implied
cross-check are not configurable.

**A rate outage never strands a paid order.** Fulfilment uses the quantity locked
at creation, and since #30 PR-A money-out reads **no rate at all** — it transfers a
figure fixed when the order was created. An outage means *no new orders*, never a
stuck buyer, and there is no longer a rate-move-mid-delivery exposure to bound.

## 5. The cycles reserve — and the treasury machinery that no longer runs

### Funding the reserve (this is the live part)

```bash
# The reserve IS the gateway's own cycles-ledger account.
icp cycles transfer 100t <backend-principal>

# ⚠️ REQUIRED after every top-up. Without it the balance is real and unsellable.
icp canister call backend refresh_reserve '()'

# What the gateway will actually sell: floor - promised = availableToSell.
icp canister call backend reserve_status '()'

# Read the truth from the ledger — anyone can, including the frontend.
icp canister call um5iw-rqaaa-aaaaq-qaaba-cai icrc1_balance_of \
  '(record { owner = principal "<backend-principal>"; subaccount = null })'
```

⚠️ **`reserveFloor` is a maintained lower bound, not the balance** (#30 PR-B).
Solvency is decided synchronously against it, so admission needs no ledger call —
which also means the floor only learns about incoming cycles by looking. It rises on
`refresh_reserve` and on the hourly sweep; it falls when the gateway itself transfers
out. **The ledger reading 100 T while `availableToSell` reads 0 is the expected
appearance of a top-up nobody observed**, and `reserveObservedAtNs` is how you tell
that from a genuinely spent reserve.

An observation is adopted only across a **quiet window** — no delivery in flight —
so a reconcile during a busy sweep is *skipped*, audited as
`reserve.reconcileSkipped`, and retried. That is a delay, never a loss: a stale floor
under-sells and can never over-sell.

Delivery is one `icrc1_transfer` out of that account, and the buyer receives
`lockedCycles − fee`, where the fee is the **stored** one (#30 PR-B: the ledger
reports its own fee on `#BadFee`, so the copy self-corrects and delivery needs no
`icrc1_fee` round trip). ⚠️ **Nothing writes that stored fee but the ledger itself.**
An admin lever for it existed briefly and was deleted as self-justifying: the only
state it fixed was one it could create, and its own typo silently shorted buyers. If
the ledger's fee ever exceeds an order's locked quantity, delivery stalls loudly on
`delivery.feeExceedsOrder` and the answer is a redeploy — at that fee the rail cannot
sell anyway. The ledger charges its fee **on top of** the amount,
so a delivery moves the reserve by exactly `lockedCycles` — which is why #30's
promise tally has no separate fee term.

⚠️ **Nothing mints into the reserve.** Refills are `icp cycles transfer` from
outside, and there is deliberately no `withdraw_reserve` (#30 rejected it: the app
is not in production and an over-funded local reserve costs nothing).

⚠️ **Two pots, and confusing them is the most common local-setup failure.**
`icp canister top-up` funds the canister's **gas** (what it spends to run, gated
by `minCanisterCycles`). `icp cycles transfer` funds the **reserve** (what it
sells). An unfunded reserve looks like orders that pay and then never deliver.

### ⚠️ Everything below describes machinery that no longer runs

> #30 PR-A replaced minting with selling from the reserve. The ICP float, the burn
> cap, the rolling window and the mint pre-gate are **still in the code and still
> callable, but unreachable**: `#awaitingTreasury` had exactly one entrance and it
> was that pre-gate. So `burnCapE8s` bounds nothing, `lowFloatThresholdE8s` gates
> nothing, `refresh_float` observes a balance nothing reads, and `heldOrders` is
> permanently 0.
>
> It is described rather than deleted because deleting it is **#36**, and a
> half-deleted procedure is worse than a marked one. Two consequences that are
> live right now:
>
> - **The blast-radius bound for a leaked webhook secret is the reserve balance**,
>   not the burn cap (§2 says so).
> - **There is no solvency gate yet.** An order can be admitted that the reserve
>   cannot cover; it fails at delivery and retries. #30 PR-B closes that with the
>   promise tally and `#reserveShort`.

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
  '(record { burnCapE8s = 50_000_000_000; burnWindowNs = 86_400_000_000_000; alertAfterNs = 7_200_000_000_000; maxHoldNs = 259_200_000_000_000; lowFloatThresholdE8s = 20_000_000_000 })' \
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
- **Held too long — two stages, and the first one is the useful one.** A paid
  order that cannot mint yet is *waiting*, not broken, so the timeline separates
  "tell the operator" from "give up":

  | Age | What happens | Buyer position |
  |---|---|---|
  | < `alertAfterNs` (2 h) | silent retries on the sweep | waiting; normal |
  | ≥ `alertAfterNs` | `#deliveryDelayed` alert enters the queue; **retries continue** | still waiting; nothing lost |
  | ≥ `maxHoldNs` (72 h) | escalates to a terminal `#deliveryStuck`, stage per money position | see below |

  **To see every delivery failing RIGHT NOW**, with no wait for the alert
  threshold — the operator's first question:

  ```bash
  icp canister call backend pending_deliveries '()' -e ic --identity <operator>
  ```

  Every delivery with money-out work outstanding, from the journal. `retries` is how
  often it has already failed (`0` = first attempt, not yet a problem). **It
  self-clears**: an entry leaves the set the moment delivery records its block, so a
  successful `process_order` empties it for that order immediately and there is no
  resolve step to forget. Admin-only because it scans the whole journal — a public
  version would let anyone make the canister walk its entire history for free, which
  is also why none of it is in the public, O(1) `reserve_status`.

  The queue is the other half of the answer, and the two are not redundant: this is
  the live view, the queue is the **worklist with obligations attached**.

  ```bash
  icp canister call backend error_queue_unresolved '(null, 50)' -e ic --identity <operator>
  ```

  `#deliveryDelayed` = still retrying, still recoverable, buyer still waiting; it
  self-resolves on delivery *or* escalation. `#deliveryStuck` = terminated, a human has
  to act, and the entry's `detail` names the money position. `error_queue_depth` is
  the public gauge for alerting.

  ⚠️ **One kind, and `stage` is the money position** (#36). `#stuckMint` — a misnomer
  the moment nothing minted — and `#transferUnresolved`, which existed only because
  #36 was going to delete the other, folded into **`#deliveryStuck`**. They were one
  operator question wearing two names, and folding cost nothing: both were
  `refundResolvable = false` with no `paymentRef`, so only the payloads differed.
  **Read `stage`, never the kind:**

  | `stage` | Position | Do |
  |---|---|---|
  | `staleIntent` | **unknown** — a transfer was issued, no block recorded, past the ~24 h dedup window | establish its fate on the cycles ledger (order id is in the memo). ⚠️ Never refund blind: the buyer may already hold the cycles |
  | `deliveryWaitExceeded` | **certain** — nothing was ever sent | refund in the Stripe Dashboard |
  | `transferRejected` / `journalInconsistent` | the ledger refused definitively, or the intent contradicts the order | establish the fate before re-sending |

  ⚠️ **Under two hours the QUEUE is silent by design** — a delivery taking a sweep or
  two is normal — so use `pending_deliveries` for the live view rather than lowering
  `alertAfterNs`, which would file worklist entries for orders that deliver
  themselves. And since #30 PR-B deleted the delivery retry cap, the 2 h alert is the
  only *queue* signal: retry exhaustion used to escalate an order on its own and no
  longer does, deliberately. What bounds retrying now is time on both ends — the
  ledger's ~24 h dedup window and this 72 h wait.

  ⚠️ **The timeline covers every in-flight status, not just `paid`.** `minting`
  and `icpAtCmc` can sit still too — a ledger or CMC answering retriably leaves an
  order there — and the retry count alone is not a time bound. The alert names
  which stage is stuck. ⚠️ Only **`deliveryDelayed`** is reachable today (`#paid` is
  the one in-flight status); `transferDelayed` and `notifyDelayed` belong to the
  legacy mint stages and go with them in #36. It was called `mintDelayed` until
  #30 PR-C, while reporting a delivery delay.

  **The terminal stage differs by status, because the money position does**, and
  the position is what determines the action:

  ⚠️ **The stage is derived from the mint journal, not from the status** — the
  status says where the order stopped, the journal says where the *money* is, and
  only the money position determines your action (`Delivery.terminationFor`):

  | Stuck in | Journal says | Escalates as | Action |
  |---|---|---|---|
  | `paid` | — | `mintWaitExceeded` | fiat in, no ICP moved → **refund** |
  | `awaitingTreasury` | — | `treasuryWaitExceeded` | fiat in, no ICP moved → **refund** |
  | `minting` | no `blockIndex` | `staleIntent` | transfer fate unknown → establish it on the ICP ledger first; **never** rebuild the intent |
  | `minting` | `blockIndex` set | `retriesExhausted` | transfer confirmed → **notify manually** with that block |
  | `icpAtCmc` | no `cyclesMinted` | `retriesExhausted` | ICP parked at the CMC → **notify manually** with the journaled block |
  | `icpAtCmc` | **`cyclesMinted` set** | `ambiguousForward` | ⚠️ the ICP is **already consumed** and cycles exist → **check the buyer's cycles-ledger balance**; never re-forward, never re-notify |

  That last row is why this is journal-derived: read off the status alone it looks
  like "notify never completed", and following that instruction would re-notify an
  already-spent transfer and risk double delivery.

  ### Per-stage clocks are cumulative

  ⚠️ Each transition resets `updatedAtNs`, so the 72 h bound applies **per state**,
  not to the whole order. An order that lingers in `paid`, then `minting`, then
  `icpAtCmc` can therefore take longer than 72 h end to end — worst case on the
  order of a week and a half.

  This is deliberate: each state is a distinct failure mode with a distinct
  recovery, and an order that *just* progressed is making progress and should not
  be terminated on a clock started before its current problem existed. But it means
  "72 h" is the bound on **being stuck in one place**, not on total time to
  resolution — and the 2 h alert is what you actually operate against.

  The 2 h alert is the one to act on: it fires while the position is still fully
  recoverable, and clearing the underlying cause (refill the float, widen the
  cap, `reset_burn_window`) delivers the order for real. The alert **resolves
  itself on delivery**. Validation refuses `alertAfterNs >= maxHoldNs` — an alert
  that fires at or after the give-up point is not an alert.

  Reaching 72 h means the operator had 70 h of warning and the buyer waited three
  days. Refund in the Stripe Dashboard, then `resolve_error` (§6) — position is
  *certain* (fiat in, nothing minted). Refunding rather than waiting longer is
  deliberate: a buyer who has paid and received nothing files a chargeback, which
  costs more than the refund and counts against the Stripe account.

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
| `maxOpenOrdersPerPrincipal` | 20 | Unbounded state growth. Abandoned orders are the only thing a user can create for free, so this is the real bound. Nothing sweeps them away (§5b): a slot frees when Stripe expires the session, or when the buyer cancels. | Raise for legitimate power users. Must be > 0; 0 is rejected as config. |
| `minCanisterCycles` | 5 T | **This canister's own gas.** Below the freezing threshold it stops accepting updates; at zero it is uninstalled and its state is gone. | Keep well above the freezing threshold (default ~30 days of idle burn) so there is room to notice and top up. `0` disables the check. |
| `maxPurchaseUsdCents` | 100 000 (\$1 000) | Operator typo in a tier, and the webhook's upward repricing path. | Set just above your largest tier. `set_card_tiers` rejects any tier above it, and the webhook refuses to mint a payment above it. |

**These three deliberately default to non-zero**, unlike the burn cap and the
burn cap. That is a money decision that must ship dark; these are safety
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

## 5b. Order expiry — Stripe owns it, and there is no lever here

```bash
icp canister call backend reserve_status '()' -e ic   # public counters (was order_stats)
```

**There is no retention config, no TTL and no sweep.** #33 deleted
`Retention.mo`: an order's deadline is its Checkout Session's `expires_at`
(~35 min, above Stripe's 30-minute floor), stored on the order, and the *only*
thing that moves an order to `expired` is Stripe's `checkout.session.expired`
event. A buyer freeing their own open-order slot uses `cancel_order`
(owner-scoped), which produces `cancelled` — a separate status.

| Status | Payable? |
|---|---|
| `created` | yes, until the session's own `expiresAtNs` |
| `expired` | **no** (#34) |
| `cancelled` | **no** (#34) |

⚠️ **A missed `checkout.session.expired` leaves the order visibly `created` past
its `expiresAtNs`, and that is deliberate.** A sweep as a backstop was specified
and then rejected: it would flip the order to `expired` while its reserve promise
stayed held, so a broken order would look like a correctly expired one and the
reserve would leak silently. The stuck order IS the detection signal (#30's
predicate 1) — treat "created, past `expiresAtNs`" as an alert, not as noise.
⚠️ **And since #30 PR-B it costs RESERVE CAPACITY.** A `created` order holds its
promise from the moment it exists (the gate admitted it against capacity), and the
only things that release one are `checkout.session.expired` and the buyer's own
`cancel_order` — `abandon_order` refuses a `created` order by design, since no money
was taken. So a missed expiry webhook strands `lockedCycles` of sellable reserve
until someone acts, and `reserve_status.promisedTotal` climbing while `openOrders`
also climbs is what it looks like.

**The lever is off-chain: resend `checkout.session.expired` from the Stripe
Dashboard** (§9's P2 row). ⚠️ An earlier version of this note said there was "no
operator lever at all", which contradicted that row — the honest statement is that
the remedy exists but is **gated on noticing**, because nothing on-chain surfaces the
stranded order. That observability gap, and an on-chain remedy, are what #30's ranked
fixes describe; PR-B does not close them. Bounded per incident by the purchase
ceiling, and unbounded only in aggregate against a failure that Stripe itself retries
for ~3 days first.

⚠️ **Nothing exposes it yet**: order reads are owner-scoped and `reserve_status`
carries only counts, so §8 records this as a gap with an interim signal rather
than as an alert you can wire. #38 (admin order listing) is what closes it.

⚠️ **A payment arriving against an expired or cancelled order cannot be
converted** (#34 deleted `#expired → #paid`). It answers 200, the status does not
move, and a Type 1 `#unattributed` entry is filed carrying the payment intent.
**Refund it in Stripe** — since #33 deleted `attach_payment` there is no other
remedy at all.

The webhook-lost-for-three-days problem that made the old 48 h TTL awkward is
gone with it: the session and the order now die together, so a session that can
still be paid always belongs to an order that can still accept it.

Nothing deletes an order. The record and its `client_reference_id` survive
forever, which is what keeps a late payment *attributable*, and therefore
refundable rather than a mystery charge.

### The outcall cost, and the one field that moves it

`create_order` now spends the canister's own cycles on an HTTPS outcall, so
`minCanisterCycles` is more load-bearing than before: it is the floor that closes
the rail before the gas runs out.

The cost is **computed exactly** by `ic0.cost_http_request` — `Call.httpRequest`
attaches precisely that and never a buffer, because attached cycles are reserved
for the call's duration and a margin therefore caps how many outcalls can be in
flight. There is nothing to measure. What decides the number is
**`max_response_bytes`**, currently **16,384** (`Session.maxResponseBytes`):

| Replication | Cost per call at 16 KB |
|---|---|
| n = 13 (application subnets, and the local network) | **≈ 220 M cycles** (~$0.0003) |
| n = 7 (the confidential subnet, our target — #2) | **≈ 118 M cycles** |

Work with the 13-node figure: it is the conservative one, and the local network
prices on it, so local runs *overstate* production cost. At 20 T gas with a 5 T
floor that is ≈68,000 creations before the rail closes.

⚠️ **The cap counts response HEADERS, not just the body, and it is checked
twice** — once on the raw response, once on the transform's Candid-encoded
output. Three distinct rejects, and the middle one misleads:
`Header size exceeds specified response size limit` (headers alone),
`Http body exceeds size limit of <N>` (**prints the full cap, not the remainder
left after headers, so the body that failed can be well under `<N>`**), and
`Transformed http response exceeds limit`. Raising the cap fixes all three;
stripping headers in the transform fixes only the last.

⚠️ **`No consensus could be reached` means the transform, not Stripe.** It is the
signature of a per-request value not being stripped, it takes the whole rail down
rather than degrading it, and **no test suite in this repo can catch it** — the
PocketIC suite mocks outcalls, verified by mutation. `Session.classifyFailure`
labels it in the audit log for exactly that reason.

### Growth

Growth is bounded at its source, not by deletion:
`maxOpenOrdersPerPrincipal` (§5a) bounds what a user can create for free, and
the burn cap bounds legitimate volume. An order is a few hundred bytes, so a
million is a few hundred MB — and a million orders is millions of dollars of
volume. If store size ever genuinely binds, archive to a separate canister;
deleting a financial record is not the answer.

Monitor `reserve_status.openOrders` — climbing while `delivered` orders do not
is the signature of order-creation abuse, and the lever is
`maxOpenOrdersPerPrincipal` (§5a). `totalOrders` and `paidIntentsIndexed` should
grow together and never diverge.

## 6. Error queue — triage (§4.1)

```bash
icp canister call backend error_queue '()' -e ic --identity <operator>
icp canister call backend resolve_error '(42)' -e ic --identity <operator>
icp canister call backend delivery_journal '("<orderId>")' -e ic --identity <operator>
```

The queue is the **operator worklist** — resolving an entry lives on the entry and
never transitions the order. The order's own status says whether anything is
still owed, which is why #34 split the old `errorQueue` status in two:

| Status | Meaning | The order's promise |
|---|---|---|
| `NeedsReview` | a money position nobody knows the outcome of — typically a transfer past the ledger's ~24 h dedup window. **Check the ledger.** | **still held** |
| `Abandoned` | you ended it, having refunded by hand. Terminal. | **released** |

**How an order GETS to `NeedsReview`**, since the triage depends on it and "it
escalated" is not one thing:

| Route | Money position | What you do |
|---|---|---|
| the intent aged past the ledger's ~24 h dedup window, or the ledger answered `#TooOld` (the same case, told to us) | **unknown** — a replay is no longer protected | establish the fate on the ledger; the order id is in the transfer's **memo** |
| §5.3's 72 h max-wait, on an order where **nothing was ever sent** | **certain** — fiat in, nothing moved | refund in the Stripe Dashboard |
| `journalInconsistent` | unreachable guard | ⚠️ if this ever fires, `lockedCycles` acquired a second writer — a much bigger problem than one order |

⚠️ **So `NeedsReview` is NOT always an unknown position.** `delivery_journal(orderId)` and
the queue entry's `detail` say which — `terminationFor` derives it from the journal
rather than the status, precisely because the status cannot tell these apart. Reaching
the *unknown* case at all takes a ~day-long cycles-ledger outage with an hourly sweep
and buyer kicks hammering it throughout: treat it as expected-never, not routine.

`NeedsReview` has exactly **two** exits, and both are your finding rather than the
gateway's:

| You established, on the ledger | Call | Result |
|---|---|---|
| the transfer **did** land — the buyer has the cycles | `record_delivered '("<orderId>", <blockIndex>)'` then `resolve_error '(<entryId>)'` | `Delivered`, with the block recorded in the journal |
| it did **not**, and you refunded the fiat by hand | `abandon_order '("<orderId>", "<reason>")'` then `resolve_error '(<entryId>)'` | `Abandoned`, reason in the audit trail |

⚠️ **Neither lever closes the queue entry — `resolve_error` is the last step, always.**
Resolving lives on the entry and never transitions an order, and the reverse holds too:
moving the order does not resolve the entry. The `#deliveryStuck` entry that
brought you here stays open until you close it, which is deliberate (an obligation
must not disappear because a status changed) but means a finished order can sit behind
an open worklist item if you stop after the first command.

⚠️ **You cannot `abandon_order` a `Paid` order whose delivery is still outstanding**
(#30 PR-B). The lever refuses and names `pending_deliveries`, because abandoning an
unknown position releases the promise and files a refund while the transfer may
already have landed — the buyer would keep the cycles and get the refund. It is a
wait, not a block: the ~24 h fuse moves such an order to `NeedsReview`, which is this
table, where establishing the fate first is the documented procedure.

⚠️ **`record_delivered` exists because its absence made the record lie** (#30 PR-B).
Until it did, `abandon_order` was the only exit, so an order whose cycles the buyer
demonstrably held could only be filed as abandoned — auditing a refund that never
happened. The block index is required: it is the evidence that you looked, and the
order id is in the transfer's **memo**, so finding it is a ledger search rather than
a reconstruction. Nothing automatic reaches `Delivered` from `NeedsReview`, because
re-driving an unknown money position is the double-delivery this status prevents.

⚠️ **Never treat `NeedsReview` as finished.** It is the status that still owes
cycles; `Abandoned` and `Delivered` are the ones that do not.
**Only a *full* `charge.refunded` auto-resolves a Type 1 entry** — Stripe fires
the same event for partial refunds, so the canister compares `amount_refunded`
against the charge's `amount`. A partial refund leaves the entry open and audits
`stripe.refundPartial`; finish the refund in the Dashboard (or close the entry by
hand once reconciled). `#deliveryDelayed` self-resolves on delivery *or*
escalation; everything else is manual.

**Only resolved entries are ever evicted.** The soft cap is 1,000, but an
unresolved entry is an open obligation — usually someone's money — so the queue
**grows past the cap rather than dropping one**. That makes `error_queue_depth`
a real alarm instead of a saturating gauge: a depth climbing above 1,000 means
unresolved work is accumulating faster than it is being cleared, and no amount
of ignoring it can lose an obligation.

Paginate with a cursor rather than fetching the whole queue:

```bash
icp canister call backend error_queue_depth '()' -e ic          # public: {total; unresolved}
icp canister call backend error_queue_unresolved '(null, 50)' -e ic --identity <operator>
icp canister call backend error_queue '(opt (120 : nat), 50)' -e ic --identity <operator>
icp canister call backend resolve_error '(137 : nat)' -e ic --identity <operator>
```

`error_queue_unresolved` is the worklist; pass the last id returned as
`afterId` to page forward. Page size is capped at 200.

| Kind / stage | Money position | Action |
|---|---|---|
| `#duplicate {orderId; paymentRef}` (Type 1) | Fiat in twice for one order; first payment minted, second did not | Refund `paymentRef` in the Stripe Dashboard (search by payment_intent). The `charge.refunded` webhook auto-resolves the entry; `resolve_error` is the fallback. |
| `#unattributed {claimedRef; paymentRef}` (Type 1) | Fiat in, and no order that can accept it: a bad/missing `client_reference_id`, an owner/rail/currency mismatch, **a paid amount that is not the one the order asked Stripe for** (#33 — see below), or a payment against a `cancelled` or `expired` order (#34), which is the common producer. The entry's own `detail` says which. | Inspect the session in Stripe by `paymentRef`, then **refund in Stripe** → auto-resolve (or `resolve_error`). Since #33 deleted `attach_payment` this is the only remedy, whatever the order's status (see below). ⚠️ If the detail says the amount is not the quoted one, refunding is not the end of it: the session carried our own figure, so something in the Stripe configuration moved the total — check the forbidden-settings list in `docs/STRIPE.md` before the next order is created, because it will recur. |
| `#undeliverable {orderId; cycles}` (Type 2) | Cycles minted, the forward *cleanly rejected* — the cycles sit in the backend's own cycle balance. Since #29 there is one destination, so the cause is the **cycles ledger**, not the target: stopped, upgrading, or its call queue full. | Check the cycles ledger is serving (`icrc1_fee` on `um5iw-rqaaa-aaaaq-qaaba-cai` answers). There is no automatic re-forward lever; once it is back, either deliver manually with a cycles-ledger transfer to the buyer's account (the stranded balance reimburses you) or refund the fiat in Stripe. Then `resolve_error`. |
| `#deliveryStuck{stage="treasuryWaitExceeded"}` | Certain: fiat in, nothing minted | Refund in the Stripe Dashboard → `resolve_error`. |
| `#deliveryStuck{stage="staleIntent"}` | Uncertain: ICP transfer intent aged past the 24 h ledger dedup window with no recorded block — the original transfer's fate is unknowable, auto-replay risks double-spend (§5.1) | Read `delivery_journal(orderId)` for the intent (amount, `created_at_time`, CMC top-up subaccount). Check the ICP ledger for a matching transfer from the backend account. **Executed** → the ICP sits at the CMC under the backend's top-up subaccount; call `notify_top_up` on the CMC with the found block index (anyone may notify; if the CMC refuses an old block, contact DFINITY ops — the ICP is parked, not lost) and reconcile. **Not executed** → fiat in, nothing moved: refund in Stripe. Either way `resolve_error`; never rebuild a fresh intent. |
| `#deliveryStuck{stage="retriesExhausted"}` | ICP transferred to the CMC (**block recorded**), `notify_top_up` never succeeded — either the retry budget ran out or the max wait elapsed | Almost certainly a prolonged CMC outage. The block index is in `delivery_journal`; the order is terminal (`process_order` will not retry an escalated order) — notify the CMC manually with the journaled block once the outage clears (notify is idempotent), or contact DFINITY ops. The ICP is parked at the CMC top-up subaccount, not lost. |
| `#deliveryStuck{stage="mintWaitExceeded"}` | Certain: fiat in, **no ICP moved** | Refund in the Stripe Dashboard → `resolve_error`. Same position as `treasuryWaitExceeded`; this one means the mint could not even start (stale CMC rate, unpriceable amount, float read failing) rather than being held by the burn cap. |
| `#deliveryStuck{stage="transferRejected"}` | **Usually** certain: the ICP ledger refused the transfer, so nothing moved. ⚠️ **One exception** — `#TooOld` routes here too, and that one is *not* certain: the intent aged past the dedup window, so whether the original transfer executed is unknowable. Read the detail before assuming nothing moved | Read the detail for the ledger's reason. `#InsufficientFunds` → refill the float (the order is terminal, so re-drive it by hand or refund). `#BadFee` → the protocol fee changed; that is a code fix, and every order will fail until it lands. Fiat is in and nothing was minted, so refunding is always a valid resolution. |
| `#deliveryStuck{stage="notifyRejected"}` | **ICP is gone from the float and the CMC refused to mint** — usually `#Refunded`, meaning the CMC returned the ICP | Read the detail. `#Refunded{block_index}` → the ICP came back to this canister's ledger account; confirm on the ICP ledger, then refund the fiat (net-neutral) or re-drive a fresh order. `#InvalidTransaction`/`#Other` → establish where the ICP is on the ledger **before** refunding, or you may refund fiat *and* lose the ICP. |
| `#deliveryStuck{stage="ambiguousForward"}` | Cycles minted; forward may or may not have reached the destination (died between the pre-forward marker and delivery) | Check the buyer's cycles-ledger balance against `delivery_journal.cyclesMinted` less the ledger's 100 M deposit fee. **Arrived** → done, `resolve_error`. **Not arrived** → cycles are in the backend's balance; deliver manually as for Type 2. Never re-forwarded automatically — double delivery is the risk being avoided. ⚠️ **Do not notify the CMC again**: the ICP is already consumed. This stage is also what the 72 h bound produces for an `#icpAtCmc` order that has `cyclesMinted` journaled, precisely so that case is never mistaken for `retriesExhausted`. |
| `#deliveryStuck{stage="mintShortfall"}` | Cycles minted, but **fewer than the order locked** — the CMC's rate moved between sizing the ICP transfer and notifying it (up to 15 min normally, longer if a recovery sweep notified a transfer stranded by an outage). The minted cycles are in this canister's balance; nothing was forwarded | Read `delivery_journal(orderId).cyclesMinted` for the real figure. Either forward that amount and tell the buyer, or top up to `lockedCycles` from operator funds — a business call, not a technical one. **Never** just re-run the mint: the ICP is already spent. Deliberately not absorbed automatically, because covering the gap from the canister's own gas is an unbudgeted subsidy that grows with volatility. `resolve_error` once delivered. |
| `#deliveryStuck{stage="missingJournal"}` | Order status implies money-out state the journal doesn't have | Invariant breach — should be unreachable. Reconstruct from `audit_log` + ledgers; treat as a bug, file it. |
| `#duplicate` naming an order the session did **not** reference | An intent already credited to a *different* order. **Nothing was minted twice.** ⚠️ Since #33 this should be unreachable: nothing but the webhook writes an attribution and nothing but the canister sets `client_reference_id`. It is kept because an unreachable contradiction that fires is worth seeing | Treat it as a bug report first. Cross-check `order_for_payment` against the session's `client_reference_id` in the Stripe Dashboard, then settle the buyer by refunding in Stripe — there is no way to credit the other order. The audit tag is `stripe.creditedElsewhere`. |
| `#unprocessable {eventId; field}` | **Unknown — establish it first.** A verified Stripe event was missing a required field, so the canister could not tell whether money moved | Look the `eventId` up in the Stripe Dashboard. Paid → refund. Not paid → nothing happened; `resolve_error`. Then find the configuration that produced it: with per-order sessions (#33) the canister controls every field it sends, so a missing one points at an account-level API-version change (RUNBOOK §1 pins it) rather than at a link setting, and it will recur until fixed. One event never becomes two entries: a Dashboard resend inside the ~7-day event-dedup window is dropped there, and past it the worklist itself is checked (audited `stripe.unprocessableResend`). Once you `resolve_error` it, a later resend is allowed to file again — so resolve only after you have established the money position. |
| `#refundAfterDelivery {orderId; paymentRef; cycles; refundedCents; fullRefund}` | **A loss, not a recoverable position**: the fiat was refunded (or charged back) *after* the cycles were credited to the buyer's account. Cycles cannot be clawed back. | There is nothing to recover on-chain. Reconcile in the Stripe Dashboard by `paymentRef` to see whether this was your own refund (a support decision — expected) or a customer-initiated dispute (fraud signal). For repeated disputes, tighten Stripe Radar rules and lower the per-purchase ceiling (§5a); the burn cap does **not** bound this, because each payment is individually legitimate. `resolve_error` once reconciled — nothing auto-resolves it, deliberately: the refund is what created the entry. |

### A Type 1 payment has exactly one remedy: refund — and it is usually not "unattributable"

⚠️ **Read the entry's `detail`, not its kind.** `#unattributed` is one variant
covering two very different situations, and since #33 the common one is the
second:

| | What it means | How common now |
|---|---|---|
| Genuinely unattributable | no order can be named: missing, malformed, or unresolvable `client_reference_id`, wrong currency | **should not happen** — the canister sets that field itself through the API, so treat one as a bug to find (or as a session someone created outside the app) |
| Attributable but unpayable | the entry names the order; we refuse to credit it — a lowered ceiling, an amount that is not the quoted one, a cancelled or expired order | the normal producer |

The second kind needs no hunting in the Dashboard: the order id is in the detail.
What it needs is fixing the cause, or the next order fails the same way.


`attach_payment` — the admin lever that credited a payment the canister never
saw — was **deleted in #33**, along with the failure it existed for. Under
Payment Links the *frontend* appended `client_reference_id` to the URL, so a
buyer could strip it, bookmark a bare link or hand-edit it, and misattribution
was the dominant failure. The canister now sets that field itself through the
Checkout Sessions API: there is no URL parameter to touch, so the class is gone
by construction.

What remains is refunding, in the Stripe Dashboard, by `paymentRef`. There is no
path that turns a Type 1 payment into cycles for that buyer, whether or not we
know which order it was for — that is
the deliberate cost of the deletion, and it matches the decision that this app
does not model refunds. A refund auto-resolves the entry (a partial one leaves it
open, carrying the remainder).

⚠️ If you find yourself wanting the lever back, the thing to check first is
whether attribution is broken — since #33 nothing but the canister writes
`client_reference_id`, so a payment that cannot be attributed is a bug worth
finding, not a routine occurrence to be papered over.

## 7. Recovery timer & manual kicks (§5.2)

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
- The sweep also **reconciles the per-status tallies once a day** and reports the
  result on `recovery_status.lastCountReconcile`. The tallies are maintained
  incrementally so the admission-gate queries stay O(1); the reconcile is the
  O(orders) check that they still match. It audits `orders.countDrift` **only when
  something moved** — a clean line every day would bury the one that matters.
  `recount_orders` is the same repair on demand.
- The sweep also **reconciles the reserve floor against the cycles ledger once an
  hour**, which is how a top-up becomes sellable without an operator call.
  `recovery_status.lastReserveReconcileAttemptNs` is the attempt clock and
  `reserve_status.reserveObservedAtNs` the success one; the two diverging means the
  read is failing or every attempt landed while a delivery was in flight. Both
  under-sell, never over-sell. `refresh_reserve` is the same reconcile on demand and
  is what you call right after `icp cycles transfer`.
- `process_order` is the safe-to-spam manual kick for one order
  (per-order single-flight; `#inFlight` just means it's already being
  driven). Use it to resume a specific held order immediately after a
  float refill or cap change instead of waiting for the sweep.
  ⚠️ **It is admin *or* the order's own owner** since #30 PR-B, so a buyer's page
  refresh heals their own stuck delivery in seconds rather than at sweep cadence. It
  does **not** make the sweep optional: the sweep is the guarantee (we took the money,
  so we deliver whether or not the buyer comes back), this is the latency fix.

## 8. Monitoring plan

Every safety mechanism in this system is a **number someone has to look at**. The
2 h delay alert, the error queue, the rate-refresh liveness — none of them page
anybody. An alert nobody receives is not an alert, so wire this before taking
money.

### The whole alerting layer needs no credentials

These are public queries, so a monitor can poll them anonymously — no controller
key on a monitoring box:

`health` · `cycles_status` · `treasury_status` · `pricing_status` ·
`recovery_status` · `reserve_status` · `error_queue_depth`

`can_purchase` is also callable anonymously and is worth special mention: the
anonymous principal owns no orders, so `tooManyOpenOrders` can never trip for it.
That makes **anonymous `can_purchase '(<smallest tier cents>)'` a pure global-health
probe** — it answers with the reason the rail would refuse a sale, and every reason
it can give is a global one (`burnCapExhausted`, `floatLow`, `canisterCyclesLow`).
It is the single best "is the rail actually selling?" check.

### ⚠️ The ICP float is the one metric you cannot poll honestly

You are right that it is crucial, and it is also the trickiest.

`treasury_status` is a **query**, and queries cannot make inter-canister calls. So
it does not read the ledger — it returns `lastObservedFloat`, a *cached*
observation, refreshed only when something calls the ledger:

- every mint pre-gate (so it is fresh while orders are flowing), or
- `refresh_float`, an **admin update call**.

The consequence: **the float reading goes stale exactly when the system is idle**,
which is precisely when a drained or mis-funded float would otherwise go unnoticed
until the next buyer arrives. `lowFloat` is derived from the same cached value, so
it inherits the staleness — and so does the admission gate, which means a stale-high
observation can admit orders the float cannot cover.

**So a float monitor must push, not just poll:** run `refresh_float` on a schedule
(hourly is plenty when idle) and alert on both the returned value *and*
`lastObservedFloat.atNs` falling behind. Checking `atNs` alone tells you the number
is old; it does not make it fresh.

⚠️ **This is the one place monitoring needs a privileged key**, and under the flat
controller model (§0) that key can also upgrade and drain the canister. Options, in
descending preference: run the scheduled `refresh_float` from a tightly-scoped
environment and treat that key as production-critical; or accept poll-only
staleness and compensate by alerting hard on `atNs` age; or keep a small
synthetic order flowing, which refreshes the observation as a side effect. Do not
put a controller key on a general-purpose monitoring host.

### Metric table

Severity: **P1** = wake someone; **P2** = same working day; **P3** = review weekly.

| Metric | Alert when | Sev | Action |
|---|---|---|---|
| `pricing_status.lastAttempt.ok` | false on two consecutive ticks | **P1** | §4 — order creation stops once the cache passes `maxAgeNs`. `detail` names the failing guard |
| `pricing_status.rates.fetchedAtNs` | older than `maxAgeNs` | **P1** | the rail has stopped selling. Timer dead or every tick rejected |
| `cycles_status.balance` | below 3× `minCanisterCycles` | **P1** | top up. At zero the canister is **uninstalled** and money-bearing state is lost. Note the XRC needs 1 B attached per refresh, so pricing dies before the gate does |
| `refresh_float` result | below ~2× the largest tier's ICP cost | **P1** | refill (§5). Held orders resume on the next sweep |
| `lastObservedFloat.atNs` | older than 2× your refresh schedule | **P1** | the float number is not trustworthy — see above |
| anonymous `can_purchase` | returns `#err` | **P1** | the rail is refusing sales; the reason says which lever |
| `error_queue_depth.unresolved` | `> 0` | **P2** | §6 triage. Depth climbing past 1,000 means work is accumulating faster than it clears |
| `treasury_status.paidOrders` | non-transient `> 0` | **P2** | money in, nothing minted — orders are on the clock toward `mintWaitExceeded` |
| `treasury_status.heldOrders` | non-transient `> 0` | **P2** | burn cap or float; both are §5 levers |
| `treasury_status.burnedInWindowE8s` | jumps beyond expected volume | **P1** | possible leaked secret → §2 procedure, cap to 0 first |
| `recovery_status.lastSweep.atNs` | older than 2 intervals | **P2** | the sweep timer is not running; nothing recovers while it is dead |
| `recovery_status.lastCountReconcile.drift` | non-empty | **P2** | the per-status tallies had diverged from the order store and were repaired. The counts are correct again; the bookkeeping bug that moved them is not fixed. They gate admission, so a drifted count refuses or admits the wrong orders |
| `recovery_status.lastCountReconcile.atNs` | older than ~48 h while `lastSweep` advances, or materially older than `lastCountReconcileAttemptNs` | **P3** | the daily reconcile is failing. It runs in its own message, so it cannot take the sweep down with it — money-out is unaffected — but the tallies are now **unverified**, not known-good. Written only on success, and the cadence is claimed by the sweep, so a reconcile that traps retries daily rather than every tick. `recount_orders` is the on-demand repair and will show the same failure if it is a real one |
| `reserve_status.openOrders` | climbing while `delivered` does not | **P3** | order-creation abuse; lever is `maxOpenOrdersPerPrincipal` (§5a) |
| `reserve_status.availableToSell` | 0, or far below `reserveFloor` − `promisedTotal` as you expect it | **P2** | the gateway is refusing sales. Three causes and the same query separates them: the reserve is genuinely spent (`reserveFloor` low), it is committed to live orders (`promisedTotal` high), or **the floor has not observed a top-up** (`reserveObservedAtNs` old). The last is the common one and the lever is `refresh_reserve` |
| `reserve_status.reserveObservedAtNs` | materially older than `recovery_status.lastReserveReconcileAttemptNs` | **P3** | the hourly reserve reconcile is attempting and not adopting: either the ledger read is failing (`reserve.observeFailed` in the audit log) or every attempt lands while a delivery is in flight (`reserve.reconcileSkipped`). Under-sells rather than over-sells, so it explains refusals; it is not a loss |
| `delivery.feeChanged` in the audit log | on **every** delivery rather than once | **P3** | the stored cycles-ledger fee is stale, so every order pays one rejected call before its transfer lands. Self-correcting by design — the first `#BadFee` persists the ledger's value — so a *repeating* tag means the correction is not sticking (an upgrade reverting the stored value, or the ledger's fee moving repeatedly). ⚠️ **This is the ONLY detector for a stored fee that will not stick**, since nothing but the ledger writes that value and the persistence itself is untested (`docs/TEST-COVERAGE.md`). Each occurrence costs one rejected call, never a wrong debit — the buyer still gets the quoted amount and the reserve absorbs the real fee. If it repeats, redeploy rather than looking for a lever; there is none, deliberately |
| `reserve.unexplainedShortfall` in the audit log | any occurrence | **P1** | the ledger holds LESS than the floor's lower bound, which the design says is impossible — no allowance exists and `withdraw` is unused. Treat as a bookkeeping breach: stop selling (`set_gate_config` with a high `minPurchaseUsdCents`, or pause), reconcile the journal against the ledger, and find the outflow before funding anything |
| an order still `created` past its own `expiresAtNs` | any | **P2** | a `checkout.session.expired` was missed. Nothing sweeps it (§5b, deliberately — a sweep would hide a held reserve): resend the event from the Stripe Dashboard. ⚠️ **You cannot query this today** — see the gap below |
| `pricing_status.xrcCanisterId` | anything other than `uf6dk-hyaaa-aaaaq-qaaaq-cai` | **P1** | **on mainnet this must be the real Exchange Rate Canister.** The id is resolved from a `PUBLIC_CANISTER_ID:xrc` canister environment variable so a local network can point at a mock; a mainnet canister reporting any other id is pricing real sales off something that is not the market. Only a controller can inject it, so this reads as either a misconfigured deploy or a compromised controller. Cap the burn to 0 (§2) before investigating. **`null` is not a pass** — it means no refresh has reached the XRC call at all (expected for seconds after an install or upgrade, since the value is transient). Do **not** wait on `lastAttempt` becoming non-null: that field is persistent, so it survives the upgrade and is already set while this one is still null. Re-read until `lastAttempt.atNs` post-dates the deploy. A *failing* refresh never shows null here — the id is recorded when the call is constructed, so a rejected call reads as a non-null id plus `lastAttempt.ok = false` |
| `pricing_status.rates.quality.receivedRates` | drops to `minRateSources` | **P3** | thin market — a price from 2 sources is not one from 12 |
| `health` | unreachable | **P1** | canister stopped, frozen, or out of cycles |

⚠️ **One row above is not yet observable, and saying so is the point.** "An order
still `created` past its own `expiresAtNs`" is #30's detection predicate 1 — the
signal that exists *because* #33 refused to add a sweep that would have hidden a
held reserve. Nothing exposes it:

- `get_order` / `list_orders` / `receipt` are **owner-scoped**. Not even a
  controller can read another principal's order.
- `reserve_status` returns counts, not records — it cannot tell a fresh `created`
  order from one that lapsed an hour ago.
- An admin order listing is **#38**, not built yet.

So today the predicate is reachable only through a buyer's complaint or the
Stripe Dashboard's own event list. Until #38 lands, the interim signal is
`reserve_status.openOrders` **staying non-zero and static well past ~40 minutes**
(the session lifetime is ~35), cross-checked against expired sessions in Stripe.
That is weaker than an alert and it is the honest state of it — a runbook that
claims an alert nobody can wire is worse than a documented gap.

### Needs a controller key

- **`audit_log` tags** worth alerting on: `stripe.livemodeMismatch` (real money may
  be landing in the wrong Stripe account), `stripe.creditedElsewhere`,
  `stripe.unprocessable` / `stripe.unhandledType` (a Dashboard config producing
  events this gateway cannot use — it will recur until changed),
  `orders.countDrift` (the status tallies were wrong; see the table above),
  `stripe.refundPartial` (an obligation deliberately left open), and `delivery.stuck`.
- **`error_queue_unresolved`** for the entries themselves. `error_queue_depth` is
  public, so **alert on the public depth and only fetch details when it fires** —
  that keeps the key out of the polling loop.
- ⚠️ Gaps in `audit_log`'s `seq` mean the 4,096-entry ring dropped events. Read it
  often enough that it doesn't, and remember it is *telemetry*: the order store,
  mint journal and error queue are the records of money.

### Off-chain

- **Stripe Dashboard → event deliveries.** A run of failures means the secret is
  out of sync or the gateway is unhealthy. Stripe retries non-2xx for ~3 days, so
  transient failures lose nothing — but a *permanent* 4xx can get the endpoint
  disabled, which is why verified-but-unprocessable events are acked 200 (§6).
- **Stripe payouts and disputes.** Disputes produce **no on-chain signal** (only
  `charge.refunded` is subscribed), so the Dashboard is the only control.

### Do you need a dashboard?

**Alerting first, dashboard second** — and the order matters. The failure modes
here are slow (a 2 h alert window, a 72 h terminate bound), so what you need is
something that reaches a human at 03:00, not a page someone visits. A cron job
polling the public queries and posting to Slack/PagerDuty covers the entire table
above except the audit tags, and needs no credentials.

A dashboard earns its place afterwards, for the things alerts are bad at: float and
burn-rate trends, order volume, delivered-vs-open ratios, rate quality over time.
Everything it needs is a public query, and the frontend already reads
`treasury_status` for its low-float soft gate — so a read-only operator page is
straightforward. It is a convenience, not a control.

## 9. Confidential-subnet checklist (§7, §11.1)

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

## 10. Upgrades & releases

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
  completes before the upgrade happens, so a controlled
  upgrade cannot strand money. Verified by `test/integration` scenarios 12
  and 13.

  Consequence: `ambiguousForward` and `stalePullIntent` are **not** reachable
  through a controlled upgrade. They cover genuine faults — a callee that
  never replies, a subnet incident, running out of cycles mid-call — and
  §8's triage rules still apply when they appear.

- **A call that never replies blocks the stop, and therefore the upgrade.**
  If `icp canister stop` hangs, the canister is waiting on an outstanding
  call. Check `recovery_status.sweepInFlight` and the audit log for a stage
  that keeps retrying; the money path is journalled at every step, so
  waiting is safe.

- **Locally, a stable-shape change is a reinstall, not a migration.** A new
  field, a removed variant tag or a changed config record makes the upgrade trap
  in `register_stable_type` — enhanced orthogonal persistence refuses to
  reinterpret the existing memory. On a local network the answer is:

  ```bash
  icp deploy --mode reinstall --yes
  ./scripts/local-dev-seed.sh
  ```

  which wipes local orders, the audit log and the mint journal, and takes
  seconds. `scripts/e2e-local.sh` detects the trap and does it automatically.

  ⚠️ **This is a development lever and has no mainnet counterpart.** `reinstall`
  discards every order, journal and dedup set, so on mainnet a shape change needs
  the mops migration chain (issue #32) — which is why no migration file is written
  before the schema settles: every file replays forever on a fresh install.

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
