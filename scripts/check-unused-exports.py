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


def is_test(path: str) -> bool:
    return ".test." in os.path.basename(path) or path.endswith(".spec.ts")


def main() -> int:
    prod, tests = [], []
    for p in glob.glob(f"{SRC}/**/*.ts", recursive=True):
        if any(f"/{d}/" in p for d in EXEMPT_DIRS):
            continue
        (tests if is_test(p) else prod).append(p)
    if not prod:
        sys.exit(f"ABORT: found no production sources under {SRC} — cannot pass vacuously")

    # Collect exported names, and where each is referenced.
    exports = {}
    for p in prod:
        if os.path.basename(p) in EXEMPT_FILES:
            continue
        for m in re.finditer(
            r"^export\s+(?:async\s+)?(?:function|const|let|class)\s+([A-Za-z_$][\w$]*)",
            open(p).read(),
            re.M,
        ):
            exports[m.group(1)] = p

    if not exports:
        sys.exit(f"ABORT: parsed no exports out of {SRC} — cannot pass vacuously")

    prod_text = {p: open(p).read() for p in prod}
    test_text = {p: open(p).read() for p in tests}
    # Browser specs drive the built page rather than importing modules, but a name can
    # still legitimately appear there.
    for p in glob.glob("test/browser/**/*.ts", recursive=True):
        test_text[p] = open(p).read()

    dead = []
    for name, home in sorted(exports.items()):
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
    print(f"   {len(exports)} frontend exports: none referenced only by tests")
    return 0


if __name__ == "__main__":
    sys.exit(main())
