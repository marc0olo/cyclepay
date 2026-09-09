#!/usr/bin/env python3
"""Fail if two module functions have the same body.

⚠️ **The class: one piece of arithmetic implemented twice, in two modules, both live.**
Nothing else here can see it. `check-unused-motoko.py` finds a function with no caller;
this finds two functions that both have callers and both do the same thing — where the
loss is not dead code but **divergence**, because the next correction lands on one of them.

**It has already happened once, and on the money path.** #136 added a private
`Reserve.deliverable` that re-implemented `Delivery.deliverableCycles` — the fee-on-top
correction — while its own docstring claimed *"the same correction, so the same function"*,
and it replaced a call site that had been calling the real one. Delivery and withdrawal
are the two outflow classes of one account, so a fee correction diverging between them is
exactly the failure `Reserve.mo`'s "two destination classes, ONE outflow mechanism"
framing exists to prevent. Caught in review; this is what catches the next one — and
⚠️ **the first two versions of this script did not**, which is recorded on `MIN_TOKENS`
and on the normalisation steps because each was a claim that measurement contradicted.

**Normalisation, stated because it is the whole instrument.** A body is compared after:
comments stripped (the Motoko stripper from `check-unused-motoko.py`, block comments
NEST), all whitespace collapsed to single spaces, and nothing else. Parameter *names* are
NOT normalised, so two functions that differ only in the names of their parameters are
reported as distinct — a deliberate false-negative, because renaming a parameter to dodge
this check is not a thing anyone does by accident, and inferring alpha-equivalence needs a
parser rather than a scanner.

⚠️ **`MIN_TOKENS` is a small floor, not a filter, and the measurement is on the constant
itself.** This tree has zero cross-module duplicate bodies at every threshold from 4 up,
so the bar excludes nothing today; it exists so a future pair of one-expression
projections cannot report as duplication. The count below the bar is printed so the
exemption stays visible rather than implied.

⚠️ **What this does NOT reach**, stated because a check implying more than it verifies is
worse than no check:

  - **Near-duplicates.** Two bodies that differ by a LOCAL variable name, an argument
    order, or a `+ 1` are distinct here. Parameter names and in-expression type
    annotations ARE normalised — both were needed to see the motivating case — but
    anything beyond that needs a parser, and a similarity score would need tuning against
    false positives on every commit.
  - **Duplication across a module and a mixin, or inside one function.** Only
    `public func` bodies in `src/backend/**/*.mo` are compared, and only against each
    other.
  - **Whether the duplicate is the WRONG one.** It reports the pair; a human decides
    which call site should survive.
"""

import glob
import os
import re
import sys
import tempfile

SOURCES = ("src/backend/*.mo", "src/backend/rails/*.mo", "src/backend/mixins/*.mo")

# Smallest body worth reporting, in whitespace-separated tokens of the normalised text.
#
# ⚠️ **Measured, and the first version of this constant was a guess that made the check
# blind to its own motivating case.** It was set to 18 on the invented claim that "the
# real duplicate is 22 tokens"; the real duplicate normalises to **9**, so the check
# passed over it. And the collision the bar was supposed to prevent does not exist here:
# scanned at 4, 6, 8, 9, 10 and 12 tokens, this tree has **zero** cross-module duplicate
# bodies at every one of them. So the bar is not holding anything back — it stays only to
# keep a future pair of one-expression projections (`store.promised`, 2 tokens) from
# reporting as duplication, and it sits below the smallest real duplicate seen.
MIN_TOKENS = 6

FUNC = re.compile(r"^\s*public\s+func\s+([a-z_][A-Za-z0-9_]*)", re.M)

# `name : Type` inside a parameter list. Used to rename parameters positionally so two
# copies of one rule compare equal when only their argument names differ.
PARAM = re.compile(r"([a-z_][A-Za-z0-9_]*)\s*:")

# ` : TypeName` inside an expression — disambiguation for the compiler, not behaviour.
ANNOTATION = re.compile(r"\s*:\s*\??[A-Z][A-Za-z0-9_.]*")


def strip_comments(src: str) -> str:
    """Motoko source with comments blanked, string bodies kept. Block comments NEST."""
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


def bodies(path):
    """(name, normalised body) for every `public func` in one file.

    The body is the text between the signature's opening `{` and its matching `}`, found
    by counting braces over comment-stripped source — so a `{` inside a comment or a
    string cannot end a body early.
    """
    text = strip_comments(open(path).read())
    out = []
    for m in FUNC.finditer(text):
        open_at = text.find("{", m.end())
        if open_at == -1:
            continue
        depth, i = 1, open_at + 1
        while i < len(text) and depth:
            # ⚠️ **Strings are skipped, and the self-test is why this is here.** The
            # stripper deliberately KEEPS string bodies (a symbol inside one is a real
            # reference), so a `}` in a string literal would close the body early and
            # every function after it would compare as a truncated fragment. The first
            # run of the self-test caught exactly that.
            if text[i] == '"':
                i += 1
                while i < len(text):
                    if text[i] == "\\":
                        i += 2
                        continue
                    if text[i] == '"':
                        break
                    i += 1
                i += 1
                continue
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        body = " ".join(text[open_at + 1 : i - 1].split())
        # ⚠️ **Parameters are renamed POSITIONALLY, and this is the whole point of the
        # check.** #136's duplicate took `(total, fee)` where the original took
        # `(lockedCycles, fee)` — identical arithmetic, different argument names, chosen
        # naturally rather than to dodge anything. Comparing raw text called them
        # distinct, which made the check blind to the one instance that motivated it.
        # Measured before and after: raw text 9 vs 11 tokens and unequal; normalised,
        # both are `if (_1 >= _0) return null; ?(_0 - _1 : Nat);` and equal.
        params = PARAM.findall(" ".join(text[m.end() : open_at].split()))
        for position, param in enumerate(dict.fromkeys(params)):
            body = re.sub(rf"\b{re.escape(param)}\b", f"_{position}", body)
        # ⚠️ **In-expression type annotations are dropped, and that is what closes the
        # motivating case.** #136's copy wrote `?(_0 - _1 : Nat)` where the original
        # wrote `?(_0 - _1)` — an annotation that disambiguates for the compiler and
        # says nothing about behaviour, so leaving it in made two identical rules compare
        # distinct. ⚠️ The cost is stated rather than hidden: two bodies that differ ONLY
        # by which type they annotate (`: Nat` vs `: Int`) now collide and are reported.
        # That pair is worth a human look anyway, and the report names both sites.
        body = ANNOTATION.sub("", body)
        body = " ".join(body.split())
        out.append((m.group(1), body))
    return out


