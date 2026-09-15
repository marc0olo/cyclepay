# Changelog

Notable changes per release. A release is a tag plus the module hashes published with it
— see [`RELEASE.md`](RELEASE.md), whose procedure refuses to cut a version that has no
entry here.

⚠️ **Keep an entry to what CHANGED, plus anything a user of that build must know.** The
entry is published verbatim at the top of the release notes, above the module-hash table
and the reproduce-it-yourself commands the release script generates — so re-explaining the
product, the verification story or the standing limits makes the notes longer and says it
worse than the pages that own those. Link instead.

Versions are `MAJOR.MINOR.PATCH` with a pre-release suffix while this is not yet handling
real money.

## Unreleased

## 0.1.0-beta.1

First tagged release, and the first build whose module hashes are published. The gateway
was already running on mainnet in **simulation mode**, deployed untagged; this replaces
that module with one anyone can reproduce.

⚠️ **Simulation mode**, so cycles are scaled: `pricing_status().config.divisor` divides
what a purchase delivers, and buying requires an allow-listed principal. Cards are charged
in Stripe's sandbox.

What it is, how it works, what can be checked and what cannot: [`README.md`](README.md),
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/VERIFY.md`](docs/VERIFY.md).
