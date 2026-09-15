# Verify it yourself

What a stranger can check about this gateway today, what they cannot, and why. Every
figure below was measured, and the commands are the measurement.

## The deployment's status, plainly

The gateway is live in **simulation mode** on mainnet —
<https://cyclepay.raymondk.co>, backend `saz2a-riaaa-aaaay-aadha-cai`. It was deployed
with a plain `icp deploy`: **nothing was tagged, no `MODULE-HASHES.txt` was published,
and [`RELEASE.md`](../RELEASE.md)'s step 5 — the gate comparing the deployed hash
against a published one — has never run.**

⚠️ **The on-chain hash is deliberately not published here as a verifiable artifact.** A
number with no independently reproducible counterpart looks like verification without
being one. Read it yourself:

```bash
icp canister status backend -e ic
```

### What the module hash turned out to be — measured 2026-09-15

The question "do the live bytes reproduce from their own commit?" is no longer *unknown*.
It was answered by running the procedure retroactively, and the answer is **the live
bytes are not third-party reproducible, for a reason worth knowing**.

**Which commit is deployed: `468687e`** (#157), established two independent ways.

1. The wasm's own embedded Candid is **byte-identical** to that commit's committed
   interface — one trailing newline the metadata fetch adds:
   ```bash
   icp canister metadata backend candid:service -e ic > /tmp/deployed.did
   git show 468687e:src/backend/dist/backend.did | diff - /tmp/deployed.did
   ```
2. Rebuilding that commit on the operator's own machine reproduces the module hash
   **exactly**.

**But the pinned container build of the same commit produces different bytes:**

| build of `468687e` | `backend.wasm` sha256 |
|---|---|
| deployed, per `icp canister status` | `6cc46209e627d1d5…` |
| **native**, on the operator's host | `6cc46209e627d1d5…` — match |
| **container**, per `RELEASE.md` | `c91b4cfe110d65a7…` — differs |

**The cause is the toolchain, not the code.** `moc` agrees on both sides (1.16.0, pinned
by the committed `mops.toml`). The tools *around* it do not:

| | host, which built the deployed wasm | `Dockerfile.release` |
|---|---|---|
| `icp` | 1.3.0 | 0.3.2 |
| `ic-wasm` | 0.9.10 | 0.9.11 |

`ic-wasm` shrinks the module and embeds its metadata, so a version difference there
changes the bytes. The deployed wasm is therefore reproducible **only** on a host
carrying those versions — which is not a property anyone else can rely on.

⚠️ **This exposes a defect in the five-step procedure itself, and it is not this
document's to fix.** Step 2 builds in the container; **step 4 (`icp deploy --mode
upgrade`) rebuilds on the host**. Unless the host's toolchain matches the container's,
step 5's gate cannot pass — so the procedure needs one decision (which bytes are
canonical, and how the container's artifact reaches the canister) before it can gate
anything. Filed separately.

⚠️ **And until this PR the procedure could not run at all.** `scripts/release-build.sh`
called a bare `icp build`, which builds every canister in the **local** environment —
including the `xrc` mock, whose wasm is a fetched, gitignored artifact absent from the
`git archive` context the whole script is built on. Every container build failed with
`failed to read wasm file`, on every commit. That is why
[`docs/SANDBOX-TESTPLAN.md`](./SANDBOX-TESTPLAN.md) could say the gate had never run
against a deployment: it could not run. Fixed by naming the two release canisters.

**What does hold now:** the container build is **deterministic**. Two independent runs of
the same ref produced identical hashes for all three artifacts.

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

**Frontend responses are certified per response**, and there is no uncertified raw mode
to switch off — see [`RELEASE.md`](../RELEASE.md).

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
