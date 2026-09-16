# Operating the gateway

Setup, in every mode it runs in. `RUNBOOK.md` is the other half — day-2 operations,
entered by symptom, once something is already running.

## The three modes, and the fourth cell

Two settings decide the mode, and they are independent, so four combinations are
representable:

| `expected_livemode` | `divisor` | mode | what bounds a giveaway |
|---|---|---|---|
| `?false` | 1 | **local plain** — what `scripts/local-dev-seed.sh` sets | nothing needed; the cycles are local |
| `?false` | >1 | **mainnet simulation** | the buyer allow-list |
| `?true` | 1 | **mainnet production** | real money |
| `?true` | >1 | **refused by design** — `#simulationDivisorSet` / `#divisorNeedsSandbox` | — |

⚠️ **Row 1 is representable on MAINNET, and that is the sharp edge.** `?false` with
`divisor = 1` on mainnet means free Stripe-sandbox payments delivering **full-value**
cycles out of a funded reserve. `Gate`'s `#unboundedGiveaway` guard keys on *accepting
test payments + an empty allow-list + a funded reserve* — **it never looks at the
divisor**. So the only thing between that configuration and giving real cycles away is
who is on the allow-list. Both halves of that are enforced; nothing but this table puts
them on one page.

⚠️ **The divisor must be set BEFORE the first order.** `set_pricing_config` refuses a
divisor change once any order is stored (`#divisorChangeWithOrders`), because every
earlier receipt would recompute against the new value. The only way back is
`icp deploy --mode reinstall`, which discards the stored orders along with everything
else in canister memory.

⚠️ **Reinstall is available on mainnet too — what makes it unacceptable is REAL orders,
not the network.** On a simulation gateway the stored orders are test orders, so
reinstalling to `divisor = 1` is the ordinary route to production, and it is much
cheaper than a fresh canister because the canister id does not change:

| survives a reinstall | because |
|---|---|
| the Stripe webhook URL | it names the canister id |
| both sealed secrets' **ciphertexts** | the seal derives from the master key, the canister id and a fixed context — nothing from canister state, so re-send the same blobs |
| the reserve's cycles | the account belongs to the canister's principal and lives on the cycles ledger, a different canister |

What has to be redone: `refresh_reserve` (the floor resets to 0 while the stock is
intact), the buyer allow-list, and re-sending the two sealed blobs. Orders, receipts,
the audit log, the journals and the dedup sets are gone — which is why a gateway
holding orders **someone paid for** has no way back.

**Local runs in plain mode only.** A simulation divisor is settable locally too, but it
exists for mainnet simulation, where the arithmetic and its guards are documented — see
Mode 2. Keeping one local path means the local procedure has one shape.

## Prerequisites

- Node.js ≥ 22
- `mops` — `npm i -g ic-mops` (the Motoko compiler version is pinned in
  `mops.toml [toolchain]`; mops resolves it automatically)
- `icp` CLI — `npm i -g @icp-sdk/icp-cli @icp-sdk/ic-wasm`

This project uses **`icp-cli`, never `dfx`**. Project configuration lives in
`icp.yaml`; Motoko dependencies in `mops.toml` / `mops.lock`.

⚠️ **Clone with submodules.** The backend decrypts its sealed secrets using a
BLS12-381 implementation pinned as a git submodule, resolved by `mops` as a path
dependency — so without it nothing compiles:

```sh
git clone --recurse-submodules https://github.com/marc0olo/cyclepay
# already cloned:
git submodule update --init --recursive
```

That code is **experimental and unaudited**; `docs/DESIGN.md` §7.3 explains what it is
trusted with, what it is not, and the deletion criterion.

## Mode 1 — local

### Run the app locally, from nothing

Six steps, in this order. Steps 1–4 need nothing from Stripe; 5–6 are for clicking
through a real payment.

```sh
# 1. dependencies and a local replica
git submodule update --init --recursive   # the pinned crypto, first time only
mops install
icp network start -d                    # PocketIC, gateway on :8000

# 2. deploy (backend, frontend, local XRC mock)
icp deploy

# 3. make the gateway sellable — NOT optional, see below
scripts/local-dev-seed.sh

# 3b. OPTIONAL — simulation mode: real Stripe test payments, cycles scaled down.
#     ⚠️ MUST come before the first order. A divisor change is refused once any
#     order is stored, and the only way back is `icp deploy --mode reinstall`.
#     Requires the seed's `expected_livemode = ?false` (guard: `?false` exactly,
#     and `null` — the fresh-install default — is refused), so run it after step 3.
icp canister call backend set_pricing_config '(record {
  feeBps = 290 : nat; divisor = 1_000 : nat; minRateSources = 2 : nat;
  feeFixedCents = 30 : nat; maxAgeNs = 300_000_000_000 : int;
  maxRateDeltaBps = 5_000 : nat })'
#     At divisor 1_000 a $10 purchase quotes ~7.24 G cycles instead of ~7.24 T.
#     The arithmetic and the ceiling that scales with minPurchaseUsdCents are in
#     "The simulation arithmetic" under Mode 2 below. It is framed for mainnet
#     against the Stripe sandbox; the arithmetic is identical locally. The ordered
#     mainnet procedure, custom domain included, is Mode 2 itself.

# 4. allow-list yourself as a buyer
#    Open http://frontend.local.localhost:8000/ , sign in with Internet Identity,
#    copy the principal the page shows, then:
icp canister call backend add_allowed_buyer '(principal "<your-principal>")'

# 5. one-time: your restricted Stripe key (see below for the required scope)
cat > scripts/.local-dev.env <<'ENV'
STRIPE_API_KEY=rk_test_...
ENV
scripts/local-dev-seed.sh               # re-run: it provisions the key

# 6. in a SECOND terminal: webhook secret + forwarder, and leave it running
scripts/stripe-dev.sh
```

Then buy: pick an amount, pay with `4242 4242 4242 4242`, and the order walks
`created → paid → delivered`.

**Which script owns what**, because re-running the wrong one fixes nothing:

| | owns | after a `--mode reinstall` |
|---|---|---|
| `local-dev-seed.sh` | tiers, the cycles reserve, the CMC + XRC rates, the delivery timeline, the canister's own gas, the Stripe **API key** | re-run it |
| step 4 | the buyer allow-list | redo it — the principal is wiped |
| `stripe-dev.sh` | expected livemode, the **webhook signing secret**, forwarding | re-run it |

