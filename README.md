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

A second rail, **ck-USDC** (ICRC-2 approve → pull), is implemented and tested but
**ships disabled**. It shares the same money-out path and exists as a fallback if
the card processor ever becomes unavailable; it is not the product.

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
| `RUNBOOK.md` | Operations, authoritative for procedure: go-live checklist, secret rotation, rate diagnosis, treasury levers, error-queue triage |
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

One-time setup:

```sh
mops install                 # Motoko dependencies (pinned by mops.lock)
```

Backend iteration loop:

```sh
mops check                   # typecheck (includes unit tests)
mops build                   # compile to src/backend/dist/
mops test                    # run the Motoko unit suites
```

Running the whole app locally:

```sh
icp network start -d         # project-local replica; the OS picks a free port
icp deploy                   # build + deploy backend and frontend canisters
icp network status --json    # gateway URL (the port changes every start — never hardcode it)
icp network stop             # when done
```

The local network is configured with `gateway.port: 0` so parallel
worktrees/projects never collide — always read the URL from
`icp network status --json`.

Frontend iteration with hot reload (needs the network up and the backend
deployed, since the Vite dev server shells out to `icp` to simulate the
`ic_env` cookie the asset canister sets in production):

```sh
icp network start -d && icp deploy backend
npm --prefix src/frontend run dev
```

TypeScript bindings for the backend actor are regenerated from the committed
Candid interface (`src/backend/dist/backend.did`) by the `icpBindgen` Vite
plugin on every dev/build run — if you change the backend API, run
`mops build` to refresh the `.did`, and the frontend will pick it up (or fail
to typecheck, which is the point).

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

There are three suites:

**1. Motoko unit tests** (`test/*.test.mo`) — 21 suites of pure-logic coverage
(state machine, idempotency, HMAC/Stripe signatures, HTTP routing, pricing,
treasury caps, …):

```sh
mops test
```

**2. Frontend tests** (`src/frontend`):

```sh
npm --prefix src/frontend run test        # vitest unit tests
npm --prefix src/frontend run typecheck
```

**3. PocketIC integration suite** (`test/integration`) — the **go-live bar**
(spec §9): 33 end-to-end scenarios against the real ICP ledger, CMC, cycles
ledger, and ck-USDC ledger Wasms, plus the released XRC mock at the mainnet XRC
id, with crafted HMAC-signed Stripe webhooks, time control, and
upgrade-mid-flight replay checks:

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
