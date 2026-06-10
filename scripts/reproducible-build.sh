#!/usr/bin/env bash
# Reproducible release build wrapper (spec §8).
#
#   scripts/reproducible-build.sh [git-ref] [outdir]
#
# Builds <git-ref> (default HEAD) inside the pinned container and writes
# backend.wasm / frontend.wasm / backend.did / MODULE-HASHES.txt to <outdir>
# (default release/). The context is `git archive <ref>` — the committed tree
# only — so the resulting hashes are a pure function of the ref. Verifiers run
# the same command on the release tag and diff MODULE-HASHES.txt against the
# published one and against `icp canister status --public`.
set -euo pipefail

cd "$(dirname "$0")/.."
ref="${1:-HEAD}"
out="${2:-release}"

commit="$(git rev-parse "$ref")"
if [ "$ref" = "HEAD" ] && ! git diff-index --quiet HEAD --; then
  echo "warning: working tree is dirty — building committed HEAD ($commit); local changes are NOT included" >&2
fi

echo "building $ref ($commit) in the pinned container..."
git archive --format=tar "$ref" |
  docker build -f Dockerfile.release --output "type=local,dest=$out" -

echo
echo "== $ref ($commit) =="
cat "$out/MODULE-HASHES.txt"
