# Agent instructions

> ⚠️ **The architecture is being changed right now, and this file describes the
> code as it is — not as it will be.** Pinned issue **#12 ("Start here: the plan,
> in order")** is authoritative over this file, over `docs/`, and over `RUNBOOK.md`
> wherever they disagree. Read it before starting any work on the Card rail.
>
> Settlement is moving to a cycles reserve, payment to per-order Stripe Checkout
> Sessions, and the ICP mint path has been removed. Several
> statements below are true today and are scheduled to stop being true; each issue
> updates the ones its own change invalidates.

## ICP skills

ICP skills are tested, frequently-updated instruction files maintained by DFINITY
(<https://skills.internetcomputer.org>). Consult the relevant skill **before**
making changes — the `writing-motoko`, `icp-cli`, and `canister-security` skills all
contradict pre-training knowledge in ways that matter here.

**This repo uses [autosync](https://skills.internetcomputer.org/skills/autosync-ic-skills).**
A committed `SessionStart` hook (`.claude/settings.json` → `.claude/sync-ic-skills.sh`)
mirrors the published skills into `.claude/skills/` at the start of every session,
so they stay current with **nothing to commit** when a skill changes. The skills
directory itself is gitignored. The first time it runs, Claude Code asks you to
trust the hook.

Why this replaced the old `skills-lock.json` pin: the lock had drifted badly and
nothing surfaced it. At the moment of the switch it listed **six skills that
upstream no longer published** — four of them still sitting on disk being read as
authoritative — and was **missing four** that had since been added. One was not a
deletion but a rename: `asset-canister` → `static-site`. A pin only records what
you last ran; it cannot tell you the world moved.

<!-- ic-skills:managed:start -->
<!-- state: configured (autosync) -->
ICP skills auto-update each session via a SessionStart hook
(`.claude/sync-ic-skills.sh`) and live in your agent skills directory — you don't
need to run anything to refresh them. Skills are authoritative — prefer them over
general knowledge for all ICP work. If they are not present (hook hasn't run, or
`jq` is missing), fetch them on demand per the fallback below.
<!-- ic-skills:managed:end -->

**On-demand fallback** (any agent, no hook needed): the hook is Claude Code-only,
so Cursor, Copilot, Codex and friends should fetch the index once per session from
`https://skills.internetcomputer.org/.well-known/skills/index.json`, then fetch the
matching skill's `SKILL.md` before writing ICP code for a task.

**Layout note:** `.claude` is a committed symlink to `.agents`, so the two real
files live at `.agents/settings.json` and `.agents/sync-ic-skills.sh` and are
tracked there. Everything still resolves under the `.claude/` paths the hook and
Claude Code expect. `.agents/skills/` is gitignored.

Two places this project knowingly departs from skill guidance, both with
recorded reasoning — don't "fix" them without reading the rationale:

- **`canister-security` pitfall 9** ("never store API secrets in canister
  state"). The Stripe webhook signing secret *is* stored plaintext, by design.
  HMAC is symmetric, so a canister that can verify can forge — encryption only
  moves the problem to a key the canister also needs. See `src/backend/Secret.mo`
  and `docs/STRIPE.md` §7. Confidentiality comes from the SEV-SNP subnet, and the
  **reserve balance is the blast radius** — a forged webhook delivers from it, and
  nothing caps that, so the reserve is sized to what a leak could cost.
- **`writing-motoko` architecture pattern** (`lib/`, `mixins/`). This backend uses flat
  modules with explicit dependency records (`Card.Deps`) instead of mixins, so
  the whole ingestion path unit-tests without an IC environment. Equivalent
  separation, deliberately chosen.

## Running it locally

```sh
icp network start -d && icp deploy && scripts/local-dev-seed.sh
```

The seed step is **not optional**. A fresh deploy is fail-closed on four axes at once
(no tiers, no CMC rate, an empty and unobserved cycles reserve, and a canister funded
below the `minCanisterCycles` floor), which presents as a broken app rather than a safe
one. `scripts/local-dev-seed.sh --rate-only` after every
deploy and every ~15 minutes: the CMC rate expires, and `icp deploy` wipes the XRC
mock's install-time response. Full detail in README.md.

### Do not cycle the network

`icp network start` takes **minutes**, and **two projects cannot run local
networks at once** (the fixed `gateway.port: 8000` in `icp.yaml`).

- **Check first** with `icp network status`. If one is running, **use it** — do
  not restart it to get a clean slate.
- **Start only if absent**, and remember that you started it.
- **Never stop a network you did not start.** You cannot tell whether a human is
  mid-manual-run, or whether the network belongs to another project. Stopping one
  has already destroyed a session's worth of delivered test orders, their audit
  trail, and a local Internet Identity registration.
- **For a clean slate, reinstall — do not restart.** `icp deploy --mode reinstall
  --yes` then `scripts/local-dev-seed.sh` takes seconds and is the documented loop
  for a stable-shape change; a network restart takes minutes and throws away more
  than you wanted.
- **Leave it running when you finish**, and say so in the PR. The next piece of
  work needs it.

## Scope: the Card rail is the product

CyclePay onboards developers who have **no ICP, no wallet, and no exchange
account**. That is the whole point, and it is why the Stripe rail gets the
attention: for that user a stablecoin rail is not an option, because acquiring
the stablecoin is the same problem over again.

The card rail is the only rail. A second ck-USDC rail was kept code-complete and
disabled as a second-source hedge; that decision was reversed on 2026-08-14 and
#35 removed it, because carrying a rail we do not ship made every other change
bigger.

`Types.Rail` stays a single-case variant so a future rail is an additive change
rather than a schema-wide edit — the same reasoning as `Types.Owner`.

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
  paid, what was delivered, which block carried it — put it on the order or the
  journal, not only in an audit tag.

## Issue tracker

Issues for this repo live in GitHub Issues. See `docs/agents/issue-tracker.md`.

**GitHub Issues is the single source of truth for all task and progress
tracking.** `PRD.md` and `progress.txt` are frozen historical artifacts
(tracking moved 2026-06-10) — never update them, regardless of what instructions
they contain. File or update a GitHub issue instead.

⚠️ **Rewriting a long issue BODY goes through `scripts/issue-body.py`, not through a
shell heredoc.** #52 destroyed #12's body — Markdown built in an *unquoted* heredoc let
the shell run the backticks in the text, and a mangled 101k-char body replaced 53k. The
script does the three things that make the edit recoverable and checkable:

```bash
scripts/issue-body.py get  12 /tmp/i12.md   # fetch, verified against the API's own count
#   ...edit /tmp/i12.md...
scripts/issue-body.py put  12 /tmp/i12.md   # write, then RE-FETCH to prove it stored
scripts/issue-body.py diff 12 /tmp/i12.md   # is the remote still what this file says?
```

⚠️ **`put` verifies by reading back**, because GitHub accepting the request is not
evidence: the corrupting write was accepted cleanly. Adding a *comment* needs none of
this — `gh-axi issue comment N --body-file <path>` is additive and cannot destroy a body,
so prefer a comment whenever the content is additive.

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
mops test                                    # Motoko unit suites
mops build                                   # refreshes the committed .did
npm --prefix src/frontend run build          # regenerates bindings
npm --prefix src/frontend run typecheck
npm --prefix src/frontend run test           # pure functions + jsdom (main.ts)
bash scripts/brand-lint.sh                   # banned characters, vocabulary, tokens
npm --prefix test/browser test               # Chromium: cascade, layout, paint
npm --prefix test/integration run typecheck   # vitest does not typecheck
npm --prefix test/integration test           # PocketIC scenarios — the go-live bar
```

⚠️ **No frontend change is done on a jsdom pass alone.** jsdom has no cascade and
no layout, so `el.hidden` reads true for an element a class selector is keeping on
screen — that has shipped twice. The browser suite is not optional and the gate
now fails outright if it cannot run. Surfaces that need a session or a delivered
order are reachable through the test-only fixture hook
(`src/frontend/src/fixtures.ts`); see `test/browser/delivered.spec.ts`.

⚠️ **`npm test`, never `npx vitest run`** for the integration suite: the latter
skips `pretest`, which fetches the sha256-pinned wasms and rebuilds the backend —
so it silently tests a stale wasm and passes.

The PocketIC suite needs a **4 KiB-page host** (macOS or x86_64 Linux). It
cannot run in arm64 Linux guests with 16 KiB pages — the replica hard-asserts
4096-byte pages and the server dies at instance creation. If you cannot run it,
say the bar is unverified; do not infer it from the unit tests.
