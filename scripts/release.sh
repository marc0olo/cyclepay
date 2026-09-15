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
if printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+'; then
  if ! git show "$ref:CHANGELOG.md" 2>/dev/null | grep -q "^## $version\$"; then
    echo "error: CHANGELOG.md in $ref has no '## $version' section." >&2
    echo "  Add the entry, commit it, and move the tag — a published hash with no" >&2
    echo "  changelog leaves nobody able to say what changed." >&2
    exit 1
  fi
  echo "changelog: '## $version' found in $ref"
fi

scripts/reproducible-build.sh "$ref" release

expected="$(awk '/backend\.wasm/{print $1}' release/MODULE-HASHES.txt)"
[ -n "$expected" ] || { echo "error: no backend.wasm hash in release/MODULE-HASHES.txt" >&2; exit 1; }

echo
echo "built:    $expected"

if ! $install; then
  echo
  echo "Publish release/MODULE-HASHES.txt verbatim, including its '# build arch:' line."
  echo "Then install and gate in one step:"
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
