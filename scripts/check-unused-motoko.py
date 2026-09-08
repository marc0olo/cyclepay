#!/usr/bin/env python3
"""Fail if a module's `public func` has no caller outside its own tests.

The Motoko half of `check-unused-exports.py`, which gates this class for the frontend
only. ⚠️ **The gap had a live instance:** `Gate.configErrorToText`'s only caller was
`test/gate.test.mo`, while #131 was deleting three renderers of exactly that shape on
exactly that reasoning — *a `*ToText` with no production caller is dead code that reads
as a supported path.* One module over, unflagged.

⚠️ **The compiler contributes nothing here, which is why this has to exist.** moc's
unused-identifier warning (M0194) fires only in the canister's MAIN file — never in
modules or mixins. So an entire module of dead exports compiles clean under `-Werror`.

⚠️ **Comments are stripped before the reference scan, and that is load-bearing.** The
frontend checker learned it the hard way: it decided `in_prod` over raw text, so any
comment naming a symbol shielded it — and this codebase comments heavily. A symbol whose
only "caller" is prose about it is dead. The stripper here is Motoko's, not TypeScript's:
Motoko has no template literals, and its block comments NEST (`/* /* */ */` is one
comment), which a non-counting stripper closes too early and then eats live code.

⚠️ **What this does NOT reach**, stated because a check implying more than it verifies is
worse than no check:

  - **`public type`, `public let`, `public class`.** Functions only. A dead type is
    harmless in a way a dead function is not: it cannot be mistaken for a supported
    operation, and types are legitimately referenced only in signatures.
  - **Mixins and the composition root.** A mixin's `public shared` functions are
    endpoints, reached by the IC and gated by `check-endpoint-docs.py` instead.
  - **A function reachable only through dead code.** This is a reference scan, not a
    call graph: `a` calling `b` keeps `b` alive even when nothing calls `a`. Deleting a
    dead function can therefore reveal the next one; run this again after deleting.
  - **Whether a used function is used WELL.** One caller in one branch counts.

An export that legitimately has no production caller — a test oracle derived from a type
— gets an in-source `@test-oracle` marker in the doc block directly above it, and the
count is printed. A list of exemptions inside this script is where an exemption goes to
be forgotten.
"""

import glob
import os
import re
import sys

# Modules only: `src/backend/*.mo` and the rails. Mixins hold endpoints, and `Main.mo`
# is the composition root — both are covered by other steps.
MODULE_GLOBS = ("src/backend/*.mo", "src/backend/rails/*.mo")
CALLER_GLOBS = ("src/backend/**/*.mo",)
TEST_GLOBS = ("test/*.mo", "test/**/*.mo")
EXCLUDE = ("src/backend/Main.mo",)

PUBLIC_FUNC = re.compile(r"^\s*public\s+func\s+([a-z_][A-Za-z0-9_]*)", re.M)


