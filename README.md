# CyclePay — Fully On-Chain Cycles Gateway

**Buy cycles with a credit card.** No ICP, no wallet, no exchange account — which is the
whole point: it gets a developer from "I have a card" to "my canister has cycles" without
first solving crypto onboarding.

It runs entirely on the Internet Computer — one Motoko backend canister and one
certified-assets frontend canister, **no server**. It sells cycles from a reserve it
already holds, prices them from two on-chain rates with **no outbound HTTPS in the pricing
path**, and shows the buyer the cycle quantity before they commit.

Everything money-touching **fails closed**: a freshly deployed gateway accepts no orders
and delivers nothing until each lever is consciously set.

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

## How it works, and how to run it

**[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) has the diagram** — the money path end to end, where the trust
boundaries sit, and which of the two cycle pots a delivery spends from. Start there.

| you want to | go to |
|---|---|
| understand the system | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), then [`docs/DESIGN.md`](docs/DESIGN.md) for *why* |
| run it locally | [`docs/OPERATE.md`](docs/OPERATE.md) — Mode 1 |
| deploy it | [`docs/OPERATE.md`](docs/OPERATE.md) — Mode 2 (mainnet simulation) or Mode 3 (production) |
| operate one that is misbehaving | [`RUNBOOK.md`](RUNBOOK.md) — entered by symptom |
| check the claims yourself | [`docs/VERIFY.md`](docs/VERIFY.md) |

```sh
git clone --recurse-submodules https://github.com/marc0olo/cyclepay
icp network start -d && icp deploy && scripts/local-dev-seed.sh
```

⚠️ **The submodule and the seed are both load-bearing**, and neither failure looks like
its cause — [`docs/OPERATE.md`](docs/OPERATE.md) explains both before the first command.

## Verify it yourself

[`docs/VERIFY.md`](docs/VERIFY.md) is the list: what a stranger can check with no
identity, what only a buyer can, and the limits stated in the same breath.

⚠️ **One limit worth stating here:** the live module hash has no published provenance.
`scripts/release.sh` builds in a pinned container, installs that artifact and gates on the
canister reporting the same hash — this deployment was not cut that way.
[`docs/VERIFY.md`](docs/VERIFY.md) has the detail.

## Documents

For a **reader or verifier**:

| | |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | The diagram: canisters, money path, trust boundaries, the two cycle pots |
| [`docs/DESIGN.md`](docs/DESIGN.md) | The decision record — *why* it is built this way. What the `§N` comments point at. Gate-enforced |
| [`docs/STRIPE.md`](docs/STRIPE.md) | The Card rail end to end, written from the code: ingress, signature verification, attribution, dedup, pricing, the order lifecycle, refunds |
| [`docs/TEST-COVERAGE.md`](docs/TEST-COVERAGE.md) | What is tested, how, and what is not |
| [`docs/VERIFY.md`](docs/VERIFY.md) | What anyone can check about the live deployment, what they cannot, and the measured state of the module-hash chain |

For an **operator**:

| | |
|---|---|
| [`docs/OPERATE.md`](docs/OPERATE.md) | Setup, one procedure per mode: local, mainnet simulation, mainnet production |
| [`RUNBOOK.md`](RUNBOOK.md) | Day-2 operations, entered by symptom: secret rotation, rate diagnosis, reserve sizing, obligation triage, monitoring |
| [`RELEASE.md`](RELEASE.md) | Reproducible build and module-hash verification procedure |
| [`docs/SANDBOX-TESTPLAN.md`](docs/SANDBOX-TESTPLAN.md) | The manual Stripe-sandbox pass required before go-live, and what a green run does not prove |

For an **agent changing the code**: [`AGENTS.md`](AGENTS.md) (conventions, skills, the verification
gate), and [`docs/DESIGN.md`](docs/DESIGN.md) above — it is the primary surface for that audience, along
with the invariant comments in `src/backend`. `docs/agents/` holds the loop's own
conventions: the triage labels, the issue-tracker rules and `deleted-vocabulary.md`.

Also: [`docs/DEMO-PLAYBOOK.md`](docs/DEMO-PLAYBOOK.md), the running order for demoing this to a technical
audience.

## Release

Releases are built in a Docker-pinned toolchain, from `git archive <ref>` so only
the committed tree can shape the output:

```sh
scripts/reproducible-build.sh <git-ref>
```

⚠️ **The verify half is a procedure, and the live deployment did not go through it** —
untagged, no published hash, step 5 never run. Worse, measured: the pinned container
produces **different bytes** for the deployed commit than the host that deployed it, so
the live wasm is not third-party reproducible. [`docs/VERIFY.md`](docs/VERIFY.md) carries
the hashes, the cause and the consequence for the procedure.

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
