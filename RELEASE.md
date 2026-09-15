# Reproducible build & release (spec §8)

The thesis of this gateway is verifiability: anyone can rebuild the canister
from a tagged commit and check that the bytes running on mainnet are exactly
the bytes that commit produces. This document is the procedure, for both
sides of that check.

## What is pinned

Every tool that shapes the module bytes is pinned by the *committed tree*:

| What | Where pinned |
|------|--------------|
| `moc` 1.16.0 | `mops.toml [toolchain]` |
| Motoko dependencies (`core`, `sha2`, `ic`) | `mops.lock` |
| `@dfinity/motoko@v5.1.0` / `@dfinity/static-site@v0.3.3` recipes | `icp.yaml` (icp-cli rejects unpinned recipes) |
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

```bash
git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z
scripts/release.sh vX.Y.Z                                    # build, print the hashes
# publish release/MODULE-HASHES.txt verbatim in the release notes
scripts/release.sh vX.Y.Z --install -e ic --identity <operator>
```

The second call builds in the container again, installs **that artifact**, reads the
module hash back from the canister and fails if it differs from what it built. Three
things follow from that shape:

⚠️ **The installed bytes are the built bytes.** `icp deploy` rebuilds on the host, so a
container build followed by `icp deploy` publishes one module and installs another.
`scripts/release.sh` uses `icp canister install --wasm`, which installs the file.

⚠️ **The gate cannot be skipped.** It is the same command, not a later instruction — and
a skipped verification is indistinguishable from a passing one. The hash is read back
from the canister, never from the build.

⚠️ **Publish `MODULE-HASHES.txt` including its `# build arch:` line.** The architecture
is part of the claim (see Caveats); a hash without it cannot be compared.

**The frontend is deployed normally, and verified differently:**

```bash
icp deploy frontend -e ic
scripts/check-frontend-assets.py -e ic
```

⚠️ **The frontend's module hash is not a meaningful check.** The `@dfinity/static-site`
recipe installs a **pre-built** certified-assets wasm, so that hash is a property of the
recipe — the same for every project using it, and unrelated to the page anyone is served.
The content lives in canister state, uploaded by the sync plugin.

So the frontend check compares **what is served against a local build**:
`check-frontend-assets.py` reads each asset's `Identity` encoding `sha256` from
`get_asset_details` and compares it to `sha256` of the corresponding file in
`src/frontend/dist`. A mismatch names the asset.

⚠️ **`state_hash` is recorded, not recomputed.** It is one root hash over everything the
canister certifies, produced inside the canister, so reproducing it locally would mean
reimplementing its certification tree and would break whenever that internal shape
changed. The script prints it: publish it with the release as a fingerprint, so later
drift is detectable even though it cannot be derived from a build. The per-asset
comparison is what ties the deployment to the source.

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

The frontend **module** (`frontend.wasm`) is the certified-assets canister wasm
bundled with the pinned recipe — its hash is published and checked the same way.
The asset **content** is not part of the module hash; it is verified per-response:
every HTTP response carries `IC-Certificate` and `IC-CertificateExpression` over
the asset tree, and the gateway rejects responses whose certificate does not
verify. There is no uncertified raw mode to switch off — the legacy asset
canister needed `allow_raw_access: false` for that, and this canister has no such
escape hatch. The asset build itself is reproducible
(vite + committed `package-lock.json`, node pinned by the container), so an
auditor can rebuild `src/frontend/dist` and compare files against what the
canister serves.

## Caveats (stated, not hidden)

- ⚠️ **`backend.wasm` depends on the platform it is built on, so the platform is pinned
  and published.** The same commit yields three different hashes on `darwin/arm64`
  native, `linux/arm64` container and `linux/amd64` container. `reproducible-build.sh`
  pins `--platform linux/amd64` (`RELEASE_PLATFORM=` overrides) and `MODULE-HASHES.txt`
  records the architecture, so a hash is never compared across platforms by accident.
  `frontend.wasm` and `backend.did` are identical on all three.
- Recipe tags (`@dfinity/motoko@v5.1.0`) are fetched from
  `dfinity/icp-cli-recipes` by git tag, which is not content-addressed. A
  moved tag cannot go unnoticed — it changes the hash — but it would break
  reproducibility of *old* tags. Accepted for v1.
- `MODULE-HASHES.txt` in release notes is trust-on-first-publish; the
  reproducible build exists precisely so nobody has to take it on faith.
