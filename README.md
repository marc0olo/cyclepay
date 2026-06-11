# CyclePay — Fully On-Chain Cycles Gateway

A "buy cycles with fiat or stablecoins" service that runs entirely on the
Internet Computer: a single verifiable Motoko backend canister plus an asset
canister serving the frontend. Two payment rails — **Card** (Stripe webhook,
inbound only, no `sk_live` ever leaves the user's browser flow) and
**ck-USDC** (ICRC-2 approve → pull) — converge on a unified mint through the
Cycles Minting Canister from an operator ICP float. Purchases are
Internet-Identity-authenticated, one-shot, and delivered either to a canister
(`notify_top_up`) or a cycles-ledger account (`notify_mint_cycles`).

The design bar is "production money-handler from day one": full idempotency,
write-intent-before-call replay safety, a bounded error queue with defined
money positions for every failure, and a reproducible build so anyone can
verify the deployed module hash against a tagged commit.

Key documents:

| Document | What it is |
|----------|------------|
| `design-docs/ONCHAIN_GATEWAY_SPEC.md` | The decision record (spec v2.1) — canonical source for all design decisions |
| [GitHub Issues](https://github.com/raymondk/cyclepay/issues) | Task and progress tracking (source of truth; `PRD.md` and `progress.txt` are frozen historical artifacts) |
| `RUNBOOK.md` | Operations: go-live checklist, secret rotation, error-queue triage |
| `RELEASE.md` | Reproducible build and module-hash verification procedure |

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

## Tests

There are three suites:

**1. Motoko unit tests** (`test/*.test.mo`) — pure-logic coverage per module
(state machine, idempotency, HMAC/Stripe signatures, HTTP routing, forex,
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
(spec §9): end-to-end scenarios against the real ICP ledger, CMC, cycles
ledger, and ck-USDC ledger Wasms, with crafted HMAC-signed Stripe webhooks,
mocked forex outcalls, time control, and upgrade-mid-flight replay checks:

```sh
cd test/integration
npm ci
npm test        # pretest fetches the sha256-pinned ledger wasm + builds the backend
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
