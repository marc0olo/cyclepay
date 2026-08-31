#!/usr/bin/env bash
# The full verification gate, in dependency order, fail-fast.
#
# AGENTS.md previously listed these as six commands to run by hand, which is how
# you end up reporting a task done on a partial run. This is the single entry
# point.
#
# Usage:
#   scripts/test-all.sh              # everything
#   scripts/test-all.sh --fast       # skip the PocketIC suite (~30 s vs ~2 min)
#
# The PocketIC suite needs a 4 KiB-page host (macOS, or x86_64 Linux). It cannot
# run in arm64 Linux guests with 16 KiB pages — the replica hard-asserts 4096-byte
# pages and the server dies at instance creation. --fast exists for that case; say
# the bar is unverified rather than inferring it from the unit tests.
# ⚠️ **`-E` (errtrace) is load-bearing, not decoration.** Without it the `ERR` trap
# below is NOT inherited by shell functions — and every step runs inside `run()` — so
# the gate exited on failure with no banner at all, only the failing tool's own output
# and a nonzero status. That is how a truncated run gets misread as a pass: there was
# nothing for a reader (or a grep) to find that said the gate itself had stopped.
set -Eeuo pipefail

FAST=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    -h | --help)
      sed -n '2,17p' "$0" | sed 's|^# \{0,1\}||'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

cd "$(dirname "$0")/.."

# ⚠️ **Print the branch, because "I assumed where I was" has cost this repo twice.**
#
# Two work-in-progress commits landed on `main` in one session — the branch had been
# created before an intervening merge and never re-checked. `git branch --show-current`
# before committing is written down in #12 both times, and the second time it still was
# not run: a rule that needs remembering is a rule that gets skipped.
#
# This gate runs far more often than commits do, so putting the answer on screen turns
# "remember to check" into "you already know". Both strays were in fact caught by reading
# a number in this output — a scenario count that differed from the branch's — so the
# header is the same detector made explicit rather than incidental.
#
# Not an error when it says `main`: releasing from main is legitimate, and a gate that
# refused would be wrong. It reports; the reader decides.
# ⚠️ **Detached HEAD gets named, not printed as the word "HEAD".** `--abbrev-ref` answers
# `HEAD` when detached, which reads like a branch called HEAD and hides exactly the state
# this header exists to surface: a checkout where "which branch am I on" has no answer and
# a commit would be orphaned.
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(not a git checkout)')"
if [ "$BRANCH" = "HEAD" ]; then
  BRANCH="(detached: $(git rev-parse --short HEAD))"
fi
# One comparison against HEAD, so staged and unstaged both count and neither masks the
# other. Tracked files only: an untracked scratch file is not a reason to say "uncommitted".
DIRTY=""
git diff HEAD --quiet 2>/dev/null || DIRTY=" · uncommitted changes"
printf '\033[1mgate\033[0m on \033[1m%s\033[0m%s\n' "$BRANCH" "$DIRTY"

step=0
run() {
  step=$((step + 1))
  printf '\n\033[1m── %d. %s\033[0m\n' "$step" "$1"
  shift
  "$@"
}

# Counted from the script itself so it cannot drift from the steps it announces.
#
# ⚠️ **Counting increment SITES is wrong and was the first attempt**: `run()` has one
# site and eleven invocations, which gave 3 against a real run's 13. What has to be
# counted is invocations — every `run "…"` call at any indent, plus the two steps that
# increment inline because they are shell rather than a command. Verified against an
# actual green run's output rather than reasoned about, which is the only way a count
# like this is ever right.
TOTAL_STEPS=$((
  $(grep -cE '^[[:space:]]*run "' "$0") + $(grep -cE '^step=\$\(\(step \+ 1\)\)' "$0")
))

