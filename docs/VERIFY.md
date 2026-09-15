# Verify it yourself

The gateway is live in **simulation mode** on mainnet — <https://cyclepay.raymondk.co>,
frontend `shy4u-4qaaa-aaaay-aadhq-cai`, backend `saz2a-riaaa-aaaay-aadha-cai`.

Two separate questions, with different answers.

## "Is the page I am using built from this repo?" — yes, check it

This takes two minutes and needs no identity:

```bash
git clone --recurse-submodules https://github.com/marc0olo/cyclepay && cd cyclepay
npm --prefix src/frontend ci && npm --prefix src/frontend run build
scripts/check-frontend-assets.py -e ic
```

It compares the `sha256` the canister publishes for **every asset it serves** against the
file your own build produced, and names any that differ. At the time of writing it passes:
all ten built assets — `index.html`, both bundles, all four fonts, both `.well-known`
files — match byte for byte.

⚠️ **Do not check the frontend's module hash instead.** The `@dfinity/static-site` recipe
installs a pre-built certified-assets wasm, so that hash describes the recipe, not the
page. The page lives in canister state.

## "Is the backend module built from this repo?" — not for this deployment

The backend was deployed with a plain `icp deploy`, untagged, with no published module
hash, so there is nothing to compare the on-chain hash against. And it would not have
matched: **`backend.wasm` depends on the platform it is built on**, and this one was built
on the operator's Mac rather than in the release container.

```
darwin/arm64, native      8dae04a0…      ← how the live canister was built
linux/arm64,  container   98c99a3a…
linux/amd64,  container   41128dbd…      ← the pinned default
```

(The deployed commit is identifiable — `468687e`, whose committed `backend.did` is
byte-identical to the Candid embedded in the running wasm — and rebuilding it on that
same machine reproduces the hash exactly. That is not something a stranger can rely on.)

⚠️ **The on-chain hash is deliberately not published here as a verifiable artifact.** A
number with no independently reproducible counterpart looks like verification without
being one. Read it yourself with `icp canister status backend -e ic`.

**Future releases do not have this problem.** [`RELEASE.md`](../RELEASE.md)'s procedure
builds in the container on a pinned platform, installs *that* artifact rather than
rebuilding on the host, and fails unless the canister reports the hash it built — so the
published hash and the running module cannot drift apart. The remedy for this deployment
is to re-cut it that way before real money, not to bless the hash it has.

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

**Frontend responses are certified per response**, on top of the asset comparison above:
each carries `IC-Certificate` over the asset tree and the gateway rejects a response whose
certificate does not verify. There is no uncertified raw mode to switch off.

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
