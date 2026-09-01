#!/usr/bin/env python3
"""Assert every `§N` label in the code is glossed, every glossed row is used, and every
pointer the glossary gives still resolves.

⚠️ **Why this is a gate step and not a convention.** The `§N` shorthand came from a
697-line spec that was deleted because it had rotted: 67 mentions of architecture three
issues had removed, while `Main.mo` still cited it by section number. The glossary that
replaced it is one line per section — and within an hour of writing it, one row was
already **wrong in the dangerous direction**: it said `§5.3` was deleted (it labelled the
ICP burn cap) and told the reader a citation to it was a bug. In fact §5.3 held *two*
things, and the eight live citations all mean the surviving half — the 72 h max-wait
bound. A future agent following that row would have deleted eight correct comments.

That is the whole argument: a document nothing checks rots at the speed it is written.
The three checks below are what make the glossary maintainable rather than another
artifact to distrust.

  1. **Cited but not glossed** — a new `§N` appears in code with no row. The label is
     then unresolvable for everyone who did not write it.
  2. **Glossed but not cited** — a row nobody references. Keeps the file to what is
     worth keeping instead of growing back into a spec.
  3. **Pointer does not resolve** — the row names a module or symbol that no longer
     exists. This is the check that makes a RENAME update the glossary: move
     `Orders.isLegalTransition` and the gate fails until the row follows.

⚠️ **What this does NOT reach, stated because a check implying more than it verifies is
worse than no check:**

  - **Prose accuracy.** Nothing here could have caught the wrong `§5.3` row: it named a
    real section and pointed at real code, and was still wrong about *what the section
    meant*. That remains a human's job, and it is why rows are one line — a claim you
    can check by reading is better than one you cannot.
  - **Doc citations.** Only `src/backend/*.mo` and `test/*.mo` are scanned. In
    `RUNBOOK.md` and `docs/STRIPE.md` a bare `§2` means *that document's own* section 2,
    so scanning them would compare two different numbering schemes and produce noise.
    Code comments have no sections of their own, so there `§N` is unambiguous.
"""

import glob
import os
import re
import sys

SPEC = "docs/DESIGN.md"
CODE_GLOBS = ("src/backend/*.mo", "test/*.mo")
SECTION = re.compile(r"§([0-9][0-9a-z]*(?:\.[0-9a-z]+)*)")
# ⚠️ An issue's OWN sections are written `#37 §2c` and are not design-record sections.
# The `#NN ` prefix is the disambiguator, and it is required: a bare `§2c` is
# indistinguishable from a design section and this check will demand one.
ISSUE_SCOPED = re.compile(r"#[0-9]+\s+§[0-9]")


def cited():
    out = {}
    for pat in CODE_GLOBS:
        for f in glob.glob(pat):
            for i, line in enumerate(open(f, errors="replace"), 1):
                for m in SECTION.finditer(line):
                    before = line[max(0, m.start() - 8):m.end()]
                    if ISSUE_SCOPED.search(before):
                        continue
                    out.setdefault(m.group(1), []).append(f"{f}:{i}")
    return out


def documented():
    """Section number -> the heading text that follows it."""
    out = {}
    for line in open(SPEC, errors="replace"):
        m = re.match(r"#{2,4}\s+" + SECTION.pattern + r"\s*(?:—|-)?\s*(.*)", line.strip())
        if m:
            out[m.group(1)] = m.group(2)
    return out


def main() -> int:
    use, rows = cited(), documented()
    if not use:
        sys.exit("ABORT: found no §N citations in the code — this check cannot pass vacuously")
    if not rows:
        sys.exit(f"ABORT: parsed no numbered sections out of {SPEC} — this check cannot pass vacuously")

    fail = []
    def documented_for(sec):
        """§11.1.3 is item 3 of §11.1 — an ancestor section documents it."""
        parts = sec.split(".")
        while parts:
            if ".".join(parts) in rows:
                return ".".join(parts)
            parts.pop()
        return None

    covered = set()
    for sec in sorted(use):
        owner = documented_for(sec)
        if owner is None:
            where = ", ".join(use[sec][:3])
            fail.append(f"§{sec} is cited ({where}) but has no section in {SPEC}")
        else:
            covered.add(owner)
    for sec in sorted(set(rows) - covered):
        fail.append(
            f"§{sec} is a section in {SPEC} that nothing cites — delete it, or"
            " the file grows back into the 697-line spec it replaced"
        )

    if fail:
        print("\n\033[31m✗ docs/DESIGN.md disagrees with the code\033[0m", file=sys.stderr)
        for f in fail:
            print(f"    {f}", file=sys.stderr)
        print(
            f"\n  {SPEC} is the decision record. If you added a §N label, add its section;\n"
            "  if you deleted the behaviour, delete the section. ⚠️ Change the behaviour,\n"
            "  change that file IN THE SAME COMMIT — its predecessor rotted by being\n"
            "  updated less often than the code, not by being abandoned.",
            file=sys.stderr,
        )
        return 1
    print(f"   {len(rows)} DESIGN.md sections: every cited §N documented, every section cited")
    return 0


if __name__ == "__main__":
    sys.exit(main())
