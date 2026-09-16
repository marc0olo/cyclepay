#!/usr/bin/env python3
"""Fail if a ⚠️ marker is in a place where it cannot be a warning.

The marker means **stop: doing the obvious thing here breaks something you will not
notice**. That only works while it is rare. At 2,164 of them across 139 files, a reader
skimming for the dangerous line finds every line marked, which is the same as none --
and the two failure modes are not symmetrical: an unread warning on the money path costs
more than a missing one, because its presence is what a reviewer trusts.

## What this enforces -- three shapes, none of them a judgement call

  1. **Not in a test, suite, describe or it NAME.** The name already states the property
     the test defends; the glyph adds nothing to it and prints on every run, in every
     runner's output, where it is decoration rather than a warning to an editor.
  2. **Not three-to-a-block.** One warning in a comment block is a warning. Three is the
     block's ordinary voice, and the reader has no way to tell which line is the trap.
     The bar is deliberately generous -- two is allowed, because a block can honestly
     hold two distinct traps (`Main.mo`'s quiet-window predicate does) -- so anything
     failing here is not a borderline call.
## And one it REPORTS without failing

Endpoint `///` docs are PUBLISHED: `mops build` copies them into
`src/backend/dist/backend.did` and from there into the generated TypeScript. So a marker
there reaches whoever calls the API, and whether that is right depends entirely on who
the warning is addressed to:

  - *"Uncertified query answers, and nothing may be wired to decide on them"* belongs in
    the published doc. A caller can act on it; an operator wiring a dashboard needs it.
  - *"Declared inside the mixin body, not above it"* does not. It is addressed to the
    next editor of this repo, and it is delivered to someone who cannot act on it at
    all. That trap belongs in a `//` beside the implementation.

⚠️ **No regex separates those two, so this is counted and listed, never failed on** --
the same arrangement as `sweep-vocabulary.py`'s adjudication step. Making it a failure
would push genuinely caller-facing warnings out of the one place a caller reads. The
count is printed so the population stays visible rather than growing quietly.

## What it does NOT enforce

Whether a given marker earns its glyph. The test is *"can the next editor act on this
the wrong way?"* -- **"Do not add a force flag to `refresh_reserve`"** earns it, **"this
count going LOW is the oversell direction"** does not, and no regex tells those apart.
`AGENTS.md` carries that rule; this file covers the part a check can own, so the review
attention goes to the part it cannot.
"""

import re
import subprocess
import sys

MARKER = "⚠"
DID = "src/backend/dist/backend.did"
GENERATED = (
    "src/backend/dist/",
    "test/integration/src/generated/",
    "src/frontend/src/bindings/",
)
SKIP_SUFFIXES = (".png", ".jpg", ".woff2", ".svg", ".ico", ".wasm", ".gz", ".most", ".lock")
# ⚠️ **This file, because the shapes it forbids ARE its self-test vectors.** Same
# arrangement as `check-issue-refs.py`, and audited the same way: `main()` fails if this
# file stops carrying a vector, so the exemption cannot outlive its reason. Sibling
# checkers do not get one -- a marker in a real test name here would be a finding.
EXEMPT_FILES = ("scripts/check-markers.py",)
# A marker inside the STRING argument of a test declaration. Deliberately not anchored to
# the line start: `test.skip(`, `it.each(` and an indented call all have to match.
IN_NAME = re.compile(r"\b(?:test|suite|describe|it)\b[\w.]*\s*\(\s*[\"'`][^\"'`]*" + MARKER)
COMMENT = re.compile(r"^\s*(?://|///|#)")
# Three in one block. Two is allowed on purpose -- see the docstring.
MAX_PER_BLOCK = 2


def names_in(text: str):
    return [
        (n, line.strip())
        for n, line in enumerate(text.split("\n"), 1)
        if IN_NAME.search(line)
    ]


def stacked_in(text: str):
    """Comment blocks carrying more than MAX_PER_BLOCK markers, as (line, count)."""
    out = []
    start = 0
    count = 0
    lines = 0
    for n, line in enumerate(text.split("\n"), 1):
        if COMMENT.match(line):
            if not lines:
                start = n
            lines += 1
            count += line.count(MARKER)
        else:
            if count > MAX_PER_BLOCK:
                out.append((start, count))
            start = count = lines = 0
    if count > MAX_PER_BLOCK:
        out.append((start, count))
    return out