⚠️ **Run the seed before `stripe-dev.sh`.** The latter refuses to start if the gateway
cannot price, which is how it says "seed first" rather than half-configuring.

⚠️ **Step 4 is the one nobody guesses.** With an empty allow-list every purchase
refuses with `unboundedGiveaway` — the faucet guard, not a misconfiguration. The
seed prints the exact command and does not treat it as a failure.

⚠️ **Step 5 needs a restricted key** (`rk_...`) with **Checkout Sessions = Write** and
everything else None. Write is the level that also grants the read the recovery sweep
needs. No Payment Links exist to configure: the canister creates a Checkout
Session per order through the API and sets `client_reference_id` on it.

⚠️ **Do NOT `export STRIPE_API_KEY`** into a shell where you run the Stripe CLI. The CLI
prefers it over your `stripe login` credential, and opening a CLI session needs a
permission a restricted key correctly lacks — `stripe listen` then fails with
*more_permissions_required*, naming your key. Keeping it in `scripts/.local-dev.env`
avoids this; our scripts strip the variable before calling the CLI, a command you type
yourself is not protected.

#### Why the seed is not optional

A freshly deployed gateway is fail-closed on five axes at once, which looks like a
broken app rather than a safe one:

| What you see | Why |
|---|---|
| "No amounts are configured yet" | No presets registered. That is **not** a paused rail — a custom amount still works; the seed registers the tiles |
| "No exchange rate available yet" | Pricing needs the CMC rate, which only NNS governance can set — the seed reaches it through the local PocketIC control API |
| "temporarily unavailable while the gateway is topped up" | `minCanisterCycles` is 5 T and `icp deploy` creates the canister with less. This is the canister's own **gas**, not the cycles it sells; the seed tops up rather than lowering the floor |
| Orders paid but never delivered | The **cycles reserve** is empty — delivery transfers from the gateway's own cycles-ledger account |
| `unboundedGiveaway` on every purchase | The buyer allow-list is empty (step 4) |

The seed verifies a **$10** purchase is admitted before reporting success, and queries
the CMC for what it actually stored rather than trusting the `Ok` reply — PocketIC
returning 200 only means the message was delivered.

⚠️ **The CMC rate goes stale in 15 minutes.** `scripts/local-dev-seed.sh --rate-only`
re-arms it without redoing the rest.

⚠️ **A stale rate shows as `cycles = null` in `quote_previews` — at ANY divisor.** That is
the same symptom as a scaled amount too small to clear the ledger fee, so re-arm with
`--rate-only` before concluding the divisor is too large. Both readings are available and
only one is usually true.

⚠️ **If the local identity runs out of cycles** — `Insufficient cycles` from a top-up —
either convert more or restart the network:

```sh
icp cycles mint --icp 5                 # ~17.5 T; ICP is pre-seeded on local principals
icp network stop && icp network start -d   # worst case: reseeds principals, wipes state
```

Re-running the seed is otherwise free: it skips the 20 T top-up when the canister
already clears its floor with headroom.

### Verify the deployment wiring

```sh
scripts/e2e-local.sh                      # 20 checks against a real local network
```

Covers what the canister suites structurally cannot: the deploy pipeline, the
`PUBLIC_CANISTER_ID:xrc` override, the `ic_env` cookie, local Internet Identity,
a signed webhook through the real gateway (and unsigned/bad-MAC bodies refused),
and that `icp.yaml`'s `ic` environment excludes the local-only mock.

### Backend iteration loop

```sh
mops check -- -Werror        # typecheck + lint; -Werror makes M0145 a build failure
mops build                   # compile, and regenerate the committed .did
mops test                    # the Motoko unit suites
```

The three IC brand typefaces are **vendored** into the bundle rather than linked from
Google Fonts: a page that takes card details should not send every visitor's IP to a
third party on load. `scripts/fetch-fonts.sh` re-vendors them — the committed `.woff2`
files are its output.

### Frontend iteration with hot reload

Needs the network up and the backend deployed: the Vite dev server shells out to
`icp` to simulate the `ic_env` cookie the asset canister sets in production.

```sh
icp network start -d && icp deploy
npm --prefix src/frontend run dev
```

TypeScript bindings are regenerated from the committed Candid interface
(`src/backend/dist/backend.did`) by the `icpBindgen` Vite plugin on every
dev/build run. Change the backend API, run `mops build` to refresh the `.did`,
and the frontend picks it up — or fails to typecheck, which is the point.

### After a change to the stable shape

A new field on `Order`, a removed variant tag, a changed config record: the
upgrade **traps in `register_stable_type`** because enhanced orthogonal
persistence refuses to reinterpret the existing memory. Locally that is not a
migration problem, it is a two-command problem:

```sh
icp deploy --mode reinstall --yes
./scripts/local-dev-seed.sh
```

`scripts/e2e-local.sh` detects the trap and does this for you. Do **not** add a
mops migration file to avoid it — the app holds no data anyone needs, and every
migration replays forever on a fresh install. The chain is a go-live
prerequisite, and `RUNBOOK.md` section 1.1 item 1 carries the three facts that decide
how it gets written.

Reinstalling wipes local orders, the audit log and the delivery journal. That is
expected: re-seed, and restart a manual run from the top.

⚠️ **It also wipes the Stripe webhook secret, and `local-dev-seed.sh` does not
put it back** — only `scripts/stripe-dev.sh` does, because the secret belongs to
a `stripe listen` session rather than to the deployment. So after a reinstall,
re-run `scripts/stripe-dev.sh` before paying anything.

Skipping it costs more than it looks: an unprovisioned secret makes the canister
drop every event it cannot verify, so a real payment produces **no order
movement, no error-queue entry and no audit line at all**. Check it in one call
rather than guessing:

```sh
icp canister call backend webhook_secret_status '()'    # isSet must be true
```

### Stopping

```sh
icp network stop
```

### Testing the Stripe rail locally

Against a **Stripe sandbox account**, with the real Stripe CLI forwarding real
signed webhooks into a local replica:

```sh
brew install stripe/stripe-cli/stripe
stripe login                 # choose a SANDBOX account, never a live one

icp network start -d && icp deploy backend
scripts/stripe-dev.sh        # bootstraps dev config, wires the signing secret, forwards
```

Then, in another terminal, `stripe trigger checkout.session.completed`. See
`docs/STRIPE.md` §15 for the happy-path walkthrough and the two gotchas
(`stripe trigger` sends no `client_reference_id`; the canister checks the
signature timestamp against its own clock).

## Mode 2 — mainnet simulation

