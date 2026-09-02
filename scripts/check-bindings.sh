#!/usr/bin/env bash
# The committed Candid bindings match the canister's own interface.
#
# ⚠️ **Why the bindings are committed rather than generated on demand.** The integration
# CI job installs only `test/integration` deps and never runs `mops build` — so it
# typechecks against whatever is in the checkout. Generating at test time would need the
# Motoko toolchain in that job; committing means a fresh checkout can typecheck and run,
# and an interface change shows up in a pull-request diff instead of only at runtime.
#
# ⚠️ **The cost of committing generated code is that it rots silently, which is what this
# check exists for.** Same pattern the gate already applies one layer down to
# `src/backend/dist/backend.did` — regenerate, diff, fail on drift.
#
# ⚠️ **Why generated at all.** `test/integration/src/idl.ts` used to hand-transcribe 555
# lines of `IDL.Func` declarations, and `types.ts` 42 TypeScript mirrors, with nothing
# checking either against the Motoko. The drift was real: `GateReason` still carried
# `burnCapExhausted` and `floatLow` after #36 deleted the treasury path, and was missing
# `reserveShort` entirely — so a reserve-short refusal was undecodable from the suite and
# therefore untestable, found only because #61 needed to test that exact refusal.
#
# ⚠️ **And a mirror fails ASYMMETRICALLY, which is why no test caught it.** Declaring a
# field the canister lacks breaks the Candid decode and gets found. *Omitting* one decodes
# fine and the suite silently covers less than it claims.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

DID="src/backend/dist/backend.did"
OUT="test/integration/src/generated"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$DID" ] || {
  echo "✗ $DID is missing — run \`mops build\` first" >&2
  exit 1
}

# ⚠️ `--prefix test/integration`, not the frontend's copy. `@icp-sdk/bindgen` is a
# devDependency of the suite precisely so this works in the integration CI job, which does
# not install the frontend. Reaching for the frontend's node_modules would pass locally and
# fail there — the exact defect that shipped in a sibling project because `npx` resolved a
# global install.
npx --prefix test/integration icp-bindgen \
  --did-file "$DID" --out-dir "$TMP" --actor-disabled >/dev/null

STALE=""
for f in declarations/backend.did.js declarations/backend.did.d.ts; do
  if ! diff -q "$OUT/$f" "$TMP/$f" >/dev/null 2>&1; then
    STALE="$STALE $f"
  fi
done

if [ -n "$STALE" ]; then
  printf '\n\033[31m✗ %s is stale:%s\033[0m\n' "$OUT" "$STALE" >&2
  for f in $STALE; do
    printf '\n--- %s ---\n' "$f" >&2
    diff -u "$OUT/$f" "$TMP/$f" | head -40 >&2
  done
  printf '\n  Regenerate and commit:\n    npm --prefix test/integration run bindings\n' >&2
  exit 1
fi
printf '   bindings match the canister (2 files)\n'