def self_test():
    """⚠️ Unconditional. The brace matcher and the stripper are the instrument; if either
    silently stops working, every body reads as unique and this passes over anything."""
    sample = "\n".join([
        "module {",
        "  public func alpha(a : Nat, b : Nat) : ?Nat {",
        "    if (b >= a) return null;   // a comment { with a brace",
        '    let s = "a } string";',
        "    ?(a - b : Nat);",
        "  };",
        "  public func beta(a : Nat, b : Nat) : ?Nat {",
        "    if (b >= a) return null;",
        '    let s = "a } string";',
        "    ?(a - b : Nat);",
        "  };",
        "  public func gamma(x : Nat) : Nat { x + 1 };",
        "};",
    ])
    fd, path = tempfile.mkstemp(suffix=".mo")
    with os.fdopen(fd, "w") as fh:
        fh.write(sample)
    got = bodies(path)
    os.unlink(path)
    names = [n for n, _ in got]
    if names != ["alpha", "beta", "gamma"]:
        sys.exit(f"ABORT: self-test parsed {names}, expected alpha, beta, gamma")
    by = dict(got)
    if by["alpha"] != by["beta"]:
        sys.exit(
            "ABORT: self-test — two identical bodies did not normalise equal:\n"
            f"  {by['alpha']!r}\n  {by['beta']!r}"
        )
    if by["alpha"] == by["gamma"]:
        sys.exit("ABORT: self-test — different bodies normalised equal")
    if "comment" in by["alpha"] or "} string" not in by["alpha"]:
        sys.exit(f"ABORT: self-test — stripper wrong on {by['alpha']!r}")

    # ⚠️ **The case the check exists for: same rule, different parameter names.** Without
    # positional renaming these compare distinct, which is how the first version of this
    # script passed over the very duplicate it was written to catch.
    renamed = "\n".join([
        "module {",
        "  public func one(lockedCycles : Nat, fee : Nat) : ?Nat {",
        "    if (fee >= lockedCycles) return null;",
        "    ?(lockedCycles - fee : Nat);",
        "  };",
        "  public func two(total : Nat, fee : Nat) : ?Nat {",
        "    if (fee >= total) return null;",
        "    ?(total - fee : Nat);",
        "  };",
        "};",
    ])
    fd, path = tempfile.mkstemp(suffix=".mo")
    with os.fdopen(fd, "w") as fh:
        fh.write(renamed)
    pair = dict(bodies(path))
    os.unlink(path)
    annotated = "\n".join([
        "module {",
        "  public func three(a : Nat, b : Nat) : ?Nat { ?(a - b) };",
        "  public func four(x : Nat, y : Nat) : ?Nat { ?(x - y : Nat) };",
        "};",
    ])
    fd2, path2 = tempfile.mkstemp(suffix=".mo")
    with os.fdopen(fd2, "w") as fh:
        fh.write(annotated)
    ann = dict(bodies(path2))
    os.unlink(path2)
    if ann["three"] != ann["four"]:
        sys.exit(
            "ABORT: self-test — an in-expression annotation kept two identical rules "
            f"apart:\n  {ann['three']!r}\n  {ann['four']!r}"
        )

    if pair["one"] != pair["two"]:
        sys.exit(
            "ABORT: self-test — one rule under two parameter names did not compare equal:\n"
            f"  {pair['one']!r}\n  {pair['two']!r}"
        )


def main():
    self_test()
    files = []
    for pattern in SOURCES:
        files.extend(sorted(glob.glob(pattern)))
    if not files:
        sys.exit(f"ABORT: no sources matched {SOURCES} — cannot pass vacuously")

    seen = {}
    total = 0
    below = 0
    for f in files:
        for name, body in bodies(f):
            total += 1
            if len(body.split()) < MIN_TOKENS:
                below += 1
                continue
            seen.setdefault(body, []).append((name, f))
    if total == 0:
        sys.exit(f"ABORT: parsed no `public func` bodies out of {len(files)} files")

    dupes = {b: w for b, w in seen.items() if len({f for _, f in w}) > 1}
    if dupes:
        print("\n\033[31m✗ the same function body appears in two modules\033[0m", file=sys.stderr)
        for body, where in dupes.items():
            print("    " + " = ".join(f"{n} ({f})" for n, f in where), file=sys.stderr)
            print(f"      {body[:100]}", file=sys.stderr)
        print(
            "\n  Call one from the other. Two live implementations of one rule means the\n"
            "  next correction lands on one of them — and on the money path that is a\n"
            "  divergence nothing else here can see. Check the import direction is\n"
            "  acyclic; it usually is.",
            file=sys.stderr,
        )
        return 1

    print(
        f"   {len(seen)} module function bodies compared, none duplicated"
        f" ({below} below the {MIN_TOKENS}-token bar)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