fail() {
  printf '\n\033[31m✗ gate FAILED at step %d of %d\033[0m\n' "$step" "$TOTAL_STEPS" >&2
  # ⚠️ **Say what did NOT run.** A fail-fast gate's output is genuinely about the step
  # that broke, and the mind supplies "…and everything else was fine". It did not run.
  # A passing step is evidence; a run that ended early is not evidence about the rest.
  if [ "$step" -lt "$TOTAL_STEPS" ]; then
    printf '\033[31m  steps %d–%d DID NOT RUN — this says nothing about them\033[0m\n' \
      $((step + 1)) "$TOTAL_STEPS" >&2
  fi
  exit 1
}
trap fail ERR

command -v mops >/dev/null 2>&1 || {
  echo "mops not found on PATH. Install: npm i -g ic-mops" >&2
  exit 2
}

# -Werror, not plain `mops check`. Motoko reports a non-exhaustive match (M0145)
# as a WARNING, so adding a case to `Types.Owner` — the §11.1.1 Base seam — used
# to leave five authz sites silently trapping at runtime while the build passed.
# On the webhook path that trap is a 5xx and Stripe retries it for ~3 days.
#
# It lives here rather than in mops.toml's [moc] args because `mops test` passes
# --hide-warnings, and moc rejects that combination outright.
# ⚠️ **First, because it is the cheapest and it guards the gate's own substrate.** An
# unquoted heredoc that runs its own body has bitten twice in three days — once destroying
# a GitHub issue body, once turning `stripe-dev.sh`'s closing notes into an `icp deploy`.
# Fixed syntax, so it is enforceable here rather than written down again; see the script.
run "shell — no unquoted heredoc runs its own body" scripts/check-heredocs.sh

run "mops check — lint + typecheck (-Werror)" mops check -- -Werror
run "mops test — Motoko unit suites" mops test

# Before the frontend: the committed .did is both the embedded candid:service
# metadata and the frontend's bindgen source, so it has to be current or the
# typecheck below is checking against a stale interface.
run "mops build — regenerate the committed .did" mops build
if ! git diff --quiet -- src/backend/dist/backend.did; then
  printf '\n\033[31m✗ src/backend/dist/backend.did is out of date — commit the regenerated file\033[0m\n' >&2
  git --no-pager diff --stat -- src/backend/dist/backend.did >&2
  exit 1
fi
printf '   .did is current\n'

# `npm run build` regenerates the bindings the typecheck needs; running the
# typecheck first on a clean tree fails for the wrong reason.
run "frontend build — regenerate bindings" npm --prefix src/frontend run build
run "frontend typecheck" npm --prefix src/frontend run typecheck
run "frontend tests" npm --prefix src/frontend run test

# The test-only fixture hook (src/frontend/src/fixtures.ts) exists behind a
# `define`d `__FIXTURES__` so the browser specs can reach the post-purchase
# surfaces. Its absence from the SHIPPING bundle is the whole basis for letting it
# exist, and dead-code elimination is a compiler behaviour rather than a promise —
# so it is checked here against the bytes that would be deployed.
step=$((step + 1))
printf '\n\033[1m── %d. %s\033[0m\n' "$step" "no test hooks in the shipping bundle"
if grep -rl "__cyclepayFixtures" src/frontend/dist >/dev/null 2>&1; then
  printf '\n\033[31m✗ the fixture hook is present in src/frontend/dist — a fixtures build was left in the shipping output\033[0m\n' >&2
  grep -rl "__cyclepayFixtures" src/frontend/dist >&2
  exit 1
fi
printf '   dist/ carries no fixture hook\n'

