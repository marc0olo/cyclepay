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
write-intent-before-call replay safety, obligations that live on the order so an
unresolved one is never dropped, a defined money position for every failure, and
a reproducible build, so that a deployed module hash **can** be verified against a
tagged commit. ⚠️ That last one is a property of the build system and not yet of any
deployment — see **Release** below for where that stands.

## It is running

**<https://cyclepay.raymondk.co>** — or <https://shy4u-4qaaa-aaaay-aadhq-cai.icp.net>,
which is the same app on the canister's own gateway origin. Internet Identity derives
principals from the **frontend canister id**, so both addresses give you the same
account and the same cycles.

⚠️ **Simulation mode, and you cannot buy on it.** Cards are charged in Stripe's
sandbox, and cycles are divided by `pricing_status().config.divisor` — so a purchase
quotes *and* delivers that fraction of what a live gateway would for the same charge.
Read the divisor rather than trusting a number written here.

Purchases also require the buyer's principal to be **allow-listed by a controller**:
without that, free sandbox payments against a funded reserve would be a faucet, so an
unlisted principal is refused with `buyerNotAllowed`.

What anyone can do on it, with no identity at all: browse, read a **live quote** for any
amount, and check every operational number the gateway publishes.

```bash
icp canister call backend quote_previews '(vec { 1_000 : nat })' -e ic  # $10, with both rate inputs
icp canister call backend reserve_status  '()' -e ic
icp canister call backend pricing_status  '()' -e ic
icp canister call backend lifecycle_config '()' -e ic
icp canister call backend card_tiers      '()' -e ic
```

Canister ids are in `.icp/data/mappings/ic.ids.json`; the backend is
`saz2a-riaaa-aaaay-aadha-cai`.

This repository began as a fork of [`raymondk/cyclepay`](https://github.com/raymondk/cyclepay),
which explored the design with an agent loop; it is the source of truth now, and the
architecture it ships is not the one the fork point described.

Key documents:

| Document | What it is |
|----------|------------|
| `docs/OPERATE.md` | Setup, per mode: local, mainnet simulation, mainnet production — one complete procedure each, plus the local troubleshooting table |
| `docs/DESIGN.md` | The decision record — *why* it is built this way. What the `§N` comments point at. Gate-enforced |
| `docs/STRIPE.md` | The Card rail end to end, written from the code: ingress, session creation, signature verification, attribution, dedup, pricing, the order lifecycle, refunds, the two secrets, and the local Stripe-sandbox loop |
| `docs/TEST-COVERAGE.md` | What is tested, how, and what is not — one place to answer "is X covered?" |
| `docs/SANDBOX-TESTPLAN.md` | The manual Stripe-sandbox verification pass required before go-live, and an explicit statement of what a green run does not prove |
| `docs/DEMO-PLAYBOOK.md` | The running order for demoing this to a technical audience: what to show, why each step is interesting, and the three "looks wrong and isn't" answers. Names no live figures — every number is a query read on camera |
| `RUNBOOK.md` | Day-2 operations, entered by symptom: secret rotation, rate diagnosis, reserve funding and sizing, obligation triage, the monitoring plan. First-time setup is `docs/OPERATE.md` |
| `RELEASE.md` | Reproducible build and module-hash verification procedure |
| `AGENTS.md` | Agent instructions: ICP skills setup, conventions, the verification gate |

**The go-live prerequisites are no longer tracked as issues.** The build is done, and
what has to happen before real money is `RUNBOOK.md` section 1.1 — ahead of the
deployment commands, each item naming the closed issue that holds its reasoning. The
tracker carries current work, not the plan; closed issues are the archive. `docs/agents/` holds the conventions an agent needs,
including `deleted-vocabulary.md` and `issue-tracker.md`.

## Running it, and deploying it

`docs/OPERATE.md` is the setup half: the three modes this runs in — **local**, **mainnet
simulation**, **mainnet production** — one complete procedure each, plus the
prerequisites and the local troubleshooting table. `RUNBOOK.md` is the other half, for
when something is already running and misbehaving.

```sh
git clone --recurse-submodules https://github.com/marc0olo/cyclepay
icp network start -d && icp deploy && scripts/local-dev-seed.sh
```

⚠️ **The submodule and the seed are both load-bearing**, and neither failure looks like
its cause — `docs/OPERATE.md` explains both before the first command.

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

⚠️ **The verify half is a procedure, not a past result — and the live deployment did
not go through it.** The gateway on mainnet was deployed with a plain `icp deploy`:
nothing was tagged, no `MODULE-HASHES.txt` was published, and `RELEASE.md`'s step 5 —
the gate that compares the deployed hash against the published one — has never run.
So whether the live bytes reproduce from their own commit is **unknown**, not
known-negative: a deploy from a clean checkout of a tag is expected to match, and that
premise has simply never been tested here.

The on-chain hash is deliberately **not** published in this repo as a verifiable
artifact. A number with no independently reproducible counterpart looks like
verification without being one. Read it yourself with
`icp canister status backend -e ic` if you want it.

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