⚠️ **This is not Mode 3 with different values.** Mode 3 deploys a production gateway:
live Stripe key, `expected_livemode = ?true`, real cycles delivered. This deploys a
gateway that takes **real charges in Stripe's sandbox** and delivers a divisor'd fraction
of the cycles, so two of Mode 3's steps are not merely different here, they are *refused*
— `divisor > 1` requires `expected_livemode == ?false` exactly, and the two guards are
mutual (see The simulation arithmetic below).

Target of this procedure: `https://cyclepay.raymondk.co`, on the confidential subnet
`re2t4-faa75-v3vhk-kdmdr-uyrkl-aik2l-ixd6u-p3fyr-zlfkc-6c5af-zae`, divisor 1000.

### What needs no configuration

| | why |
|---|---|
| the Exchange Rate Canister | `icp.yaml`'s `ic` environment lists `[backend, frontend]` only, so the local XRC mock is never created on mainnet and its id is never injected. The backend then falls back to the real XRC. **Verify — but not until a rate call has happened, see below:** `pricing_status.xrcCanisterId` must read `uf6dk-hyaaa-aaaaq-qaaaq-cai` |
| the Cycles Minting Canister | `rkp4c-7iaaa-aaaaa-aaaca-cai` is compiled in and is the same principal on mainnet and PocketIC |
| a webhook forwarder | `scripts/stripe-dev.sh` exists only because Stripe cannot reach localhost. On mainnet Stripe posts straight to the canister |
| the CSP | `connect-src` already admits `https://icp-api.io`, which is where a custom-domain page sends its canister calls |

### The order is one-way in four places

```
expected_livemode = ?false        <- ?false EXACTLY; null is the fresh-install default and is refused
        |
set_pricing_config divisor=1000   <- refused once ANY order is stored. Reinstall is the only way back
        |
add_allowed_buyer <tester>        <- MUST precede funding the reserve
        |
icp cycles transfer -> refresh_reserve
```

And the fifth, outside the canister: **the derivation origin decides who every buyer is.**
It is pinned to the frontend canister's own origin (`src/frontend/src/config.ts`), which is
what makes this test domain and whatever production domain is chosen yield the **same**
principals. Changing that pin after the first sign-in strands every account.

### Cycles

```bash
# ⚠️ `-n ic` on BOTH. Without it these act on the local network, where `mint` has no CMC
# to convert against and `balance` reports a local balance that has nothing to do with
# what you are about to spend. Exactly one of --icp / --cycles is required.
icp cycles mint --icp 5 -n ic     # or --cycles 8600b, which solves for the ICP needed
icp cycles balance -n ic
```

⚠️ **Every row is cash to mint, and a component sits under its parent rather than beside
it.** Mixing targets ("to 5 T") with increments ("+0.2 T") is how a budget stops being
checkable: an earlier version of this table listed the creation fee next to the 4.0 T it
comes out of, and totalled 7.7 T while its own rows summed to 8.5 T.

⚠️ **Measured on this subnet, not derived.** An earlier version scaled the creation fee
by 7/13 with the rest of the per-node costs and budgeted ~269 B per canister. The real
deployment consumed **505.9 B each**: the creation fee is the 500 B flat figure and does
**not** scale with subnet size. That understated the total by half a trillion.

```
  4.000 T   icp deploy, two canisters at the 2 T default
              of which creation fees         1.012 T   consumed (505.9 B each, MEASURED)
              of which lands as balance      2.988 T   1.494 T per canister
+ 3.506 T   top the backend up to its own-gas floor
              5 T floor minus the 1.494 T it actually holds. COMPUTE THIS, see below
+ 0.200 T   the sellable reserve, a SEPARATE pot on the cycles ledger
              at divisor 1000 a $10 purchase locks ~7.24 G, so ~27 test purchases
+ 1.000 T   slack for one reinstall, because the divisor is one-way once an order exists
  ────────
  8.706 T   to mint
```

| threshold | value | what happens below it |
|---|---|---|
| `Gate.Config.minCanisterCycles` | 5 T | the gate admits **no orders**. Compared against the raw `Cycles.balance()`, so the freezing threshold does not eat into it |
| the reserve floor | anything | `#reserveShort`, and it stays 0 until `refresh_reserve` observes a top-up |

⚠️ **4.5 T is not enough, and the shortfall is invisible until the first order**: the two
canisters get created, the frontend serves, and every `create_order` is refused because the
backend sits under its own-gas floor. 5 ICP mints comfortably past 8.6 T at current rates;
check with `icp cycles balance -n ic` before starting rather than after step 1.

⚠️ **`pricing_status` reads `xrcCanisterId = null`, `rates = null`, `lastAttempt = null`
on a fresh deploy, and all three are CORRECT.** Do not read them as a broken rate path.

- `xrcCanisterId` is **null until an XRC call has actually resolved it** (`Main.mo`), and
  deliberately so: defaulting it to the mainnet id would make the one signal that detects
  a mainnet deploy wrongly pointed at a mock read *all-clear* during exactly the window an
  operator checks a fresh deploy.
- No XRC call has happened because the rate timer returns early while no rail is selling
  (`rateTimerJob`: `if (not railsLive()) return`). A dark gateway spends nothing, and the
  rail is not live until both Stripe secrets and the return origin are set (steps 4 and 5).

So the XRC verification cannot pass before step 5. To check it earlier, force a tick:
`refresh_rates` is an admin method that calls the refresh **directly and bypasses the
`railsLive` guard**, which is what makes it the right lever here and after any deploy.

```bash
icp canister call backend refresh_rates '()' -e ic --identity <operator>
icp canister call backend pricing_status '()' -e ic   # xrcCanisterId = uf6dk-hyaaa-aaaaq-qaaaq-cai
```

⚠️ And `xrcCanisterId` is **transient**: it is null again after every upgrade until the
next rate call. A null reading after a redeploy means "not yet asked", never "misconfigured".

### 1. Create and install on the confidential subnet

