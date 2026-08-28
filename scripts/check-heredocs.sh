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
# ⚠️ **What it does NOT catch — and the bigger gap is the first incident above.** That one
# was an ad-hoc heredoc typed into a command that never became a file, so nothing scanning
# `git ls-files` can ever see it. This gate covers heredocs **in committed scripts** only;
# for one typed at a prompt the #12 rule still applies, and still has to be remembered.
#
# ⚠️ Also not caught, and it is a REAL hazard rather than an oversight: a dollar amount in
# an unquoted body. `$100 ceiling` expands to `00 ceiling` — silently, with no error, in a
# repo whose operator prose is full of prices. It is excluded because unquoted heredocs are
# also used legitimately to interpolate (`local-dev-seed.sh` prints a gateway port that
# way), so flagging every dollar sign would fire on correct code. If a dollar amount ever
# needs to appear in an unquoted body, escape it `\$100` or move the line out.
#
# Also not caught: a body that is clean today and gains a backtick later — caught on *that*
# change rather than this one, which is why it runs every time.
set -euo pipefail
cd "$(dirname "$0")/.."

found=0
scanned=0
while IFS= read -r f; do
  scanned=$((scanned + 1))
  # Track heredoc bodies with awk: remember the tag when an UNQUOTED `<<TAG` opens one,
  # close on a line equal to the tag, and report ` or $( seen in between.
  hits="$(
    awk '
      # ⚠️ Skip COMMENT lines when looking for an opener. The checker flagged its own
      # prose on its first run — a comment describing `cat <<NOTES` is not an opener, and a
      # detector that cannot survive being documented is not finished.
      !open && /^[ \t]*#/ { next }
      # An unquoted heredoc opener: <<TAG or <<-TAG, but not <<"TAG" / <<'"'"'TAG'"'"'.
      # An unquoted opener: <<TAG, <<-TAG, and ALSO << TAG with whitespace, which bash
      # allows and which cat << EOF style uses. Requiring a letter adjacent to the
      # operator missed it: a reviewer built the four forms and the space form executed
      # a command in a body whose prose only named it.
      #
      # A quoted tag never opens a scan, by the same test rather than a separate one: a
      # quote is not [A-Za-z_]. That is correct, because a quoted body is literal text.
      !open && /<<-?[ \t]*[A-Za-z_]/ {
        tag = $0
        sub(/.*<<-?/, "", tag)
        # ⚠️ Strip the whitespace FIRST. Without this, << TAG extracts " TAG", the next
        # sub() cuts from the leading space, the tag comes back empty, and the opener is
        # silently dropped — so widening the opener regex alone did not fix the space form.
        # The regex and the extraction have to agree about what a tag may look like.
        sub(/^[ \t]+/, "", tag)
        sub(/[^A-Za-z_0-9].*/, "", tag)
        if (tag != "") { open = 1; next }
      }
      open && $0 ~ ("^[ \t]*" tag "[ \t]*$") { open = 0; next }
      # ⚠️ **Execution only — deliberately NOT bare dollar-expansion.** Widening this to
      # catch a dollar-name was tried and reverted: it flagged local-dev-seed.sh, which
      # interpolates a gateway port into its closing notes **on purpose**. A check that
      # fires on correct code teaches people to ignore it, which is worse than a limit
      # written down. So the limit is written down instead — see the header.
      open && (/`/ || /\$\(/) { printf "  %s:%d: %s\n", FILENAME, FNR, $0 }
    ' "$f"
  )"
  if [ -n "$hits" ]; then
    found=1
    printf '%s\n' "$hits"
  fi
done < <(git ls-files 'scripts/*.sh' '*.sh')

# ⚠️ **Fail on zero files, because a detector that reports success without looking is the
# exact class it exists to prevent.** A `git ls-files` failure — no git, a pathspec typo,
# running from an export — happens inside the process substitution feeding the loop, where
# `set -euo pipefail` cannot see it, and this would print its green tick having examined
# nothing. Found by a reviewer whose first run landed outside a repo.
if [ "$scanned" -eq 0 ]; then
  echo "✗ scanned 0 files — git ls-files found nothing. Not a pass." >&2
  exit 2
fi

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
