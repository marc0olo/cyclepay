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
#      ours. ⚠️ **They HAVE now diverged** — upstream is pinned to moc 1.15.1 and this
#      project moved to 1.16.0 — which is why the run below rewrites the pin instead of
#      testing in place. Upstream is a frozen proof of concept; this project's compiler
#      moves, so the combination actually shipped here is tested nowhere else.
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

# ⚠️ **The suites must run under THIS project's compiler, not the submodule's.**
#
# Each vendored package is a self-contained mops project with its own `[toolchain] moc`,
# pinned at 1.15.1. Running `mops test` in place therefore verifies the port under *that*
# compiler while the backend compiles the same source under ours — so the moment the two
# diverge, this check silently stops covering the combination that ships, which is exactly
# the gap §7.3's acceptance depends on not existing. It went unnoticed for one commit
# during the 1.16.0 bump.
#
# `mops` has no flag or environment override for the compiler (`mops test --help`), so
# each package is copied to a temp directory with its pin rewritten to ours. The rewrite
# is VERIFIED below rather than assumed: a `sed` that silently matched nothing would put
# us straight back to testing the wrong compiler.
OURS="$(sed -nE 's/^moc = "([^"]+)"/\1/p' mops.toml | head -1)"
[ -n "$OURS" ] || fail "could not read the moc pin from mops.toml"

# ⚠️ **Nothing is copied. Each package is a directory of SYMLINKS into the submodule,
# plus one real `mops.toml` carrying our compiler pin.**
#
# The only file that has to differ is the toolchain pin, so that is the only file
# materialised — `src/`, `test/`, `bench/` and the vectors are linked, and the submodule's
# working tree is never touched. That also rules out the two alternatives: editing the
# submodule's own `mops.toml` in place mutates checked-out state and leaves it dirty if a
# run is interrupted, and duplicating the suites into `test/` would be a real, maintained
# copy of someone else's tests.
#
# ⚠️ **Both packages must be SIBLINGS in one root.** `vetkeys` declares
# `sealed-secrets-bls = "../bls12-381"`, a path relative to its own directory — a
# per-package root gives `package error [M0012], file "../bls12-381" does not exist`, and
# only for the second package, so it fails in a way that reads as package-specific.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SUB="$(pwd)/vendor/icp-seeding-secrets-poc/motoko"
for pkg in bls12-381 vetkeys; do
  mkdir -p "$WORK/$pkg"
  # `.mops` is deliberately NOT linked: a cache resolved under the old pin would defeat
  # the point of the rewrite. Everything else the build reads is linked, not duplicated.
  for entry in "$SUB/$pkg"/*; do
    name="$(basename "$entry")"
    [ "$name" = "mops.toml" ] && continue
    [ "$name" = ".mops" ] && continue
    ln -s "$entry" "$WORK/$pkg/$name"
  done
  # `vectors.json` is shared, one level up, and reached as `../vectors.json`.
  [ -e "$WORK/vectors.json" ] || ln -s "$SUB/vectors.json" "$WORK/vectors.json"
  cp "$SUB/$pkg/mops.toml" "$WORK/$pkg/mops.toml"
done

TOTAL=0
for pkg in bls12-381 vetkeys; do
  DIR="$WORK/$pkg"

  THEIRS="$(sed -nE 's/^moc = "([^"]+)"/\1/p' "$DIR/mops.toml" | head -1)"
  [ -n "$THEIRS" ] || fail "$pkg/mops.toml has no moc pin to rewrite"
  sed -i.bak -E "s/^moc = \"[^\"]+\"/moc = \"$OURS\"/" "$DIR/mops.toml"
  rm -f "$DIR/mops.toml.bak"
  NOW="$(sed -nE 's/^moc = "([^"]+)"/\1/p' "$DIR/mops.toml" | head -1)"
  [ "$NOW" = "$OURS" ] || fail "failed to rewrite $pkg's moc pin ($THEIRS -> $OURS, got $NOW)"

  ( cd "$DIR" && mops install ) >/dev/null 2>&1 || fail "mops install failed for $pkg under moc $OURS"

  OUT="$( ( cd "$DIR" && mops test ) 2>&1 )" || {
    printf '%s\n' "$OUT" >&2
    fail "crypto vectors FAILED in $pkg under moc $OURS — do not ship a secret through this"
  }
  # `mops test` prints "Done in Xs, passed N". Pull N out so the gate reports coverage
  # rather than a bare tick: a suite that silently stopped collecting tests would
  # otherwise pass here looking identical to one that ran.
  N="$(printf '%s' "$OUT" | sed -nE 's/.*passed ([0-9]+).*/\1/p' | tail -1)"
  [ -n "$N" ] && [ "$N" -gt 0 ] 2>/dev/null || fail "could not read a passing test count from $pkg"
  if [ "$THEIRS" = "$OURS" ]; then
    printf '   %-12s %3s vectors against the Rust reference (moc %s)\n' "$pkg" "$N" "$OURS"
  else
    printf '   %-12s %3s vectors against the Rust reference (moc %s, pinned %s upstream)\n' \
      "$pkg" "$N" "$OURS" "$THEIRS"
  fi
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
