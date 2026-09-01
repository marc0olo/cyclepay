#!/usr/bin/env python3
"""Re-run the deleted-mechanism sweep from the term list, and diff against the recorded counts.

    scripts/sweep-vocabulary.py            # counts + drift against the table
    scripts/sweep-vocabulary.py --hits     # also print every hit, for adjudication

⚠️ **Not a gate step, deliberately** — most hits are correct prose (`mint` is the Cycles
Minting Canister; "nothing is ever evicted" is an end-state statement), and a check that
fires on correct code teaches people to ignore it. This is a tool you run when sweeping.

⚠️ **This script is the source of truth for the counts; the table is a dated snapshot.**
The table used to say "update them when you sweep" — a rule requiring memory, which is
precisely what the artifact exists to remove. A stale count reads exactly like a measured
one, which is this project's most-repeated failure class. So the numbers in the file are
for *diffing*, and this command is what produces them.

The term list is read FROM `docs/agents/deleted-vocabulary.md`, so there is one list, not
two.
"""

import glob
import re
import sys

TABLE = "docs/agents/deleted-vocabulary.md"


def files():
    """The corpus a sweep adjudicates.

    ⚠️ **`TABLE` itself is excluded, and the first run of this script is why.** Every term
    appears in the table by construction, so including it made five counts drift the moment
    the file existed — a self-reference that reads exactly like a real new hit. Excluding
    the file that lists the terms is not an exemption; it is the difference between counting
    the corpus and counting the question.
    """
    out = glob.glob("src/backend/*.mo") + glob.glob("src/frontend/src/*.ts")
    out += ["RUNBOOK.md", "AGENTS.md", "README.md"] + glob.glob("docs/*.md")
    return [f for f in out if "/bindings/" not in f and f != TABLE]


def terms():
    """Rows look like: | `term` | 12 | disposition |"""
    rows = []
    for line in open(TABLE):
        m = re.match(r"\|\s*`([^`]+)`\s*\|\s*(\d+)\s*\|", line)
        if m:
            rows.append((m.group(1), int(m.group(2))))
    return rows


def main() -> int:
    rows = terms()
    if not rows:
        sys.exit(f"ABORT: parsed no term rows out of {TABLE} — the sweep would cover nothing")
    show_hits = "--hits" in sys.argv
    corpus = {f: open(f, errors="replace").read().split("\n") for f in files()}
    drift = []
    print(f"{'term':<24}{'now':>5}{'was':>6}   {'':<4}")
    for term, recorded in rows:
        try:
            rx = re.compile(term, re.I)
        except re.error as e:
            print(f"  {term:<24}  ⚠️ not a valid regex: {e}")
            continue
        hits = [
            (f, i, l.strip())
            for f, lines in corpus.items()
            for i, l in enumerate(lines, 1)
            if rx.search(l)
        ]
        flag = "" if len(hits) == recorded else ("  ↑ NEW" if len(hits) > recorded else "  ↓")
        if flag:
            drift.append((term, recorded, len(hits)))
        print(f"`{term}`".ljust(24) + f"{len(hits):>5}{recorded:>6}{flag}")
        if show_hits:
            for f, i, l in hits:
                print(f"      {f}:{i}  {l[:100]}")

    if drift:
        print("\n\033[33m⚠️ counts moved — adjudicate each new hit, then update the table:\033[0m")
        for term, was, now in drift:
            print(f"    `{term}`: {was} → {now}")
        print(
            "\n  A count going UP is the case to read: ask whether the term is cited as the\n"
            "  JUSTIFICATION for unrelated behaviour, which is what a usage-aimed grep misses."
        )
    else:
        print("\n   every term matches its recorded count")
    return 0


if __name__ == "__main__":
    sys.exit(main())
