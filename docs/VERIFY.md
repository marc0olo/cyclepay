# Verify it yourself

The gateway is live in **simulation mode** on mainnet — <https://cyclepay.raymondk.co>,
frontend `shy4u-4qaaa-aaaay-aadhq-cai`, backend `saz2a-riaaa-aaaay-aadha-cai`.

Two separate questions, with different answers.

## "Is the page I am using built from this repo?" — yes, check it

This needs no identity, and a Rust toolchain the first time:

```bash
git clone --recurse-submodules https://github.com/marc0olo/cyclepay && cd cyclepay
git checkout vX.Y.Z                             # the release the deployment published
npm --prefix src/frontend ci && npm --prefix src/frontend run build
scripts/check-frontend-hash.py -e ic
```

⚠️ **Check out the tag, not `main`.** The deployment is a release; `main` moves on after
it. Comparing a `main` build against a released deployment reports a mismatch that means
nothing, and `main` is one commit past a tag more often than not. This page said "no
checkout" until it was measured: `main` and `v0.1.0-beta.1` differ by HTML comments in
`index.html`, which is enough to change the hash.

The canister publishes a **state hash**: one SHA-256 over every asset it serves — each
one's bytes in every encoding, its `content_type` and its response headers — plus the
redirect rules in match order. The check computes the same number from the directory your
own build just produced and compares them. Equal means the canister serves exactly that
build, down to the CSP.

It computes that number with the verifier from `dfinity/certified-assets` at the release
`icp.yaml` pins, built from source on first run and cached under `.cache/`. That is the
Rust dependency, and building it rather than downloading it is the point: the hash is
only worth anything if the thing computing it came from source you can read. The check
also refuses to compare unless the canister reports running that same release, because
the hash is frozen per release and a version-crossing comparison would fail for no
reason.

No result is quoted here, because a status written into prose is what goes stale. Run
the command: it reads the live hash, and the answer is only as old as your terminal.

⚠️ **Do not check the frontend's module hash instead.** The `@dfinity/static-site` recipe
installs a pre-built certified-assets wasm, so that hash describes the recipe, not the
page. The page lives in canister state.

## "Is the backend module built from this repo?" — compare it to a release

Every release publishes the module hashes its container build produced. Rebuild the tag
yourself and compare three things — your build, the release notes, and the canister:

```bash
git checkout vX.Y.Z
scripts/reproducible-build.sh vX.Y.Z              # writes release/MODULE-HASHES.txt
icp canister status saz2a-riaaa-aaaay-aadha-cai -n ic -p
gh release view vX.Y.Z                            # the published hashes
```

All three must agree, including the `# build arch:` line — the same commit produces
different bytes on different platforms, so a hash without its architecture cannot be
compared. [`RELEASE.md`](../RELEASE.md) is the procedure that keeps them in step: it
installs the artifact the container built rather than rebuilding on the host, and fails
unless the canister reports the hash it built.

**Status: the running module is `v0.1.0-beta.1`'s published build.** It was installed
from the container artifact whose hashes that release publishes, and the install gated on
the canister reporting them — so the three comparisons above agree, and you can re-check
that yourself with the commands rather than take it from this page. No hash is restated
here: a figure written into prose goes stale, and those commands read the live ones.

## What anyone can check right now

No identity, no permissions, nothing installed but `icp`.

**The price you are shown is produced by the code that locks it.** `quote_previews` is a
public query running the same pricing path as order creation, and it returns both rate
inputs so the arithmetic is yours to redo:

```bash
icp canister call backend quote_previews '(vec { 1_000 : nat })' -e ic
```

**Pricing crosses no trust boundary.** Both rates come from canisters — the Exchange Rate
Canister for USD/ICP, the CMC for XDR/ICP — read on a timer. There are exactly three
HTTPS outcalls in the system and all three go to Stripe (create, expire and retrieve a
Checkout Session). See [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md).

**The operational state is public**, so solvency is checkable against the cycles ledger
without this canister's cooperation:

```bash
icp canister call backend reserve_status   '()' -e ic   # floor, promised, available
icp canister call backend pricing_status   '()' -e ic   # both rates, the divisor
icp canister call backend lifecycle_config '()' -e ic   # the gate's bounds
icp canister call backend cycles_status    '()' -e ic
icp canister call backend recovery_status  '()' -e ic
icp canister call backend health           '()' -e ic
```

**The interface cannot drift from the source.** `mops build` regenerates the committed
`src/backend/dist/backend.did`; a gate step fails on drift; and the recipe embeds *that
file* as the canister's `candid:service` metadata.

**Which means the running canister names its own commit.** The interface it publishes is a
file in this repo, so you can find which tree it was built from without any published
hash — including on a deployment that was never released:

```bash
icp canister metadata backend candid:service -e ic > /tmp/deployed.did
git show <ref>:src/backend/dist/backend.did | diff - /tmp/deployed.did
```

An exact match (bar one trailing newline the metadata fetch adds) means the deployed
interface is that ref's. It narrows the commit rather than proving the bytes — two commits
that do not touch the interface share it — but it needs nothing published and no
cooperation from us.

**The reserve floor is enforced by an omission in a type.** `src/backend/Delivery.mo`
declares the cycles-ledger interface the canister may call, and `icrc2_approve` and the
ledger's `withdraw` are absent — so they cannot be called, which is what makes the floor
a valid lower bound. `scripts/test-all.sh` fails on a declaration that widens it.

**Frontend responses are certified per response**, on top of the state-hash check above:
each carries `IC-Certificate` over the asset tree and the gateway rejects a response whose
certificate does not verify. There is no uncertified raw mode to switch off.

**Every suite is in the repo and one command runs them all**: `scripts/test-all.sh`, with
[`docs/TEST-COVERAGE.md`](./TEST-COVERAGE.md) stating what is *not* covered and why.

## What a buyer can check that a visitor cannot

`receipt(orderId)` is **owner-scoped** (`caller == order.owner`), so it is a buyer's
affordance. It returns both rate inputs and the delivery block index, so a buyer can
recompute their own price and confirm the transfer on the cycles ledger independently.

## The limits, in the same breath

- **The published hash is reproducible on one architecture.** `backend.wasm` depends on
  it, so the build is pinned to `--platform linux/amd64` and the release records the
  architecture it ran on — `x86_64`, as `uname -m` reports it inside that container.
  Rebuilding elsewhere gives different bytes and proves nothing.
- **The hashes are published by us.** The reproducible build is what makes that not
  require trust — anyone can produce the same bytes — but nobody else counter-signs them.
- **Any single controller can upgrade and drain.** IC controllers are OR-semantics; the
  hardening path is a multisig canister as sole controller. See
  [`docs/SANDBOX-TESTPLAN.md`](./SANDBOX-TESTPLAN.md).
- **The webhook secret is plaintext canister state**, protected by the confidential
  subnet rather than by cryptography. HMAC is symmetric, so a canister that can verify
  can also forge; encrypting it would only move the problem to a key the canister must
  also hold. Checkpoint and state-sync confidentiality are confirmed on the target
  subnet; **attestation coverage of every replica is not** — `RUNBOOK.md`'s
  confidential-subnet checklist carries it.
- **A purchase requires an allow-listed principal** while test payments are accepted, so
  a visitor cannot exercise the buying path end to end on the live gateway.