```bash
# From a green main. The -Werror gate runs on `mops check`, not on `icp deploy` (see Mode 3).
bash scripts/test-all.sh

icp deploy -e ic \
  --subnet re2t4-faa75-v3vhk-kdmdr-uyrkl-aik2l-ixd6u-p3fyr-zlfkc-6c5af-zae

icp canister status backend -e ic -i     # note both ids
icp canister status frontend -e ic -i

# The backend's own gas, to the floor. This is NOT the reserve.
#
# ⚠️ **Read the balance and compute the difference; do not paste a figure.** What
# creation leaves behind is not something to assume -- this step said `--amount 3400b`,
# which lands at 4.894 T against a 5 T floor and leaves the gate refusing every order
# after an operator has "done the step". Off by 106 B, invisible until the first order.
icp canister status backend -e ic | grep -i cycles      # e.g. 1_494_093_400_599
#   top-up = 5_000_000_000_000 - that, rounded up. For the figure above: 3506b.
icp canister top-up backend --amount 3506b -e ic
icp canister status backend -e ic | grep -i cycles      # must now read >= 5_000_000_000_000
```

⚠️ **`--subnet` on the deploy, not on a later create.** A canister already created on the
default application subnet cannot be moved; the only fix is to delete it and start over,
and on mainnet that means new canister ids — which means a new derivation origin and a
new principal for anyone who signed in.

Raise the freezing threshold once the deployment is real. 30 days is thin for
money-bearing state, and for a sandbox it is a judgement call rather than a rule:

```bash
icp canister settings update backend --freezing-threshold 7776000 -e ic   # 90 days
```

### 2. The custom domain

Two files ship in the frontend already — `src/frontend/public/.well-known/ic-domains` and
`ii-alternative-origins` — so the canister serves both after step 1. What remains is DNS
and the registration call.

| record | host | value |
|---|---|---|
| CNAME | `cyclepay.raymondk.co` | `cyclepay.raymondk.co.icp1.io` |
| TXT | `_canister-id.cyclepay.raymondk.co` | the **frontend** canister id |
| CNAME | `_acme-challenge.cyclepay.raymondk.co` | `_acme-challenge.cyclepay.raymondk.co.icp2.io` |

⚠️ **Turn off the DNS provider's own TLS.** Cloudflare's Universal SSL and equivalents
interfere with the ACME challenge the boundary nodes run, and can leave stale
`_acme-challenge` TXT records that do not appear in the dashboard. Check with
`dig TXT _acme-challenge.cyclepay.raymondk.co` — there should be no TXT records, only the
CNAME.

```bash
curl -sL "https://icp.net/custom-domains/v1/cyclepay.raymondk.co/validate" | jq
curl -sL -X POST "https://icp.net/custom-domains/v1/cyclepay.raymondk.co" | jq
curl -sL "https://icp.net/custom-domains/v1/cyclepay.raymondk.co" | jq '.data.registration_status'
```

Poll until `registered`, then give the gateways a few minutes.

⚠️ **`.well-known/ii-alternative-origins` is what makes the domain usable at all.**
Internet Identity fetches it from the derivation origin and refuses to derive for a
serving origin the file does not list. Adding a second serving domain later means editing
that file **and** redeploying before the domain goes live.

### 3. Declare the mode, then the divisor

```bash
# ?false EXACTLY. `null` accepts either mode and is what a fresh install has.
icp canister call backend set_expected_livemode '(opt false)' -e ic --identity <operator>
icp canister call backend expected_livemode '()' -e ic

# Simulation. MUST come before the first order.
icp canister call backend set_pricing_config '(record {
  feeBps = 290 : nat; feeFixedCents = 30 : nat; maxAgeNs = 300_000_000_000 : int;
  maxRateDeltaBps = 5_000 : nat; minRateSources = 2 : nat; divisor = 1_000 : nat })' \
  -e ic --identity <operator>

icp canister call backend pricing_status '()' -e ic   # divisor = 1_000, xrcCanisterId = uf6dk-...
```

⚠️ **The divisor's ceiling scales with `minPurchaseUsdCents`, not with the purchase.** At
the shipped $10 floor, divisor 1000 leaves 7.24 G — 72x the flat 100 M ledger deposit fee,
so it is accepted. Lower the floor for a demo and the same divisor is refused
(`#simulationScaleTooSmall`): that is the guard working, not a bug.

### 4. The secrets, sealed, without any local script

Both Stripe secrets are **encrypted to the canister before they are sent**, so the
plaintext never appears in an ingress message, a shell history or a CI log. The mainnet
path differs from the local one only in the `ic` argument, which selects the **mainnet
vetKD master key** — and that choice is derived from the environment rather than typed,
because mainnet and a local network both call their key `key_1` and sealing against the
wrong one produces a ciphertext nobody can ever open.

You do **not** set these up front. Each `read` waits for you to paste the value:

```bash
# `read -rs` takes one line from the terminal into the variable: -s so nothing echoes,
# -r so a backslash stays a backslash. The `printf` is the prompt -- `read` prints none
# of its own, so without it the terminal just looks hung.
#
# ⚠️ **This is the point, not ceremony.** `STRIPE_API_KEY=rk_... scripts/seal-secret.sh`
# would put the key in ~/.zsh_history; typed into `read`, the only thing history records
# is `read -rs STRIPE_API_KEY`. `export` is what lets the script's child process see it.
#
# ⚠️ `read -rsp "prompt: " VAR` is the BASH idiom and FAILS in zsh, where -p means "read
# from the coprocess" (`zsh:read:1: -p: no coprocess`). Prompt with printf in both.
printf 'Stripe restricted key (rk_...): '; read -rs STRIPE_API_KEY
printf '\n%s chars captured\n' "${#STRIPE_API_KEY}"
export STRIPE_API_KEY
scripts/seal-secret.sh api-key ic

printf 'Stripe webhook signing secret (whsec_...): '; read -rs STRIPE_WEBHOOK_SECRET
printf '\n%s chars captured\n' "${#STRIPE_WEBHOOK_SECRET}"
export STRIPE_WEBHOOK_SECRET
scripts/seal-secret.sh webhook-secret ic

# ⚠️ Not optional. An exported key stays readable by every later child process of this
# shell -- including the Stripe CLI, which prefers STRIPE_API_KEY over its own session
# and cannot use a restricted key (`more_permissions_required`).
unset STRIPE_API_KEY STRIPE_WEBHOOK_SECRET
```

⚠️ **The length echo is the confirmation, and it exists because there was none.** `read -rs`
shows nothing as you type, so a paste that silently fails is indistinguishable from one that
worked. Check the number against the key you hold before running the seal.

`scripts/.local-dev.env` is the other way the script finds these, and it is read **only for
a local environment**: it holds sandbox values, and a mainnet key does not belong in the
repo tree even gitignored.

