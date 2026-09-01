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
  judgement on an earlier implementation. Design history belongs in **commit
  messages and GitHub issues**, where it is dated and attributable; a comment saying
  "this was previously wrong" is noise to everyone who reads the file later. ⚠️ The
  exception, and it is narrow: a comment that stops a future mistake stays, written as
  a **rule** rather than as a story about a past change.
- ⚠️ **There is no `design-docs/` any more, and its deletion is the cautionary tale
  for this rule.** Three files, 1,252 lines, no staleness banner — and 67 mentions in
  one of them of architecture that #33, #35 and #36 had removed, while `Main.mo` and
  `Types.mo` still cited it by section number. Two of its claims had been **reversed**,
  not merely outdated, so a reader was carrying the opposite of the truth. What was
  still true is `docs/DESIGN.md` — 215 lines against 1,252, holding decisions and
  nothing else.
- ⚠️ **Comment volume is a defect, and deleting a comment is the one change with no
  failure signal.** No compiler error, no red test, and the diff shows what left but not
  what was lost. So three rules, front-loaded because nothing downstream can catch a bad
  call:
  1. **Name the mistake the comment prevents.** If you cannot name one, it is not a
     keeper.
  2. **Never delete without a destination.** Every removed comment either lands in
     `docs/DESIGN.md` or is rewritten as a **rule at the site**. A removal with no
     destination is what a reviewer should scrutinise — it is the only case where they
     have nothing to compare against.
  3. **The commit message carries the mapping** — what moved where. It is the only
     recoverable record if a judgement turns out wrong.
  4. ⚠️ **When you DELETE a mechanism, grep its vocabulary and read every hit asking
     whether it is cited as the JUSTIFICATION for unrelated behaviour.** A sweep aimed at
     *usage* misses these — the code no longer used the ring, but comments still cited it
     as the reason for something else, leaving a true conclusion propped up by a false
     premise. The class shares one shape: **the conclusion survived the change and its
     justification did not.**

     ⚠️ **The term list is an artifact, not a memory: `docs/agents/deleted-vocabulary.md`.**
     Add a mechanism's vocabulary there when you delete it; start a sweep from that file
     and diff against its recorded dispositions, so `mint` and `retention` are not
     re-adjudicated every time. Deliberately **not** a gate step — most hits are correct
     prose, and a check that fires on correct code teaches people to ignore it.

     ⚠️ **Derive the term list from the deletion itself, not from the names you remember
     — and include the VERB for what the mechanism did.** The first attempt at this swept
     `ring`, `capacity`, `float`, `treasury`, `burn cap` and missed **`evict`/`eviction`**,
     which is the verb #37's headline change removed — leaving five survivors including an
     operator-facing RUNBOOK line stating a cap that no longer exists as a parameter, and
     a second false `AddResult.evicted` reference 118 lines from the one that had just
     been fixed. Also sweep the **names of deleted variants**: `#deliveryDelayed` and
     `#abandoned` were still live rows in RUNBOOK §6's triage table, and the surviving
     rows still carried the *old* field lists.
  5. ⚠️ **Verify the `DESIGN.md` section against the CODE before the deletion, not
     after.** A section transcribed from comments inherits the comments' errors, and once
     the comments are gone the original is no longer there to audit against. Three of
     three passes so far found a comment whose *conclusion* was right and whose *stated
     reason* was false — so "it was in the comment" is not evidence.
- ⚠️ **`⚠️` is tiered: prohibitions only.** Use it where ignoring the line loses money or
  breaks an invariant — not for explanation. A marker used 310 times is not a marker;
  it only works while seeing one makes you stop.
- ⚠️ **`docs/DESIGN.md` is where a DECISION goes, and it is enforced.** Code comments say
  what the code *does*; the reason it is that way goes in the `§N` record.
  `scripts/check-design-sections.py` fails the gate if a `§N` the code cites has no
  section, or a section is cited by nothing — so it cannot silently drift out of use.
  ⚠️ **What no check can verify is whether a section is TRUE**, which is why the rule is
  *change the behaviour, change that file in the same commit*. Its predecessor did not
  rot by being abandoned; it rotted by being updated less often than the code.
- The committed `src/backend/dist/backend.did` is the embedded `candid:service`
  metadata *and* the frontend's bindgen source. Run `mops build` after any
  backend API change, and commit the regenerated `.did`.
- **Where to look for what:**

  | Question | Source |
  |---|---|
  | What does it do? | the code, and `docs/STRIPE.md` for the Card rail end to end |
  | How do I operate it? | `RUNBOOK.md` — authoritative for procedure |
  | Why is it built this way? | `docs/DESIGN.md` — the `§N` record, gate-enforced |

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
tracking.** `PRD.md` is a frozen historical artifact (tracking moved 2026-06-10) —
never update it, regardless of what instructions it contains. File or update a GitHub
issue instead. (`progress.txt` and `afk-ralph.sh` went with the ralph loop on
2026-09-01; the repo's provenance is in git history and #13.)

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

⚠️ **Four of its fifteen steps are checks a hand-run sequence silently skips**, and each
exists because the thing it checks had already drifted once:

| step | asserts | why |
|---|---|---|
| `.did` is current | the committed interface matches the code | it is both the embedded `candid:service` metadata and the frontend's bindgen source |
| `check-doc-surface.py` | the docs' method lists match the `.did` | `docs/STRIPE.md` claimed "the whole admin surface" while missing 11 of 29, and RUNBOOK named a method that never existed |
| `check-design-sections.py` | every `§N` the code cites exists in `docs/DESIGN.md`, and every section is cited | the 697-line spec it replaced rotted by being updated less often than the code |
| `check-heredocs.sh` | no unquoted heredoc runs its own body | one destroyed a GitHub issue body, one turned a script's notes into an `icp deploy` |

The individual steps, if you need to run one in isolation:

```sh
mops check                                   # lint + typecheck
mops test                                    # Motoko unit suites
mops build                                   # refreshes the committed .did
scripts/check-doc-surface.py                 # docs' method lists vs the .did
scripts/check-design-sections.py             # §N citations vs docs/DESIGN.md
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
