# CyclePay — Fully On-Chain Cycles Gateway

**Buy cycles with a credit card.** No ICP, no wallet, no exchange account — which
is the whole point: it exists to get a developer from "I have a card" to "my
canister has cycles" without first solving crypto onboarding.

It runs entirely on the Internet Computer: a single verifiable Motoko backend
canister plus an asset canister serving the frontend. The **Card** rail (Stripe
webhook, inbound only — there is no Stripe API key anywhere in the system) mints
through the Cycles Minting Canister from an operator ICP float. Purchases are
Internet-Identity-authenticated, one-shot, and delivered either to a canister
(`notify_top_up`) or a cycles-ledger account (`notify_mint_cycles`).

**Pricing is derived on-chain and reproducible by anyone.** Two rates, both read
from canisters — USD/ICP from the Exchange Rate Canister, XDR/ICP from the CMC —
so the canister makes no outbound HTTPS at all.

The buyer sees the cycle quantity **before** committing (`quote_previews`, a
public query running the same code that locks the price), the quoted figure is
**pinned server-side** at creation so an order can never lock less than they were
shown, and afterwards `receipt(orderId)` hands them both rate inputs so they can
recompute the price themselves rather than take our word for it.

The design bar is "production money-handler from day one": full idempotency,
write-intent-before-call replay safety, an error queue that never drops an
unresolved obligation and carries a defined money position for every failure, and
a reproducible build so anyone can verify the deployed module hash against a
tagged commit.

Key documents:

| Document | What it is |
|----------|------------|
| `design-docs/ONCHAIN_GATEWAY_SPEC.md` | The decision record — *why* it is built this way. Non-binding rationale; the implementation wins where they disagree |
| `docs/STRIPE.md` | **Start here.** The Card rail end to end, written from the code: ingress, signature verification, attribution, dedup, pricing, retention, refunds, the secret, and the local Stripe-sandbox loop |
| `docs/TEST-COVERAGE.md` | What is tested, how, and what is not — one place to answer "is X covered?" |
| `docs/SANDBOX-TESTPLAN.md` | The manual Stripe-sandbox verification pass required before go-live, and an explicit statement of what a green run does not prove |
| `RUNBOOK.md` | Operations, authoritative for procedure: go-live checklist, secret rotation, rate diagnosis, treasury levers, error-queue triage, monitoring plan |
| `RELEASE.md` | Reproducible build and module-hash verification procedure |
| `AGENTS.md` | Agent instructions: ICP skills setup, conventions, the verification gate |

Task and progress tracking lives in **GitHub Issues** (see
`docs/agents/issue-tracker.md`). `PRD.md` and `progress.txt` are frozen
historical artifacts and are not updated.

## Prerequisites

- Node.js ≥ 22
- `mops` — `npm i -g ic-mops` (the Motoko compiler version is pinned in
  `mops.toml [toolchain]`; mops resolves it automatically)
- `icp` CLI — `npm i -g @icp-sdk/icp-cli @icp-sdk/ic-wasm`

This project uses **`icp-cli`, never `dfx`**. Project configuration lives in
`icp.yaml`; Motoko dependencies in `mops.toml` / `mops.lock`.

## Local development

### Run the app locally, from nothing

```sh
mops install                              # Motoko dependencies (pinned by mops.lock)
icp network start -d                      # local replica (PocketIC), gateway on :8000
icp deploy                                # backend, frontend, and the local XRC mock
scripts/local-dev-seed.sh                 # make the gateway actually sellable
```

Then open **<http://frontend.local.localhost:8000/>**.

**The seed step is not optional.** A freshly deployed gateway is fail-closed on
five axes at once, and the result looks like a broken app rather than a safe one:

| What you see | Why |
|---|---|
| "No amounts are configured yet" | The tier list *is* the card rail's on/off switch (RUNBOOK §3) |
| "No exchange rate available yet" | Pricing needs the CMC rate, which only NNS governance can set |
| "temporarily unavailable while the gateway is topped up" | `minCanisterCycles` defaults to 5 T and `icp deploy` creates the canister with less, so the gate refuses every purchase. This one is about the canister's own **gas**, not the treasury; the seed script fixes it with `icp canister top-up backend --amount 20t`, which is what you would do on mainnet, rather than by lowering the floor |
| Orders never mint | Burn cap defaults to 0 (the §5.3 pause lever) and there is no ICP float |

`scripts/local-dev-seed.sh` sets all five and verifies a $5 purchase is admitted
before reporting success. It reaches the CMC through the local network's PocketIC
control API — see `docs/SANDBOX-TESTPLAN.md` for why that is possible and why
nothing in CI depends on it.

The CMC step is verified from a stopped network through to a priced $5 quote. If
it ever reports that the CMC did not take the rate, that check is real: the script
queries the CMC and compares what it actually stored rather than trusting the `Ok`
reply, because PocketIC returning 200 only means the message was delivered.

To click all the way through payment you also need real Stripe Payment Links. Put
them in **`scripts/.local-dev.env`** once (gitignored) and every later run picks them
up:

```sh
cat > scripts/.local-dev.env <<'LINKS'
STRIPE_LINK_T5=https://buy.stripe.com/test_xxx
STRIPE_LINK_T20=https://buy.stripe.com/test_yyy
STRIPE_LINK_T50=https://buy.stripe.com/test_zzz
LINKS
scripts/local-dev-seed.sh
```

Precedence is environment → that file → **the link already registered on the
canister** → a placeholder naming the variable. The third rule is what makes
re-seeding safe: a re-run cannot overwrite working links with placeholders. See
RUNBOOK §3 for how each link must be configured — the settings matter more than the
URL.

Without them the tiers carry a placeholder URL and "Pay with card" lands on a
Stripe `AccessDenied` page. Everything up to that point works.

Then wire the webhook, in its own terminal:

```sh
scripts/stripe-dev.sh                     # asserts the gateway can price, then forwards
```

The two scripts own different levers and the order matters: `local-dev-seed.sh` owns
the money (tiers, treasury, float, the CMC rate, the canister's own cycles) and
`stripe-dev.sh` owns Stripe (expected livemode, the forwarding session's signing
secret, a dev-short order TTL). Run the seed first.

**For the full buy → pay → deliver → link the CLI → see the cycles walkthrough,
including the local Internet Identity step and how to prove the cycles arrived, see
`docs/SANDBOX-TESTPLAN.md` → "The whole flow, in order, in a browser".** That is the
one procedure; the rest of that file is scenarios and reference.

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

Reinstalling wipes local orders, the audit log and the mint journal. That is
expected: re-seed, and restart a manual run from the top.

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
There are three suites:

**1. Motoko unit tests** (`test/*.test.mo`) — one suite per module, pure-logic
(state machine, idempotency, HMAC/Stripe signatures, HTTP routing, pricing,
treasury caps, …):

```sh
mops test
```

**2. Frontend tests** (`src/frontend`) — pure-function tests, plus jsdom tests
driving `main.ts` against the real `index.html`:

```sh
npm --prefix src/frontend run test        # vitest unit tests
npm --prefix src/frontend run typecheck
```

**3. PocketIC integration suite** (`test/integration`) — the **go-live bar**
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

Releases are built reproducibly in a Docker-pinned toolchain and verified
against the on-chain module hash:

```sh
scripts/reproducible-build.sh <git-ref>
```

See `RELEASE.md` for the full publish/verify procedure.
