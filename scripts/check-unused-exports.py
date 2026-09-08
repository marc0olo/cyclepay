#!/usr/bin/env python3
"""Fail if a frontend export's only referents are test files.

⚠️ **Why this is a gate step.** `paymentLinkWithRef` survived past the PR that scheduled
its own deletion — its comment said *"Kept only until PR-C deletes the Payment Link
mechanism wholesale"*, PR-C shipped, and the function stayed. It was invisible for a
specific reason: **two vitest cases referenced it**, so it was neither unused (the test
imports it) nor covered (nothing ships it). The suite counted it as coverage.

`noUnusedLocals` cannot see this — the symbol *is* used, from a test. Only the
production-vs-test distinction makes it visible, which is a fixed syntactic target and
therefore gate-able.

⚠️ **What this does NOT reach**, because a check implying more than it verifies is worse
than no check:

  - **Motoko.** A `public func` in a module has no such detector: `-Werror` does not flag
    an unused export, and the equivalent sweep would need a call graph. `Reserve.recount`
    is the deliberate case — a test oracle with no production caller, documented as such —
    so a Motoko version of this check would need an opt-out marker before it could exist.
  - **Transitively dead code.** An export used only by another export that is itself dead
    still passes. This finds leaves, not subtrees.
  - **Anything outside `src/frontend/src`.**
  - **Exports marked `@test-oracle`**, which are skipped. A symbol can legitimately have
    no production caller: `CREATE_ORDER_ERROR_KEYS` exists so the suite iterates a list
    derived from the backend's type rather than a hand-written copy of it, and deleting
    it to satisfy this check would delete the guarantee. The marker has to sit in the
    export's own doc comment, so the reason is next to the symbol rather than in a list
    here, and the count is printed so a growing set of them is visible.

⚠️ **Comments are stripped before the reference scan, and that is load-bearing.** The
scan is a word match over the file's text, so for a while ANY comment naming a symbol
shielded it — including the symbol's own doc block, and including a comment that says the
symbol is dead. `feeBreakdown` passed this check on two hits in its home file: the
definition, plus a sentence in a neighbour's doc saying `feeBreakdown` was built from it.
A check on dead code, blinded by prose about dead code. Stripping is done with a real
scanner rather than a regex because `"https://x"` contains `//`, and cutting there would
delete live code and report a used symbol as dead.
"""

import glob
import os
import re
import sys

SRC = "src/frontend/src"
# Entry points and generated code: reached by the bundler or the browser, not by an import
# this checker can see.
EXEMPT_FILES = {"main.ts", "fixtures.ts"}
EXEMPT_DIRS = ("bindings",)


def strip_comments(src: str) -> str:
    """TS source with `//` and `/* */` comments blanked, string bodies left alone.

    Newlines are preserved so a stripped file still lines up with the original.
    """
    out = []
    i, n = 0, len(src)
    quote = None  # the delimiter we are inside, or None
    while i < n:
        c = src[i]
        if quote is not None:
            if c == "\\" and i + 1 < n:
                out.append("  ")
                i += 2
                continue
            out.append(c)
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'`":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def self_test() -> None:
    """⚠️ Unconditional, like `check-admin-commands.py`'s parser test. The stripper is
    the instrument: if it silently stops stripping, every symbol is shielded again and
    this step passes while checking nothing."""
    cases = [
        ("const a = 1; // feeBreakdown", "feeBreakdown", False),
        ("/// feeBreakdown is built from this\nconst a = 1;", "feeBreakdown", False),
        ("/* feeBreakdown */ const a = 1;", "feeBreakdown", False),
        ('const u = "https://x/y"; const b = feeBreakdown();', "feeBreakdown", True),
        ('const s = "// feeBreakdown";', "feeBreakdown", True),
        ("const t = `a ${feeBreakdown()} b`;", "feeBreakdown", True),
    ]
    for src, name, expected in cases:
        got = name in strip_comments(src)
        if got != expected:
            sys.exit(
                f"ABORT: strip_comments self-test failed on {src!r}: "
                f"expected {name!r} {'kept' if expected else 'stripped'}"
            )
    # And the stripper must not eat the line structure it is scanned by.
    if strip_comments('const a = 1; // x\nconst b = 2;').count("\n") != 1:
        sys.exit("ABORT: strip_comments dropped a newline")


def is_test(path: str) -> bool:
    return ".test." in os.path.basename(path) or path.endswith(".spec.ts")


def main() -> int:
    self_test()
    prod, tests = [], []
    for p in glob.glob(f"{SRC}/**/*.ts", recursive=True):
        if any(f"/{d}/" in p for d in EXEMPT_DIRS):
            continue
        (tests if is_test(p) else prod).append(p)
    if not prod:
        sys.exit(f"ABORT: found no production sources under {SRC} — cannot pass vacuously")

    # Collect exported names, and where each is referenced.
    exports = {}
    oracles = set()
    for p in prod:
        if os.path.basename(p) in EXEMPT_FILES:
            continue
        text = open(p).read()
        for m in re.finditer(
            r"^export\s+(?:async\s+)?(?:function|const|let|class)\s+([A-Za-z_$][\w$]*)",
            text,
            re.M,
        ):
            exports[m.group(1)] = p
            # The marker is read from the doc comment immediately above the export, so
            # it cannot be claimed from somewhere else in the file.
            doc = text[:m.start()].rsplit("\n\n", 1)[-1]
            if "@test-oracle" in doc:
                oracles.add(m.group(1))

    if not exports:
        sys.exit(f"ABORT: parsed no exports out of {SRC} — cannot pass vacuously")

    # ⚠️ Comments stripped: see the module docstring. A production REFERENCE is a call
    # or an import, never a mention.
    prod_text = {p: strip_comments(open(p).read()) for p in prod}
    test_text = {p: open(p).read() for p in tests}
    # Browser specs drive the built page rather than importing modules, but a name can
    # still legitimately appear there.
    for p in glob.glob("test/browser/**/*.ts", recursive=True):
        test_text[p] = open(p).read()

    dead = []
    for name, home in sorted(exports.items()):
        if name in oracles:
            continue
        word = re.compile(rf"\b{re.escape(name)}\b")
        in_prod = any(
            word.search(t) for p, t in prod_text.items() if p != home
        ) or len(word.findall(prod_text[home])) > 1
        if in_prod:
            continue
        where = [p for p, t in test_text.items() if word.search(t)]
        dead.append((name, home, where))

    if dead:
        print("\n\033[31m✗ frontend export(s) referenced only by tests\033[0m", file=sys.stderr)
        for name, home, where in dead:
            tail = f" — referenced only in {', '.join(sorted(where))}" if where else " — referenced nowhere"
            print(f"    {name}  ({home}){tail}", file=sys.stderr)
        print(
            "\n  Delete the export AND its tests, or wire it into the app. A symbol whose only\n"
            "  caller is its own test is neither used nor covered, and the suite counts it as\n"
            "  coverage — which is how paymentLinkWithRef survived the PR that scheduled its\n"
            "  own deletion.",
            file=sys.stderr,
        )
        return 1
    oracle_note = f", {len(oracles)} marked @test-oracle" if oracles else ""
    print(f"   {len(exports)} frontend exports: none referenced only by tests{oracle_note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