def _self_test() -> None:
    # Rule 1: a marker in a test name, however the call is spelled.
    assert names_in('test("⚠️ the pay note cannot outlive the pay button", async () => {')
    assert names_in('  suite("⚠️ divisor 1 is byte-identical", func() {')
    assert names_in("describe('⚠️ real vs crafted', () => {")
    assert names_in('test.skip("⚠️ pending", () => {})')
    # ...and NOT a marker in the body, which is where it belongs.
    assert not names_in('test("the pay note", () => {\n  // ⚠️ By id, not by position\n')
    assert not names_in("// ⚠️ **A test name is not the place**, but this line is fine")
    # Rule 2: three in one block fails, two does not, and a blank line ends the block.
    three = "// ⚠️ a\n// ⚠️ b\n// ⚠️ c\nlet x = 1;\n"
    assert [c for _, c in stacked_in(three)] == [3]
    assert stacked_in("// ⚠️ a\n// ⚠️ b\nlet x = 1;\n") == []
    assert stacked_in("// ⚠️ a\n\n// ⚠️ b\n\n// ⚠️ c\n") == []
    # A marker twice on ONE line still counts twice -- the unit is the block, not the line.
    assert [c for _, c in stacked_in("// ⚠️ a ⚠️ b\n// ⚠️ c\nx\n")] == [3]
    assert MAX_PER_BLOCK == 2


def main() -> int:
    _self_test()
    files = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "--cached"],
        capture_output=True, text=True, check=True,
    ).stdout.split()

    scanned = 0
    total = 0
    in_names = []
    stacked = []
    for path in files:
        if path.startswith(GENERATED) or path.endswith(SKIP_SUFFIXES):
            continue
        if path in EXEMPT_FILES:
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError, PermissionError):
            continue
        scanned += 1
        total += text.count(MARKER)
        for n, line in names_in(text):
            in_names.append((path, n, line))
        for n, count in stacked_in(text):
            stacked.append((path, n, count))

    try:
        published = open(DID, encoding="utf-8").read().count(MARKER)
    except FileNotFoundError:
        print(f"   check-markers: {DID} is missing -- run `mops build`.", file=sys.stderr)
        return 1

    # ⚠️ An exemption must die with its reason. The only signal this one has is that the
    # exempt file no longer carries the shape it was exempted for.
    for path in EXEMPT_FILES:
        try:
            text = open(path, encoding="utf-8").read()
        except (FileNotFoundError, IsADirectoryError, PermissionError):
            print(
                f"   check-markers: exempt file {path} is missing -- delete the"
                " exemption.",
                file=sys.stderr,
            )
            return 1
        if not names_in(text) and not stacked_in(text):
            print(
                f"   check-markers: {path} is exempt but carries none of the shapes it"
                " was exempted for -- delete the exemption rather than leaving a hole.",
                file=sys.stderr,
            )
            return 1

    # ⚠️ Vacuity floor. This check's steady state is green, so "no findings" has to be
    # backed by evidence it looked: at the markers AND at the artifact rule 3 reads.
    if scanned < 100 or total == 0:
        print(
            f"   check-markers: {scanned} file(s) and {total} marker(s) -- refusing to"
            " report a clean scan over nothing.",
            file=sys.stderr,
        )
        return 1

    failed = False
    if in_names:
        failed = True
        print(f"   {len(in_names)} marker(s) inside a test name:", file=sys.stderr)
        for path, n, line in in_names[:20]:
            print(f"     {path}:{n}  {line[:96]}", file=sys.stderr)
        if len(in_names) > 20:
            print(f"     ... and {len(in_names) - 20} more", file=sys.stderr)
        print(
            "   The name states the property; drop the glyph from it. Keep it in the"
            " body if there is a trap there.",
            file=sys.stderr,
        )
    if stacked:
        failed = True
        print(
            f"\n   {len(stacked)} comment block(s) with more than {MAX_PER_BLOCK}"
            " markers:",
            file=sys.stderr,
        )
        for path, n, count in stacked[:20]:
            print(f"     {path}:{n}  {count} markers in one block", file=sys.stderr)
        if len(stacked) > 20:
            print(f"     ... and {len(stacked) - 20} more", file=sys.stderr)
        print(
            "   Keep the one the next editor can get wrong; the rest are explanation"
            " and keep their text.",
            file=sys.stderr,
        )
    if failed:
        return 1

    print(
        f"   {total} markers across {scanned} files: none in a test name, none stacked"
        f" past {MAX_PER_BLOCK}"
    )
    # Reported, never failed on -- see the docstring. Printed on stdout with the count so
    # a reader can see the population without the step going red over a judgement call.
    print(
        f"   {published} reach API callers via {DID} — each should be a warning a CALLER"
        " can act on, not a note to the next editor"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
