#!/usr/bin/env python3
"""Fail if a tracked file outside `docs/agents/` carries a bare `#NN` issue reference.

An issue number reads as a pointer to a live requirement and is a pointer to a closed
argument. Worse, it *defers* the work: whatever the number stood for was never written
down in terms of the code, so the next reader has to leave the repo to find out what the
line means -- and the issue, once closed, no longer says what is true.

⚠️ **Why this is a gate step and not a convention.** `AGENTS.md` carried the rule in
prose for one commit; this repo's own position on that arrangement is written into
`check-heredocs.sh` and `test-all.sh` -- *a rule that needs remembering is a rule that
gets skipped*. The sweep that removed 1,117 of these left three behind, and the three
shared one shape (`#NN` followed by a semicolon) that a hand-written scan pattern had
excluded to skip mermaid's `#35;` escape. A check does not have that blind spot twice.

## What is allowed, and the exceptions may only ever SHRINK

  - **`docs/agents/`** -- the agent loop's own record rather than product. Both files
    there exist to point at issues.
  - **A repo-qualified reference to an EXTERNAL tracker**: `dfinity/icp-js-core#1384`.
    This is the standing exception in the owner's instructions -- *"only include issues
    if they refer to some bugfix or feature that we rely on"* -- and the qualified form
    is what makes it checkable: it names a tracker a reader can reach, about code this
    repo does not own. `src/frontend/src/ic-env.ts` is the live instance: it cites the
    upstream issue as the source of a measured header claim and as where the real fix
    belongs.
  - **Mermaid's `#35;` escape**, inside a mermaid fence only. Outside one, `#NN;` is a
    reference -- that is the exact case this check exists for.
  - **`scripts/check-mermaid.py`**, one file, because the escape sequence IS its subject:
    every occurrence there is the literal `#35;` inside a message, a doc line or a
    self-test vector. The exemption is on the file and not on the number, since `#35` is
    also a real issue in this repo -- which is why it cannot be exempted globally.

## The digit bound is deliberate

Only `#1`-`#9999` is flagged, and the match must not be followed by a word character.
That is what separates a reference from a CSS hex colour (`#868078`), an HTML numeric
entity (`&#8599;`), and a Markdown heading anchor (`](#2-what-the-canister-calls)`).
A run of five or more digits is a colour, not an issue -- `_self_test` pins every one of
these shapes, so widening the bound has to be a deliberate edit that fails the test first.
"""

import re
import subprocess
import sys

EXEMPT_PREFIXES = ("docs/agents/", "vendor/")
# One file, named rather than pattern-matched, for the reason in the docstring.
EXEMPT_FILES = ("scripts/check-mermaid.py",)
SKIP_SUFFIXES = (
    ".png", ".jpg", ".woff2", ".svg", ".ico", ".wasm", ".gz", ".most", ".lock",
)
# A bare reference: `#` + 1-4 digits, not part of a longer alphanumeric run.
REF = re.compile(r"#(\d{1,4})(?!\w)")
# Qualified -- `owner/repo#NN` or `repo#NN`. Allowed: an external tracker.
QUALIFIED = re.compile(r"[\w.-]+(?:/[\w.-]+)?#\d{1,4}(?!\w)")
ANCHOR = re.compile(r"\]\(#")
FENCE = re.compile(r"^\s*```\s*(\w*)")
# 5+ digits is a colour or an entity, never an issue here. Kept as an explicit floor
# rather than folded into REF so the reason survives.
MAX_DIGITS = 4


def _spans(pattern, line):
    return [m.span() for m in pattern.finditer(line)]


def refs_in(text: str, mermaid_aware: bool):
    """Every bare reference, as (line number, line, token).

    Skips mermaid fences when `mermaid_aware`, because `#35;` is mermaid's escape for a
    literal `#`. Nothing else is skipped by content -- a reference inside a comment, a
    string or a test name is still a reference.
    """
    out = []
    in_mermaid = False
    for n, line in enumerate(text.split("\n"), 1):
        fence = FENCE.match(line)
        if fence:
            in_mermaid = fence.group(1) == "mermaid" and not in_mermaid
            continue
        if in_mermaid:
            continue
        qualified = _spans(QUALIFIED, line)
        anchors = _spans(ANCHOR, line)
        for m in REF.finditer(line):
            start = m.start()
            if any(a <= start < b for a, b in qualified):
                continue
            if any(b - 2 <= start < b for a, b in anchors):
                continue
            if start > 0 and line[start - 1] == "&":
                continue
            out.append((n, line.strip(), m.group(0)))
    return out


def _self_test() -> None:
    flagged = lambda s, md=False: [t for _, _, t in refs_in(s, md)]
    # The three the hand sweep missed: a reference followed by a semicolon.
    assert flagged("tracked on issue #171; they are deferred") == ["#171"]
    assert flagged("The copy left the canister in #123; the FACTS did not") == ["#123"]
    # Plain references, in prose and in a test name.
    assert flagged('suite("#61 refusal counters", func() {') == ["#61"]
    assert flagged("// #30 PR-A: the whole money-out path") == ["#30"]
    # NOT flagged: a CSS hex colour, an HTML entity, a Markdown heading anchor.
    assert flagged("/* darkened from #868078, measured */") == []
    assert flagged('the reserve account &#8599;</a>') == []
    assert flagged("- [2. What it cannot do](#2-what-it-cannot-do)") == []
    # NOT flagged: an external tracker, qualified. The ic-env.ts exception.
    assert flagged("The real fix belongs upstream: dfinity/icp-js-core#1384") == []
    assert flagged("tracked on icp-js-core#1384") == []
    # Mermaid's escape, inside a fence only.
    assert flagged("```mermaid\nA[#35;paid]\n```", md=True) == []
    assert flagged("A[#35;paid]", md=True) == ["#35"]
    # The digit bound, pinned so widening it is deliberate.
    assert MAX_DIGITS == 4 and flagged("#12345 is not an issue") == []


def main() -> int:
    _self_test()
    files = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, check=True
    ).stdout.split()
    scanned = 0
    findings = []
    for path in files:
        if path.startswith(EXEMPT_PREFIXES) or path.endswith(SKIP_SUFFIXES):
            continue
        if path in EXEMPT_FILES:
            continue
        if "-snapshots" in path:
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue
        scanned += 1
        for n, line, token in refs_in(text, mermaid_aware=path.endswith(".md")):
            findings.append((path, n, line, token))

    # ⚠️ Vacuity floor. A check that reports a clean scan over nothing is worse than no
    # check: this one's whole job is to be green, so "0 findings" has to be backed by
    # evidence that it looked. The floor is well under the real count (~250 files).
    if scanned < 100:
        print(
            f"   check-issue-refs: only {scanned} file(s) scanned -- refusing to report"
            " a clean scan. Is `git ls-files` working?",
            file=sys.stderr,
        )
        return 1

    if findings:
        print(
            f"   {len(findings)} bare issue reference(s) outside docs/agents/:",
            file=sys.stderr,
        )
        for path, n, line, token in findings:
            print(f"     {path}:{n}  {token}   {line[:100]}", file=sys.stderr)
        print(
            "\n   State the constraint in terms of the code as it is now, or drop the"
            "\n   line. An external tracker stays if it is qualified"
            " (`owner/repo#NN`).",
            file=sys.stderr,
        )
        return 1

    print(f"   {scanned} files scanned: no bare issue reference outside docs/agents/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
