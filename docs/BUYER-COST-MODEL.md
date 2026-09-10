# What a purchase actually buys

**The question:** someone buys cycles here to create and deploy **two canisters** — a
backend and a frontend — and run them for **two weeks to a month**, syncing assets and
upgrading the backend wasm **about three times a day**. What does that cost, and does the
$10 minimum cover it?

**The answer:** the buyer needs **4.0 T upfront** and *consumes* ~1.34 T in the month. The
gate is the upfront figure, because `icp canister create` funds each canister with **2 T by
default** — so **$10 works (6.851 T, 1.7× the requirement) and $5 does not (3.320 T, short
by 0.68 T).**

⚠️ **Upfront requirement and consumed cost are different numbers, and pricing the wrong
one inverts the conclusion.** An earlier draft of this document costed only what gets
consumed — the 0.5 T protocol creation fee, uploads, storage — and concluded a $5 minimum
would be sufficient. It is not. The 2 T per canister is not *spent*; it lands in the
canister as its balance and remains the buyer's. But they must **have** it, and default
tooling asks for it without being told.

⚠️ **This did not exist before 2026-09-10 and its absence was not obvious.** The $5 → $10
minimum was decided on the **card-fee share** — `Gate.mo` says so at `minPurchaseUsdCents`,
and #21 quantified it as ≈9% of a $5 purchase lost to 2.9% + 30¢ against a zero operator
margin. That reasoning is sound and this model does not disturb it. What was missing is the
other half: whether the minimum buys anything *useful*. It does, with room to spare.

## Where the figures come from

All costs are the documented **13-node application subnet** rates —
<https://docs.internetcomputer.org/references/cycles-cost-formulas> — because that is the
subnet a buyer's own canisters would typically land on.

| | 13-node cost |
|---|---|
| Create a canister | 500,000,000,000 (0.5 T) |
| Storage | 127,000 per GiB per second |
| Ingress message | 1,200,000 base + **2,000 per byte** |
| Update call execution | 5,000,000 base + 1 per instruction |

USD is the docs' own: $0.683 per 0.5 T ⇒ **$1.366 per T**, consistent with 1 T ≈ 1 XDR.
⚠️ Used for cost intuition only. The headroom comparison below is done in **cycles**, since
this gateway's quote and these costs are both denominated in XDR and putting a USD rate
between them would import a conversion neither side needs.

⚠️ **Two subnets that are NOT this one, both easy to conflate.**

- **This gateway's own canister** is headed for a 7-node confidential subnet (#2), where
  these costs scale by 7/13 ≈ 0.54. That affects *our* gas, not a buyer's app.
- **A local `icp network` prices differently, and measurably so.** Solving two
  observations of this repo's backend (7.7 MB → 1,061,634,457 idle cycles/day; 336.7 MB →
  9,465,058,545) gives 317,500 cycles/GiB/s and a flat 10,000 cycles/s per canister —
  **2.5× the documented storage rate, plus a baseline the mainnet tables do not list.** So
  local burn is not a proxy for a buyer's bill; it overstates it.

## The model

Sizes are this repo's own artifacts, which is a fair stand-in for "a small app": the
backend wasm is **1,165,653 bytes** and the built frontend is **612,831 bytes** across 8
files.

### What must be held upfront

```
icp canister create --cycles default   2.000 T  per canister   ← not documented at the call site
× 2 canisters                          4.000 T                 ← THE GATE
   of which protocol creation fee      1.000 T   consumed
   of which lands as canister balance  3.000 T   still the buyer's
```

⚠️ **`--cycles` defaults to `2000000000000`.** It appears only in `icp canister create
--help`, and `icp deploy` inherits it silently, so a buyer who never reads that flag still
needs 2 T per canister. This is the single largest number in the model and the only one
that decides whether a purchase is enough.

### What gets consumed in the month

```
protocol creation fee, 2 canisters    1.000 T     $1.37     one-time
90 deploys (3/day × 30 days)          0.321 T     $0.44     3.57 G each
storage, 50 MB across both, 30 days   0.015 T     $0.02
                                      ───────
                                      1.336 T     $1.83
```

So after a month the two canisters still hold about **2.664 T** between them — roughly eight
further months of the same pattern before either needs a top-up, entirely separate from
whatever is left unspent in the buyer's wallet.

