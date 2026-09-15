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
| `icp` 1.4.0, `ic-wasm` 0.11.1, `mops` 3.2.0, Node 24.20.0 | `ghcr.io/dfinity/icp-dev-env-motoko:v2.1.0`, pinned **by digest** in `Dockerfile.release` |
| Candid interface | `src/backend/dist/backend.did`, committed; the recipe embeds **this file** as the `candid:service` metadata, so the committed interface and the deployed one are the same bytes |

The backend recipe runs `ic-wasm` shrink (deterministic optimize) and embeds
metadata (`candid:service` public; `candid:args`, `motoko:stable-types`,
`enhanced-orthogonal-persistence`, `moc:version` private). The module is
**not** gzip-compressed: the on-chain module hash is the sha256 of the wasm
file itself, so `sha256sum` and `icp canister status` are directly comparable.

⚠️ **Bumping the dev-env image changes every module hash.** That is correct — the image
is part of what shapes the bytes — but it makes the bump a release of its own, with its
own published hashes, never a passenger on an unrelated change.

`scripts/release.sh` and `scripts/reproducible-build.sh` write `backend.wasm`,
`frontend.wasm`, `backend.did` and `MODULE-HASHES.txt` into `release/`, from
`git archive <ref>` — the committed tree only, so local changes cannot reach a hash.
⚠️ `frontend.wasm` is written for completeness and is **not** a useful check: it is the
pinned recipe's pre-built canister, the same for every project that uses it.

## Cutting a release

Five steps, in this order.

```bash
# 1. CHANGELOG.md: rename "Unreleased" to the version, commit it
git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z

scripts/release.sh vX.Y.Z                                        # 2. build, print hashes
# 3. publish release/MODULE-HASHES.txt verbatim in the release notes,
#    including its `# build arch:` line — a hash without its architecture
#    cannot be compared (see Caveats)
scripts/release.sh vX.Y.Z --install -e ic --identity <operator>  # 4. install + gate

icp deploy frontend -e ic && scripts/check-frontend-assets.py -e ic   # 5. frontend
```

Step 4 rebuilds in the container, installs **that artifact** with
`icp canister install --wasm`, then reads the module hash back from the canister and
fails if it differs from what it built.

⚠️ **The changelog comes first because the check reads the TAGGED tree.**
`scripts/release.sh` refuses a version whose `CHANGELOG.md` has no `## X.Y.Z` section,
and it looks inside the ref rather than the working copy — so the entry is part of the
commit the hash is published for and cannot be backfilled. Building `HEAD` or a bare
commit to inspect hashes needs no entry.

⚠️ **Never `icp deploy` the backend.** It rebuilds on the host, so a container build
followed by `icp deploy` publishes one module and installs another — which is how a
deployment becomes unverifiable without anyone noticing.

⚠️ **The gate is inside step 3 on purpose.** A verification that is a separate
instruction gets skipped, and a skipped verification is indistinguishable from a passing
one. The hash is read from the canister, never from the build.

⚠️ **The frontend is checked by its ASSETS, not its module hash.** The
`@dfinity/static-site` recipe installs a pre-built certified-assets wasm, so that hash
describes the recipe — identical for every project using it, and unrelated to the page
anyone is served. The content lives in canister state, put there by the sync plugin, so
`check-frontend-assets.py` compares each asset's `Identity` `sha256` from
`get_asset_details` against `src/frontend/dist`. A mismatch names the asset.

## Verifying a release (anyone)

No identity, no permissions.

```bash
git clone <repo> && cd <repo> && git checkout vX.Y.Z

scripts/reproducible-build.sh vX.Y.Z          # rebuild the backend in the container
icp canister status <backend-id> -n ic -p     # read the deployed module hash

npm --prefix src/frontend ci && npm --prefix src/frontend run build
scripts/check-frontend-assets.py -n ic        # compare served assets to that build
```

`release/MODULE-HASHES.txt`, the hash in the release notes and the canister's
`Module hash` must all agree — and so must the `# build arch:` line, since the same
commit gives different bytes on different platforms. The module hash is also on the
public dashboard (`dashboard.internetcomputer.org/canister/<id>`).

**What each half proves.** The backend hash ties the running module to a tagged commit.
The asset comparison ties the served page to that same tree — the frontend module hash
proves nothing, because it is the recipe's. Beyond that, every HTTP response carries
`IC-Certificate` and `IC-CertificateExpression` over the asset tree and the gateway
rejects responses whose certificate does not verify; there is no uncertified raw mode to
turn off, the way the legacy asset canister needed `allow_raw_access: false`.

⚠️ **`state_hash` is a fingerprint, not a check.** The canister publishes one root hash
over everything it certifies, and `check-frontend-assets.py` prints it — publish it with
a release so later drift is detectable. It is computed inside the canister, so it cannot
be derived from a build; the per-asset comparison is what ties a deployment to a source.

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
