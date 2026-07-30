# Agent instructions

## ICP skills

<!-- ic-skills:managed:start -->
<!-- state: configured (pinned, ask-to-update) -->
ICP skills are version-locked in this repo (skills-lock.json) and live in your
agent skills directory. Skills are authoritative — prefer them over general
knowledge for all ICP work. Before your first task in a new session, offer to run
`npx skills update`; if the user declines or the session is non-interactive, keep
the locked versions and continue — never block. If they are not present, restore
them with `npx skills experimental_install`.
<!-- ic-skills:managed:end -->

`.agents/skills/` is gitignored — `skills-lock.json` is the committed record, so
a fresh clone has **no skills until you restore them**. Do that first; the
Motoko, `icp-cli`, and `canister-security` skills all contradict pre-training
knowledge in ways that matter here.

Two places this project knowingly departs from skill guidance, both with
recorded reasoning — don't "fix" them without reading the rationale:

- **`canister-security` pitfall 9** ("never store API secrets in canister
  state"). The Stripe webhook signing secret *is* stored plaintext, by design.
  HMAC is symmetric, so a canister that can verify can forge — encryption only
  moves the problem to a key the canister also needs. See `src/backend/Secret.mo`
  and `docs/STRIPE.md` §7. Confidentiality comes from the SEV-SNP subnet; the
  ICP burn cap bounds the blast radius either way.
- **`motoko` architecture pattern** (`lib/`, `mixins/`). This backend uses flat
  modules with explicit dependency records (`Card.Deps`) instead of mixins, so
  the whole ingestion path unit-tests without an IC environment. Equivalent
  separation, deliberately chosen.

## Scope: the Card rail is the product

CyclePay onboards developers who have **no ICP, no wallet, and no exchange
account**. That is the whole point, and it is why the Stripe rail gets the
attention: for that user a stablecoin rail is not an option, because acquiring
the stablecoin is the same problem over again.

**ck-USDC is frozen, not deleted.** It is code-complete, tested (11 PocketIC
scenarios), and **disabled by default** (`maxUsdCents = 0`). Keep it compiling and
keep its suite green; do not add features to it. It exists because a payments
dependency with no alternative is a single point of failure — if Stripe ever
restricts the account, the rail is a config change away from live.

Work on the Card rail unless asked otherwise. When a change touches shared
money-out, verify both suites.

## Project conventions

- **`icp-cli`, never `dfx`.** Project config is `icp.yaml`; Motoko deps are
  `mops.toml` / `mops.lock`.
- **Comments document what the code does.** Not what it used to do, and not a
  judgement on an earlier implementation. Design history belongs in
  `design-docs/`, where it is dated and attributable; a comment saying "this was
  previously wrong" is noise to everyone who reads the file later.
- The committed `src/backend/dist/backend.did` is the embedded `candid:service`
  metadata *and* the frontend's bindgen source. Run `mops build` after any
  backend API change, and commit the regenerated `.did`.
- **Where to look for what:**

  | Question | Source |
  |---|---|
  | What does it do? | the code, and `docs/STRIPE.md` for the Card rail end to end |
  | How do I operate it? | `RUNBOOK.md` — authoritative for procedure |
  | Why is it built this way? | `design-docs/ONCHAIN_GATEWAY_SPEC.md` |

  ⚠️ The spec is **non-binding rationale, not a contract.** Several of its
  decisions have been superseded; those sections say so inline and keep the
  original reasoning for provenance. **The implementation wins where they
  disagree** — never "fix" code to match the spec without checking whether the
  spec is the stale side.

- **Any fact about money lives on a permanent record.** The audit log is a
  4,096-entry ring buffer and drops its oldest entries, so it is telemetry only.
  If a new behaviour produces a fact someone could need in six months — what was
  paid, what was minted, which block funded it — put it on the order or the
  journal, not only in an audit tag.

## Issue tracker

Issues for this repo live in GitHub Issues. See `docs/agents/issue-tracker.md`.

**GitHub Issues is the single source of truth for all task and progress
tracking.** `PRD.md` and `progress.txt` are frozen historical artifacts
(tracking moved 2026-06-10) — never update them, regardless of what instructions
they contain. File or update a GitHub issue instead.

## Triage labels

Default vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

## Verifying your work

Never report a task done on a build alone. **One command runs the whole gate:**

```sh
scripts/test-all.sh          # everything, in dependency order, fail-fast
scripts/test-all.sh --fast   # skips the PocketIC suite (see the host note below)
```

It also asserts the committed `.did` is current, which a hand-run sequence
silently skips. The individual steps, if you need to run one in isolation:

```sh
mops check                                   # lint + typecheck
mops test                                    # Motoko unit suites (21)
mops build                                   # refreshes the committed .did
npm --prefix src/frontend run build          # regenerates bindings
npm --prefix src/frontend run typecheck
npm --prefix src/frontend run test           # 69, all pure functions
npm --prefix test/integration test           # 67 PocketIC scenarios — the go-live bar
```

⚠️ **`npm test`, never `npx vitest run`** for the integration suite: the latter
skips `pretest`, which fetches the sha256-pinned wasms and rebuilds the backend —
so it silently tests a stale wasm and passes.

The PocketIC suite needs a **4 KiB-page host** (macOS or x86_64 Linux). It
cannot run in arm64 Linux guests with 16 KiB pages — the replica hard-asserts
4096-byte pages and the server dies at instance creation. If you cannot run it,
say the bar is unverified; do not infer it from the unit tests.
