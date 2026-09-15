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
# ⚠️ **Name the two release canisters.** A bare `icp build` builds every canister in the
# LOCAL environment, which includes the `xrc` mock — and that mock's wasm is a fetched,
# gitignored artifact (`test/integration/wasm/`), so it is absent from the `git archive`
# context this whole procedure is built on. A bare build therefore fails inside the
# container, on every commit, with `failed to read wasm file`. Measured: that is why
# `docs/SANDBOX-TESTPLAN.md` could say the reproducible-build gate had never run.
# The `ic` environment declares exactly `[backend, frontend]`; naming them here keeps
# that true without depending on `-e ic`, which would want network access.
icp build backend frontend

mkdir -p "$out"
cp .icp/cache/artifacts/backend "$out/backend.wasm"
cp .icp/cache/artifacts/frontend "$out/frontend.wasm"
# The committed interface ships alongside the module it is embedded in.
cp src/backend/dist/backend.did "$out/backend.did"

# ⚠️ **The architecture goes IN the file, because `backend.wasm` depends on it.** The same
# commit gives three different hashes on darwin/arm64 native, linux/arm64 container and
# linux/amd64 container, so a hash without its build architecture cannot be compared.
# `uname -m` is read here rather than passed in, so it reports where the build really
# happened. A `#` comment is safe: `sha256sum -c` and `shasum -c` both skip it.
(cd "$out" && {
  printf '# build arch: %s\n' "$(uname -m)"
  sha256sum backend.wasm frontend.wasm backend.did
} > MODULE-HASHES.txt)

echo
echo "== expected module hashes (publish MODULE-HASHES.txt with the release) =="
cat "$out/MODULE-HASHES.txt"