⚠️ **That scoping is a fix, not a convention.** The file used to be consulted for any
environment whenever the variable was empty, so an empty paste during a mainnet
provisioning sealed the **sandbox** key to the **mainnet** canister, and printed the same
byte count, the same `isSet = true` and the same `generation = 1`. Both keys are 107
characters, so even the length disclosure could not separate them. The script now refuses a
set-but-empty value outright and never reads the file for a named environment.

⚠️ **Use a SANDBOX restricted key (`rk_test_...`), Checkout Sessions = Write, everything
else None.** Write is the level that also grants the read the recovery sweep needs.
Never an unrestricted `sk_`: a leaked write-sessions key can only create sessions that pay
*us*, while one that can issue refunds is materially worse.

⚠️ **Do NOT export `STRIPE_API_KEY` into a shell where the Stripe CLI runs.** The CLI
prefers that variable over its own `stripe login`, and a restricted key cannot open a CLI
session (`more_permissions_required`).

If you would rather run the two steps by hand — a different machine, or wanting each step
visible — that is all the script does:

```bash
BACKEND=$(icp canister status backend -e ic -i)

# 1. Seal, OFFLINE. The public key is computed from a master key shipped in
#    @icp-sdk/vetkeys plus the canister id: no network call, no identity, nothing to
#    trust. Anyone may seal a secret TO the canister; only it can open one.
CYCLEPAY_SEAL_SECRET="$STRIPE_API_KEY" npm --prefix scripts/seal run --silent seal -- \
  --canister "$BACKEND" --source mainnet --out /tmp/sealed.arg

# 2. Send it. This is the only step that involves your identity.
icp canister call backend set_stripe_api_key --args-file /tmp/sealed.arg -e ic
rm -f /tmp/sealed.arg

icp canister call backend stripe_api_key_status '()' -e ic   # isSet = true, generation = 1
```

`--source mainnet` has no default, on purpose. A `#notSealedToThisCanister` refusal means
the ciphertext was sealed against the other network's master key — the failure this
arrangement exists to make loud instead of silent.

### 5. Stripe: where events arrive, and where the buyer comes back

Two different URLs, and only the second one is the custom domain.

```bash
# Where the BUYER returns after paying. Validated: https, no query, no fragment.
# success_url becomes `<origin>/#/order/<id>`, and the app routes on the hash, so the
# certified-assets canister needs no _redirects rule for it.
icp canister call backend set_stripe_origin '("https://cyclepay.raymondk.co")' \
  -e ic --identity <operator>
icp canister call backend stripe_origin '()' -e ic
```

In the Stripe **sandbox** dashboard, add a webhook destination pointing at the **backend
canister**, not the domain:

```
https://<backend-canister-id>.icp.net/webhook/stripe
```

| event | what it does here | omitting it |
|---|---|---|
| `checkout.session.completed` | the delivery path | nothing is ever delivered |
| **`checkout.session.expired`** | the **only** *event* that moves an order to `#expired` and releases its reserve promise (`RUNBOOK.md`'s order-expiry section) | ⚠️ orders sit `#created` past their deadline forever. That section makes a stuck `#created` order the detection signal for a broken one, so a missing subscription manufactures false alarms in the signal the design relies on. ⚠️ **And the obvious lever does not recover it:** `expire_order` asks Stripe first and refuses with `#sessionNotOpen` once the session has really expired there, which is precisely this case. Subscribe, then **resend the event from the Stripe Dashboard** so the order moves through its normal path |
| `charge.refunded` | resolves an `#unattributed` obligation, and files one for a late payment | a refund settles the money and leaves the worklist item open |
| `charge.dispute.created` | one audit line: *reconcile in Stripe; cycles cannot be recovered* | the dispute leaves no trace in the trail |
| `checkout.session.async_payment_succeeded` | the delivery path, for a delayed method | **cannot fire today** — `createBody` pins `payment_method_types[]=card` and cards settle synchronously. Subscribe anyway: if that pin is ever removed, an unsubscribed success is fiat in with nothing delivered and nothing on the worklist |
| `checkout.session.async_payment_failed` | one audit line: *will never pay* | same, and same reason to subscribe |

⚠️ **Subscribe to all six.** The first three are load-bearing, the next one is the audit
trail, and the last two are free insurance against a change to the payment-method pin.

⚠️ The signing secret that destination shows you is the one step 4 provisions. Until it is
set the route answers 503 and Stripe retries.

### 6. Allow-list, then fund the reserve

⚠️ **This order, for the reason `RUNBOOK.md`'s reserve section gives**: sandbox payments are free and unlimited, so
test mode plus an empty allow-list plus a funded reserve is a cycles faucet, and the
gateway refuses every buyer in that state (`#unboundedGiveaway`).

```bash
# Sign in at https://cyclepay.raymondk.co, copy the principal the page shows.
# ⚠️ That principal is derived from the pinned derivation origin, so it is the same one
# you would get at the canister URL -- and a principal copied from any OTHER deployment
# of this app is not.
icp canister call backend add_allowed_buyer '(principal "<tester>")' -e ic --identity <operator>
icp canister call backend allowed_buyers '()' -e ic

icp cycles transfer 200b <backend-principal> -n ic
icp canister call backend refresh_reserve '()' -e ic --identity <operator>
icp canister call backend reserve_status '()' -e ic     # availableToSell > 0
```

⚠️ **`refresh_reserve` is not optional and its absence is silent**: the ledger holds
the cycles, `availableToSell` stays 0, and every buyer is refused with
`#reserveShort`. Read `reserve_status` back — that is what the third line is for.

### 6a. The price tiles

⚠️ **This step was missing from this procedure entirely**, which is how a deployment
gets a buy page with no way to buy: `renderTiers` returns early on an empty list and
the custom-amount tile is built *after* that return, so an unconfigured gateway offers
neither. The canister accepts a custom amount; the page never asks for one. Mode 3's step 4
carries the same warning, and this procedure is the one that produced the live
deployment.

```bash
icp canister call backend set_card_tiers \
  '(vec { record { id = "t10"; usdCents = 1_000 : nat };
          record { id = "t20"; usdCents = 2_000 : nat };
          record { id = "t50"; usdCents = 5_000 : nat } })' \
  -e ic --identity <operator>
icp canister call backend card_tiers '()' -e ic          # three tiles
```

Every tier must sit inside the gate's bounds (`RUNBOOK.md`'s admission-gate section) or the whole vector is refused. No
`$100` preset: that is the ceiling, and it is what the custom field is for.

### 7. Verify before spending a card

