#!/usr/bin/env python3
"""Every relative markdown link resolves — the file AND the `#anchor`.

⚠️ **The anchor half is the point.** A link to a file that moved is loud: GitHub 404s.
A link to a *section* that was renamed is silent — the page opens at the top and the
reader never learns they were sent somewhere specific. This repo has produced that class
repeatedly: pointers at `§10` for a checklist that was `§9`, at a "step 5" that renumbered,
and at a "commit identification above" that had been deleted.

⚠️ **What this does NOT do: notice a link that names a section without anchoring to it.**
Writing ``docs/OPERATE.md`` — Mode 1 sends the reader to the top of a 900-line file to go
hunting, and that is worth fixing — but detecting it needs to match prose against headings,
and the version attempted here was both too eager and too weak: it flagged the Key
documents table, where a row's description IS the file's title, and it missed the real
cases, where the prose says "Mode 1" and the heading is "Mode 1 — local". A check that
noisy would be turned off. Anchors are added by reading; this verifies the ones written.

GitHub's anchor rule lives in `scripts/_github_anchor.py` and is imported, not restated —
`release-notes.py` needs the same rule to link into `CHANGELOG.md` at a tag.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _github_anchor import anchor, self_test as anchor_self_test  # noqa: E402

FILES = sorted(set(list(Path(".").glob("*.md")) + list(Path("docs").glob("*.md"))))
LINK = re.compile(r"\[(?P<text>[^\]]*)\]\((?P<href>[^)\s]+)\)")
HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*$", re.M)
FENCE = re.compile(r"```.*?```", re.S)


def links_in(src: str):
    """(line, href) for every markdown link outside a fenced block.

    ⚠️ **Fences are SKIPPED BY POSITION, not stripped.** Two reasons, and both were bugs
    here. Searching a stripped copy for the matched text attributes every duplicate link
    to the first one's line — this README has the same link twice, so it sent the author
    to a line that was already correct. And matching line-by-line instead would drop a
    link whose TEXT wraps across a newline, of which this README has three, silently
    checking less than it claims.
    """
    fences = [(m.start(), m.end()) for m in FENCE.finditer(src)]
    for m in LINK.finditer(src):
        if any(a <= m.start() < b for a, b in fences):
            continue
        yield src.count("\n", 0, m.start()) + 1, m.group("href")


def anchors_of(path: Path) -> set[str]:
    return {anchor(h) for h in HEADING.findall(FENCE.sub("", path.read_text()))}


def _self_test() -> None:
    """Unconditional: the anchor rule is a transcription of GitHub's, and a wrong one
    would fail every link or none — both of which read as 'the check ran'."""
    anchor_self_test()
    # the same link twice must report two DIFFERENT lines, and a link whose text wraps
    # must still be seen at all
    sample = "[a](x.md#p)\nfiller\n[a](x.md#p)\n```\n[in](a-fence.md)\n```\n[wrapped\ntext](y.md#q)\n"
    got = list(links_in(sample))
    assert got == [(1, "x.md#p"), (3, "x.md#p"), (7, "y.md#q")], got


def main() -> int:
    _self_test()
    checked = 0
    bad: list[str] = []
    for f in FILES:
        for line, href in links_in(f.read_text()):
            if href.startswith(("http://", "https://", "mailto:")):
                continue
            file_part, _, frag = href.partition("#")
            target = f.parent / file_part if file_part else f
            if not target.exists():
                bad.append(f"{f}:{line}: link target missing — {href}")
                continue
            checked += 1
            if frag and frag not in anchors_of(target):
                bad.append(f"{f}:{line}: no such section in {file_part or f.name} — #{frag}")
    if checked == 0:
        sys.exit("ABORT: resolved no relative links — this check cannot pass vacuously")
    if bad:
        print("\n\033[31m✗ a documentation link does not land where it says\033[0m", file=sys.stderr)
        for b in bad:
            print(f"    {b}", file=sys.stderr)
        return 1
    print(f"   {checked} relative doc link(s): every file and every #anchor resolves")
    return 0


if __name__ == "__main__":
    sys.exit(main())
