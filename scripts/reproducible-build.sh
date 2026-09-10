#!/usr/bin/env bash
# Reproducible release build wrapper (spec §8).
#
#   scripts/reproducible-build.sh [git-ref] [outdir]
#
# Builds <git-ref> (default HEAD) inside the pinned container and writes
# backend.wasm / frontend.wasm / backend.did / MODULE-HASHES.txt to <outdir>
# (default release/). The context is the committed tree only — so the resulting
# hashes are a pure function of the ref. Verifiers run the same command on the
# release tag and diff MODULE-HASHES.txt against the published one and against
# `icp canister status --public`.
#
# ⚠️ **`git archive` does NOT include submodules, and the pinned crypto (#11) is one.**
# A plain `git archive | docker build` produces a context whose
# `vendor/icp-seeding-secrets-poc/` is empty, and the build then fails inside the
# container on a `mops` path dependency that resolves to nothing. So the context is
# assembled explicitly below: the superproject tree, then the submodule tree overlaid at
# its own path.
#
# ⚠️ **The submodule commit is read FROM THE REF**, via `<ref>:<path>` — not from whatever
# the working tree happens to have checked out. That is what preserves the property this
# whole script exists for: same ref in, same bytes out, regardless of local state.
set -euo pipefail

cd "$(dirname "$0")/.."
ref="${1:-HEAD}"
out="${2:-release}"

commit="$(git rev-parse "$ref")"
if [ "$ref" = "HEAD" ] && ! git diff-index --quiet HEAD --; then
  echo "warning: working tree is dirty — building committed HEAD ($commit); local changes are NOT included" >&2
fi

SUBMODULE="vendor/icp-seeding-secrets-poc"
# `ls-tree` gives the gitlink's object id — the submodule commit this ref pins.
sub_commit="$(git ls-tree "$ref" "$SUBMODULE" | awk '{print $3}')"
[ -n "$sub_commit" ] || {
  echo "error: $ref records no submodule at $SUBMODULE" >&2
  exit 1
}
# It has to be a commit this machine actually has. A fresh clone without
# --recurse-submodules does not, and the failure would otherwise be an obscure tar error.
git -C "$SUBMODULE" cat-file -e "${sub_commit}^{commit}" 2>/dev/null || {
  echo "error: submodule commit $sub_commit is not available locally. Run:" >&2
  echo "    git submodule update --init --recursive" >&2
  exit 1
}

echo "building $ref ($commit) in the pinned container..."
echo "  with $SUBMODULE at $sub_commit"

ctx="$(mktemp -d)"
trap 'rm -rf "$ctx"' EXIT
git archive --format=tar "$ref" | tar -x -C "$ctx"
# The gitlink leaves an empty directory (or none); fill it from the submodule's own tree.
mkdir -p "$ctx/$SUBMODULE"
git -C "$SUBMODULE" archive --format=tar "$sub_commit" | tar -x -C "$ctx/$SUBMODULE"

tar -c -C "$ctx" . |
  docker build -f Dockerfile.release --output "type=local,dest=$out" -

echo
echo "== $ref ($commit) =="
cat "$out/MODULE-HASHES.txt"