```bash
icp canister call backend health '()' -e ic                       # true
icp canister call backend pricing_status '()' -e ic               # ok, divisor 1_000, real XRC id
icp canister call backend quote_previews '(vec { 1_000 : nat })' -e ic
icp canister call backend refusal_counts '()' -e ic               # every refusingNow flag false
icp canister call backend expected_livemode '()' -e ic            # opt false
curl -sI https://cyclepay.raymondk.co                             # HTTP/2 200
curl -sL https://cyclepay.raymondk.co/.well-known/ic-domains
```

⚠️ **Verify IDENTITY too — it is the only one-way item in this list**, and the one nothing
above touches. Two checks, before step 6 allow-lists a principal and funds a reserve
against it:

```bash
# 1. Internet Identity reads this CROSS-ORIGIN from the derivation origin. Without the
#    CORS header it cannot read the file, cannot validate the domain, and refuses to
#    derive -- which presents as sign-in failing only on the custom domain.
curl -sI https://<frontend-canister-id>.icp.net/.well-known/ii-alternative-origins
#    expect: content-type: application/json  AND  access-control-allow-origin: *
```

2. **Sign in at `https://cyclepay.raymondk.co` and at
   `https://<frontend-canister-id>.icp.net`, and confirm the page shows the same
   principal.** Thirty seconds, and it turns this section's central claim from prose into
   an observation. If they differ, stop: the derivation origin is not in effect, and
   anything allow-listed from here is allow-listed for an identity that will not come
   back.

⚠️ **`availableToSell` stays in REAL cycles while quotes are scaled**, so it can read
200 G while $10 buys 7.24 G. Arithmetically right, and startling without this sentence.

⚠️ **A stale rate shows as `cycles = null` in `quote_previews` at ANY divisor.** Read
`pricing_status` before concluding the divisor is wrong, and force a tick rather than
waiting for the timer -- a fresh install before its first refresh is exactly when this
appears:

```bash
icp canister call backend refresh_rates '()' -e ic --identity <operator>
icp canister call backend pricing_status '()' -e ic     # ok = true, fetchedAt recent
```

### The simulation arithmetic

**One number is the whole switch: `pricing_status().config.divisor`.** `1` is
production; anything greater is simulation, and the mode signal, the banner and the
receipt's extra terms all key off that same value.

This section is the mechanism and the guards. The ordered deployment procedure -- the
confidential subnet, the custom domain, sealed secrets on mainnet, and the four one-way
steps -- is **`RUNBOOK.md` section 1a**. There is deliberately no second
boolean — one that disagreed with the divisor would let two places answer "are we
simulating?" differently.

| what | where | why there |
|---|---|---|
| the scale | `Pricing.quote` | the **single** derivation of a cycle quantity, one caller — so the quote, `lockedCycles`, the promise tally, the floor decrement and the transfer are all the same scaled number |
| who may buy | the buyer allow-list | the only bound on the **total** given away; the divisor bounds only the per-order loss |
| the ceiling | `Pricing.quote` again | the cycles-ledger deposit fee is **flat**, so an over-scaled order cannot clear it |

⚠️ **Do NOT scale at delivery.** The reserve floor decrements at *issue* by the full
locked amount (§5.4 rule 2), so a scaled transfer against an unscaled decrement would
surface as an unexplained shortfall on every reconcile — the one signal that means an
outflow we did not cause.

⚠️ **The Stripe fee is taken BEFORE the divisor and the ledger fee AFTER it**, and the
asymmetry reports what each third party actually took: the buyer really is charged the
gross and Stripe really keeps its cut, so those are real dollars; the ledger really
charges a flat fee to accept whatever deposit arrives. Where the division sits in the
formula does not matter for correctness — `floor(floor(a/b)/d) == floor(a/(b*d))` for
positive integers — so it is written as one division after the rate conversion, and
`checkReceipt` divides at the same point.

### The four guards, and what each one prevents

| guard | prevents |
|---|---|
| `divisor > 1` requires `expected_livemode == ?false` **exactly** | real money in, scaled cycles out. ⚠️ `?false` exactly, not "not live": `null` means *either mode* and accepts live payments, **and `null` is the default** |
| `set_expected_livemode` refuses anything but `?false` while `divisor > 1` | the same state reached from the other direction. Mutual, so neither order of operations gets there |
| a divisor **change** is refused while any order is stored | a global divisor with earlier receipts recomputing against the new one, each reporting a mismatch. Reinstall to change it; refusing is the safe direction |
| a scaled quote must clear the ledger fee **ten times over** | the one delivery state with no recovery lever: a fee above a whole order's locked quantity means nothing reaches the ledger, so no `#BadFee` ever arrives to correct the stored copy |

⚠️ **The divisor's ceiling scales with `minPurchaseUsdCents`, not with the amount being
bought**, because the guard asks whether the *smallest purchase this gateway sells*
still clears the fee. At the shipped $10 floor a divisor of 1,000 leaves 7.24 G (72x the
100 M fee); at a $1 floor the same divisor leaves 515 M and is **refused**. An operator
who lowers the floor for a demo and then cannot set the divisor is seeing the guard work.

### The faucet, and the one ordering rule

⚠️ **Stripe test payments are free and unlimited** — `4242 4242 4242 4242` pays any
session, for anyone who reaches the page. So test mode plus an empty allow-list plus a
funded reserve is a cycles faucet, and the gateway **refuses to sell** in that state
rather than warning about it (`#unboundedGiveaway`, a rail condition with its own
counter and `refusingNow` flag).

> **The allow-list must exist and be populated before the reserve is funded.**

An **unfunded** reserve refuses every order structurally at `Gate.solvent`, before a
Stripe session is even created — which is what makes a no-code sandbox deployment safe
to explore, and why only the happy path waits on the allow-list. The canister cannot
enforce the rule at funding time: the reserve arrives as an ICRC transfer *to* its
ledger account, which it has no ability to refuse. It enforces it at the **sale**
instead, which is the operation that gives cycles away.

⚠️ **An empty list therefore means two different things**, and that is the design: it
does not filter per buyer while the floor is zero (nothing can be sold anyway), and it
refuses everyone the moment the floor is not.

### What the buyer sees

A sentence, not a badge — that a real charge happens in Stripe's sandbox and a fraction
of the cycles is delivered. And the receipt shows **both legs**: `checkReceipt`'s
`recomputed` stays the *unscaled* quantity, recomputed from the two rate inputs the
order carries, so a simulation receipt states what production would have locked, the
divisor, the locked quantity, and the ledger fee — four numbers that reconcile.

