# Changelog

Notable changes per release. A release is a tag plus the module hashes published with it
— see [`RELEASE.md`](RELEASE.md), whose procedure refuses to cut a version that has no
entry here.

Versions are `MAJOR.MINOR.PATCH` with a pre-release suffix while this is not yet handling
real money.

## Unreleased

## 0.1.0-beta.1

First tagged release. The gateway was already running on mainnet in **simulation mode**,
deployed untagged and with no published hash; this release replaces that module with one
whose bytes are published and reproducible.

**What it is.** Buy cycles with a credit card, on-chain: one Motoko backend canister and
one certified-assets frontend, no server. Cycles are sold from a reserve the canister
already holds, priced from the Exchange Rate Canister and the CMC with no outbound HTTPS
in the pricing path, and delivered by one `icrc1_transfer` to the buyer's cycles-ledger
account.

**Simulation mode.** `pricing_status().config.divisor` scales delivered cycles; `1` is
production. Cards are charged in Stripe's sandbox, and buying requires an allow-listed
principal, so a funded gateway cannot be drained by free test payments.

**Verifiability.** This is the first build published with module hashes.
`scripts/release.sh` builds in a digest-pinned container, installs that artifact, and
gates on the canister reporting the hash it built, so the published bytes and the running
bytes cannot drift apart. `scripts/check-frontend-assets.py` compares every asset the
frontend serves against a local build. Rebuild the tag and check both yourself —
[`docs/VERIFY.md`](docs/VERIFY.md) has the commands.

**Known limits, stated in `docs/VERIFY.md`:** any single controller can upgrade and drain;
the webhook secret is plaintext canister state protected by the confidential subnet; the
mops migration chain is not in place, so a stable-shape change still needs a reinstall.
