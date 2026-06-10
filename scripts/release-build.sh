#!/usr/bin/env bash
# Inner release build (spec §8): produce the exact module bytes `icp deploy`
# installs, plus their sha256 module hashes. Runs identically inside the
# pinned container (Dockerfile.release) and on a dev host that has the same
# pinned toolchain (ic-mops 2.13.2, icp-cli 0.3.2, ic-wasm 0.9.11 — see
# RELEASE.md). The published hash is the container's.
#
# Usage: scripts/release-build.sh [outdir]   (default: release/)
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-release}"

# Build from a clean artifact cache — determinism is asserted, not assumed.
rm -rf .icp/cache/artifacts
icp build

mkdir -p "$out"
cp .icp/cache/artifacts/backend "$out/backend.wasm"
cp .icp/cache/artifacts/frontend "$out/frontend.wasm"
# The committed interface ships alongside the module it is embedded in.
cp src/backend/dist/backend.did "$out/backend.did"

(cd "$out" && sha256sum backend.wasm frontend.wasm backend.did > MODULE-HASHES.txt)

echo
echo "== expected module hashes (publish MODULE-HASHES.txt with the release) =="
cat "$out/MODULE-HASHES.txt"
