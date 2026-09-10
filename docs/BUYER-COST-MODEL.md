# What a purchase actually buys

**The scenario:** someone buys cycles here to create and deploy **two canisters** — a
backend and a frontend — and run them for **two weeks to a month**, syncing assets and
upgrading the backend wasm **about three times a day**, on a **13-node** application subnet.

**The answer:** they need **4.0 T upfront** and consume **~1.34 T** over the month. The
upfront figure decides sufficiency: **$10 covers it 1.7×, $5 does not cover it at all.**

## Upfront and consumed are different numbers

⚠️ **Compare a purchase against `upfront`, not against `consumed`.** They differ by 3× here,
and only the first decides whether a buyer can get started.

```
UPFRONT   icp canister create --cycles default   2.000 T per canister
          × 2 canisters                         4.000 T   ← the gate
            of which protocol creation fee      1.000 T   consumed
            of which lands as canister balance  3.000 T   still the buyer's

CONSUMED  protocol creation fee, 2 canisters    1.000 T   $1.37
          90 deploys (3/day × 30 days)          0.321 T   $0.44
          storage, 50 MB across both, 30 days   0.015 T   $0.02
                                                ───────
                                                1.336 T   $1.83
```

⚠️ **`--cycles` defaults to `2000000000000`, documented only in `icp canister create
--help`.** `icp deploy` inherits it silently, so a buyer who never reads that flag still
needs 2 T per canister. It is the largest number in the model. Those cycles are not *spent*
— they land in the canister as its balance and remain the buyer's — but they must be held to
create the canister at all.

Two weeks rather than a month consumes ~1.16 T; the upfront figure does not move, because
creation does not scale with duration. After a month the two canisters still hold about
**2.664 T** between them, separate from whatever is unspent in the buyer's wallet.

## Where the figures come from

Documented **13-node application subnet** rates —
<https://docs.internetcomputer.org/references/cycles-cost-formulas>:

| | 13-node cost |
|---|---|
| Create a canister | 500,000,000,000 (0.5 T) |
| Storage | 127,000 per GiB per second |
| Ingress message | 1,200,000 base + **2,000 per byte** |
| Update call execution | 5,000,000 base + 1 per instruction |

Sizes are this repo's own artifacts, as a stand-in for "a small app": the backend wasm is
**1,165,653 bytes** and the built frontend is **612,831 bytes** across 8 files.

⚠️ **Price cycles off the REAL XDR/USD rate.** `Pricing.mo` computes
`cycles = netCents × xdrPermyriadPerIcp / usdPerIcpMicros`, so **ICP cancels** — it is an
intermediate unit, not an input to how many cycles a dollar buys. What remains is XDR/USD,
and cycles mint at 1 T = 1 XDR. The §3 **test vector** (3.5 XDR/ICP ÷ $4.55/ICP = 0.769
XDR/USD) is a fixture running ~5.6% generous, and `test/browser`'s baselines are generated
from it — so agreement with a baseline says nothing about the real figure. Figures below use
the IMF rate for 2026-09-10: **1 XDR = $1.373470**, $1.00 = 0.728083 XDR.

⚠️ **Two subnets that are NOT the buyer's.**

- **This gateway's own canister** targets a 7-node confidential subnet (#2), where these
  costs scale by 7/13 ≈ 0.54. That affects *our* gas, not a buyer's app.
- **A local `icp network` prices differently.** Solving two observations of this repo's
  backend (7.7 MB → 1,061,634,457 idle cycles/day; 336.7 MB → 9,465,058,545) gives 317,500
  cycles/GiB/s and a flat 10,000 cycles/s per canister — 2.5× the documented storage rate,
  plus a baseline the mainnet tables do not list. Local burn overstates a buyer's bill.

## What each tier buys

Using the canister's own integer fee arithmetic (`feeBps` 290, `feeFixedCents` 30):

| tier | net | cycles | covers the 4.0 T upfront? | spare |
|---|---|---|---|---|
| **$5.00** | $4.56 | **3.320 T** | **NO** — short 0.68 T | — |
| $10.00 | $9.41 | **6.851 T** | yes, 1.7× | +2.851 T |
| $20.00 | $19.12 | 13.921 T | yes, 3.5× | +9.921 T |
| $50.00 | $48.25 | 35.130 T | yes, 8.8× | +31.130 T |

At $10 the buyer holds ~5.5 T across wallet and canisters after the first month — roughly
sixteen further months of the same three-deploys-a-day pattern.

## Why $10 rather than $5

The floor has **two independent justifications**, and both hold:

1. **Sufficiency.** $5 buys 3.320 T against a 4.0 T upfront requirement. A $5 buyer creates
   the first canister and fails on the second, holding 1.32 T against a 2 T request — a
   failure that surfaces from `icp deploy`, with nothing pointing back at the purchase being
   too small.
