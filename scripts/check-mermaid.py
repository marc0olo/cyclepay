#!/usr/bin/env python3
"""Refuse the two mermaid label bugs that fail SILENTLY on GitHub.

⚠️ **Parsing is not the check.** Both bugs below parsed clean and rendered wrong, which is
why this is a lint over the source rather than a call to mermaid's parser. Found by
rendering the diagrams in Chromium and diffing the visible text against the source:

  `markPaid → #paid, paidIntents[intent] = orderId`   rendered as   `markPaid →`

1. **A bare `#` opens an HTML entity code and swallows the rest of the label.** Motoko
   variant tags are written `#paid`, so every diagram describing this system walks into
   it. Write `#35;paid`, which renders as `#paid`.
2. **A literal `;` ends the statement**, so the text after it becomes a syntax error or
   vanishes. Use a dash.

⚠️ **CSS colours are not this bug.** `classDef ours fill:#1b4965` is a colour, not a
label, so `classDef`/`style` lines are exempt — flagging them would make the check
unusable on any styled diagram.

⚠️ **What this does NOT cover.** A malformed diagram that fails to PARSE is loud — GitHub
prints "Unable to render rich display" where the picture should be — so it does not need a
gate step. This covers the class that renders as a confident, quietly incomplete picture.
"""

import re
import sys
from pathlib import Path

FILES = sorted(set(list(Path(".").glob("*.md")) + list(Path("docs").glob("*.md"))))
BLOCK = re.compile(r"```mermaid\n(.*?)```", re.S)
EXEMPT = re.compile(r"^\s*(classDef|style|linkStyle|%%)")
BARE_HASH = re.compile(r"#(?![0-9]+;)[A-Za-z]")


def hazards(block: str) -> list[tuple[int, str, str]]:
    out = []
    for i, line in enumerate(block.split("\n"), 1):
        if EXEMPT.match(line):
            continue
        if BARE_HASH.search(line):
            out.append((i, line.strip(), "a bare `#` swallows the rest of the label — write `#35;`"))
        # `;` that is not the terminator of an `#NN;` entity
        if re.search(r"(?<!#[0-9])(?<!#[0-9][0-9])(?<!#[0-9][0-9][0-9]);", line):
            out.append((i, line.strip(), "a literal `;` ends the statement — use a dash"))
    return out


def _self_test() -> None:
    """Unconditional: this is a regex over other people's prose, and a silently
    non-matching pattern turns the whole check into a green tick."""
    assert hazards("    BE->>BE: markPaid → #paid")
    assert hazards("    Note over BE: stays #35;paid; the sweep replays")
    assert not hazards("    BE->>BE: markPaid → #35;paid, paidIntents[intent] = orderId")
    assert not hazards("    classDef ours fill:#1b4965,stroke:#62b6cb,color:#fff")
    assert not hazards("    Created --> Paid: webhook, verified")
    # an entity followed by a slash parses badly, but that failure is LOUD; not our job
    assert not hazards("    Buyer->>FE: lands on the order page (success_url)")


def main() -> int:
    _self_test()
    blocks = 0
    bad: list[str] = []
    for f in FILES:
        src = f.read_text()
        for m in BLOCK.finditer(src):
            blocks += 1
            base = src[: m.start(1)].count("\n") + 1
            for line_no, text, why in hazards(m.group(1)):
                bad.append(f"{f}:{base + line_no - 1}: {why}\n      {text[:100]}")
    if blocks == 0:
        sys.exit("ABORT: found no mermaid blocks — this check cannot pass vacuously")
    if bad:
        print("\n\033[31m✗ a mermaid label will render wrong on GitHub\033[0m", file=sys.stderr)
        for b in bad:
            print(f"    {b}", file=sys.stderr)
        return 1
    print(f"   {blocks} mermaid diagram(s): no label loses text to an entity code")
    return 0


if __name__ == "__main__":
    sys.exit(main())
