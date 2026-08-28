#!/usr/bin/env bash
# Fail on an UNQUOTED heredoc whose body contains a command substitution.
#
# ⚠️ **Twice in three days, in two different substrates.** First, building Markdown for a
# GitHub issue body inside `<<PY` let the shell execute the backticks in the text and put a
# mangled 101k-char body live in place of 53k. Then, unquoting `<<NOTES` in
# `scripts/stripe-dev.sh` so one variable would interpolate activated three `…` spans that
# had been inert prose — `icp deploy` among them, so printing the closing notes would have
# RUN a deploy.
#
# The second one was introduced by the fix for a review finding whose entire subject was
# that written-down lessons do not transfer. The rule was already in #12 from the first
# incident. So it stops being a rule.
#
# ⚠️ **This belongs in the gate rather than the Traps section because its target is FIXED
# syntax**, unlike a vocabulary sweep whose target moves with every issue — the same test
# the outflow census passes. A fixed target can be enforced; a judgement call can only be
# surfaced.
#
# What it does NOT catch, stated so nobody trusts it further than it goes: an unquoted
# heredoc whose body is currently clean and gains a backtick later is caught on that
# change, not this one — which is the point of running it every time.
set -euo pipefail
cd "$(dirname "$0")/.."

found=0
while IFS= read -r f; do
  # Track heredoc bodies with awk: remember the tag when an UNQUOTED `<<TAG` opens one,
  # close on a line equal to the tag, and report ` or $( seen in between.
  hits="$(
    awk '
      # ⚠️ Skip COMMENT lines when looking for an opener. The checker flagged its own
      # prose on its first run — a comment describing `cat <<NOTES` is not an opener, and a
      # detector that cannot survive being documented is not finished.
      !open && /^[ \t]*#/ { next }
      # An unquoted heredoc opener: <<TAG or <<-TAG, but not <<"TAG" / <<'"'"'TAG'"'"'.
      !open && /<<-?[A-Za-z_]/ && !/<<-?["'"'"']/ {
        tag = $0
        sub(/.*<<-?/, "", tag)
        sub(/[^A-Za-z_0-9].*/, "", tag)
        if (tag != "") { open = 1; next }
      }
      open && $0 ~ ("^[ \t]*" tag "[ \t]*$") { open = 0; next }
      open && (/`/ || /\$\(/) { printf "  %s:%d: %s\n", FILENAME, FNR, $0 }
    ' "$f"
  )"
  if [ -n "$hits" ]; then
    found=1
    printf '%s\n' "$hits"
  fi
done < <(git ls-files 'scripts/*.sh' '*.sh')

if [ "$found" -ne 0 ]; then
  cat >&2 <<'WHY'

✗ an unquoted heredoc contains a command substitution — the shell will RUN it.

  Quote the tag (<<'TAG') so the body is literal text. If one line genuinely needs a
  variable, keep the heredoc quoted and print that line separately — escaping the
  backticks works today and re-breaks the next time someone writes prose with one.
WHY
  exit 1
fi
echo "✓ no unquoted heredoc runs its own body"
