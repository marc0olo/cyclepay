#!/usr/bin/env python3
"""Keep the ⚠️ marker rare: no marker in a test name, and the population may only fall.

The marker means **stop: doing the obvious thing here breaks something you will not
notice**. That only works while it is rare, and the two failure modes are not
symmetrical -- an unread warning on the money path costs more than a missing one, because
its presence is what a reviewer trusts. At 2,164 across 139 files it marked nothing.

Whether a given marker earns its glyph is a judgement no regex makes: *can the next
editor act on this the wrong way?* **"Do not add a force flag to `refresh_reserve`"**
earns it, **"this count going LOW is the oversell direction"** does not. `AGENTS.md`
carries that rule. This file owns only the two things a check can own.

## 1. Never in a test, suite, describe or it NAME

Fully decidable, and 183 instances existed. The name already states the property the test
defends; the glyph adds nothing to it and prints on every run, in every runner's output,
where it is decoration rather than a warning to an editor.

## 2. The population may only FALL

`MARKER_CEILING` is the tree-wide total and the check fails on any disagreement. Adding a
genuine new trap is a one-line edit here, with the reason in the commit -- which is the
point: the count cannot move quietly in either direction, and every cleanup pass ratchets
it down visibly in the diff. `PUBLISHED_CEILING` does the same for the markers that reach
API callers through the generated `.did` (see below). Same mechanism as
`check-issue-refs.py`'s exemption audit: make the thing shrink-only rather than trusting
a convention.

⚠️ **A per-block cap was tried here and REMOVED, because it claimed a guarantee it did
not deliver.** It counted markers in contiguous comment-line runs, and measured against
this tree:

  - a blank line between them defeated it, changing nothing a reader experiences;
  - trailing comments on code lines were never counted at all;
  - it saw 97% of markers in code, 60% in shell and Python, and **4% in Markdown** --
    so `RUNBOOK.md`, the file where a false warning costs an operator the most, sat
    almost entirely outside it.

A ceiling has none of those properties: it counts every shape, in every file type, and
cannot be satisfied by reformatting.

## What about the markers PUBLISHED into the .did?

Endpoint `///` docs are copied into `src/backend/dist/backend.did` and from there into the
generated TypeScript, so a marker there reaches whoever calls the API. Whether that is
right depends on who the warning is addressed to: *"uncertified query answers, and
nothing may be wired to decide on them"* belongs in the published doc, and *"declared
inside the mixin body, not above it"* is addressed to the next editor of this repo and
delivered to someone who cannot act on it. No regex separates those, so the rule here is
only the ratchet -- the count may fall, never rise.
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
# ⚠️ **Exempt from the NAME rule only, because the shapes it forbids are its own test
# vectors.** Its markers still count toward the ceiling, so the number this prints is the
# whole tree's and matches what any other tool counting the tree will get. Audited in
# `main()`: the exemption fails if this file stops carrying a vector.
NAME_EXEMPT_FILES = ("scripts/check-markers.py",)

# ⚠️ **These may only ever FALL.** Raising one is a deliberate edit whose reason belongs
# in the commit message; if you are lowering one, you are doing the intended thing.
MARKER_CEILING = 1810
PUBLISHED_CEILING = 40

# A marker inside the STRING argument of a test declaration. Deliberately not anchored to
# the line start: `test.skip(`, `it.each(` and an indented call all have to match.
IN_NAME = re.compile(r"\b(?:test|suite|describe|it)\b[\w.]*\s*\(\s*[\"'`][^\"'`]*" + MARKER)


def names_in(text: str):
    return [
        (n, line.strip())
        for n, line in enumerate(text.split("\n"), 1)
        if IN_NAME.search(line)
    ]


def _self_test() -> None:
    # A marker in a test name, however the call is spelled.
    assert names_in('test("⚠️ the pay note cannot outlive the pay button", async () => {')
    assert names_in('  suite("⚠️ divisor 1 is byte-identical", func() {')
    assert names_in("describe('⚠️ real vs crafted', () => {")
    assert names_in('test.skip("⚠️ pending", () => {})')
    # ...and NOT a marker in the body, which is where it belongs.
    assert not names_in('test("the pay note", () => {\n  // ⚠️ By id, not by position\n')
    assert not names_in("// ⚠️ **A test name is not the place**, but this line is fine")
    # The ceilings are counts, not thresholds with slack: an exact-match check is what
    # makes the ratchet visible in a diff.
    assert isinstance(MARKER_CEILING, int) and isinstance(PUBLISHED_CEILING, int)


def main() -> int:
    _self_test()
    files = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "--cached"],
        capture_output=True, text=True, check=True,
    ).stdout.split()

    scanned = 0
    total = 0
    in_names = []
    for path in files:
        if path.startswith(GENERATED) or path.endswith(SKIP_SUFFIXES):
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError, PermissionError):
            continue
        scanned += 1
        total += text.count(MARKER)
        if path in NAME_EXEMPT_FILES:
            continue
        for n, line in names_in(text):
            in_names.append((path, n, line))

    try:
        published = open(DID, encoding="utf-8").read().count(MARKER)
    except FileNotFoundError:
        print(f"   check-markers: {DID} is missing -- run `mops build`.", file=sys.stderr)
        return 1

    # ⚠️ An exemption must die with its reason. The only signal this one has is that the
    # exempt file no longer carries the shape it was exempted for.
    for path in NAME_EXEMPT_FILES:
        try:
            text = open(path, encoding="utf-8").read()
        except (FileNotFoundError, IsADirectoryError, PermissionError):
            print(
                f"   check-markers: exempt file {path} is missing -- delete the"
                " exemption.",
                file=sys.stderr,
            )
            return 1
        if not names_in(text):
            print(
                f"   check-markers: {path} is exempt from the name rule but carries no"
                " test-name vector -- delete the exemption rather than leaving a hole.",
                file=sys.stderr,
            )
            return 1

    # ⚠️ Vacuity floor. This check's steady state is green, so "no findings" has to be
    # backed by evidence that it looked.
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
    for label, got, ceiling, const in (
        ("markers in the tree", total, MARKER_CEILING, "MARKER_CEILING"),
        (f"markers published in {DID}", published, PUBLISHED_CEILING, "PUBLISHED_CEILING"),
    ):
        if got > ceiling:
            failed = True
            print(
                f"\n   {got} {label}, ceiling {ceiling}. A marker was ADDED: it has to be"
                f"\n   a trap the next editor can act on wrongly, and then {const} moves"
                f"\n   to {got} in this commit with the reason in the message.",
                file=sys.stderr,
            )
        elif got < ceiling:
            failed = True
            print(
                f"\n   {got} {label}, ceiling {ceiling} — the population FELL, which is"
                f"\n   the intended direction. Ratchet it: set {const} = {got}.",
                file=sys.stderr,
            )
    if failed:
        return 1

    print(
        f"   {total} markers across {scanned} files, {published} of them published in the"
        " .did: at the ceiling, none in a test name"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