Two weeks rather than a month is roughly **1.16 T** — the recurring half halves, creation
does not.

**A deploy costs 3.57 G cycles, and it is almost entirely the ingress byte charge.** At
2,000 cycles/byte, every megabyte uploaded costs 2 G; the two update-call base fees are
10 M of the 3,570 M. So deploy cost tracks *artifact size*, not deploy count in any other
sense — and the asset sync uploads only **changed** files, which makes the 90-full-syncs
figure above a deliberate worst case.

**Storage is a rounding error at this scale.** 50 MB across both canisters for a month is
2 cents. Even a full gibibyte is $0.43/month. Anyone reasoning about a small app's cycle
budget should ignore storage and count creations and uploads.

⚠️ **And the conclusion survives the one figure here I am least sure of.** The docs present
127,000/GiB/s as already scaled to 13 nodes; the local measurement above disagrees with
that framing, and I attribute the gap to local pricing rather than to the doc being
per-node. If it *were* per-node, mainnet storage would be 13× higher — 0.199 T for the same
50 MB, a **1.520 T** total, and still **4.5× headroom** on a $10 purchase. So the verdict
does not rest on resolving it. Nothing else in this model is sensitive to it, because
storage is the smallest term either way.

## The one way to exceed the budget

`install_code` execution is the term this model does **not** measure, and it is the only
one that can dominate. At 1 cycle per instruction:

| instructions per upgrade | per deploy | 90 deploys | 30-day total | USD |
|---|---|---|---|---|
| base only (modelled) | 3.57 G | 0.321 T | 1.336 T | $1.83 |
| 100 M — light | 3.67 G | 0.330 T | 1.345 T | $1.84 |
| 1 B — moderate | 4.57 G | 0.411 T | 1.426 T | $1.95 |
| 10 B — heavy | 13.57 G | 1.221 T | 2.236 T | $3.05 |
| **200 B — the install limit** | 203.57 G | **18.321 T** | **19.336 T** | **$26.41** |

⚠️ **A buyer running instruction-heavy upgrades three times a day can exceed a $10
purchase**, and nothing about the storage or upload arithmetic hints at it. The realistic
band for a small app is the light-to-moderate rows, where it changes the total by under
10%; the limit row is included because it is the shape of the only failure mode, not
because it is likely.

### The freezing threshold, measured

Each canister must retain 30 days of its own idle cost (the default
`freezing_threshold = 2_592_000` seconds) and stops executing rather than spending into it.
Read off this project's own canisters:

| canister | memory | idle | reserve locked |
|---|---|---|---|
| `xrc` | 1.3 MB | 0.90 B/day | **26.9 B cycles** |
| `frontend` | 104.1 MB | 3.52 B/day | **105.7 B cycles** |
| `backend` | 336.7 MB | 9.47 B/day | **284.0 B cycles** |

So 0.03–0.28 T per canister depending on size — small against 2 T, but it is **locked, not
spendable**, and it grows with stored data. It does not change the verdict at either tier;
it is recorded because "the balance says 0.1 T" and "0.1 T is available" are different
claims.

## What $10 buys

⚠️ **Only XDR-per-USD matters, and it must be the REAL rate.** `Pricing.mo` computes
`cycles = netCents × xdrPermyriadPerIcp / usdPerIcpMicros`, so **ICP cancels** — the ICP
price is an intermediate unit, not an input to how many cycles a dollar buys. What is left
is the XDR/USD rate, and cycles mint at 1 T = 1 XDR.

At the IMF rate for 2026-09-10 — **1 XDR = $1.373470**, so $1.00 = 0.728083 XDR — and the
canister's own integer fee arithmetic (`feeBps` 290, `feeFixedCents` 30):

| tier | net | cycles | covers 4.0 T upfront? | spare |
|---|---|---|---|---|
| $5.00 | $4.56 | **3.320 T** | **NO** — short 0.68 T | — |
| $10.00 | $9.41 | **6.851 T** | yes, 1.7× | +2.851 T |
| $20.00 | $19.12 | 13.921 T | yes, 3.5× | +9.921 T |
| $50.00 | $48.25 | 35.130 T | yes, 8.8× | +31.130 T |

