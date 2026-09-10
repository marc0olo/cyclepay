# CyclePay — Fully On-Chain Cycles Gateway

**Buy cycles with a credit card.** No ICP, no wallet, no exchange account — which
is the whole point: it exists to get a developer from "I have a card" to "my
canister has cycles" without first solving crypto onboarding.

It runs entirely on the Internet Computer: a single verifiable Motoko backend
canister plus an asset canister serving the frontend. The **Card** rail creates a
Stripe Checkout Session per order through the API (#33) and **sells cycles from a
reserve it already holds** — the canister's own cycles-ledger account — rather
than minting them per payment (#30). Purchases are Internet-Identity-authenticated,
one-shot, and delivered by one `icrc1_transfer` to the buyer's cycles-ledger
account.

The operator funds that reserve with `icp cycles transfer`. **The canister never
holds ICP**: no float, no mint path, no burn cap.

**Pricing is derived on-chain and reproducible by anyone.** Two rates, both read
from canisters — USD/ICP from the Exchange Rate Canister, XDR/ICP from the CMC —
so **no outbound HTTPS is involved in pricing**. The canister does make HTTPS
outcalls, to Stripe only: creating a Checkout Session, expiring one, and the
recovery sweep retrieving one.

The buyer sees the cycle quantity **before** committing (`quote_previews`, a
public query running the same code that locks the price), the quoted figure is
**pinned server-side** at creation so an order can never lock less than they were
shown, and afterwards `receipt(orderId)` hands them both rate inputs so they can
recompute the price themselves rather than take our word for it.

The design bar is "production money-handler from day one": full idempotency,
write-intent-before-call replay safety, obligations that live on the order and never drop an
unresolved obligation and carries a defined money position for every failure, and
a reproducible build so anyone can verify the deployed module hash against a
tagged commit.

Key documents:

| Document | What it is |
|----------|------------|
| `docs/agents/deleted-vocabulary.md` | The sweep list: a deleted mechanism's vocabulary, with each term's adjudicated disposition |
| `docs/DESIGN.md` | The decision record — *why* it is built this way. What the `§N` comments point at. Gate-enforced |
| `docs/STRIPE.md` | **Start here.** The Card rail end to end, written from the code: ingress, session creation, signature verification, attribution, dedup, pricing, the order lifecycle, refunds, the two secrets, and the local Stripe-sandbox loop |
| `docs/TEST-COVERAGE.md` | What is tested, how, and what is not — one place to answer "is X covered?" |
| `docs/SANDBOX-TESTPLAN.md` | The manual Stripe-sandbox verification pass required before go-live, and an explicit statement of what a green run does not prove |
| `RUNBOOK.md` | Operations, authoritative for procedure: go-live checklist, secret rotation, rate diagnosis, reserve funding and sizing, error-queue triage, monitoring plan |
| `RELEASE.md` | Reproducible build and module-hash verification procedure |
| `AGENTS.md` | Agent instructions: ICP skills setup, conventions, the verification gate |

Task and progress tracking lives in **GitHub Issues** (see
`docs/agents/issue-tracker.md`).

## Prerequisites

- Node.js ≥ 22
- `mops` — `npm i -g ic-mops` (the Motoko compiler version is pinned in
  `mops.toml [toolchain]`; mops resolves it automatically)
- `icp` CLI — `npm i -g @icp-sdk/icp-cli @icp-sdk/ic-wasm`

This project uses **`icp-cli`, never `dfx`**. Project configuration lives in
`icp.yaml`; Motoko dependencies in `mops.toml` / `mops.lock`.

⚠️ **Clone with submodules.** The backend decrypts its sealed secrets (#11) using a
BLS12-381 implementation pinned as a git submodule, resolved by `mops` as a path
dependency — so without it nothing compiles:

```sh
git clone --recurse-submodules https://github.com/marc0olo/cyclepay
# already cloned:
git submodule update --init --recursive
```

That code is **experimental and unaudited**; `docs/DESIGN.md` §7.3 explains what it is
trusted with, what it is not, and the deletion criterion.

## Local development

### Run the app locally, from nothing

Six steps, in this order. Steps 1–4 need nothing from Stripe; 5–6 are for clicking
through a real payment.

```sh
# 1. dependencies and a local replica
git submodule update --init --recursive   # the pinned crypto (#11), first time only
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
#     The arithmetic and the ceiling that scales with minPurchaseUsdCents:
#     docs/STRIPE.md, "9a. Simulation mode". That section is framed for mainnet
#     against the Stripe sandbox; the arithmetic is identical locally.

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
refuses with `unboundedGiveaway` — the #99 faucet guard, not a misconfiguration. The
seed prints the exact command and does not treat it as a failure.

⚠️ **Step 5 needs a restricted key** (`rk_...`) with **Checkout Sessions = Write** and
everything else None. Write is the level that also grants the read the recovery sweep
needs (#52). No Payment Links exist to configure: the canister creates a Checkout
Session per order through the API and sets `client_reference_id` on it (#33).

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
| "No amounts are configured yet" | No presets registered. Since #33 that is **not** a paused rail — a custom amount still works; the seed registers the tiles |
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
prerequisite; see issue #32.

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

## Testing the Stripe rail locally

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

## Tests

```sh
scripts/test-all.sh          # the whole gate, fail-fast
scripts/test-all.sh --fast   # skip PocketIC (needs a 4 KiB-page host)
```

See `docs/TEST-COVERAGE.md` for what each suite covers and what is not covered.
There are four suites:

**1. Motoko unit tests** (`test/*.test.mo`) — one suite per module, pure-logic
(state machine, idempotency, HMAC/Stripe signatures, HTTP routing, pricing, the
admission gate, the delivery decision, the reserve floor, …):

```sh
mops test
```

**2. Frontend tests** (`src/frontend`) — pure-function tests, plus jsdom tests
driving `main.ts` against the real `index.html`:

```sh
npm --prefix src/frontend run test        # vitest unit tests
npm --prefix src/frontend run typecheck
```

**3. Browser specs** (`test/browser`) — Playwright against the built page, for what
jsdom structurally cannot see: cascade, layout and reachability. `hidden` defeated by
CSS is invisible to a DOM test and visible here.

```sh
npm --prefix test/browser ci                             # first run only
npx --prefix test/browser playwright install chromium    # first run only
npm --prefix test/browser test
```

**4. PocketIC integration suite** (`test/integration`) — the **go-live bar**
(spec §9): end-to-end scenarios against the real ICP ledger, CMC, cycles
ledger Wasms, plus the released XRC mock at the mainnet XRC
id — HMAC-signed Stripe webhooks (over a real HTTP gateway in scenario 55), time
control, outage injection against the real NNS canisters, and upgrade-mid-flight
replay checks:

```sh
cd test/integration
npm ci
npm test        # pretest fetches the sha256-pinned wasms + builds the backend
                # never `npx vitest run` — it skips pretest and tests a stale wasm
```

Requirements: Node ≥ 20.11, `mops` on PATH, and a **4 KiB-page kernel** —
macOS or x86_64 Linux are fine, but the replica cannot run inside arm64 Linux
VMs with 16 KiB pages (e.g. Apple-Silicon Docker guests). See
`test/integration/README.md` for the full scenario map and the ready-made CI
job.

## Release

Releases are built in a Docker-pinned toolchain, from `git archive <ref>` so only
the committed tree can shape the output:

```sh
scripts/reproducible-build.sh <git-ref>
```

⚠️ **The verify half is a procedure, not a past result.** Nothing is deployed to
mainnet, so no on-chain module hash exists to diff against yet — `RELEASE.md` has the
publish/verify steps, and the first real execution happens at go-live (#40).

Pinned: the base image by digest, `ic-mops`/`icp-cli`/`ic-wasm` by exact version, `moc`
via `mops.toml [toolchain]`, Motoko deps via `mops.lock`, recipes by tag in `icp.yaml`, and
the crypto submodule by the commit **the ref itself records** — read with `git ls-tree`, so
a local checkout at a different commit cannot change the output. ⚠️ `git archive` omits
submodules, so `reproducible-build.sh` assembles the build context explicitly rather than
piping the archive straight to Docker; without that the container fails on an empty path
dependency.
Not pinned: the two `apt` packages (not byte-shaping) and the npm tools' transitive
dependencies — so identical bytes are expected from the same ref on the same day, and
are not guaranteed across a registry change.