2. **Fee share.** The fixed 30¢ is regressive: **8.8%** of a $5 purchase against **5.9%** of
   a $10 one, so the buyer's effective price rises from **$1.46/T to $1.51/T**, which is
   visible on the receipt.

A $5 floor works **only** if the buyer tunes `--cycles` down — at ~600 M each (protocol fee
plus freezing reserve plus slack) the upfront need falls to ~1.2 T and $5 clears it 2.8×.
That is a real path and not the default one.

⚠️ **There is no operator loss at either tier.** `Pricing` derives cycles from **netCents**,
so Stripe's cut is recovered *from the buyer*, not absorbed. Unrecovered per-order cost is
the HTTPS outcall (~220 M cycles at 13 nodes) plus the ledger transfer fee, ~320 M cycles
≈ **$0.0004**. Per-order overhead does not scale with purchase size, which is what
`Gate.mo`'s "worth an outcall and a reserve hold" refers to.

## The cost shape, and the one thing that breaks it

**Storage is a rounding error** at small-app scale — 50 MB across both canisters for a month
is 2 cents, a full gibibyte-month is $0.43. Count creations and uploads, not storage.

**The recurring cost is upload bytes.** At 2,000 cycles/byte every megabyte costs 2 G, so a
deploy costs 3.57 G and tracks *artifact size* rather than deploy frequency — the two
update-call base fees are 10 M of that 3,570 M. The 90-full-syncs figure is a worst case:
the asset sync uploads only changed files.

⚠️ **`install_code` execution is the only term that can dominate, and it is not measured
here.** At 1 cycle per instruction:

| instructions per upgrade | per deploy | 90 deploys | consumed, 30d |
|---|---|---|---|
| base only (modelled) | 3.57 G | 0.321 T | 1.336 T |
| 100 M — light | 3.67 G | 0.330 T | 1.345 T |
| 1 B — moderate | 4.57 G | 0.411 T | 1.426 T |
| 10 B — heavy | 13.57 G | 1.221 T | 2.236 T |
| **200 B — the install limit** | 203.57 G | **18.321 T** | **19.336 T** |

The realistic band for a small app is light-to-moderate, under 10% of the total. The limit
row is the shape of the only failure mode: instruction-heavy upgrades three times a day can
exceed a $10 purchase, and nothing in the storage or upload arithmetic hints at it.

### The freezing threshold

Each canister retains 30 days of its own idle cost (`freezing_threshold = 2_592_000`
seconds) and stops executing rather than spending into it. Measured on this project's
canisters:

| canister | memory | idle | reserve locked |
|---|---|---|---|
| `xrc` | 1.3 MB | 0.90 B/day | **26.9 B cycles** |
| `frontend` | 104.1 MB | 3.52 B/day | **105.7 B cycles** |
| `backend` | 336.7 MB | 9.47 B/day | **284.0 B cycles** |

0.03–0.28 T per canister depending on stored data — small against 2 T, but **locked rather
than spendable**, and it grows.

### Sensitivity

The documented storage rate is presented as already scaled to 13 nodes. If it were per-node
instead, storage is 13× higher — 0.199 T for the same 50 MB, a 1.520 T consumed total. The
verdict is unchanged at every tier, because storage is the smallest term either way.

## Reproducing this

```python
CLI_DEFAULT, CREATE_FEE = 2_000_000_000_000, 500_000_000_000
STORAGE, IB, IBY, UB    = 127_000, 1_200_000, 2_000, 5_000_000
XDR_PER_USD             = 0.728083          # IMF — check it, it moves
WASM, ASSETS, DAYS, PER_DAY = 1_165_653, 612_831, 30, 3
CANISTERS = 2

deploy   = (IB + IBY*WASM + UB) + (IB + IBY*ASSETS + UB)
storage  = STORAGE * (50e6 / 2**30) * 86400 * DAYS
upfront  = CANISTERS * CLI_DEFAULT
consumed = CANISTERS * CREATE_FEE + deploy*DAYS*PER_DAY + storage

def buys(gross_cents):                      # the canister's own fee math
    net = gross_cents - (gross_cents*290//10000 + 30)
    return net/100 * XDR_PER_USD

print("upfront  %.3f T" % (upfront/1e12))
print("consumed %.3f T" % (consumed/1e12))
for tier in (500, 1000):
    print("$%.2f -> %.3f T  covers upfront: %s"
          % (tier/100, buys(tier), buys(tier) >= upfront/1e12))
```

Swap `WASM`/`ASSETS` for the app being priced, `CANISTERS` for its shape, and add an
instruction estimate to `deploy` if its upgrades do real work on install.
