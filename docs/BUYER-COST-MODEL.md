# What a purchase actually buys

**The question:** someone buys cycles here to create and deploy **two canisters** — a
backend and a frontend — and run them for **two weeks to a month**, syncing assets and
upgrading the backend wasm **about three times a day**. What does that cost, and does the
$10 minimum cover it?

**The answer:** ~1.35 T cycles, about **$1.83**. The $10 minimum covers it **3–5× over**,
and the single largest line is canister creation, which is one-time.

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

```
create 2 canisters                    1.000 T     $1.37     one-time, 75% of the total
90 deploys (3/day × 30 days)          0.321 T     $0.44     3.57 G each
storage, 50 MB across both, 30 days   0.015 T     $0.02
                                      ───────
                                      1.336 T     $1.83
```

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

The freezing threshold is a further reserve each canister must retain — 30 days of its own
idle cost by default — which at these sizes is well under a gibibyte-month and does not
change any conclusion.

## What $10 buys

Best compared in **cycles**, using this gateway's own quote arithmetic rather than a USD
round-trip — that way no exchange rate sits between the two sides:

```
$10.00 gross − fee (290 bps + 30¢)      = $9.41 net
$9.41 ÷ $4.55/ICP × 3.5 XDR/ICP         = 7.238 XDR = 7.238 T cycles
```

⚠️ Not a re-derivation of the docs' rate: this is `Pricing`'s own formula on §3's rate
vector, and it lands on **exactly** the 7.238 T that `test/browser`'s delivered-order
baseline shows for a $10.00 order. So it is the figure a buyer actually receives.

```
light upgrades     needs 1.35 T  → 5.4× headroom
moderate upgrades  needs 1.43 T  → 5.1× headroom
heavy upgrades     needs 2.24 T  → 3.2× headroom
```

After the one-time 1.0 T of creation, the recurring cost is ~0.336 T/month, so a $10
purchase carries about **eighteen further months** of the same three-deploys-a-day pattern.

⚠️ **The minimum is not what constrains a buyer, and $5 would also have covered this**
(~3.4 T, 2.5× headroom). Anyone re-litigating the floor should argue about the card fee,
which is the actual binding constraint and the reason recorded in the code.

⚠️ **The consequence for product copy, which is #40's open question.** #41 drafted an
unshipped tile reading *"enough to deploy a small app and run it for about a month."*
Measured, $10 covers creation **plus roughly eighteen further months** of the same
three-deploys-a-day pattern. The claim understates by more than 10×. That is the safe
direction for a claim to be wrong in, but it is wrong, and #40 owns whether to say
something truer.

## Reproducing this

```python
CREATE, STORAGE, IB, IBY, UB = 500_000_000_000, 127_000, 1_200_000, 2_000, 5_000_000
USD_PER_T = 0.683 / 0.5
WASM, ASSETS, DAYS, PER_DAY = 1_165_653, 612_831, 30, 3

deploy  = (IB + IBY*WASM + UB) + (IB + IBY*ASSETS + UB)
storage = STORAGE * (50e6 / 2**30) * 86400 * DAYS
total   = 2*CREATE + deploy*DAYS*PER_DAY + storage
print(total/1e12, "T", "$%.2f" % (total/1e12*USD_PER_T))
```

Swap `WASM`/`ASSETS` for the app being priced, and add an instruction estimate to `deploy`
if its upgrades do real work on install.
