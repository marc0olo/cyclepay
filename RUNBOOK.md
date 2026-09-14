# Operations runbook

Day-2 operations for the cycles gateway: provisioning, money levers, error
triage, incident response. Build/upgrade/verify procedure lives in
`RELEASE.md`; first-time setup for all three modes in `docs/OPERATE.md`.

**`§N` always means a `docs/DESIGN.md` section** (spec v2.1) — that is what the `§N`
comments in the code point at too. This file's own sections are referred to **by name**,
because a bare `§5a` meant two different things depending on which file you were reading
and `check-design-sections.py` read one of them as the other.

## Enter here: what you are looking at

This file is read under pressure, by lookup. Find the symptom, not the section number.

| what you are seeing | go to |
|---|---|
| the rail refuses every purchase, `refusingNow.railClosed` | **3. Presets, the API key** — the rail opens when both secrets are provisioned |
| `refusingNow.reserveShort`, or `availableToSell` is 0 while the ledger holds cycles | **5. The cycles reserve** — a floor that only rises by observation |
| `refusingNow.stripeApiFailing` latched | **8. Monitoring** P1 rows — one lever: rotate the key |
| an order sits at `created` past its own `expiresAtNs` | **5b. Order expiry** — the missed-event case, and why nothing sweeps it |
| buyers report that cancelling does nothing | **8. Monitoring** P2 — run `expire_order` once, read `order.expireRaced` |
| a buyer paid and was never credited | **6. Obligations** — the `#paidNotCredited` row. Resend first, always |
| `pricing_status.lastAttempt.ok` is false, or a quote returns no cycles | **4. Pricing rates** — the staleness window is a security control |
| a delivery is stuck, delayed, or you must establish where the money is | **6. Obligations** and **7. Recovery timer** |
| you suspect the webhook secret leaked | **2. Webhook secret** — rotate, and know what you cannot do |
| an unexpected principal can or cannot buy | **5a. Admission gate** |
| you are about to upgrade the canister | **10. Upgrades & releases**, then `RELEASE.md` |
| you are setting a deployment up for the first time | not here — `docs/OPERATE.md` |

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