⚠️ **Do not price a claim off the §3 test vector.** That vector (3.5 XDR/ICP ÷ $4.55/ICP =
0.769 XDR/USD) is a fixture and runs **5.6% generous**: it yields 7.238 T for $10, which is
exactly what `test/browser`'s delivered-order baseline shows. Matching that baseline is
**not** validation of the real figure — the baseline is generated from the same fixture, so
the agreement is circular. Two drafts of this document reported 7.238 T and "eighteen
months" for that reason before the rate was checked against the IMF.

## Could the minimum go back to $5?

⚠️ **Not with default tooling.** $5 buys 3.320 T; two canisters at the CLI's default ask
for 4.0 T. A $5 buyer creates the first canister and **fails on the second**, holding
1.32 T against a 2 T request — a failure that arrives from `icp deploy` rather than from
this gateway, with nothing pointing back at the purchase being too small.

**It works only if the buyer knows to tune the flag.** At `--cycles 600m` each — protocol
fee plus the freezing reserve plus slack — the upfront need falls to ~1.2 T and $5 clears
it 2.8×. That is a real path, and it is not the default path.

⚠️ **So the $10 floor turns out to be product-justified as well as fee-justified**, which
the recorded rationale does not say. `Gate.mo` cites the card-fee share, and #21 quantified
that; neither mentions that $5 cannot fund two canisters through the standard tooling. The
number is right for a second and stronger reason than the one written down.

If it were ever revisited, the other considerations are:

- **The fixed 30¢ is regressive.** Fee share is **8.8%** of a $5 purchase against **5.9%**
  of a $10 one, so the buyer's effective price rises from **$1.46/T to $1.51/T**. That
  difference is visible on the receipt, so a buyer comparing tiers sees the penalty.
- **Per-order overhead does not scale with size.** Each order costs one HTTPS outcall
  (~220 M cycles at 13 nodes), one reserve hold, and one of the buyer's open-order slots
  regardless of amount — which is what `Gate.mo`'s "worth an outcall and a reserve hold"
  refers to.
- ⚠️ **But there is no operator loss at $5**, and that is worth stating because #21's
  comment says a $5 purchase means "selling at a loss". `Pricing` derives cycles from
  **netCents**, so Stripe's cut is recovered *from the buyer*, not absorbed. Our own
  unrecovered per-order cost is the outcall plus the ledger transfer fee, ~320 M cycles
  ≈ **$0.0004**. That framing appears to predate the net-based formula.

⚠️ **The consequence for product copy, which is #40's open question.** #41 drafted an
unshipped tile reading *"enough to deploy a small app and run it for about a month."*
Measured at the real XDR rate, $10 covers creation **plus roughly sixteen further months**
of the same three-deploys-a-day pattern. The claim understates by more than 10×. That is the safe
direction for a claim to be wrong in, but it is wrong, and #40 owns whether to say
something truer.

## Reproducing this

```python
CLI_DEFAULT, CREATE_FEE = 2_000_000_000_000, 500_000_000_000
STORAGE, IB, IBY, UB    = 127_000, 1_200_000, 2_000, 5_000_000
XDR_PER_USD             = 0.728083          # IMF, check this — it moves
WASM, ASSETS, DAYS, PER_DAY = 1_165_653, 612_831, 30, 3
CANISTERS = 2

deploy   = (IB + IBY*WASM + UB) + (IB + IBY*ASSETS + UB)
storage  = STORAGE * (50e6 / 2**30) * 86400 * DAYS
upfront  = CANISTERS * CLI_DEFAULT                        # what the CLI demands
consumed = CANISTERS * CREATE_FEE + deploy*DAYS*PER_DAY + storage

def buys(gross_cents):                                    # the canister's own fee math
    net = gross_cents - (gross_cents*290//10000 + 30)
    return net/100 * XDR_PER_USD

print("upfront  %.3f T" % (upfront/1e12))
print("consumed %.3f T" % (consumed/1e12))
for tier in (500, 1000):
    print("$%.2f -> %.3f T  covers upfront: %s"
          % (tier/100, buys(tier), buys(tier) >= upfront/1e12))
```

⚠️ Compare a tier against **`upfront`**, not `consumed`. Getting that backwards is what made
an earlier draft conclude a $5 minimum would do.

Swap `WASM`/`ASSETS` for the app being priced, and add an instruction estimate to `deploy`
if its upgrades do real work on install.
