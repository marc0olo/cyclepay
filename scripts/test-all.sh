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
set -euo pipefail

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

step=0
run() {
  step=$((step + 1))
  printf '\n\033[1m── %d. %s\033[0m\n' "$step" "$1"
  shift
  "$@"
}

fail() {
  printf '\n\033[31m✗ gate FAILED at step %d\033[0m\n' "$step" >&2
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

if [ "$FAST" -eq 1 ]; then
  printf '\n\033[33m⚠ skipped the PocketIC suite (--fast). The go-live bar is UNVERIFIED.\033[0m\n'
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

printf '\n\033[32m✓ gate passed\033[0m\n'
