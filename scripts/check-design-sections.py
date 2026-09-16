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

⚠️ **That last premise is ENFORCED rather than assumed.** A `§N` preceded by a document
name — `RUNBOOK §1` in a comment — would otherwise read as a citation of `DESIGN §1`, and
the "glossed but not cited" arm would pass over a section nothing in the code references.
So a document-scoped `§N` is refused: the glyph in code means a design section or it fails
here.
"""

import glob
import os
import re
import sys

SPEC = "docs/DESIGN.md"
CODE_GLOBS = ("src/backend/*.mo", "src/backend/mixins/*.mo", "test/*.mo")
SECTION = re.compile(r"§([0-9][0-9a-z]*(?:\.[0-9a-z]+)*)")
# ⚠️ An issue's OWN sections must be written `#NN §2c`, never bare: the `#NN ` prefix is
# the disambiguator, because a bare `§2c` is indistinguishable from a design section and
# this check will demand one. (Nothing in the tree carries one today; the pattern stays so
# that writing one is not a failure.)
ISSUE_SCOPED = re.compile(r"#[0-9]+\s+§[0-9]")
# ⚠️ A `§N` in code must mean a DESIGN section. `RUNBOOK §1` in a comment was read as a
# citation of DESIGN §1 and kept a dead row alive; refer to another document's sections
# by NAME in code, never by glyph.
FOREIGN_SCOPED = re.compile(r"(RUNBOOK|STRIPE|OPERATE|TEST-COVERAGE|SANDBOX-TESTPLAN|VERIFY|RELEASE|ARCHITECTURE)[^§]{0,12}§[0-9]")


FOREIGN = []


def cited():
    out = {}
    for pat in CODE_GLOBS:
        for f in glob.glob(pat):
            for i, line in enumerate(open(f, errors="replace"), 1):
                for m in SECTION.finditer(line):
                    before = line[max(0, m.start() - 8):m.end()]
                    if ISSUE_SCOPED.search(before):
                        continue
                    # A citation of ANOTHER document's section, which this check would
                    # otherwise bank as a DESIGN citation. Reported, never counted.
                    if FOREIGN_SCOPED.search(line[max(0, m.start() - 40):m.end()]):
                        FOREIGN.append(f"{f}:{i}: {line.strip()[:90]}")
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
            # ⚠️ A cited CHILD covers its ancestors. `§6` documents `§6.0`/`§6.1` and is
            # cited only through them — before this, the arm below called it dead, and
            # the only thing hiding that was a `RUNBOOK §6` in a test being miscounted.
            parts = owner.split(".")
            while parts:
                covered.add(".".join(parts))
                parts.pop()
    for sec in sorted(set(rows) - covered):
        fail.append(
            f"§{sec} is a section in {SPEC} that nothing cites — delete it, or"
            " the file grows back into the 697-line spec it replaced"
        )
    # ⚠️ A refusal, not a warning. `RUNBOOK §1` in a comment was counted as a citation
    # of DESIGN §1 and kept a dead row alive for as long as it stood.
    for hit in FOREIGN:
        fail.append(
            f"{hit}\n        ^ a §N citing ANOTHER document. In code the glyph means a"
            f" {SPEC} section; name that document's section in words instead"
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
