# Reproducible build & release (spec §8)

The thesis of this gateway is verifiability: anyone can rebuild the canister
from a tagged commit and check that the bytes running on mainnet are exactly
the bytes that commit produces. This document is the procedure, for both
sides of that check.

## What is pinned

Every tool that shapes the module bytes is pinned by the *committed tree*:

| What | Where pinned |
|------|--------------|
| `moc` 1.9.0 | `mops.toml [toolchain]` |
| Motoko dependencies (`core`, `sha2`, `ic`) | `mops.lock` |
| `@dfinity/motoko@v4.1.0` / `@dfinity/asset-canister@v2.2.1` recipes | `icp.yaml` (icp-cli rejects unpinned recipes) |
| `ic-mops` 2.13.2, `@icp-sdk/icp-cli` 0.3.2, `@icp-sdk/ic-wasm` 0.9.11 | `Dockerfile.release` |
| Node 22.22.1 (toolchain host + frontend build) | `Dockerfile.release` base image, by digest |
| Candid interface | `src/backend/dist/backend.did`, committed; the recipe embeds **this file** as the `candid:service` metadata, so the committed interface and the deployed one are the same bytes |

The backend recipe runs `ic-wasm` shrink (deterministic optimize) and embeds
metadata (`candid:service` public; `candid:args`, `motoko:stable-types`,
`enhanced-orthogonal-persistence`, `moc:version` private). The module is
**not** gzip-compressed: the on-chain module hash is the sha256 of the wasm
file itself, so `sha256sum` and `icp canister status` are directly comparable.

## Building a release

```bash
scripts/reproducible-build.sh <git-ref>        # default: HEAD
```

This pipes `git archive <ref>` — the committed tree only, local changes can
never leak into a hash — into `Dockerfile.release` and writes to `release/`:

- `backend.wasm`, `frontend.wasm` — the exact modules `icp deploy` installs
- `backend.did` — the committed interface, as embedded in the module
- `MODULE-HASHES.txt` — sha256 of all three

`scripts/release-build.sh` (the inner step) also runs directly on any host
with the same pinned toolchain; the container is the canonical environment.

## Cutting a release

1. Tag: `git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z`.
2. `scripts/reproducible-build.sh vX.Y.Z`
3. Publish `release/MODULE-HASHES.txt` verbatim in the GitHub release notes.
4. Deploy: `icp deploy -e ic --mode upgrade` (named identity, never anonymous).
5. **Gate:** confirm the deployed module hash equals the published one —
   ```bash
   icp canister status backend -e ic
   ```
   If the reported module hash differs from `MODULE-HASHES.txt`, the deploy
   was built from drifted state; reinstall from a clean checkout of the tag.

## Verifying a release (anyone)

```bash
git clone <repo> && cd <repo>
scripts/reproducible-build.sh vX.Y.Z
icp canister status <backend-canister-id> -n ic --public   # works for non-controllers
```

Compare the `Module hash` line against your locally built
`release/MODULE-HASHES.txt` and against the hash published in the release
notes. All three must agree. The module hash is also visible on the public
dashboard (`dashboard.internetcomputer.org/canister/<id>`).

## Frontend verifiability

The frontend **module** (`frontend.wasm`) is the asset-canister wasm bundled
with the pinned recipe — its hash is published and checked the same way. The
asset **content** is not part of the module hash; it is verified per-response
by certified assets: every HTTP response carries a subnet-signed certificate
over the asset tree, `allow_raw_access: false` (`.ic-assets.json5`) refuses
the uncertified raw domain, and the service-worker/gateway rejects responses
whose certificate doesn't verify. The asset build itself is reproducible
(vite + committed `package-lock.json`, node pinned by the container), so an
auditor can rebuild `src/frontend/dist` and compare files against what the
canister serves.

## Caveats (stated, not hidden)

- The base image digest is a multi-arch manifest list: amd64 and arm64 hosts
  pull different platform images. The toolchain's wasm output is
  host-architecture-independent by design; container and native builds were
  verified byte-identical on linux/arm64. If a build on another platform
  produces a different hash, treat it as a toolchain bug and pin the platform
  with `docker build --platform` while investigating.
- Recipe tags (`@dfinity/motoko@v4.1.0`) are fetched from
  `dfinity/icp-cli-recipes` by git tag, which is not content-addressed. A
  moved tag cannot go unnoticed — it changes the hash — but it would break
  reproducibility of *old* tags. Accepted for v1.
- `MODULE-HASHES.txt` in release notes is trust-on-first-publish; the
  reproducible build exists precisely so nobody has to take it on faith.