⚠️ **`availableToSell` stays in REAL cycles while quotes are scaled** (it is
`reserveFloor - promised`, and only `promised` is scaled), so it can read 775 T while
$10 buys 7 G. Arithmetically right, and startling without a word of explanation.

⚠️ **A refusal from the ledger-fee guard names the simulation, not payment processing.**
`#tierBelowFees` says fees would exceed the amount, which is true for its own cause and
false for this one — the amount is fine and the operator's divisor scaled the cycles
below the deposit fee. `#simulationScaleTooSmall` is a separate variant for that reason.

## Mode 3 — mainnet production

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
gateway accepts no orders and delivers nothing until each lever below is
consciously set.

⚠️ **A simulation gateway is not promoted in place — it is reinstalled.** The divisor
is refused once any order is stored (Mode 2), so a gateway that has taken even one test
order cannot simply be switched: `set_expected_livemode '(opt true)'` is refused while
the divisor is above 1, and the divisor cannot move while orders are stored. **Reinstall
breaks that deadlock and keeps the canister id** — so the webhook URL, both sealed
ciphertexts and the reserve's cycles all survive; see Mode 2's table above for what does
not. A fresh canister is the expensive option and is not required.

Either way, buyer identity is unaffected: principals derive from the **frontend**
canister id, which is why the derivation origin is pinned there.

### What is not a command

Six prerequisites that no step below can perform: a decision, a piece of code, or
off-chain work. Each was a separate open issue until 2026-09-14 and is here instead,
because a go-live prerequisite filed somewhere else is one that gets discovered
missing at go-live. The closed issues hold the reasoning; what is kept here is what a
deployment turns on.

**1. The migration chain, before there is data worth keeping**. `Main.mo` is a
`persistent actor` with **inline initializers** and there is no
`src/backend/migrations/`, so an incompatible stable-shape change has exactly one
remedy — `icp deploy --mode reinstall` — and on a canister holding real orders,
journals and dedup sets that is not a remedy. The incompatibility itself is caught
early: `[canisters.backend.check-stable]` compares the actor against the committed
`deployed/backend.most` inside `mops check`. Three facts to write it against:

- Write it **after** the last schema-affecting change. The init migration must
  enumerate every stable field, so writing it earlier means writing it again.
- Adding a stable `var` to the actor needs **no** migration. A field on an existing
  stable record (`Order`, `Orders.Store`, `Gate.RefusalCounts`) does, and fails
  `mops check` with *"Write an explicit migration function"*.
- ⚠️ **The baseline only helps while it is current.** Promote it with `mops deployed`
  after every deploy: adding a field is *compatible*, so a stale baseline keeps the
  gate green while it has stopped describing the actor. Measured — `cancelRequests`
  shipped that way.

Read the `migrating-motoko-actors` skill first. No `preupgrade`/`postupgrade`, no
`(with migration = ...)`.

**2. An alert someone actually receives**. `RUNBOOK.md`'s monitoring section is a complete monitoring plan —
metric, threshold, severity, action — and nothing runs it. The whole P1 set polls
**public queries**, so the alerting layer needs no key. It is done when those metrics
reach a human out of hours **and someone has tripped one deliberately and watched it
arrive**; the failure modes here are slow (a 2 h delay alert, a 72 h terminate bound),
so what is needed is something that wakes a person, not a dashboard someone visits.

