# Verify it yourself

What anyone can check about this gateway, what they cannot, and why. The commands are
the check — run them rather than trusting this page.

## The deployment's status, plainly

The gateway is live in **simulation mode** on mainnet —
<https://cyclepay.raymondk.co>, backend `saz2a-riaaa-aaaay-aadha-cai`. It was deployed
with a plain `icp deploy`, untagged, with no published module hash — so there is nothing
for anyone to compare the on-chain hash against.

⚠️ **The on-chain hash is deliberately not published here as a verifiable artifact.** A
number with no independently reproducible counterpart looks like verification without
being one. Read it yourself:

```bash
icp canister status backend -e ic
```

### Does the live wasm reproduce? No

**The deployed commit is `468687e`** (#157). Two independent confirmations: the wasm's
embedded Candid is byte-identical to that commit's committed `backend.did`, and rebuilding
that commit **on the machine that deployed it** reproduces the module hash exactly.

**The container produces different bytes for the same commit**, and the build turns out
to depend on where it runs. One commit, three `backend.wasm` hashes:

```
darwin/arm64, native      8dae04a0…      ← how the live canister was built
linux/arm64,  container   98c99a3a…
linux/amd64,  container   41128dbd…      ← now the pinned default
```

`frontend.wasm` and `backend.did` are identical on all three; only the Motoko module
moves.

**A release cut through `scripts/release.sh` does not have this problem**: it builds in
the container on a pinned platform, installs that artifact rather than rebuilding on the
host, and fails unless the canister reports the hash it built. See
[`RELEASE.md`](../RELEASE.md).

**This deployment was not cut that way**, so its bytes stay unverifiable. That is the
honest statement, and the remedy is to re-cut the deployment before real money — not to
publish the hash it has.

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
file* as the canister's `candid:service` — which is what made the commit identification
above possible.

**The reserve floor is enforced by an omission in a type.** `src/backend/Delivery.mo`
declares the cycles-ledger interface the canister may call, and `icrc2_approve` and the
ledger's `withdraw` are absent — so they cannot be called, which is what makes the floor
a valid lower bound. `scripts/test-all.sh` fails on a declaration that widens it.

**What the frontend serves is checkable against a build of this repo.** Each asset's
`Identity` encoding `sha256` is public, so it can be compared to the file a local build
produces:

```bash
npm --prefix src/frontend ci && npm --prefix src/frontend run build
scripts/check-frontend-assets.py -e ic
```

⚠️ **Do not check the frontend's module hash instead.** The `@dfinity/static-site` recipe
installs a pre-built certified-assets wasm, so that hash describes the recipe and not the
page. The page lives in canister state. The canister's `state_hash` is a single
fingerprint over everything it certifies — useful for spotting later drift, but produced
inside the canister and so not reproducible from a build.

**Frontend responses are also certified per response**, with no uncertified raw mode to
switch off — see [`RELEASE.md`](../RELEASE.md).

**Every suite is in the repo and one command runs them all**: `scripts/test-all.sh`, with
[`docs/TEST-COVERAGE.md`](./TEST-COVERAGE.md) stating what is *not* covered and why.

## What a buyer can check that a visitor cannot

`receipt(orderId)` is **owner-scoped** (`caller == order.owner`), so it is a buyer's
affordance. It returns both rate inputs and the delivery block index, so a buyer can
recompute their own price and confirm the transfer on the cycles ledger independently.

## The limits, in the same breath

- **The module hash has no published provenance**, and the live bytes are not
  reproducible by a third party — measured above.
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

## How verification is meant to work

[`RELEASE.md`](../RELEASE.md) is the procedure and this document does not restate its
steps — a second copy is a second thing to drift. Read it there: tag, build in the
container, publish `MODULE-HASHES.txt`, deploy, then **gate on the deployed hash matching
the published one**.

⚠️ **Tagging and publishing cannot be done after the fact.** The current deployment is
the evidence: it was deployed untagged with no hash published, and no amount of later
work makes those bytes verifiable to someone who was not there.
