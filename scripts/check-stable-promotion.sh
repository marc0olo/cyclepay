#!/usr/bin/env bash
# Decide whether a `deployed/backend.most` promotion is REPRESENTATION-ONLY or a real
# shape change — before it is committed.
#
# ⚠️ **Why this exists.** A promotion resets the reference point the upgrade check
# compares against, so it is the one operation that can blind that check. The #90 hole
# was a baseline left stale; the mirror-image hole is a baseline promoted past a real
# change because the diff looked like noise. Both are invisible in a `git diff`.
#
# A compiler upgrade renumbers every type hash: moc 1.9.0 → 1.15.1 moved 91 lines of
# `deployed/backend.most` without changing one field. A real schema change lands in the
# same file, in the same shape of diff. Eyeballing cannot separate them; this can.
#
# The test is MUTUAL stable-compatibility. `moc --stable-compatible A B` asks "can a
# canister whose signature is A upgrade to B". Run both ways:
#
#   both pass  → the signatures are mutual subtypes, i.e. EQUIVALENT. The diff is pure
#                renumbering and the promotion carries no shape change.
#   only 1 → 2 → a real, upgrade-compatible change (a new stable field, a widened type).
#                Promote deliberately, and say in the commit what moved.
#   1 → 2 fails → the change is NOT upgrade-compatible. Promoting it strands every
#                deployed canister; that needs a migration chain (#32), not a promotion.
#
# Usage: scripts/check-stable-promotion.sh [canister]   (default: backend)
set -euo pipefail

canister="${1:-backend}"
baseline="deployed/${canister}.most"
built="src/backend/dist/${canister}.most"

[ -f "$baseline" ] || { echo "no committed baseline at $baseline — nothing to compare" >&2; exit 1; }
[ -f "$built" ] || { echo "no build output at $built — run \`mops build\` first" >&2; exit 1; }

moc="$(mops toolchain bin moc)"

if diff -q "$baseline" "$built" >/dev/null 2>&1; then
  printf '   %s: baseline already matches the build — nothing to promote\n' "$canister"
  exit 0
fi

changed=$(diff "$baseline" "$built" | grep -c '^[<>]' || true)

forward=0; "$moc" --stable-compatible "$baseline" "$built" >/dev/null 2>&1 || forward=$?
reverse=0; "$moc" --stable-compatible "$built" "$baseline" >/dev/null 2>&1 || reverse=$?

if [ "$forward" -ne 0 ]; then
  printf '\033[31m✗ %s: the built signature is NOT upgrade-compatible with the baseline\033[0m\n' "$canister" >&2
  "$moc" --stable-compatible "$baseline" "$built" 2>&1 | sed 's/^/    /' >&2
  printf '\n  A deployed canister cannot take this upgrade. This needs an explicit migration\n' >&2
  printf '  (see #32 and the `migrating-motoko-actors` skill), not a promotion.\n' >&2
  exit 1
fi

if [ "$reverse" -eq 0 ]; then
  printf '   %s: %s changed line(s), REPRESENTATION-ONLY\n' "$canister" "$changed"
  printf '   both directions of --stable-compatible pass, so the signatures are equivalent:\n'
  printf '   no field was added, removed or retyped. Safe to promote without review.\n'
else
  printf '\033[33m⚠️  %s: %s changed line(s), a REAL shape change (upgrade-compatible)\033[0m\n' "$canister" "$changed"
  printf '   Forward compatibility holds, so a deployed canister takes the upgrade — but the\n'
  printf '   signature genuinely moved. Name what moved in the commit message, and check it\n'
  printf '   is the change you meant:\n\n'
  diff "$baseline" "$built" | sed 's/^/     /'
fi
