#!/usr/bin/env bash
# Check user-facing copy against the Internet Computer brand guidelines (v2.30).
#
# Only the rules that are mechanically checkable. Typography, hierarchy and the
# italic rule need eyes; banned characters and banned vocabulary do not, and those
# are precisely the ones that creep back in one commit at a time.
#
# Scope is deliberately narrow: index.html, and STRING LITERALS in the frontend
# sources. Code comments, docs and commit messages are not brand surfaces and are
# not checked — the em-dash rule in particular would otherwise fire on most of
# this repo's prose, which is written for engineers, not visitors.
set -uo pipefail

cd "$(dirname "$0")/.."
FE=src/frontend
fail=0

report() {
  fail=1
  printf '\n\033[31m✗ %s\033[0m\n' "$1"
  shift
  printf '%s\n' "$@" | sed 's/^/    /'
}

command -v perl >/dev/null 2>&1 || {
  echo "perl not found; it is required for the character checks" >&2
  exit 2
}

# Every user-facing string literal: double-quoted, single-quoted, AND template
# literals. Template literals were the gap that mattered — three em-dashes shipped
# inside `${...}` interpolations while this script reported clean, because it only
# looked at "double quotes".
#
# perl, not `grep -P`: BSD grep has no -P, and with stderr suppressed the failure
# was silent, so the emoji check simply passed everywhere it could not run.
read -r -d '' EXTRACT_LITERALS <<'PERL' || true
while ($line = <>) {
  $n++;
  while ($line =~ /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`/g) {
    print "$ARGV:$n:$&\n";
  }
  $n = 0 if eof;
}
PERL

literals() {
  perl -CSD -e "$EXTRACT_LITERALS" "$FE"/src/*.ts 2>/dev/null | grep -v '\.test\.ts:'
}

# --- canary: do the checks below actually work? -------------------------------
# A broken extractor or a regex that matches nothing reports CLEAN, and a clean
# report is indistinguishable from a passing one. That is the worst failure this
# script can have: every rule silently becomes a no-op and the gate stays green.
# It has happened twice already — `grep -P` missing on BSD with stderr suppressed,
# and template literals not being extracted at all — so the machinery is now
# checked before its findings are trusted.
canary() {
  fail=1
  printf '\n\033[31m✗ brand lint is not working: %s\033[0m\n' "$1" >&2
}

# `grep -c`, never `grep -q`, throughout the canaries: this script runs under
# `pipefail`, and `-q` exits on its first match, which SIGPIPEs the producer and
# makes the whole pipeline report failure. A canary that fires on success is worse
# than no canary.
[ -s "$FE/index.html" ] || canary "$FE/index.html is missing or empty, so every check against it looked at nothing"

LITERAL_COUNT="$(literals | wc -l | tr -d ' ')"
# An order of magnitude below the real count (~1000), so this fires on "the
# extractor is broken" and never on ordinary editing.
[ "${LITERAL_COUNT:-0}" -ge 100 ] ||
  canary "the extractor found only ${LITERAL_COUNT:-0} string literals in $FE/src/*.ts"

# Template literals specifically: they were the gap that mattered, because three
# em-dashes shipped inside `${...}` interpolations while this script reported clean.
TEMPLATE_COUNT="$(literals | grep -c '`' || true)"
[ "${TEMPLATE_COUNT:-0}" -gt 0 ] ||
  canary "the extractor found no template literals, which is where the last escape happened"

# And prove the character classes can see a planted violation. A locale problem
# makes these match nothing while still exiting 0.
EM_CANARY="$(printf 'x:1:"an em dash %s here"\n' "—" | grep -c '—' || true)"
[ "${EM_CANARY:-0}" -gt 0 ] || canary "the em-dash pattern does not match a line that contains one"

# --- banned characters -------------------------------------------------------
# U+2014 EM DASH: the guidelines name a colon, period, or parentheses instead.
hits="$( { grep -n '—' "$FE/index.html"; literals | grep '—'; } 2>/dev/null )"
[ -n "$hits" ] && report "em-dash (U+2014) in user-facing copy (use a colon, period, or parentheses)" "$hits"

# Emoji and pictographs. ⚠ and ✓ count: they render as emoji on most platforms,
# and the voice is meant to be calm and factual rather than decorated.
PICTO='[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}]'
# Canary for this class specifically: it is the one that silently passed
# everywhere it could not run.
PICTO_CANARY="$(printf 'x:1:"a rocket 🚀"\n' | perl -CSD -ne "print if /$PICTO/" | wc -l | tr -d ' ')"
[ "${PICTO_CANARY:-0}" -gt 0 ] ||
  canary "the pictograph class does not match a line that contains one (perl -CSD?)"
hits="$( { perl -CSD -ne "print qq(\$ARGV:\$.:\$_) if /$PICTO/" "$FE/index.html"; \
           literals | perl -CSD -ne "print if /$PICTO/"; } 2>/dev/null )"
[ -n "$hits" ] && report "emoji or pictograph in user-facing copy" "$hits"

# --- banned vocabulary -------------------------------------------------------
# Bare "on-chain"/"onchain" must be replaced by the app attribute it is standing
# in for (tamperproof, unstoppable, sovereign). The others have direct
# substitutions in the guidelines' table.
BANNED='on-chain|onchain|blockchain|decentrali[sz]ed|smart contract'
hits="$( { grep -nEi "$BANNED" "$FE/index.html"; literals | grep -Ei "$BANNED"; } 2>/dev/null )"
[ -n "$hits" ] && report "banned vocabulary (see the substitution table in the guidelines)" "$hits"

# CSS with /* comments */ stripped. Without this, a comment explaining one of
# these rules trips the rule it explains — which is exactly what happened the
# first time this script ran.
css_code() {
  perl -0777 -pe 's{/\*.*?\*/}{}gs' "$1" | grep -n '' | sed "s|^|$1:|"
}

# --- hardcoded colour --------------------------------------------------------
# Everything must come from tokens.css, which is the guidelines' own review rule
# and the only thing keeping the dark theme correct. #fff is the one exception:
# on a rust or near-black fill it is that fill's contrast pair, not a theme value.
hits="$(css_code "$FE/src/styles.css" \
  | grep -E '#[0-9a-fA-F]{3,8}\b|\b(rgba?|hsla?|oklch|color-mix)\(' \
  | grep -vE '#fff\b' || true)"
[ -n "$hits" ] && report "hardcoded colour in styles.css (add a token instead)" "$hits"

# --- the theme rule ----------------------------------------------------------
# Dark is opt-in via data-theme only. Auto-switching from the OS preference is
# explicitly forbidden, and a media query in the stylesheet is how it comes back.
hits="$( { css_code "$FE/src/styles.css"; css_code "$FE/src/tokens.css"; } | grep 'prefers-color-scheme' || true)"
[ -n "$hits" ] && report "prefers-color-scheme in CSS (dark is opt-in via data-theme, never automatic)" "$hits"

if [ "$fail" -eq 0 ]; then
  printf '\033[32m✓ brand lint passed\033[0m\n'
else
  printf '\n\033[31mbrand lint failed\033[0m\n' >&2
  exit 1
fi