**3. The claim, and the legal surface of being official**.
*"At cost"* must hold **net of card processing** or become a visible fee line — the
fee is real (≈2.9% + $0.30) and the buyer pays it. Beside it: imprint, terms, privacy
and contact; invoices a developer can expense, and the VAT position; a refund
**procedure**, because the canister deliberately models no refunds (`RUNBOOK.md`'s triage section) so refunding
is an operator action; and a staffed rotation for the obligation queue, which that same section
currently describes without anyone being on the hook for it.

⚠️ **The serving domain is not irreversible, and this reverses an earlier claim.** II
derives a principal per origin, but the derivation origin is pinned to the **frontend
canister id** (`config.ts`), so a test domain and whatever production domain is chosen
yield the *same* principals. What would be one-way is making a custom domain itself the
derivation origin — which this deployment does not do.

**4. `stripe_origin` must be https and non-loopback once livemode is `?true`**.
`Session.validateOrigin` accepts `http://` for loopback hosts, and nothing refuses the
pair `expected_livemode = ?true` with `stripe_origin = http://localhost:8000` — a live
gateway returning paying buyers to their own machine. So **read `stripe_origin` back
after setting either one** (steps 5 and 8 below).

The permanent fix is a refusal on both setters, like the divisor's — but ⚠️ **key each
refusal on the BAD VALUE, not on the pair.** `set_stripe_origin` refuses a *loopback*
origin while livemode is `?true`; `set_expected_livemode(?true)` refuses while the
*stored* origin is loopback. Phrased that way a gateway already in the bad pair can
always set a good origin and walk out. The divisor's mutual refusal is the shape to
copy and **not** the constraint: its way out is blocked by a second guard entirely
(`#divisorChangeWithOrders`), so a simulation gateway with one stored order can never
go live at all. Do not add a second lockout to a money-handling setter.

**5. Attestation coverage of the confidential subnet** (`RUNBOOK.md`'s confidential-subnet checklist). Checkpoints and
state-sync **are** confirmed confidential on the target subnet, which was the spec's
"verify this hardest" item. Attestation coverage is the box still open: one unattested
replica is one node provider who can read the webhook secret. That checklist is where it stays open.

**6. Where the repo lives, before the "check the code" link is published.**
`RELEASE.md`'s trust story is *verify the deployed module hash against a tagged
commit*, so the repository URL is a user-facing artifact. `cyclepay` also still names
the upstream fork this repo grew from. Renaming or moving is free now and costs
redirect debt once that link is on a money page.

### The steps

⚠️ **Two of these are knowingly NOT done on the live simulation deployment** — step 2's
freezing threshold (still the 30-day default) and step 10's backup controller (one
principal, no second). Both are single commands and both are production prerequisites,
deferred rather than missed. Read `icp canister status backend -e ic` before assuming
either has been done on whatever deployment you are looking at.

1. **Deploy and verify** per `RELEASE.md` — reproducible build, published module
   hash, and `icp canister status` gated on matching it.

2. **The canister's own gas, and its freezing threshold.** `minCanisterCycles`
   refuses every order below the floor, and the XRC needs 1 B attached per rate
   refresh. ⚠️ **Read the balance and compute the difference; never paste a figure** —
   Mode 2 records what pasting one cost. Then raise the freezing threshold: this
   canister holds money-bearing state, so the 30-day default is thin, and losing it
   to a cycle drain destroys the order store, the journals and the dedup sets.

   ```bash
   icp canister status backend -e ic                 # read the balance first
   icp canister top-up backend --amount <diff> -e ic  # --amount, not --cycles
   icp canister settings update backend --freezing-threshold 7776000 -e ic  # 90 days
   ```

3. **Fund the cycles reserve, then tell the gateway to look** (`RUNBOOK.md`'s reserve section). Delivery transfers
   out of the gateway's own cycles-ledger account, which is a **different pot from
   step 2** — `icp canister top-up` does not touch it.

   ```bash
   icp cycles transfer <amount> <backend-principal> -n ic
   icp canister call backend refresh_reserve '()' -e ic
   ```

   ⚠️ **The second call is not optional.** Solvency is decided against a maintained
   lower bound that starts at zero and rises only by observation, so without it the
   gateway refuses every sale with `#reserveShort{available = 0}` while the ledger
   holds the full amount.

   ⚠️ **How much is a SECURITY decision before it is a working-capital one.** A forged
   webhook delivers from the reserve and nothing caps that, so **the reserve balance is
   the blast radius** (`RUNBOOK.md`'s webhook-secret and confidential-subnet sections). Size it to what you are willing to lose between a leak
   and its detection, and top up on a cadence rather than parking months of stock in
   the account. The gate's `maxPurchaseUsdCents` is the per-order exposure inside it.

4. **Register card tiers. Not optional in practice** (`RUNBOOK.md`'s presets-and-keys section):

   ```bash
   icp canister call backend set_card_tiers \
     '(vec { record { id = "t10"; usdCents = 1_000 : nat };
             record { id = "t20"; usdCents = 2_000 : nat };
             record { id = "t50"; usdCents = 5_000 : nat } })' \
     -e ic --identity <operator>
   ```

   ⚠️ **With an empty list the buy view offers NO WAY TO BUY**, and the reason is not
   the one you would guess. `Amount` is `variant { custom : nat; tier : text }` and
   nothing in the create path validates an amount against the tier list, so the
   *backend* really does accept any amount within the gate's bounds. But `renderTiers`
   returns early on an empty list, and the **custom-amount tile is built after that
   return** — so no tiles and no custom field. The technically-optional reading is true
   of the canister and false of the page.

   The whole-vector setter replaces the list; there is no add or remove, and `'(vec {})'`
   clears it. Every tier must sit inside the gate's bounds or it is refused. No `$100`
   preset: that is the ceiling, and it is what the custom field is for.

5. **Declare the Stripe mode:**

   ```bash
   icp canister call backend set_expected_livemode '(opt true)' -e ic --identity <operator>
   ```

   Until this is set, a test-mode webhook secret would deliver **real** cycles for
   payments that never happened. Verify with `expected_livemode`, and re-read
   `stripe_origin` (What is not a command, item 4).

6. **Configure the Stripe webhook destination**: in the Stripe Dashboard, add
   `https://<backend-canister-id>.icp.net/webhook/stripe` subscribed to the events in
   Mode 2's table. ⚠️ **Not just `completed` and `charge.refunded`** —
   `checkout.session.expired` is the *only* thing that expires an order (`RUNBOOK.md`'s order-expiry section), and the
   canister dispatches on six types in all. An unsubscribed event is not "acked and
   ignored": it is never sent, so its handler never runs.

7. **Provision the webhook signing secret** (`RUNBOOK.md`'s webhook-secret section). Until it is set the webhook route
   answers 503 and Stripe retries. Sealed — it never appears in an ingress message, a
   shell history or a CI log (§7.3 of `docs/STRIPE.md`; Mode 2's step 4 carries the exact
   commands).

8. **The origin, then the live API key — the pair that opens the rail** (`RUNBOOK.md`'s presets-and-keys section).

   ```bash
   icp canister call backend set_stripe_origin '("https://<your-origin>")' -e ic --identity <operator>
   # then set_stripe_api_key, sealed, per Mode 2's step 4
   ```

   The key is **LIVE, restricted (`rk_...`), Checkout Sessions = Write, everything else
   None**. Write is the level that also grants the read the recovery sweep needs to
   settle an order whose expiry event never arrived (`RUNBOOK.md`'s `#paidNotCredited` triage row, and its
   `stripeApiFailing` row). A sandbox key cannot be reused.

   ⚠️ **With either missing, `create_order` refuses** — provisioning both is what opens
   the rail, so do it last; rotating either closes it until both are valid again.

   There are no Payment Links, Products or Prices to create: the session carries inline
   `price_data`, and `amount_total == usdCents` holds because of what the session does
   **not** enable — the eight settings are listed in `rails/Session.mo` beside the body
   builder, and `test/session.test.mo` asserts their absence. Historically a mismatch
   there failed silently and delivered a different cycle quantity; it now delivers
   nothing and files a refund obligation, so a wrong amount is visible on the first
   order rather than as drift.

9. **Review the admission gate** (`RUNBOOK.md`'s admission-gate section). The defaults are non-zero and usable, but
   `maxPurchaseUsdCents` should sit just above your largest tier, and
   `minCanisterCycles` should suit how closely you monitor this canister.

10. **Add a backup controller.** A single controller identity with no backup means a
    lost key makes the canister permanently un-upgradeable; there is no recovery path
    (`RUNBOOK.md`'s operating model covers the trust model this implies).

11. **Wire monitoring (`RUNBOOK.md`'s monitoring section) before announcing the service**, not after — and confirm an
    alert arrives (What is not a command, item 2).

12. **Smoke-check the public surface**: `pricing_status` — both rates populated and
    `lastAttempt.ok` true. The rate timer warms itself on install, so this should hold
    within seconds; if it does not, `lastAttempt.detail` names the failing guard (`RUNBOOK.md`'s pricing-rates section)
    and **no order can be created until it clears** (creation answers
    `rateUnavailable`, by design). Then `reserve_status`, `recovery_status` (sweep
    timer armed), `cycles_status` (balance above `minCanisterCycles`), `card_tiers`,
    and `can_purchase '(<your smallest tier's cents>)'` — the last should answer `ok`
    before you announce anything.

13. **Buy one thing on the deployed site with a real card.** Nothing short of a live
    purchase exercises the key, the origin, the return URL and the webhook secret
    together.