**For reads, open the console first (#68).** Every read-only command in this
runbook is also a panel at `#/admin`, so a triage that used to be a sequence of
typed calls is now one screen. The `Admin` header link appears for a controller
or a granted admin and for nobody else.

| panel | what it shows |
|---|---|
| **Now** (default) | the summary split into what needs a person and what clears itself, the reserve, and refusals since deploy |
| **Worklists** | orphans · problems · delayed · pending, as sortable tables |
| **Orders** | order history, paged · look up one order by id |
| **Diagnostics** | `health` · queue depths · the recovery sweep with its count drift · the audit trail, newest first and paged |
| **Configuration** | the config groups, the write commands, and this browser's identity |

⚠️ **The CLI is still the answer for four things**, and the panels do not replace
them: anything that **writes** (the console prints the command for you to run,
it does not send it); reading when the **frontend is down or not yet deployed**,
which is most of `docs/OPERATE.md`; a **scripted or monitored** read, where the public queries
below are the interface; and `-e ic` **before** the frontend canister exists.

⚠️ **Opening the console spends no audit entries.** `admin_order`,
`admin_receipt` and `delivery_journal` are updates precisely so the read is
recorded (#38), so no panel calls them on open — the Orders lookup is explicit,
and one deliberate lookup is one audited read.

Public queries (`reserve_status`, `pricing_status`, `recovery_status`,
`card_tiers`, `lifecycle_config`, `can_purchase`, `cycles_status`,
`orphan_depth`, `health`) work from any identity and are the monitoring surface (§8's verifiability stance — operational state is public,
the webhook secret is the only secret in the system).

**Units used throughout:** money is US cents (`usdCents`); durations are
nanoseconds (1 h = `3_600_000_000_000`, 24 h = `86_400_000_000_000`,
72 h = `259_200_000_000_000`); cycle prices are XDR-pegged (1 XDR = 1 T
cycles).

## 2. Webhook secret — provisioning & rotation (§7)

HMAC is symmetric, so verify = forge — anyone holding this secret can forge "paid"
webhooks and drain **the entire reserve**, one order at a time, at the operator's expense.
⚠️ **The reserve balance is the blast-radius bound, so size it to what you can afford to
lose in one window** — there is no per-period cap standing behind it. It is stored
**plaintext by design** (`Secret.mo` documents the SEV-SNP posture; the confidential-subnet
checklist below is the checklist).

**Provision / rotate — the value is sealed, never typed into a call:**

```bash
# Reads STRIPE_WEBHOOK_SECRET from the environment (or scripts/.local-dev.env).
STRIPE_WEBHOOK_SECRET='whsec_…' scripts/seal-secret.sh webhook-secret ic
```

⚠️ **`set_webhook_secret` takes a `blob`, not the string** (§7.3). It is an IBE ciphertext
sealed to this canister's vetKD public key, so the plaintext never becomes an ingress
argument. Calling it by hand with a quoted `whsec_…` returns `#notCiphertext`.

⚠️ **The trailing `ic` is what selects the MAINNET master key, and it is not optional.**
Mainnet and a local network both have a vetKD key called `key_1` backed by *different*
master keys, so the name does not identify the key. Omit the argument and the script
defaults to `local` → the PocketIC master key → a ciphertext this canister can never
open, reported as `#notSealedToThisCanister`. The script derives the choice from that one
argument precisely so it is never a separate flag to get wrong.

- Pass the **full `whsec_…` string** in the environment variable — the whole string,
  prefix included, is the HMAC key (matches Stripe's reference verifiers).
- The 16-byte floor applies to the **decrypted** value (`#tooShort`), and the working
  secret is left untouched on any rejection — a fat-fingered rotation, a wrong master key
  or a plaintext argument all leave the webhook working.
- `webhook_secret_status` returns `{isSet; generation; setAtNs}` —
  `generation` increments per successful set, so ops can confirm a rotation
  landed **without any read-back path existing** (not even for
  controllers).

**Rotation procedure** (Stripe-side overlap makes it zero-downtime):

1. In the Stripe Dashboard, roll the endpoint's secret with an overlap
   window. During overlap Stripe signs each delivery with **one `v1=` per
   active secret**, and the canister's verifier accepts *any* matching
   `v1` — so order of operations is forgiving.
2. `scripts/seal-secret.sh webhook-secret ic` with the new `whsec_…` in the
   environment; confirm `generation` bumped.
3. Expire the old secret in Stripe after confirming deliveries succeed.

**Provisioning exposure — closed** (§7.3). This used to read: *the argument transits the
TLS-terminating boundary node as ordinary ingress, so treat the first secret set over any
untrusted path as burned.* That is no longer true, and the advice is withdrawn rather than
softened: the ingress argument is ciphertext, useless to the boundary node and to anything
reading a shell history or a CI log. Sealing does nothing for the **at-rest** exposure,
which is the confidential-subnet checklist below.

**Suspected leak — immediate actions** (in this order):

1. ⚠️ **Know what you can and cannot do.** A forged webhook drains at most what the
   reserve holds — that balance **is** the blast radius, and there is no cap or pause
   lever standing behind it.

   ⚠️ **`withdraw_reserve` exists (#103) but it will REFUSE during an incident, and
   that is by design.** It is guarded on there being no promise-holder at all, and a
   forged drain means forged orders are open — so the guard fires. Do not plan an
   incident around a one-call evacuation; there isn't one.

   What you *can* do immediately is stop **new** orders while you roll the secret: the
   rail is live only while both Stripe secrets are provisioned, so rotating the webhook
   secret (step 2) closes it until the new one is set. Forged orders already in flight
   will deliver.

   **The evacuation path is three steps, and step 2 cannot be forced:**

   1. Rotate the webhook secret (step 2 below). This closes the rail to new orders.
   2. Clear every promise-holder. `reserve_status.promiseHolders` is the count, and it
      must reach **zero**.
   3. `withdraw_reserve`, which now passes its guard.

   ⚠️ **Step 2 is a wait, not a lever, for anything with a delivery in flight.**
   `abandon_order` refuses a paid order whose delivery is outstanding — *"whether its
   cycles moved is not yet known — abandoning it now would refund a buyer who may
   already hold them"* — so a forged order that is already being delivered cannot be
   cleared on demand. It has to settle, or reach `needsReview` at the ~24 h dedup
   window where the ledger is the source of truth. `process_order` re-drives a stalled
   delivery; `pending_deliveries` is the live view.

   ⚠️ **There is deliberately no lever that releases a promise over an unresolved
   delivery**, and that is the same property the withdraw guard has: the reserve does
   not move while any buyer's fate is unknown. Plan the incident around this, not
   around a one-call evacuation.

   Until `promiseHolders` reads zero the reserve stays where it is.

   The standing control is therefore still a sizing decision made **before** an
   incident: keep the reserve at what you are willing to lose between detection and
   rotation. `reserve_status.availableToSell` is that figure.
2. Roll the secret in Stripe + `set_webhook_secret` (steps above).
3. Reconcile: compare `audit_log` / order store against the Stripe
   Dashboard's event log; forged "payments" have no matching Stripe
   payment_intent. Refund nothing that has no real charge.
4. Refund the reserve to its sized level with `icp cycles transfer`, then
   `refresh_reserve` so the gateway observes it. ⚠️ **There is no "resume held
   orders" step** — an order refused for `#reserveShort` was never created, so
   nothing is waiting to be released. Legitimate buyers retry and succeed.

   ⚠️ **The order of steps 2–4 is itself the control, so do not renumber them.**
   Refunding the reserve before the secret is rolled hands the attacker a freshly
   funded account and the capability to drain it again — the reserve's usefulness as
   a bound depends entirely on cycles re-entering the account *after* the forgery
   capability is dead. Rotate, then reconcile, then refund.

## 3. Presets, the API key, and the settings that must stay off (§3, §6.1)

The canister creates a **Checkout Session per order** through the Stripe API,
with inline `price_data`. There are no Products, no Prices, no Payment Links and
no Dashboard objects to create — which is why this section is four commands
rather than a click path through three screens.

### Provisioning, in order

```bash
# 1. The API key. RESTRICTED (rk_). Permission: Checkout Sessions = WRITE, everything
#    else None. Write is the level that also grants read, and the recovery sweep needs
#    the read: it retrieves a session to settle an order whose expiry event never
#    arrived (#52). A key without it 401s on every retrieve and stranded capacity is
#    never released — watch for refusingNow.stripeApiFailing (monitoring).
#
#    SEALED (§7.3): the key is encrypted to this canister before it is sent, so it never
#    appears in an ingress message, a shell history or a CI log. The trailing `ic` selects
#    the MAINNET master key — omitting it seals against PocketIC's and the canister will
#    refuse with #notSealedToThisCanister.
STRIPE_API_KEY='rk_...' scripts/seal-secret.sh api-key ic

# 2. Where Stripe returns the buyer. Validated: https, no query, no fragment.
#    Not a secret — it is the URL buyers are sent to — so it is set directly.
icp canister call backend set_stripe_origin '("https://<your-origin>")' -e ic --identity <operator>

# 3. The webhook signing secret (DESIGN §7). Sealed the same way; rotation is
#    the webhook-secret section above.
STRIPE_WEBHOOK_SECRET='whsec_...' scripts/seal-secret.sh webhook-secret ic

# 4. The price tiles. ⚠️ REQUIRED for a usable page, whatever the canister accepts:
#    with an empty list the buy view renders no tiles AND no custom field, because
#    `renderTiers` returns early and the custom tile is built after that return. See `docs/OPERATE.md`
#    step 4. Do not register a $100 preset; that is the ceiling and the custom field's job.
icp canister call backend set_card_tiers \
  '(vec { record { id = "t10"; usdCents = 1_000 : nat } })' \
  -e ic --identity <operator>
```

⚠️ **Use a restricted key, not an `sk_`.** A leaked write-sessions key can create
sessions that pay *you*; one that can issue refunds is a materially worse thing
to leak. Stripe's IP and ASN allowlists are unusable here — a subnet's replicas
have many changing addresses.

⚠️ **Neither secret can be read back out, even by a controller.** `stripe_api_key_status`
and `webhook_secret_status` report a generation counter and a set timestamp, which is
how you confirm a rotation landed without ever exposing the value. `seal-secret.sh` prints
the relevant status after each successful set.

⚠️ **Put the values in `scripts/.local-dev.env` or export them — never on the command
line.** `seal-secret.sh` reads them from the environment on purpose. A secret typed as an
argument lands in shell history, in `ps` output and in CI logs, which would reopen the
exposure sealing exists to close. The examples above show the variable inline for brevity;
in a real session, export it or use the file.

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
within `[minPurchaseUsdCents, maxPurchaseUsdCents]` (the admission-gate section), or the whole call
rejects and the live tier list is untouched. `card_tiers` is the public query the
frontend renders.

Note the §3 invariant: a tier's *cycle* quantity is locked per-order at creation
time from the cached rate pair, so changing tier prices never reprices existing
orders. And since #33 the paid amount must **equal** the quoted one — an order
delivers what it locked, or it delivers nothing and files a refund obligation.

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
| **Automatic tax** (account default) | **off** | raises `amount_total`; the payment is refused as a mismatch, so nothing is delivered — but every order fails until it is turned off |
| **Adaptive pricing** (Dashboard toggle) | pinned off by the request | currently harmless to `amount_total` for this shape; the request pins it anyway, and it is proof Stripe adds Dashboard-side amount changers over time |

Plus the two already in `docs/OPERATE.md`: **USD** (any other currency is refused as
`#unattributed`, a refund obligation) and **card-only**
(delayed methods are handled, but they make money-in asynchronous).

⚠️ Since #33 a mismatch is no longer silent. It used to reprice from the order's
own snapshot and deliver a different quantity, with the audit log showing an
ordinary completed purchase and no alert anywhere. It now delivers nothing and files
an `#unattributed` whose detail names both figures — so an amount-moving setting shows up
as a queue entry on the first order, not as a slow drift in what buyers receive.

⚠️ **Test-mode and live-mode keys are different objects.** Going live means a
live-mode restricted key and a live-mode webhook secret, both re-provisioned
against the mainnet canister. Once `set_expected_livemode '(opt true)'` is set, a
stray test-mode event is refused and tagged `stripe.livemodeMismatch` (the monitoring section alerts
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
icp canister call backend quote_previews '(vec { 500 : nat })' -e ic  # public: what an amount buys
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

## 5. The cycles reserve

### Funding the reserve

⚠️ **On a gateway that accepts Stripe TEST payments, populate the buyer allow-list
BEFORE you fund the reserve** (#99). Test payments are free and unlimited, so test mode
plus an empty allow-list plus a funded reserve is a cycles faucet, and the gateway
refuses every buyer in that state rather than giving cycles away
(`refusal_counts.refusingNow.unboundedGiveaway`). Funding first is not dangerous — it
is simply the order that produces a deployment that refuses to sell until someone
notices why.

```bash
# Who may buy while test payments are accepted. Controller only.
icp canister call backend add_allowed_buyer '(principal "<tester>")'
icp canister call backend allowed_buyers '()'
```

An **unfunded** reserve refuses every order at `Gate.solvent` anyway, before a Stripe
session is even created — so a sandbox deployment is safe to explore before either the
allow-list or the reserve exists. Only paying needs both.

⚠️ **`icp` defaults to the LOCAL environment**, so every command in this section needs
`-n ic` (the cycles ledger) or `-e ic` (a canister) to act on mainnet. Omitted, they
succeed against a local network and report a balance that has nothing to do with the one
being funded.

```bash
# The reserve IS the gateway's own cycles-ledger account.
icp cycles transfer 100t <backend-principal>          # -n ic on mainnet

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

⚠️ **Nothing creates cycles here.** Refills are `icp cycles transfer` from outside.

⚠️ **`withdraw_reserve` exists as of #103, and #30's reason for rejecting it had
expired.** That reason was *"the app is not in production and an over-funded local
reserve costs nothing"* — true then, and false the moment the reserve is funded on
mainnet, where it is real money in a ledger account with nothing to retrieve it.

It is controller-only and refused while **any** promise-holder exists, so nothing can
be owed to a buyer when it runs. It grants a controller no capability they lack: a
controller can already move the reserve by upgrading the canister. ⚠️ **A
decommissioning lever, not an incident one** — see the three-step evacuation in the
suspected-leak section above.

⚠️ **THREE balances, and confusing them is the most common local-setup failure.**
The reserve is not special — it is just the backend canister's account on the cycles
ledger, funded by a plain transfer to the canister's own principal.

| balance | what it is | read it with | fund it with |
|---|---|---|---|
| **gas** | what the canister spends to *run*, gated by `minCanisterCycles` | `icp canister status backend` | `icp canister top-up` |
| **the reserve** (stock) | what the canister *sells* — its cycles-ledger account | `reserve_status`, or `icp cycles balance --of-principal <backend-id>` | `icp cycles transfer <amt> <backend-id>` |
| **your own account** | what funds both | `icp cycles balance` | mint from ICP |

An unfunded reserve looks like orders that pay and then never deliver.

⚠️ **A failed top-up reports the SENDER's balance, under a message about the reserve.**
`icp cycles transfer` answers *"insufficient funds. balance: N"* where `N` is **your**
cycles-ledger balance — not the reserve's. The two can differ by orders of magnitude
(measured during a reinstall: reserve 675 T, sender 53 T), so reading `N` as the reserve's
sends you to fund something that is already full.

⚠️ **The reserve survives a canister reinstall; the floor does not.** The account belongs
to the canister's principal and the cycles ledger is a different canister, so a
`--mode reinstall` leaves the stock intact and resets `reserveFloor` to 0. The fix is
`refresh_reserve`, not a transfer.

## 5a. Admission gate: who is allowed to start an order

Order creation is refused before any quote when fulfilment is already
impossible. This is separate from, and in addition to, the solvency check in
the reserve section — the point is to refuse *before* the customer pays Stripe.

```bash
icp canister call backend lifecycle_config '()' -e ic     # public: gate AND delivery bounds
icp canister call backend can_purchase '(500 : nat)' -e ic  # public: would this be admitted?
# ⚠️ Read the CURRENT config and change one field. The record is whole-value: every
# field you type replaces the live one, so a pasted example silently re-bases the
# levers you did not mean to touch. This example restates the defaults below.
icp canister call backend set_gate_config \
  '(record { maxOpenOrdersPerPrincipal = 1 : nat; minCanisterCycles = 5_000_000_000_000 : nat;
             maxPurchaseUsdCents = 10_000 : nat; minPurchaseUsdCents = 1_000 : nat })' \
  -e ic --identity <operator>
```

| Lever | Default | What it protects | Sizing |
|---|---|---|---|
| `maxOpenOrdersPerPrincipal` | **1** | Unbounded state growth. Abandoned orders are the only thing a user can create for free, so this is the real bound. Nothing sweeps them away (the order-expiry section): a slot frees when Stripe expires the session, when the buyer cancels, or via `expire_order`. | ⚠️ **1 is a product choice and it is felt.** A buyer who abandons a checkout cannot start another until that session expires (~35 min) — including whoever is demoing this. Raise it for power users; must be > 0, and 0 is rejected as config. |
| `minCanisterCycles` | 5 T | **This canister's own gas.** Below it the gate stops admitting NEW orders. It does not gate delivery, cancellation or the webhook, so a paid order is still delivered below the floor. | Sized against a gas **drain**, not against freezing: freezing is ~149x further down (~34 B, 30 days of idle burn), so at 5 T sales close with over a year of runway in hand. It is the only bound on order flooding from rotating principals, and on a revoked Stripe key retrying its session outcall at ~220 M a try. Lowering it toward the freezing threshold removes that bound. `0` disables the check. |
| `maxPurchaseUsdCents` | **10 000 (\$100)** | Operator typo in a tier, and the webhook's upward repricing path. ⚠️ **It IS the per-order reserve exposure**, which is why #33 lowered it from \$1 000 — it is the main lever against reserve griefing. | Set just above your largest tier. `set_card_tiers` rejects any tier above it, and the webhook refuses to deliver against a payment above it. |
| `minPurchaseUsdCents` | **1 000 (\$10)** | A purchase too small to be worth an outcall and a reserve hold — and one that does not buy what a buyer came for. | Two independent floors hold it at \$10: the 30¢ fixed fee is 9.0% of \$5 against 5.9% of \$10, and \$5 buys 3.313 T against the **4.0 T** two default-funded canisters need, so it fails on the second one. `docs/BUYER-COST-MODEL.md` carries the model, and `test/buyer-cost.test.mo` pins it. |

**All four deliberately default to non-zero**, unlike the tier list. A limit where 0
would brick the canister rather than protect it has to ship armed. ⚠️ **The tier list is
no longer the rail's on/off switch** — since #33 that is "both Stripe secrets
provisioned", and an empty tier list stops no purchase the canister can see (the presets-and-keys section).

⚠️ **This table's Default column is pinned to the code.** It was wrong in two of four
rows for long enough that the `set_gate_config` example above pasted a \$1 000 ceiling
and a cap of 20 — an operator following `docs/OPERATE.md`'s Mode 3 step 9 to "review the admission gate" would
have re-based the exposure #33 lowered on purpose. `test/gate.test.mo` now fails
with the lever that moved, beside the example it has to match.

`can_purchase` returns the same decision `create_order` would make, so it is
both the frontend's button-gating call and the operator's "would a purchase go
through right now?" check. Two operational gotchas:

- ⚠️ **`can_purchase` does NOT cover solvency, and cannot.** It is a query, and
  reading the reserve is what the gate does synchronously inside `create_order`. So a
  green `can_purchase` alongside `reserve_status.availableToSell = 0` is not a
  contradiction — it is the split working. Check both.
- **An unobserved top-up is the most likely reason the rail goes quiet.**
  `reserveFloor` only rises when the canister looks, so a funded reserve sells
  nothing until `refresh_reserve` runs (the hourly sweep does it too).
  `reserve_status.reserveObservedAtNs` is how you tell that from a spent reserve.

## 5b. Order expiry — Stripe owns the clock

```bash
icp canister call backend reserve_status '()' -e ic   # public counters
```

**There is no retention config, no TTL and no sweep.** #33 deleted
`Retention.mo`: an order's deadline is its Checkout Session's `expires_at`
(~35 min, above Stripe's 30-minute floor), stored on the order, and the only
*event* that moves an order to `expired` is Stripe's `checkout.session.expired`.
A buyer freeing their own open-order slot uses `cancel_order` (owner-scoped),
which produces `cancelled` — a separate status.

⚠️ **Three things reach `expired`, not one, and the difference decides your remedy.**
This section said "the only thing" for long enough that the monitoring section's own P1 row contradicted it:

| | reaches `expired` | when it does not |
|---|---|---|
| `checkout.session.expired` | the normal path; releases the promise | never sent if the event is not subscribed (`docs/OPERATE.md`, Mode 2) |
| `cancel_order` (owner) | produces `cancelled`, also releasing | expires the session at Stripe first, so a paid race wins |
| `expire_order` (admin) | asks Stripe to expire, then settles | ⚠️ refuses `#sessionNotOpen` once the session has *already* expired or completed at Stripe — which is exactly the missed-event case below |

`expire_order` is therefore the manual release for an order whose session is **still
open** at Stripe, and for the residue class with no `stripeSessionId` at all (expired
with no outcall). It is **not** the remedy for a missed expiry event.

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

**The lever for THIS case is off-chain: resend `checkout.session.expired` from the
Stripe Dashboard** (the monitoring section's P2 row) — because the session has genuinely expired there, so
`expire_order` refuses it (table above). ⚠️ An earlier version of this note said there was "no
operator lever at all", which contradicted that row — the honest statement is that
the remedy exists but is **gated on noticing**, because nothing on-chain surfaces the
stranded order. That observability gap, and an on-chain remedy, are what #30's ranked
fixes describe; PR-B does not close them. Bounded per incident by the purchase
ceiling, and unbounded only in aggregate against a failure that Stripe itself retries
for ~3 days first.

⚠️ **Nothing exposes it yet**: order reads are owner-scoped and `reserve_status`
carries only counts, so the monitoring section records this as a gap with an interim signal rather
than as an alert you can wire. #38 (admin order listing) is what closes it.

⚠️ **A payment arriving against an expired or cancelled order cannot be
converted** (#34 deleted `#expired → #paid`). It answers 200, the status does not
move, and an `#unattributed` entry is filed carrying the payment intent.
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

| Call | `max_response_bytes` | n = 13 (application subnets, and the local network) | n = 7 (the confidential subnet, our target — #2) |
|---|---|---|---|
| create a session (`create_order`) | 16,384 | **≈ 220 M cycles** (~$0.0003) | **≈ 118 M cycles** |
| expire a session (`cancel_order`, `expire_order`) | 16,384 | ≈ 220 M | ≈ 118 M |
| **retrieve a session** (the #52 sweep) | **32,768** | **≈ 390 M cycles** | **≈ 207 M cycles** |

Work with the 13-node figure: it is the conservative one, and the local network
prices on it, so local runs *overstate* production cost. At 20 T gas with a 5 T
floor, the headroom depends on **whether webhooks are working**, and the two cases
are worth keeping apart:

| | cost per abandoned order | creations before the rail closes (n=13) | (n=7) |
|---|---|---|---|
| **Webhooks healthy** — the ordinary case | one create, ≈222 M | **≈68,000** | ≈128,000 |
| **Webhooks failing** — a missed expiry event per order | create + retrieve, ≈612 M | **≈24,000** | ≈46,000 |

⚠️ **The retrieve is NOT on the abuse path in normal operation, and the grace is
what keeps it off.** Stripe fires `checkout.session.expired` within seconds of the
deadline, so an abandoned order is already `#expired` about half an hour before the
sweep would look at it — `expiryCheckDue` tests the status first. So a buyer, or an
attacker, abandoning orders costs the gateway one create outcall each, exactly as
before #52. The second row is the *degraded* case: it needs the webhook path broken
as well, which is a different incident with its own P1 rows in the monitoring section.

⚠️ **These four figures are computed from the formula above, not carried forward.** At
`max_response_bytes` 16,384 and 32,768 with a 15 T spendable balance they are 67,685 /
128,413 healthy and 24,515 / 46,236 degraded — recompute rather than reuse if a cap
changes, because a stale performance number reads exactly like a measured one. (The
previous ≈127,000 here was slightly low for n=7.)

Either way the shape is unchanged — this is **availability, not memory**, it closes
the rail via `minCanisterCycles` rather than freezing the canister, and it takes
hours of sustained paid-for abuse. And one thing improved in the same change: the
per-principal *instantaneous* strand fell from 20 open orders to **1**, a 20×
reduction in what a single identity can tie up at once (#52 PR-B).

⚠️ **The retrieve's cap is deliberately double the others', so its call costs
roughly double.** A *completed* session carries `customer_details`, a resolved
`payment_intent` and `total_details` that a freshly created one does not, and an
over-cap response fails the call outright rather than truncating. Two consequences
worth knowing before tuning it down: the sweep only retrieves for orders that are
**already stranded**, so in normal operation this line is zero calls per day; and
the stranded population is **correlated** — one unprovisioned webhook secret
strands every order in its window at once — which is why the sweep caps retrieves
per pass (`Recovery.maxRetrievesPerPass`) and resumes rather than draining a
backlog in one go.

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
`maxOpenOrdersPerPrincipal` (the admission-gate section) bounds what a user can create for free, and the
reserve bounds legitimate volume — nobody can buy more than it holds. An order is a
few hundred bytes, so a
million is a few hundred MB — and a million orders is millions of dollars of
volume. If store size ever genuinely binds, archive to a separate canister;
deleting a financial record is not the answer.

Monitor `reserve_status.openOrders` — climbing while `delivered` orders do not
is the signature of order-creation abuse, and the lever is
`maxOpenOrdersPerPrincipal` (the admission-gate section). `totalOrders` and `paidIntentsIndexed` should
grow together and never diverge.

## 6. Obligations — triage (§4.1)

```bash
icp canister call backend orphans '(null, 50 : nat)' -e ic --identity <operator>
icp canister call backend resolve_orphan '(42)' -e ic --identity <operator>
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
| the transfer **did** land — the buyer has the cycles | `record_delivered '("<orderId>", <blockIndex>)'` then `resolve_orphan '(<entryId>)'` | `Delivered`, with the block recorded in the journal |
| it did **not**, and you refunded the fiat by hand | `abandon_order '("<orderId>", "<reason>")'` then `resolve_orphan '(<entryId>)'` | `Abandoned`, reason in the audit trail |

⚠️ **Neither lever closes the queue entry — `resolve_orphan` is the last step, always.**
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
**Only a *full* `charge.refunded` auto-resolves an entry** — Stripe fires
the same event for partial refunds, so the canister compares `amount_refunded`
against the charge's `amount`. A partial refund leaves the entry open and audits
`stripe.refundPartial`; finish the refund in the Dashboard (or close the entry by
hand once reconciled). Everything here is manual: the self-resolving cases are no longer entries at all (#37).
A delivery running late is a *reading* — `delayed_deliveries` — not an obligation.

**Nothing is ever evicted (#37).** The former soft cap of 1,000 is gone as a
parameter: an unresolved entry is an open obligation — usually someone's money — so
the list **grows rather than dropping one**. That makes `orphan_depth` a real alarm
instead of a saturating gauge: a depth climbing past ~1,000 means
unresolved work is accumulating faster than it is being cleared, and no amount
of ignoring it can lose an obligation.

Paginate with a cursor rather than fetching the whole queue:

```bash
icp canister call backend orphan_depth '()' -e ic          # public: {total; unresolved}
icp canister call backend orphans_unresolved '(null, 50)' -e ic --identity <operator>
icp canister call backend orphans '(opt (120 : nat), 50)' -e ic --identity <operator>
icp canister call backend resolve_orphan '(137 : nat)' -e ic --identity <operator>
```

`orphans_unresolved` is the worklist; pass the last id returned as
`afterId` to page forward. Page size is capped at 200.

**Two columns decide everything: the money position, and whether a refund can settle
it on its own.** The second is `Orphans.refundResolvable` — true only where the
remedy is exactly "refund the fiat", so the `charge.refunded` webhook can close the
entry without a human deciding anything.

| Kind | Refund settles it? | Money position | Action |
|---|---|---|---|
| `#duplicate {orderId; paymentRef}` | ✅ **yes**, automatically | Fiat in twice for one order; the second payment delivered nothing | Refund `paymentRef` in the Stripe Dashboard (search by payment_intent). The `charge.refunded` webhook auto-resolves the entry; `resolve_orphan` is the fallback. |
| `#unattributed {claimedRef; paymentRef}` | ✅ **yes**, automatically | Fiat in, and no order that can accept it: a bad or missing `client_reference_id`, an owner/rail/currency mismatch, **a paid amount that is not the one the order asked Stripe for**, or a payment against a `cancelled` or `expired` order — the common producer. The entry's `detail` says which | Inspect the session in Stripe by `paymentRef`, then **refund** → auto-resolve (or `resolve_orphan`). This is the only remedy, whatever the order's status. ⚠️ If the detail says the amount is not the quoted one, refunding is not the end of it: the session carried our own figure, so something in the Stripe configuration moved the total — check the forbidden-settings list in `docs/STRIPE.md` before the next order, because it will recur. |
| `#deliveryStuck {stage}` (on the order) | ❌ **no** — see the stage table below | **Depends entirely on `stage`.** One of them means the buyer may already hold their cycles, so a blind refund pays twice | Read `stage` first, then follow its row |
| `#refundAfterDelivery {paymentRef; cycles; refundedCents; fullRefund}` (on the order) | ❌ **no, and never** | **A loss, not a recoverable position**: the fiat was refunded or charged back *after* the cycles were credited. Cycles cannot be clawed back | Nothing to recover on-chain. Reconcile in the Dashboard by `paymentRef` to see whether this was your own refund (a support decision) or a dispute (a fraud signal). For repeated disputes, tighten Stripe Radar and lower the per-purchase ceiling (the admission-gate section). ⚠️ **Nothing auto-resolves it, deliberately: the refund is the event that created it**, so resolving on that event would close the entry with the loss unrecorded |
| `#paidNotCredited {orderId; paymentRef; sessionId}` | ❌ **no — and a refund alone makes it worse** | **The buyer paid and this gateway never credited them.** Found by the recovery sweep asking Stripe about a `#created` order past its deadline, once Stripe has had longer than its ~3-day redelivery window to hand us the `completed` event it owed. The order is still `Created`, so it still holds reserve capacity — correctly, because the cycles are genuinely owed | ⚠️ **RESEND FIRST, ALWAYS.** Find the event in the Stripe Dashboard (search by `paymentRef`) and resend `checkout.session.completed`. That credits the order through the normal path, delivers the cycles, and **closes this entry automatically**. <br><br>⚠️ **Refunding instead does not settle it, and leaves no way out.** The refund returns the money and leaves the order in `Created` holding capacity, and a *complete* session never fires `checkout.session.expired`, so nothing is left that can release it — `expire_order` correctly refuses (Stripe reports the session not-open), and `abandon_order` cannot act on `Created`. If you have already refunded: resend anyway to move the order to `Paid`, then `abandon_order`. **The buyer keeps cycles they were refunded for** — that is the cost of refunding first, and it is why the order of operations is the whole procedure. <br><br>The entry does **not** auto-resolve on `charge.refunded`, deliberately: refunding settles the money and leaves the order broken, so auto-closing would delete the only worklist item pointing at the stranded capacity |
| `#unprocessable {eventId; field}` | ❌ no — the position is unknown | A verified Stripe event was missing a required field, so the canister could not tell whether money moved | Look the `eventId` up in the Dashboard. **Paid** → refund. **Not paid** → nothing happened; `resolve_orphan`. Then find the configuration that produced it: the canister controls every field it sends, so a missing one points at an account-level API-version change (`docs/OPERATE.md` pins it) and will recur until fixed. ⚠️ Resolve only after establishing the money position — once resolved, a later resend is allowed to file again |

### `#deliveryStuck`'s stages — read `stage`, never the kind

**`stage` is the money position.** It is derived from the *journal*, not the status,
because one status covers several positions. These five are the whole vocabulary
`Delivery.terminationFor` and the escalate route can emit — pinned by
`test/delivery.test.mo`, so a stage that reaches you without a row here is a bug in
the code rather than a gap in this table.

| `stage` | Money position | Action |
|---|---|---|
| `staleIntent` | ⚠️ **UNKNOWN.** A transfer was issued, no block was recorded, and the intent is past the ledger's ~24 h dedup window — so a replay is no longer protected and re-sending could pay twice | **Establish its fate on the cycles ledger**, matching the order id in the transfer's **memo**, the `created_at_time` and the amount from `delivery_journal(orderId)`. **Executed** → the buyer has them: `record_delivered '("<orderId>", <blockIndex>)'`, then `resolve_orphan`. **Not executed** → fiat in, nothing delivered: refund in Stripe, `abandon_order`, then `resolve_orphan`. ⚠️ **Never rebuild the intent** — past the window a rebuilt one pays twice |
| `landedNotRecorded` | **Certain, and in the buyer's favour**: the transfer landed (the block is in the entry and the journal) and the order never moved to delivered. **The buyer HAS their cycles** | Confirm the block on the cycles ledger, then `record_delivered '("<orderId>", <blockIndex>)'` → `resolve_orphan`. ⚠️ **Do NOT re-send.** Should be unreachable — the block and the transition commit in one synchronous block — so if you are reading this, file it as a bug too |
| `deliveryWaitExceeded` | **Certain**: fiat in, **nothing was ever sent** — no transfer was attempted before the 72 h bound | Refund in the Stripe Dashboard, `abandon_order '("<orderId>", "<reason>")'`, then `resolve_orphan` |
| `transferRejected` | The cycles ledger refused the call definitively, so nothing moved | Read the `detail` for the ledger's reason. `#InsufficientFunds` → the reserve is short: top it up and `refresh_reserve`, then re-drive with `process_order`. Fiat is in and nothing was delivered, so refunding is always a valid resolution |
| `journalInconsistent` | ⚠️ **An invariant breach, not a money position** — the intent's amount exceeds the order's locked quantity, which cannot happen because the amount was derived by subtracting a fee from it | **File it as a bug**: `lockedCycles` has acquired a second writer, which is a larger problem than one order. Establish the transfer's fate on the ledger before re-sending anything |
| `missingJournal` / `notInFlight` | ⚠️ **Also invariant breaches.** The order's status implies money-out work the journal cannot support, or the drive loop escalated a status that has no delivery in flight | Reconstruct from `audit_log` and the cycles ledger; treat as a bug and file it |

### An unattributed payment has exactly one remedy: refund — and it is usually not "unattributable"

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
path that turns an unattributed payment into cycles for that buyer, whether or not we
know which order it was for — that is
the deliberate cost of the deletion, and it matches the decision that this app
does not model refunds. A refund auto-resolves the entry (a partial one leaves it
open, carrying the remainder).

⚠️ If you find yourself wanting the lever back, the thing to check first is
whether attribution is broken — since #33 nothing but the canister writes
`client_reference_id`, so a payment that cannot be attributed is a bug worth
finding, not a routine occurrence to be papered over.

### Closing an order-bound problem (#37)

Since #37, four of the six kinds live on the order rather than in this list, and they
are closed with `resolve_problem` rather than `resolve_orphan`:

```sh
⚠️ **`admin_orders` is ordered by order ID, NOT by time, and the last argument is a page
size.** Order ids are `raw_rand` hex, so id order is arbitrary — **the first page is not
the most recent orders.** #38's own scope says "filter by time range", and this is where
that expectation forms, so: to look at recent orders, set `createdFromNs` rather than
reading page one. The third argument to each call is `limit`, and `null` in the second
position means "from the beginning"; pass the returned `nextCursor` back to continue.

⚠️ **Sorting by time is deliberately not offered.** It would mean materialising the whole
filtered set before sorting, which is the unbounded scan **#63** exists to remove, and a
time index would be one more piece of derived state the daily reconcile has to adjudicate.

# Read ONE order, whoever owns it (#38). Every such read is audited, hit or miss.
icp canister call backend admin_order '("<orderId>")'

# See what is outstanding, and on which orders
icp canister call backend problem_depth '()'                 # the number to alert on
icp canister call backend admin_orders '(record { status = null; owner = null; createdFromNs = null; createdToNs = null; withUnresolvedProblems = true }, null, 50)'

# Read ONE order's receipt, whoever owns it. Audited, like admin_order.
icp canister call backend admin_receipt '("<orderId>")'

# Close one. The second argument is a VARIANT, not a string (#122) — a misspelled
# tag is now refused by the decoder instead of matching nothing. The third selects
# WHICH problem, by payment reference.
icp canister call backend resolve_problem '("<orderId>", variant { duplicate }, opt "pi_...")'

# `deliveryStuck` can only ever have one per order, so null is always right:
icp canister call backend resolve_problem '("<orderId>", variant { deliveryStuck }, null)'
```

The four tags are `duplicate`, `deliveryStuck`, `refundAfterDelivery` and
`paidNotCredited` — the same four `admin_order` reports on the order's own problems.

⚠️ **Passing `null` when the order has several problems of that kind is REFUSED, and
the refusal carries the references as data** (`#ambiguous`, with a `candidates` list —
#123, where it used to be a sentence to read them out of). A buyer who pays three times files three
`#duplicate` problems, and closing "the duplicate" would mark settled a payment you
have not refunded. Refunding one and closing another is the mistake this refusal
exists to prevent — the error message is the disambiguation step, not an obstacle.

⚠️ **A resolved problem stays on the order.** Nothing drops, so the worklist filter
stops listing the order while its history remains readable. "It disappeared" is not
what success looks like here.

| kind tag | ref needed? | what closing it means |
|---|---|---|
| `duplicate` | **yes** when several exist | you refunded that specific second payment in Stripe |
| `deliveryStuck` | no — one per order | you established the money position and acted (the triage section's stage table) |
| `refundAfterDelivery` | **yes** when several exist | you reconciled the recorded loss; the cycles are not recoverable |
| `paidNotCredited` | **yes** when several exist | ⚠️ normally closes ITSELF on the resend — closing it by hand says you gave up on crediting the buyer |

## 7. Recovery timer & manual kicks (§5.2)

The recurring sweep is the backstop for every detached delivery kick that dies:
it re-drives every order in `paid`, which is the one status with delivery outstanding.
It re-arms **automatically on every upgrade** (transient initializer — a
deploy can never leave recovery dead).

```bash
icp canister call backend recovery_status '()' -e ic            # public
icp canister call backend set_recovery_interval '(3_600_000_000_000)' -e ic --identity <operator>
icp canister call backend process_order '("<orderId>")' -e ic --identity <operator>
```

- Interval validation pins cadence ≤ 6 h (ledger dedup window ÷ 4 — a
  stuck transfer must get several replay attempts while its intent still
  dedups). Default **15 min** (`Recovery.defaultIntervalNs`); re-arms immediately on
  change.
- `recovery_status.lastSweep` not advancing past ~2 intervals = the timer
  is wedged — an upgrade re-arms it, but investigate first.
- The sweep also **reconciles the per-status tallies once a day** and reports the
  result on `recovery_status.lastCountReconcile`. The tallies are maintained
  incrementally so the admission-gate queries stay O(1); the reconcile is the check
  that they still match. It audits **only when something moved** — a clean line every
  day would bury the one that matters. `recount_orders` runs the same pass on demand.
- ⚠️ **Its cost is bounded by open orders, not by lifetime sales (#63)**, and that
  changes what a stale reconcile means. It recounts over the non-terminal order set,
  which the reserve caps, so `lastCountReconcile.ordersRead` should stay flat as sales
  accumulate. If it starts tracking total orders, the bound has broken.
- ⚠️ **`drift` and `refused` are two different verdicts and demand opposite readings.**
  `drift` was **raised** to the recount, so those tallies are correct again. `refused`
  came out **below** the maintained tally and was **not** adopted, so those tallies are
  still suspect — a recount lower than the tally is indistinguishable from an index
  missing a member, and adopting it is the only way a bookkeeping bug could lower
  `promised` and oversell the reserve. `recount_orders` follows the same rule; there is
  deliberately no force flag.
- ⚠️ **One check cannot be daily, and it says so instead of pretending.** Whether
  anything *outside* an index satisfies the index's predicate is the only question that
  needs every order, so it runs as a rotating per-order scan, one chunk per sweep.
  `recovery_status.indexScan` is its coverage: `lastCompletedCycle` is the only thing
  that licenses reading a clean scan as evidence about the whole store, and
  `inFlightCycle.ordersRead` against `storedOrders` says how far the current cycle has
  walked. **Three states, not two** — an audit line is *verified and disagreed*, silence
  with a recent `completedAtNs` is *verified clean*, and silence without one is
  *unverified*, which carries the opposite response: wait for the pass rather than hunt
  for a writer.
- ⚠️ **So #63 converted unbounded WORK into unbounded LATENCY, and the honest claim is
  "bounded per message" rather than "bounded".** The daily pass verifies only the inside
  direction of each index. Detecting the outside direction — an order that holds a
  promise and is not indexed — takes up to one full cycle, and the cycle grows
  **linearly in stored orders**: `⌈storedOrders ÷ chunkSize⌉ × sweep interval`. At the
  15-minute default and 2,000 per chunk that is ~192,000 orders a day, so 365k is
  covered in about two days and 3.65M in about nineteen. This is the right trade — work
  that traps is fatal, latency that grows is degradable **and observable** — but it is a
  trade, and `indexScan.expectedFullCycleNs` is where you read the current value rather
  than assume this paragraph is still accurate.
- ⚠️ **`set_recovery_interval` is a lever on that latency, and its name does not say
  so.** The scan rides the sweep, so coarsening the cadence to the §5.1 ceiling of 6 h —
  **24× the default** — takes the same 365k store to ~46 days per cycle. The
  `recovery.intervalSet` audit line now names the resulting window, so the consequence
  is recorded next to the cause. Do not retune the cadence to save cycles without
  reading it: the finding it delays is `orders.unindexedHolders`, which is **P1**.
- The sweep also **reconciles the reserve floor against the cycles ledger once an
  hour**, which is how a top-up becomes sellable without an operator call.
  `recovery_status.lastReserveReconcileAttemptNs` is the attempt clock and
  `reserve_status.reserveObservedAtNs` the success one; the two diverging means the
  read is failing or every attempt landed while a delivery was in flight. Both
  under-sell, never over-sell. `refresh_reserve` is the same reconcile on demand and
  is what you call right after `icp cycles transfer`.
- `process_order` is the safe-to-spam manual kick for one order
  (per-order single-flight; `#inFlight` just means it's already being
  driven). Use it to retry one order the moment its cause is fixed — the reserve
  refunded, the cycles ledger back — instead of waiting for the sweep.
  ⚠️ **It is admin *or* the order's own owner** since #30 PR-B, so a buyer's page
  refresh heals their own stuck delivery in seconds rather than at sweep cadence. It
  does **not** make the sweep optional: the sweep is the guarantee (we took the money,
  so we deliver whether or not the buyer comes back), this is the latency fix.

## 8. Monitoring plan

Every safety mechanism in this system is a **number someone has to look at**. The
2 h delay alert, the obligation queue, the rate-refresh liveness — none of them page
anybody. An alert nobody receives is not an alert, so wire this before taking
money.

### The whole alerting layer needs no credentials

These are public queries, so a monitor can poll them anonymously — no controller
key on a monitoring box:

<!-- surface:public -->

`can_purchase` · `card_tiers` · `cycles_status` · `delivery_stats` · `expected_livemode` ·
`health` ·
`admin_status` · `lifecycle_config` · `operator_summary` · `orphan_depth` ·
`pricing_status` · `problem_depth` ·
`quote_previews` · `recovery_status` · `refusal_counts` · `reserve_status` ·
`stripe_origin`

<!-- /surface -->

The ones worth a monitor: `health`, `cycles_status`, `reserve_status`,
`pricing_status`, `recovery_status`, `orphan_depth`, `problem_depth` (open
obligations — the count the triage section works from) and `refusal_counts`.

`can_purchase` is also callable anonymously and is worth special mention: the
anonymous principal owns no orders, so `tooManyOpenOrders` can never trip for it.
That makes **anonymous `can_purchase '(<smallest tier cents>)'` a pure global-health
probe** — it answers with the reason the rail would refuse a sale, and every reason
it can give is actionable (`canisterCyclesLow`, `amountAboveMax`,
`amountBelowMin`, `tooManyOpenOrders`). ⚠️ **It cannot see solvency** — that is
decided synchronously inside `create_order` — so pair it with
`reserve_status.availableToSell`.

### ⚠️ The reserve is the one metric anyone can poll — including you

The reserve is an account on the cycles ledger, so `icrc1_balance_of` answers for
free, from any identity, with no cooperation from this canister. That is the
transparency thesis working: the number an operator monitors is the same number a
buyer can check.

What the canister adds is the part only it knows — **how much of that balance is
already promised**. `reserve_status` reports `reserveFloor − promisedTotal =
availableToSell`, and the three figures together separate the causes of a refusal:

| Reading | Means |
|---|---|
| ledger balance high, `reserveFloor` low | a top-up nobody observed → `refresh_reserve` |
| `reserveFloor` fine, `promisedTotal` high | genuinely committed to live orders → wait or raise the reserve |
| `availableToSell` 0 with both low | the reserve is spent → fund it |

⚠️ **`reserveObservedAtNs` is what makes the first row diagnosable**, and
`recovery_status.lastReserveReconcileAttemptNs` is its pair: an attempt clock newer
than the success clock means the hourly reconcile is running and *not adopting* —
either the ledger read is failing or every attempt landed while a delivery was in
flight. Both under-sell rather than over-sell, so it explains refusals and is never
a loss.

### Metric table

Severity: **P1** = wake someone; **P2** = same working day; **P3** = review weekly.

| Metric | Alert when | Sev | Action |
|---|---|---|---|
| `pricing_status.lastAttempt.ok` | false on two consecutive ticks | **P1** | the pricing-rates section — order creation stops once the cache passes `maxAgeNs`. `detail` names the failing guard |
| `pricing_status.rates.fetchedAtNs` | older than `maxAgeNs` | **P1** | the rail has stopped selling. Timer dead or every tick rejected |
| `cycles_status.balance` | below 3× `minCanisterCycles` | **P1** | top up. At zero the canister is **uninstalled** and money-bearing state is lost. Note the XRC needs 1 B attached per refresh, so pricing dies before the gate does |
| anonymous `can_purchase` | returns `#err` | **P1** | the rail is refusing sales; the reason says which lever |
| `orphan_depth.unresolved` | `> 0` | **P2** | triage. Depth climbing past 1,000 means work is accumulating faster than it clears |
| `reserve_status.promisedTotal` | climbing while deliveries do not complete | **P2** | money in, nothing delivered — those orders are on the clock toward the 72 h bound. `pending_deliveries` says which and why |
| `recovery_status.lastSweep.atNs` | older than 2 intervals | **P2** | the sweep timer is not running; nothing recovers while it is dead |
| `recovery_status.lastCountReconcile.drift` | non-empty | **P2** | a per-status tally had diverged and was **raised** to the recount. The counts are correct again; the bookkeeping bug that moved them is not fixed. They gate admission and they short-circuit the sweeps, so an under-counted `Paid` reads as zero to the recovery sweep and money-out silently stops |
| `recovery_status.lastCountReconcile.refused` | non-empty | **P2** | ⚠️ **The opposite reading to the row above, and the tallies are still suspect.** The recount came out **below** the maintained tally, which is indistinguishable from the non-terminal index missing a member — so it was refused and the maintained value stands. That over-refuses rather than overselling, which is why refusing is right. Two causes with one response, *find the writer*: either the index lost a member or a tally gained an adjustment. `orders.unindexedHolders` from the rotating scan tells you which |
| `orders.unindexedHolders` in the audit log | any occurrence | **P1** | ⚠️ **The one bookkeeping error nothing else can see, and it is on the money side.** An order held a promise and was missing from the non-terminal index — and if `promised` was missing its cycles too, the two agreed with each other, so the daily reconcile reported nothing while `reserve_status.availableToSell` read HIGHER than the truth. The reserve was oversellable. The scan added the order and the next reconcile raises `promised`, so the exposure closes on its own; what does not close is the writer that set a status outside `Orders.create` and `Orders.commitTransition`. Find it. Then check `reserve_status.availableToSell` against the ledger before selling more |
| `orders.staleHolders` in the audit log | any occurrence | **P2** | the reverse direction: a **terminal** order was still in the non-terminal index, so `promised` may have been holding cycles that were already released — over-refusing, not overselling. Dropped on sight, because the order's own status is the authority. Same writer to find as the row above |
| `orders.problemIndexDrift` / `orders.unindexedProblems` in the audit log | any occurrence | **P2** | ⚠️ **Not a data problem — a code problem.** The unresolved-problems index (#37) is maintained by exactly two functions, `Orders.fileProblem` and `Orders.resolveProblems`. Either tag means something else wrote `order.problems` directly. **The repair is not the fix**: find the writer. `problemIndexDrift` is an id in the index with no unresolved problem — the worklist showed an obligation that was already closed. `unindexedProblems` is the worse direction: an order carried an unresolved obligation the worklist did **not** show and `resolveByPaymentRef` could not reach |
| `orders.expiredWentBackwards` in the audit log | any occurrence | **P2** | the `Expired` tally fell, which the transition matrix makes impossible — `created → expired` is its only inbound edge and it has no outbound one. A bookkeeping breach in `Orders.bump`. ⚠️ **Reported once per decrease, not daily**, so a second occurrence means it fell again. `Expired` is an operator metric that nothing decides on, so this is a bug report rather than an exposure |
| `orders.expiredOverflow` in the audit log | any occurrence | **P2** | the `Expired` tally plus the non-terminal order count exceeds the number of orders in the store. Those two sets are disjoint subsets of it, so this is arithmetically impossible and `Expired` is over-counted. Same class as the row above — observability, not money |
| `recovery_status.indexScan.lastCompletedCycle` | empty, or `completedAtNs` older than a small multiple of `indexScan.expectedFullCycleNs` | **P2** | ⚠️ **Without this the clean-scan rows above mean nothing.** The rotating scan verifies the one property that needs every order, so it can only speak for what it has visited: silence plus a recent `completedAtNs` is *verified clean*, silence with no completed cycle is *unverified*. ⚠️ **Compare against `indexScan.expectedFullCycleNs`, not against a remembered number** — it is computed from the live store size and the live sweep cadence, and `set_recovery_interval` can move it by 24×. Empty long past that, with `inFlightCycle.ordersRead` frozen, means a chunk is trapping — the cursor does not advance, so the next sweep retries the same chunk rather than skipping forward |
| `recovery_status.lastCountReconcile.atNs` | older than ~48 h while `lastSweep` advances, or materially older than `lastCountReconcileAttemptNs` | **P3** | the daily reconcile is failing. It runs in its own message, so it cannot take the sweep down with it — money-out is unaffected — but the tallies are now **unverified**, not known-good. Written only on success, and the cadence is claimed by the sweep, so a reconcile that traps retries daily rather than every tick. `recount_orders` is the on-demand repair and will show the same failure if it is a real one |
| `reserve_status.openOrders` | climbing while `delivered` does not | **P3** | order-creation abuse; lever is `maxOpenOrdersPerPrincipal` (the admission-gate section) |
| `refusal_counts.refusingNow.reserveShort` | true | **P1** | the rail is refusing sales for want of reserve. Exactly one `gate.startedRefusing` line marks when it began — the counter says how many buyers have been turned away since. Fund the reserve (the reserve section); it clears on the next successful admission |
| `refusal_counts.refusingNow.canisterCyclesLow` | true | **P1** | the gate is refusing on its own gas. Same shape as above, different lever: top up the canister (`cycles_status`). ⚠️ **Do not expect a corroborating `pricing_status` alert, and do not read its absence as a false positive.** At the 5 T default the gate closes while the balance is still ~5000x the 1 B a rate call must attach, so pricing keeps working long after sales stop. Pricing alerting *too* means the floor has been set near `0`, which is a second finding. ⚠️ Sales are closed but delivery is not: orders already paid for keep being delivered, so this is revenue stopping, not money going missing |
| `refusal_counts.refusingNow.railClosed` | true | **P1** | ⚠️ **The rail is not provisioned, so every purchase is being refused before the gate is even consulted.** Expected on a fresh deployment — `docs/OPERATE.md` provisions the secrets last — and an incident at any other time. `stripe_api_key_status().isSet` and `stripe_origin()` say which half is missing. One `gate.startedRefusing` line marks when it began; `counts.railClosed` says how many buyers hit it since |
| `refusal_counts.refusingNow.stripeApiFailing` | true | **P1** | ⚠️ **The key is present but Stripe is refusing it — rotated or revoked without updating the canister.** Distinct from `railClosed`: that one says *provision the key*, this one says *rotate it*. `sessionConfig` cannot detect it, so every purchase reaches the outcall, 401s, and is refused. ⚠️ **Each attempt also commits an order and expires it**, and the open-order cap does not bound that because the record is not `Created` — so the order table grows while this is true. Set a fresh restricted key (the presets-and-keys section); it clears on the next successful session |
| `refusal_counts.counts.amountBelowMin` | climbing | **P3** | ⚠️ **Two very different causes and the counter cannot tell them apart.** Either the buy UI is offering an amount the gate refuses — a bug, and every affected buyer sees a dead end — or someone is probing the cheapest free refusal there is (one cent needs no order, no payment, no prior state). Compare against `reserve_status.openOrders`: climbing refusals with flat order creation is probing, climbing alongside real traffic is the UI |
| `refusal_counts.counts.amountAboveMax` | climbing | **P3** | buyers are asking for more than the per-order ceiling allows. If it is sustained the ceiling is mispriced for demand, not misconfigured — raising it raises per-order reserve exposure (the admission-gate section), so treat it as a pricing decision |
| `refusal_counts.counts.tooManyOpenOrders` | climbing | **P3** | buyers hitting the one-open-order cap. Expected in normal use — a buyer who abandons a checkout and retries meets it — so alert on the **rate**, not the total |
| `refusal_counts.counts.railClosed` | climbing while `refusingNow.railClosed` is **false** | **P2** | ⚠️ **Should be unreachable.** `sessionConfig` can only fail with a missing key or origin, both of which latch — so a climbing counter with a clear flag means it failed some other way, and the mapping in `Main.mo`'s `railClosureCondition` needs re-reading against the current `Session.Error` |
| `reserve_status.availableToSell` | 0, or far below `reserveFloor` − `promisedTotal` as you expect it | **P2** | the gateway is refusing sales. Three causes and the same query separates them: the reserve is genuinely spent (`reserveFloor` low), it is committed to live orders (`promisedTotal` high), or **the floor has not observed a top-up** (`reserveObservedAtNs` old). The last is the common one and the lever is `refresh_reserve` |
| `reserve_status.reserveObservedAtNs` | materially older than `recovery_status.lastReserveReconcileAttemptNs` | **P3** | the hourly reserve reconcile is attempting and not adopting: either the ledger read is failing (`reserve.observeFailed` in the audit log) or every attempt lands while a delivery is in flight (`reserve.reconcileSkipped`). Under-sells rather than over-sells, so it explains refusals; it is not a loss |
| `delivery.feeChanged` in the audit log | on **every** delivery rather than once | **P3** | the stored cycles-ledger fee is stale, so every order pays one rejected call before its transfer lands. Self-correcting by design — the first `#BadFee` persists the ledger's value — so a *repeating* tag means the correction is not sticking (an upgrade reverting the stored value, or the ledger's fee moving repeatedly). ⚠️ **This is the ONLY detector for a stored fee that will not stick**, since nothing but the ledger writes that value and the persistence itself is untested (`docs/TEST-COVERAGE.md`). Each occurrence costs one rejected call, never a wrong debit — the buyer still gets the quoted amount and the reserve absorbs the real fee. If it repeats, redeploy rather than looking for a lever; there is none, deliberately |
| `refusal_counts.refusingNow.stripeApiFailing` true, with `gate.startedRefusing` naming **retrieve REFUSED** | any occurrence | **P1** | ⚠️ **The restricted key cannot read Checkout Sessions, so stranded capacity can never be released automatically.** The recovery sweep's retrieve is 401/403ing. Fix the key's permission (Checkout Sessions = **Write**, which is the level that also grants read — the presets-and-keys section) and rotate it in; nothing else recovers. Until it is fixed, `expire_order` is the manual release. <br><br>⚠️ **This replaced a `stripe.retrieveUnauthorized` tag, deleted by #37 §2c.** That tag fired **once per stranded order per hourly pass** — up to ~240 permanent lines a day for one unfixed problem once the ring was gone. Our own cadence bounded a *rate*, and a rate against an unfixed persistent condition is unbounded over time. It is now the same latched condition as a failing session *create* or *expire*, because a 401 on any of the three is one incident with one lever: **rotate the key** |
| buyers report that cancelling does nothing, or `admin_orders` shows no order has ever reached `cancelled` | any occurrence | **P2** | ⚠️ **`cancel_order`'s "Stripe would not close the payment session" answer has three causes and the buyer-facing arm deliberately records none of them.** Two are normal and settle themselves (the payment won the race, or the session had already expired); the third is a malformed expire request from this canister, which leaves the order `#created` and payable while every cancel fails the same way. That is what makes one manual run diagnostic: `expire_order '("<a live created order>")'` takes the identical path, is admin-authenticated, and audits Stripe's body verbatim as `order.expireRaced`. Read that line. A session-state refusal there means the two normal causes; anything else is ours to fix. ⚠️ There is no counter for this yet — `Gate.RefusalCounts` cannot gain a field without an upgrade-incompatible stable change — so the detection is this row, not a metric |
| `stripe.retrieveFailed` in the audit log | repeatedly for the same order | **P3** | Stripe is unreachable or answering non-200 for the session read. Distinct from the row above on purpose: **"Stripe refused the read" and "Stripe is down" are different actions.** Transient failures retry hourly and need nothing; a persistent one means the outcall path is broken, so check `pricing_status` (the same egress) before suspecting the key |
| `stripe.paidAwaitingEvent` in the audit log | any occurrence | **P2** | a buyer paid and Stripe has not delivered `checkout.session.completed`. **Not yet an obligation** — Stripe redelivers for ~3 days and the entry is deliberately withheld until then — but it IS the support signal: the buyer's own page renders expired from `expiresAtNs`, so expect a contact the same hour. If it is one order, resend the event from the Dashboard now rather than waiting. If it is many, the webhook endpoint is broken: check the secret and the subscribed event list (the presets-and-keys section) |
| `stripe.paidNotCredited` in the audit log | any occurrence | **P1** | a buyer paid, Stripe has given up redelivering, and the obligation is now filed on the order itself (#37). Follow the `#paidNotCredited` triage row — **resend first, always** |
| `stripe.retrieveUnreadable` in the audit log | any occurrence | **P3** | Stripe answered the session read in a shape the classifier does not recognise, so the sweep did nothing (fail-safe). Capacity stays held until it is understood. Most likely an API-version change; `docs/OPERATE.md` pins the version, so this points at an account-level change |
| `reserve.unexplainedShortfall` in the audit log | any occurrence | **P1** | the ledger holds LESS than the floor's lower bound, which the design says is impossible — no allowance exists and `withdraw` is unused. Treat as a bookkeeping breach: stop selling (`set_gate_config` with a high `minPurchaseUsdCents`, or pause), reconcile the journal against the ledger, and find the outflow before funding anything |
| an order still `created` past its own `expiresAtNs` | any | **P2** | a `checkout.session.expired` was missed. Nothing sweeps it (the order-expiry section, deliberately — a sweep would hide a held reserve): resend the event from the Stripe Dashboard. Query it with `admin_orders '(record { status = opt variant { created }; owner = null; createdFromNs = null; createdToNs = null; withUnresolvedProblems = false }, null, 200)'` and compare each `expiresAtNs` against now |
| `pricing_status.xrcCanisterId` | anything other than `uf6dk-hyaaa-aaaaq-qaaaq-cai` | **P1** | **on mainnet this must be the real Exchange Rate Canister.** The id is resolved from a `PUBLIC_CANISTER_ID:xrc` canister environment variable so a local network can point at a mock; a mainnet canister reporting any other id is pricing real sales off something that is not the market. Only a controller can inject it, so this reads as either a misconfigured deploy or a compromised controller. ⚠️ **There is no burn cap to pull — it went with the ICP mint path.** To stop new orders while investigating, `set_gate_config` with `minCanisterCycles` above the canister's current balance: the gate refuses every creation. It does **not** stop delivery of an order already paid, or the webhook. **`null` is not a pass** — it means no refresh has reached the XRC call at all (expected for seconds after an install or upgrade, since the value is transient). Do **not** wait on `lastAttempt` becoming non-null: that field is persistent, so it survives the upgrade and is already set while this one is still null. Re-read until `lastAttempt.atNs` post-dates the deploy. A *failing* refresh never shows null here — the id is recorded when the call is constructed, so a rejected call reads as a non-null id plus `lastAttempt.ok = false` |
| `pricing_status.rates.quality.receivedRates` | drops to `minRateSources` | **P3** | thin market — a price from 2 sources is not one from 12 |
| `health` | unreachable | **P1** | canister stopped, frozen, or out of cycles |

⚠️ **One row above needs a controller key and a comparison you make yourself, and
saying so is the point.** "An order still `created` past its own `expiresAtNs`" is
#30's detection predicate 1 — the signal that exists *because* #33 refused to add a
sweep that would have hidden a held reserve.

`admin_orders` (#38) answers it: filter on `created` and read each record's
`expiresAtNs`. What it is **not** is a threshold something can alert on — the
predicate is a comparison against the clock, so there is no field to watch. The
public interim signal remains `reserve_status.openOrders` **staying non-zero and
static well past ~40 minutes** (the session lifetime is ~35), cross-checked against
expired sessions in Stripe; a cron that can hold the controller key should page the
filtered listing and do the comparison itself.

⚠️ **`get_order` / `list_orders` / `receipt` stay owner-scoped**, and `admin_order` /
`admin_orders` / `admin_receipt` are the controller-side reads that answer the same
questions across principals. `reserve_status` returns counts, not records, so it can
never tell a fresh `created` order from one that lapsed an hour ago.

### Needs a controller key

- **`audit_log` tags** worth alerting on: `stripe.livemodeMismatch` (real money may
  be landing in the wrong Stripe account), `stripe.creditedElsewhere`,
  `stripe.unprocessable` / `stripe.unhandledType` (a Dashboard config producing
  events this gateway cannot use — it will recur until changed),
  `orders.countDrift` and `orders.countRecountLow` (the status tallies were wrong, and
  whether the pass could repair them; see the table above),
  `orders.unindexedHolders` (**P1** — the reserve may have been oversellable),
  `stripe.refundPartial` (an obligation deliberately left open), and `delivery.stuck`.
- **`orphans_unresolved`** for the entries themselves. `orphan_depth` is
  public, so **alert on the public depth and only fetch details when it fires** —
  that keeps the key out of the polling loop.
- ⚠️ **The audit log no longer drops anything (#37).** It was a 4,096-entry ring, and
  gaps in `seq` were how you detected drops; there are no gaps now, and `seq` is only a
  never-reused ordering. What has not changed is what it IS: *telemetry*. The order
  store, delivery journal and orphan list are the records of money, and an order's own
  `problems` array is where its obligations live.

### Off-chain

- **Stripe Dashboard → event deliveries.** A run of failures means the secret is
  out of sync or the gateway is unhealthy. Stripe retries non-2xx for ~3 days, so
  transient failures lose nothing — but a *permanent* 4xx can get the endpoint
  disabled, which is why verified-but-unprocessable events are acked 200 (triage).
- **Stripe payouts and disputes.** Disputes produce **no on-chain signal** (only
  `charge.refunded` is subscribed), so the Dashboard is the only control.

### Do you need a dashboard?

**Alerting first, dashboard second** — and the order matters. The failure modes
here are slow (a 2 h alert window, a 72 h terminate bound), so what you need is
something that reaches a human at 03:00, not a page someone visits. A cron job
polling the public queries and posting to Slack/PagerDuty covers the entire table
above except the audit tags, and needs no credentials.

A dashboard earns its place afterwards, for the things alerts are bad at: reserve
drawdown over time, order volume, delivered-vs-open ratios, rate quality. Everything
it needs is a public query — `reserve_status` and the cycles ledger between them — so
a read-only operator page is straightforward. It is a convenience, not a control.

## 9. Confidential-subnet checklist (§7, §11.1)

The webhook secret is plaintext canister state, and SEV-SNP is the intended
confidentiality layer. ⚠️ **There is no cap standing behind it any more**: a forged
webhook delivers from the reserve, so **the reserve balance is the blast radius** and
sizing it is the always-on control (the webhook-secret section). Launch does not block on SEV, but that
trade is now "size the reserve to what a leak could cost", not "the cap bounds it". Before relying on a confidential subnet for the
secret, verify — in this order, hardest first:

- [x] **Checkpoint/state-sync confidentiality** — **confirmed encrypted on the
  target subnet** (owner, 2026-09-11). SEV-SNP protects RAM; canister state is also
  checkpointed to disk and state-synced between nodes, and both of those paths are
  confidential here too. This was §7's "verify this hardest" item, because either
  one in the clear would have leaked the plaintext secret and SEV would have bought
  nothing.
- [ ] **Attestation coverage**: every replica in the subnet runs attested
  SEV-SNP (one unattested node = one node provider who can read the
  secret).
- [ ] **Production readiness**: the subnet is GA, not a beta — and check
  the current AMD SEV-SNP CVE list (it has a published side-channel
  history; trust shifts to AMD, not math).
- [ ] **Provisioning channel**: ingress still TLS-terminates at the
  boundary node. Unless an attestation-tied confidential provisioning
  channel exists, follow the webhook-secret section's rotate-after-provisioning rule even on the
  confidential subnet.
- [ ] **Migration**: moving subnets is a canister migration — re-verify
  the module hash after (RELEASE.md gate) and rotate the secret (it
  transited infrastructure during the move).

Until all boxes tick: the secret lives plaintext on a normal subnet, and the
protections are exactly (a) **the reserve sized to what a leak could cost** (the webhook-secret and reserve sections)
and (b) accountable node providers. That is the documented, accepted §7 posture — the
loss is bounded by the reserve balance, detectable in the audit log and the order
store, and recoverable only to the extent that fiat was never taken for the forged
orders.

Related §11.1 note for future rails: the four Base seams (Owner variant,
route table, edge-captured ownership, per-rail expiry) are binding on code
changes, not operations — but any new rail lands with its own runbook
section, its own dedup set, and its own entry in `docs/OPERATE.md`'s Mode 3.

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
  is why the stop-first procedure is also the *safe* one: an in-flight delivery
  completes before the upgrade happens, so a controlled
  upgrade cannot strand money. Verified by `test/integration` scenarios 12
  and 13.

  Consequence: `staleIntent` is **not** reachable through a controlled upgrade —
  an in-flight transfer settles before the upgrade happens. It covers genuine
  faults: a ledger that never replies, a subnet incident, running out of cycles
  mid-call. The triage section's rules apply when it appears.

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

  which wipes local orders, the audit log and the delivery journal, and takes
  seconds. `scripts/e2e-local.sh` detects the trap and does it automatically.

  ⚠️ **This is a development lever and has no mainnet counterpart.** `reinstall`
  discards every order, journal and dedup set, so on mainnet a shape change needs
  the mops migration chain (section 1.1 item 1) — which is why no migration file is
  written before the schema settles: every file replays forever on a fresh install.

- In-flight deliveries resume from the persisted journal via the re-armed timer
  (§5.1), so an interrupted money movement degrades to a recoverable stage,
  never a double-spend.
- Persistent state (orders, their problems, journals, dedup sets, configs,
  secret) survives upgrades via orthogonal persistence. **Transient knobs reset
  on upgrade**: the HTTP body cap (64 KiB), the single-flight guards, and the
  index-scan cursor's in-flight cycle — that reset is deliberate (a guard stuck
  by an upgrade cannot deadlock anything). ⚠️ **The two capacities this list used
  to name are gone**: #37 removed both the error-queue capacity and the audit-log
  ring, so neither is a knob to re-check after a deploy.
- After every upgrade: `health`, `recovery_status` (timer re-armed),
  `webhook_secret_status.generation` unchanged, one test order end-to-end
  if the change touched money paths.
