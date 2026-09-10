#!/usr/bin/env bash
# The pinned BLS12-381 and vetKD packages match the audited Rust reference, under OUR
# toolchain.
#
# `src/backend/Sealed.mo` decrypts the Stripe secrets with an EXPERIMENTAL, UNAUDITED
# BLS12-381 port, pinned as a git submodule at `vendor/icp-seeding-secrets-poc`. No
# published Motoko package has the curve, so there is nothing to depend on instead. Its
# vectors were generated from `ic_bls12_381` and `ic-vetkeys` — the audited Rust
# implementations — so what they assert is not this port's arithmetic restated but values
# a reviewed implementation produced.
#
# ⚠️ **Why run them here when the source repository already does.** Two reasons, and the
# second is the one that matters:
#
#   1. `mops test` does not descend into path dependencies, so these suites execute in
#      this project only if something runs them explicitly. Nothing else does.
#   2. The upstream run proves the vectors under **that repository's** toolchain pins, not
#      ours. They happen to match today (moc 1.15.1, core 2.6.1) and will diverge, because
#      this project bumps `moc` and that one is a frozen proof of concept. From the first
#      bump onward, the combination actually shipped here is tested nowhere else.
#
# It is also what makes a submodule work at all: `mops` cannot address a package inside a
# repository subdirectory — measured, it silently DISCARDS the subdirectory and installs
# the repository root, which has no `src/`. Having the packages on disk is what lets their
# suites run in the same gate that guards the key they protect.
#
# ⚠️ **DO NOT SKIP OR DELETE THIS STEP TO GET A BUILD GREEN.** `docs/DESIGN.md` §7.3
# accepts an unaudited BLS12-381 on the money path, and that acceptance is conditional on
# this check running — not on the argument in the prose. A `moc` upgrade that makes the
# pinned packages fail to compile is the likely trigger: skipping their suites to move on
# quietly removes the only thing standing behind that decision, and nothing else reports it.
# Fix the compile, bump the pin, or reopen §7.3 — do not silence this.
#
# ⚠️ **What this does NOT establish.** These suites prove the port agrees with the
# reference on the vectors it ships. They are not an audit, they do not cover inputs the
# generator never produced, and passing here is not a statement that the implementation is
# constant-time or side-channel free. `docs/DESIGN.md` §7.3 carries the argument for why
# that is acceptable on THIS path — the audited `@icp-sdk/vetkeys` does the encrypting, so
# a bug here fails provisioning closed rather than weakening a ciphertext in flight.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

fail() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# A fresh clone without `--recurse-submodules` leaves these directories empty. Checked
# explicitly, because the alternative is a `mops` error about a missing package that says
# nothing about submodules.
for pkg in bls12-381 vetkeys; do
  [ -f "vendor/icp-seeding-secrets-poc/motoko/$pkg/mops.toml" ] || fail "vendor/icp-seeding-secrets-poc is not checked out — the crypto
is a git submodule.
    git submodule update --init --recursive"
done

# Read from the INDEX, not from HEAD: `HEAD:vendor/icp-seeding-secrets-poc` is unresolvable while the
# submodule is staged-but-uncommitted, which reported every pre-commit run as a mismatch.
PINNED="$(git ls-files -s vendor/icp-seeding-secrets-poc 2>/dev/null | awk '{print substr($2,1,7)}')"
[ -n "$PINNED" ] || PINNED='?' 
ACTUAL="$(git -C vendor/icp-seeding-secrets-poc rev-parse --short HEAD 2>/dev/null || echo '?')"
if [ "$PINNED" != "$ACTUAL" ]; then
  # Not fatal: a deliberate bump is a normal thing to be mid-way through. But the suites
  # below would then be testing something other than what the build will use.
  printf '\033[33m!\033[0m vendor/icp-seeding-secrets-poc is at %s, the commit pinned here is %s\n' "$ACTUAL" "$PINNED"
fi

TOTAL=0
for pkg in bls12-381 vetkeys; do
  DIR="vendor/icp-seeding-secrets-poc/motoko/$pkg"
  # Each package is a self-contained mops project with its own toolchain pins and its own
  # dev-dependencies, so it installs and tests independently of this one.
  ( cd "$DIR" && mops install ) >/dev/null 2>&1 || fail "mops install failed in $DIR"

  OUT="$( ( cd "$DIR" && mops test ) 2>&1 )" || {
    printf '%s\n' "$OUT" >&2
    fail "crypto vectors FAILED in $pkg — do not ship a secret through this"
  }
  # `mops test` prints "Done in Xs, passed N". Pull N out so the gate reports coverage
  # rather than a bare tick: a suite that silently stopped collecting tests would
  # otherwise pass here looking identical to one that ran.
  N="$(printf '%s' "$OUT" | sed -nE 's/.*passed ([0-9]+).*/\1/p' | tail -1)"
  [ -n "$N" ] && [ "$N" -gt 0 ] 2>/dev/null || fail "could not read a passing test count from $pkg"
  printf '   %-12s %3s vectors against the Rust reference\n' "$pkg" "$N"
  TOTAL=$((TOTAL + N))
done

# A floor, not an exact count, so adding vectors upstream does not fail the gate — but
# losing most of them does. 102 at the pinned commit.
#
# ⚠️ One variable, used by both the test and the message. Written as two literals, raising
# the floor left the failure text quoting the OLD number — caught by mutating it.
MIN_VECTORS=90
[ "$TOTAL" -ge "$MIN_VECTORS" ] \
  || fail "only $TOTAL vectors ran; expected at least $MIN_VECTORS. Has a suite stopped collecting?"
printf '   %d vectors total, pinned at %s\n' "$TOTAL" "$ACTUAL"
