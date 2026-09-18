#!/usr/bin/env bash
# Release the backend: build in the pinned container, install THAT artifact, and gate on
# the deployed module hash matching what was built.
#
#   scripts/release.sh <git-ref>                       # build + print hashes
#   scripts/release.sh <git-ref> --install [icp args]  # build, install, verify
#
# ⚠️ **Why this exists as one command.** The bytes that get published and the bytes that
# get installed have to be the same bytes, and `icp deploy` cannot give you that: it
# REBUILDS on the host, so a container build followed by `icp deploy` installs something
# nobody published. `icp canister install --wasm` installs the file.
#
# ⚠️ **The verify step is not optional here, by construction.** It is the step that gets
# skipped when it is a separate instruction, and skipping it is indistinguishable from
# passing it.
set -euo pipefail
cd "$(dirname "$0")/.."

ref="${1:-}"
[ -n "$ref" ] || { echo "usage: scripts/release.sh <git-ref> [--install [icp args...]]" >&2; exit 2; }
shift

install=false
if [ "${1:-}" = "--install" ]; then install=true; shift; fi
# Everything after --install goes to icp verbatim: -e ic, --identity <name>, --yes.
icp_args=("$@")

# ⚠️ **A version with no CHANGELOG entry is not a release.** Checked against the tree
# being built, not the working copy, so the entry is part of the tagged commit and cannot
# be added afterwards — the same reason the hashes come from `git archive`. Only refs that
# look like versions are checked: building HEAD or a bare commit to inspect hashes is a
# normal thing to do and does not need an entry.
version="${ref#v}"
is_version=false
if printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+'; then
  is_version=true
  # -F -x: the version contains dots, which as a regex would match any character —
  # `0.1.0` would accept a `## 0X1X0` heading. Fixed string, whole line.
  if ! git show "$ref:CHANGELOG.md" 2>/dev/null | grep -qxF "## $version"; then
    echo "error: CHANGELOG.md in $ref has no '## $version' section." >&2
    echo "  Add the entry, commit it, and move the tag — a published hash with no" >&2
    echo "  changelog leaves nobody able to say what changed." >&2
    exit 1
  fi
  echo "changelog: '## $version' found in $ref"
fi

scripts/reproducible-build.sh "$ref" release

# ⚠️ **The frontend is built from the REF, in a worktree, not from the working tree.**
# The backend gets this for free (`reproducible-build.sh` builds a `git archive` of the
# ref); the frontend has no such step, and a working-tree build would publish whatever
# is checked out. That is not hypothetical: `main` one commit past a tag changed HTML
# comments in `index.html`, which changes the hash, so a release cut from a tag would
# have published a number no verifier of that tag could reproduce.
#
# The hash needs `dist`, and nothing else builds it this early: `icp deploy frontend`
# does, but that is step 5, long after these notes are published.
fe_tmp="$(mktemp -d)"
fe_tree="$fe_tmp/frontend-at-ref"
# `git worktree remove` deletes the worktree but not the temp dir holding it.
cleanup() { git worktree remove --force "$fe_tree" >/dev/null 2>&1 || true; rm -rf "$fe_tmp"; }
trap cleanup EXIT
# A run killed before its trap fired leaves a registration pointing at a deleted
# temp dir; pruning first keeps those from accumulating in `git worktree list`.
git worktree prune
git worktree add -q --detach "$fe_tree" "$ref"
# ⚠️ **`cd`, not `npm --prefix`.** With a prefix under `mktemp -d` — on macOS a
# `/var/folders/...` path that resolves through a symlink — `npm ci` takes the package
# name from the directory instead of `package.json` and dies with
# `Missing: frontend@0.1.0 from lock file`, though the package is `cyclepay-frontend`.
# Measured both ways: the same command against a `/private/tmp` path succeeds, so it is
# the path shape rather than the flag, and `--prefix` elsewhere in the repo (always a
# relative path inside it) is unaffected. A subshell keeps the cwd change local.
(cd "$fe_tree/src/frontend" && npm ci && npm run build)
# --print takes the TREE ROOT, so the recipe pin and the `dist` are the same ref's.
scripts/check-frontend-hash.py --print "$fe_tree" > release/FRONTEND-STATE-HASH.txt
echo "frontend: $(cat release/FRONTEND-STATE-HASH.txt) (state hash, from $ref)"

# ⚠️ **Notes only for a version ref.** This script documents building `HEAD` or a bare
# commit to inspect hashes, and the changelog gate above deliberately skips those — but
# `release-notes.py` aborts on a ref with no `## <version>` changelog section, so for
# years the documented inspection build could not finish. An inspection build wants the
# hashes, not release notes.
if $is_version; then
  scripts/release-notes.py "$ref"
else
  echo "notes: skipped — $ref is not a version ref (hashes above are the point)"
fi

expected="$(awk '/backend\.wasm/{print $1}' release/MODULE-HASHES.txt)"
[ -n "$expected" ] || { echo "error: no backend.wasm hash in release/MODULE-HASHES.txt" >&2; exit 1; }

echo
echo "built:    $expected"

if ! $install; then
  echo
  # ⚠️ Not for a non-version ref: no notes were written for it, so this would send an
  # operator to publish whatever `release/NOTES.md` happens to hold from a previous run.
  if $is_version; then
    echo "Publish release/NOTES.md as the release body — it carries the hashes verbatim,"
    echo "the architecture they were built on, and how to reproduce them."
    echo "Then install and gate in one step:"
  else
    echo "Inspection build of $ref. To install and gate a release, use a version ref:"
  fi
  echo "    scripts/release.sh $ref --install -e ic --identity <operator>"
  exit 0
fi

echo "installing release/backend.wasm ..."
icp canister install backend --wasm release/backend.wasm --mode upgrade "${icp_args[@]}"

# ⚠️ Read the hash back from the canister, never from the build. Comparing the build to
# itself is the failure mode this gate exists to prevent.
deployed="$(icp canister status backend "${icp_args[@]}" | awk -F'0x' '/Module hash/{print $2}' | tr -d '[:space:]')"
echo
echo "built:    $expected"
echo "deployed: ${deployed:-<none reported>}"

if [ "$deployed" = "$expected" ]; then
  echo "✓ the canister is running the bytes that were built"
else
  echo "✗ MISMATCH — the canister is not running the published bytes." >&2
  echo "  Do not publish the deployed hash instead. Re-install release/backend.wasm." >&2
  exit 1
fi