def strip_comments(src: str) -> str:
    """Motoko source with `//` and `/* */` comments blanked, string bodies left alone.

    Newlines are preserved so a stripped file still lines up with the original. Block
    comments NEST in Motoko, so the depth is counted rather than scanning for the first
    `*/` — closing early would leave real code stripped and report a live symbol as dead,
    which is the dangerous direction.
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            out.append(c)
            i += 1
            while i < n:
                if src[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                out.append(src[i])
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            depth = 1
            i += 2
            while i < n and depth:
                if src[i] == "/" and i + 1 < n and src[i + 1] == "*":
                    depth += 1
                    i += 2
                    continue
                if src[i] == "*" and i + 1 < n and src[i + 1] == "/":
                    depth -= 1
                    i += 2
                    continue
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def self_test():
    """⚠️ Unconditional. The stripper is the instrument: if it silently stops stripping,
    every symbol is shielded by the prose about it and this step passes while checking
    nothing. Both directions are tested — a comment must be stripped, a string must not."""
    cases = [
        ("let a = 1; // configErrorToText", "configErrorToText", False),
        ("/// configErrorToText renders it\nlet a = 1;", "configErrorToText", False),
        ("/* configErrorToText */ let a = 1;", "configErrorToText", False),
        # Nesting: a non-counting stripper closes at the inner `*/` and keeps the tail.
        ("/* outer /* inner */ configErrorToText */ let a = 1;", "configErrorToText", False),
        ('let s = "configErrorToText";', "configErrorToText", True),
        ('let u = "https://x/y"; let b = configErrorToText(e);', "configErrorToText", True),
        ('let s = "// configErrorToText";', "configErrorToText", True),
    ]
    for src, name, expected in cases:
        got = name in strip_comments(src)
        if got != expected:
            sys.exit(
                f"ABORT: strip_comments self-test failed on {src!r}: "
                f"expected {name!r} {'kept' if expected else 'stripped'}"
            )
    if strip_comments("let a = 1; // x\nlet b = 2;").count("\n") != 1:
        sys.exit("ABORT: strip_comments dropped a newline")
    if PUBLIC_FUNC.findall("  public func foo(x : Nat) : Nat { x };") != ["foo"]:
        sys.exit("ABORT: PUBLIC_FUNC stopped matching a public func")
    if PUBLIC_FUNC.findall("  public shared func bar() : async () {};") != []:
        sys.exit("ABORT: PUBLIC_FUNC matched a shared endpoint, which is out of scope")


def expand(patterns):
    out = []
    for p in patterns:
        out.extend(glob.glob(p, recursive=True))
    return sorted(set(out))


def main():
    self_test()

    modules = [p for p in expand(MODULE_GLOBS) if p not in EXCLUDE]
    if not modules:
        sys.exit(f"ABORT: no modules matched {MODULE_GLOBS} — cannot pass vacuously")

    exports = {}
    oracles = set()
    for p in modules:
        text = open(p).read()
        for m in PUBLIC_FUNC.finditer(text):
            exports.setdefault(m.group(1), p)
            # Read from the doc block directly above, so the marker cannot be claimed
            # from elsewhere in the file.
            doc = text[: m.start()].rsplit("\n\n", 1)[-1]
            if "@test-oracle" in doc:
                oracles.add(m.group(1))
    if not exports:
        sys.exit(f"ABORT: parsed no `public func` out of {len(modules)} modules — cannot pass vacuously")

    prod = {p: strip_comments(open(p).read()) for p in expand(CALLER_GLOBS)}
    tests = {p: open(p).read() for p in expand(TEST_GLOBS)}
    if not tests:
        sys.exit(f"ABORT: no test sources matched {TEST_GLOBS} — cannot pass vacuously")

    dead = []
    for name, home in sorted(exports.items()):
        if name in oracles:
            continue
        word = re.compile(rf"\b{re.escape(name)}\b")
        # In its own file the declaration itself matches, so one hit is not a caller.
        used = any(word.search(t) for p, t in prod.items() if p != home) or (
            len(word.findall(prod.get(home, ""))) > 1
        )
        if used:
            continue
        where = [p for p, t in tests.items() if word.search(t)]
        dead.append((name, home, where))

    if dead:
        print("\n\033[31m✗ module function(s) with no caller outside their tests\033[0m", file=sys.stderr)
        for name, home, where in dead:
            tail = f" — only in {', '.join(sorted(where))}" if where else " — referenced nowhere"
            print(f"    {name}  ({home}){tail}", file=sys.stderr)
        print(
            "\n  Delete it AND its tests, or give it a production caller. A function whose\n"
            "  only caller is its own test is neither used nor covered, while the suite\n"
            "  counts it as coverage — and a `*ToText` or a validator with no caller reads\n"
            "  as a supported path that something is expected to use.\n"
            "\n  If it is legitimately a test oracle derived from a type, put\n"
            "  `@test-oracle` in the doc block directly above it, with the reason.",
            file=sys.stderr,
        )
        return 1

    note = f", {len(oracles)} marked @test-oracle" if oracles else ""
    print(f"   {len(exports)} module functions: every one called from production{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
