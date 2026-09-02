#!/usr/bin/env python3
"""Scan the lines a change ADDS for vocabulary that names a deleted mechanism.

    scripts/sweep-vocabulary.py                  # added lines vs the merge base
    scripts/sweep-vocabulary.py --base <ref>     # against an explicit base

⚠️ **Scoped to the diff, and it keeps no counts.** A recorded population is a measurement,
and a measurement expires: it cannot tell "removed two legitimate uses, added one stale
claim" from "removed one", so a prose-purging change that also introduces a stale claim
nets downward and reads clean. That is a check whose negative result is indistinguishable
from a passing one — the class this whole artifact exists to catch. Added lines have no
such hole: a stale claim is a stale claim whatever else the change did.

⚠️ **It also removes the corpus question.** A count needs a population to count, so it
needs globs, and globs go stale silently — the version that kept counts covered 40 files
and missed `test/`, `src/backend/rails/` and `scripts/` entirely, which is where two stale
claims were added and reviewed past it. A diff has no population to enumerate: every added
line in the tree is in scope, wherever it lives.

⚠️ **It PRINTS; it does not fail on a hit.** Most hits are correct prose — this repo has
~20 lines that correctly say a removed mechanism is gone — and a check that fires on
correct code teaches people to route around it. Adjudication is a judgement call, and a
judgement call can only be surfaced. The one failure is an **undeterminable base ref**,
because that is the didn't-run case, which this project treats as failure everywhere.

⚠️ **An empty diff is a genuine pass, not an abort.** Other steps abort when they find
nothing to check, because for them empty input means the step is aimed at nothing. Here it
means the change added no lines, which is a real and correct answer.

The term list and its dispositions are read FROM `docs/agents/deleted-vocabulary.md`, so
there is one list, not two.
"""

import re
import subprocess
import sys

TABLE = "docs/agents/deleted-vocabulary.md"
BASE_CANDIDATES = ("origin/main", "main")


def git(*args):
    """Run git, returning (ok, stdout)."""
    p = subprocess.run(("git",) + args, capture_output=True, text=True)
    return p.returncode == 0, p.stdout


def terms():
    """Rows look like: | `term` | disposition |

    ⚠️ Aborts on an empty parse. A term list that silently came back empty would make this
    scan every added line against nothing and print a clean result.
    """
    rows = []
    for line in open(TABLE):
        m = re.match(r"\|\s*`([^`]+)`\s*\|\s*(?!-)(.+?)\s*\|?\s*$", line)
        if m:
            rows.append((m.group(1), m.group(2)))
    if not rows:
        sys.exit(f"ABORT: parsed no term rows out of {TABLE} — the scan would match nothing")
    return rows


def collisions():
    """Terms whose hits are almost always correct, from the table's own section.

    ⚠️ Returns an empty set if the section is renamed or emptied, which prints EVERY term
    in the main list. The failure direction is more prominence, not less.
    """
    out, inside = set(), False
    for line in open(TABLE):
        if line.startswith("## "):
            inside = line.strip() == "## Known-collision terms"
        elif inside:
            m = re.match(r"-\s*`([^`]+)`", line)
            if m:
                out.add(m.group(1))
    return out


def base():
    """The merge base to diff against, or exit non-zero naming why there is none."""
    if "--base" in sys.argv:
        i = sys.argv.index("--base") + 1
        if i >= len(sys.argv):
            sys.exit("ABORT: --base needs a ref after it")
        wanted = [sys.argv[i]]
    else:
        wanted = list(BASE_CANDIDATES)
    tried = []
    for ref in wanted:
        ok, out = git("merge-base", "HEAD", ref)
        if ok and out.strip():
            return out.strip(), ref
        tried.append(ref)
    sys.exit(
        "ABORT: no base ref to diff against (tried: "
        + ", ".join(tried)
        + ").\n  This is the DID-NOT-RUN case, so it fails rather than reporting a clean\n"
        "  scan. Pass --base <ref> explicitly, or fetch the default branch."
    )


def added_lines(base_sha):
    """(path, lineno, text) for every line this working tree adds over `base_sha`.

    ⚠️ Untracked files are included whole. They are absent from `git diff`, so a brand-new
    document would otherwise be scanned as zero added lines — invisible in exactly the way
    a wrong answer is not.
    """
    out = []
    ok, diff = git("diff", "--unified=0", "--no-color", base_sha, "--")
    if not ok:
        sys.exit(f"ABORT: could not diff against {base_sha}")
    path, lineno = None, 0
    for line in diff.split("\n"):
        if line.startswith("+++ b/"):
            path, lineno = line[6:], 0
        elif line.startswith("@@"):
            m = re.search(r"\+(\d+)", line)
            lineno = int(m.group(1)) if m else 0
        elif line.startswith("+") and path:
            out.append((path, lineno, line[1:]))
            lineno += 1
    ok, untracked = git("ls-files", "--others", "--exclude-standard")
    if ok:
        for path in untracked.strip().split("\n"):
            if not path:
                continue
            try:
                for i, text in enumerate(open(path, errors="replace").read().split("\n"), 1):
                    out.append((path, i, text))
            except (IsADirectoryError, PermissionError):
                continue
    return [(p, n, t) for p, n, t in out if p != TABLE]


def main() -> int:
    rows = terms()
    base_sha, base_name = base()
    lines = added_lines(base_sha)
    print(f"scanning {len(lines)} added lines against {len(rows)} terms (base: {base_name})")
    if not lines:
        print("   no added lines — nothing to scan, and that is a pass, not an abort")
        return 0

    known = collisions()
    total, deferred = 0, []
    for term, disposition in rows:
        try:
            rx = re.compile(term, re.I)
        except re.error as e:
            print(f"  ⚠️ `{term}` is not a valid regex: {e}")
            continue
        hits = [(p, n, t) for p, n, t in lines if rx.search(t)]
        if not hits:
            continue
        if term in known:
            deferred.append((term, disposition, hits))
            continue
        total += len(hits)
        print(f"\n\033[33m`{term}`\033[0m — {disposition}")
        for p, n, t in hits:
            print(f"    {p}:{n}  {t.strip()[:110]}")

    if deferred:
        n = sum(len(h) for _, _, h in deferred)
        print(f"\n  ── below the line: {n} hit(s) on live names, almost always correct ──")
        for term, disposition, hits in deferred:
            print(f"  `{term}` — {disposition}")
            for p, ln, t in hits:
                print(f"      {p}:{ln}  {t.strip()[:110]}")

    if total:
        print(
            f"\n\033[33m⚠️ {total} added line(s) name a deleted mechanism — adjudicate each.\033[0m\n"
            "  Many are still legitimate: an end-state statement, or the rule text quoting the\n"
            "  term. Live-name collisions are below the line, not here. What is NOT legitimate\n"
            "  is a\n"
            "  present-tense claim that the mechanism still exists, or a deleted mechanism\n"
            "  cited as the JUSTIFICATION for behaviour that now has a different reason.\n"
            "  This step does not fail on these; a reviewer decides."
        )
    elif deferred:
        # ⚠️ Reachable, not hypothetical: #82's diff hits `\bmint` and nothing else. Falling
        # to the line below would print "no added line names a deleted mechanism"
        # immediately under a list of printed hits, and this step's entire value is a
        # reader trusting that last line.
        print("   nothing above the line — only the live-name collisions listed above")
    else:
        print("   no added line names a deleted mechanism")
    return 0


if __name__ == "__main__":
    sys.exit(main())