# The reserve floor's premise, enforced rather than asserted (#30 PR-B).
#
# `Reserve.mo`'s floor is a lower bound on the reserve balance ONLY because the
# balance cannot fall except when we transfer out. What makes that true is that
# `Cmc.CyclesLedgerService` does not declare the two methods the account's owner could
# otherwise use — `icrc2_approve` (which would create an allowance for someone else to
# pull from the account) and the ledger's `withdraw`. Undeclared means uncallable.
#
# So the premise has exactly one failure mode: someone widens that actor type. A
# comment cannot catch that; this can. The floor breaks SILENTLY and in the optimistic
# direction — it would keep admitting sales against cycles that had left — which is
# why this is a gate failure and not a warning.
step=$((step + 1))
printf '\n\033[1m── %d. %s\033[0m\n' "$step" "the reserve account has exactly one outflow"
# ⚠️ **The whole tree, deliberately.** A second actor declaration anywhere — inline in
# Main.mo as `actor "um5iw-…" : actor { withdraw : … }`, or a new binding in any module
# — widens what this canister can call without touching the service type in
# Delivery.mo. The threat is "a declaration exists", so the search is for declarations,
# everywhere.
if grep -rnE '(icrc2_approve|icrc2_transfer_from|withdraw)[[:space:]]*:' src/backend/ >/dev/null 2>&1; then
  printf '\n\033[31m✗ a second way to move the reserve is declared somewhere in src/backend\033[0m\n' >&2
  grep -rnE '(icrc2_approve|icrc2_transfer_from|withdraw)[[:space:]]*:' src/backend/ >&2
  printf '\n  The reserve floor is a LOWER BOUND only while `icrc1_transfer` is the only\n' >&2
  printf '  outflow. Adding one of these makes the balance fall in a way the floor cannot\n' >&2
  printf '  see, so the gate admits sales against cycles that already left — silently.\n' >&2
  printf '  Read the floor section in src/backend/Reserve.mo before proceeding.\n' >&2
  exit 1
fi
printf '   icrc1_transfer is the only declared way out, tree-wide\n'

# Brand guidelines: the mechanically checkable rules only (banned characters,
# banned vocabulary, hardcoded colour, the no-auto-dark rule). Typography and
# hierarchy still need eyes.
run "brand lint — user-facing copy and tokens" bash scripts/brand-lint.sh

# Browser specs (issue #6). These cover what jsdom is structurally blind to: the
# CASCADE and LAYOUT. A class selector's `display` outranks the UA stylesheet's
# `[hidden]`, so elements the app had hidden stayed on screen while every DOM
# test passed — that shipped once, and these exist so it cannot again.
# Serves the built dist over a static server; needs no local network.
if [ -d test/browser/node_modules ]; then
  run "browser specs — cascade, layout, reachability" npm --prefix test/browser test
else
  # FAILS, rather than warning and carrying on to a green tick. Nobody asked for
  # this skip: it means the dependency is not installed, and the fix is one
  # command. Every frontend claim in this gate — that a view is on screen, that
  # the delivered tour renders, that a poll does not repaint a dead view — is
  # unverified without it, and a yellow line above "✓ gate passed" is not how you
  # tell someone that.
  printf '\n\033[31m✗ the browser specs cannot run, so nothing about the frontend is verified.\033[0m\n' >&2
  printf '\033[31m  Install them:  npm --prefix test/browser ci && npx --prefix test/browser playwright install chromium\033[0m\n' >&2
  exit 1
fi

if [ "$FAST" -eq 1 ]; then
  printf '\n\033[31m⚠ skipped the PocketIC suite (--fast)\033[0m\n' >&2
else
  # `npm test` and never `npx vitest run`: the latter skips pretest, which fetches
  # the sha256-pinned wasms and rebuilds the backend — so it would silently test a
  # stale wasm and pass.
  # Typecheck the suite too: vitest does not, so a broken spec would otherwise
  # only surface as a runtime failure — or not at all for an unused helper.
  run "integration typecheck" npm --prefix test/integration run typecheck
  run "PocketIC integration suite — the go-live bar" \
    npm --prefix test/integration test
fi

# One summary line, and it must not say "passed" when a suite did not run. --fast
# is an explicit request so it still exits 0, but a green tick after an admitted
# skip is the thing that lets "the gate is green" be quoted for a run that never
# checked the go-live bar.
if [ "$FAST" -eq 1 ]; then
  printf '\n\033[31m✗ gate INCOMPLETE: everything except the PocketIC suite passed.\033[0m\n' >&2
  printf '\033[31m  The go-live bar is UNVERIFIED. Run without --fast before claiming it.\033[0m\n' >&2
else
  printf '\n\033[32m✓ gate passed\033[0m\n'
fi
