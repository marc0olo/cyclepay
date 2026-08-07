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

# --- banned characters -------------------------------------------------------
# U+2014 EM DASH: the guidelines name a colon, period, or parentheses instead.
hits="$( { grep -n '—' "$FE/index.html"; literals | grep '—'; } 2>/dev/null )"
[ -n "$hits" ] && report "em-dash (U+2014) in user-facing copy (use a colon, period, or parentheses)" "$hits"

# Emoji and pictographs. ⚠ and ✓ count: they render as emoji on most platforms,
# and the voice is meant to be calm and factual rather than decorated.
PICTO='[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}]'
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
