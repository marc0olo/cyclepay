#!/usr/bin/env bash
# Assert the canister's Candid SIGNATURES are unchanged against a git ref, ignoring doc
# comments.
#
# ⚠️ **Why signatures rather than the whole file.** A pure relocation of endpoints must
# not move the interface, and `git diff` on `backend.did` is the natural proof — until doc
# text moves independently of the API, at which point a byte diff can no longer tell "I
# relocated code" from "I changed the contract".
#
# ⚠️ **The original reason for that has REVERSED, and the check outlives it.** It was: moc
# did not emit doc comments for mixin members, so relocating an endpoint into a mixin
# deleted ~6 doc lines from the interface while changing nothing about it. **moc 1.16.0
# emits them**, so a relocation now carries its doc along and leaves the `.did` doc lines
# untouched. What still moves independently is an ordinary doc EDIT — now published, so it
# shows up in the interface diff — which is the same confusion from the other direction.
#
# So this strips `///` lines from both sides and compares what is left: method names,
# argument names and types, return types, and every type declaration. That is the part a
# caller is bound by.
#
# ⚠️ **Not a gate step, and it could not be one:** it compares against a ref you choose,
# which only the author of a refactor knows. Run it while relocating code, and quote the
# result in the PR — the way `check-stable-promotion.sh` is run at promotion time.
#
# Usage: scripts/check-did-signatures.sh [git-ref]     (default: merge-base with main)
set -euo pipefail

did="src/backend/dist/backend.did"
[ -f "$did" ] || { echo "no $did — run \`mops build\` first" >&2; exit 1; }

ref="${1:-$(git merge-base HEAD main)}"

# Doc comments out, blank lines out, trailing whitespace out. Nothing else is touched:
# reordering or rewrapping a signature is a real difference and must still show.
strip() { sed -e '/^[[:space:]]*\/\/\//d' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]*$//'; }

before="$(mktemp)"; after="$(mktemp)"
trap 'rm -f "$before" "$after"' EXIT

if ! git show "$ref:$did" 2>/dev/null | strip > "$before"; then
  echo "cannot read $did at $ref" >&2
  exit 1
fi
strip < "$did" > "$after"

before_n=$(grep -c '' "$before" || true)
after_n=$(grep -c '' "$after" || true)
if [ "$before_n" -eq 0 ] || [ "$after_n" -eq 0 ]; then
  echo "ABORT: stripped one side to nothing ($before_n vs $after_n lines) — cannot pass vacuously" >&2
  exit 1
fi

if diff -q "$before" "$after" >/dev/null; then
  printf '   candid signatures unchanged vs %s (%s lines, doc comments ignored)\n' \
    "$(git rev-parse --short "$ref")" "$after_n"
  exit 0
fi

printf '\033[33m⚠️  candid signatures CHANGED vs %s\033[0m\n' "$(git rev-parse --short "$ref")"
diff "$before" "$after" | sed 's/^/    /'
exit 1
