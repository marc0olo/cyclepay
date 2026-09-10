#!/usr/bin/env python3
"""Every `icp canister call backend <method> '(...)'` in docs and scripts must
actually run: the method has to exist in the committed `.did`, and the number of
top-level arguments has to match what it declares.

Why this exists: `audit_log` took `(opt nat, nat)` from #38 onward while three
places still called it `'()'`, and `quote_previews` lost its rail argument when
#35 deleted the ck-USDC rail while RUNBOOK kept passing one -- the line it calls
"the fastest is-the-rail-actually-quoting check". Four instances, all of them an
operator's copy-paste failing mid-incident, none of them visible to any suite:
these are strings in prose, so nothing type-checks them and the gate was green.

`check-admin-commands.py` is the neighbouring check and does NOT cover this. It
compares mutating methods against the console's command table; arity in prose is
a different question about different files.

Scope, deliberately: arity is checked only where the argument is a LITERAL. A
templated one (`<candid args>`, `$VAR`, `%s`) has its method checked and its
arity skipped, because the text is a shape rather than a call.
"""
import re
import sys
from pathlib import Path

DID = Path("src/backend/dist/backend.did")
TARGETS = ["RUNBOOK.md", "README.md", *sorted(str(p) for p in Path("docs").glob("*.md")),
           *sorted(str(p) for p in Path("scripts").glob("*.sh"))]
PLACEHOLDER = re.compile(r"[<$%]")


def top_level_commas(body: str) -> int:
    """Commas at nesting depth zero, ignoring double-quoted spans."""
    depth = in_str = 0
    commas = 0
    i = 0
    while i < len(body):
        c = body[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = 0
        elif c == '"':
            in_str = 1
        elif c in "({[":
            depth += 1
        elif c in ")}]":
            depth -= 1
        elif c == "," and depth == 0:
            commas += 1
        i += 1
    return commas


def arity(params: str) -> int:
    params = params.strip()
    return 0 if not params else top_level_commas(params) + 1


def did_arities(text: str) -> dict[str, int]:
    """`name: (params) -> ...` inside the service block. Multi-line, so this
    scans with a paren matcher rather than a per-line regex."""
    text = re.sub(r"^\s*///.*$", "", text, flags=re.M)
    start = text.index("service :")
    out: dict[str, int] = {}
    for m in re.finditer(r"([a-z][A-Za-z0-9_]*)\s*:\s*\(", text[start:]):
        i = start + m.end() - 1
        depth = 0
        for j in range(i, len(text)):
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
                if depth == 0:
                    break
        else:
            continue
        # Only a method has `->` after its parameter list; a record field does not.
        if text[j + 1 : j + 40].lstrip().startswith("->"):
            out[m.group(1)] = arity(text[i + 1 : j])
    return out


def calls(text: str):
    """(method, literal_arg_or_None, line_no) for each call in one file."""
    # ⚠️ Do NOT join backslash continuations first. It shifts every subsequent line
    # number, which points the report at the wrong line — and it buys nothing: the
    # argument scan below already crosses newlines, which is what a continued call
    # needs.
    for m in re.finditer(r"canister\s+call\s+backend\s+([A-Za-z_][\w]*)", text):
        line_no = text.count("\n", 0, m.start()) + 1
        method = m.group(1)
        rest = text[m.end():]
        q = rest.find("'")
        # A shell single-quoted string cannot contain a quote, so the next one closes it.
        arg = None
        if q != -1:
            end = rest.find("'", q + 1)
            if end != -1:
                candidate = rest[q + 1 : end].strip()
                # The argument is the first quoted string only if it looks like candid.
                if candidate.startswith("("):
                    arg = candidate
        yield method, arg, line_no


def main() -> int:
    if not DID.exists():
        print(f"cannot read {DID} — run `mops build` first", file=sys.stderr)
        return 2
    declared = did_arities(DID.read_text())
    problems, checked, skipped = [], 0, 0

    for name in TARGETS:
        path = Path(name)
        if not path.exists():
            continue
        for method, arg, line in calls(path.read_text()):
            if PLACEHOLDER.search(method):
                continue
            if method not in declared:
                problems.append(f"{name}:{line}  {method} is not in the .did")
                continue
            if arg is None or PLACEHOLDER.search(arg):
                skipped += 1
                continue
            body = arg[1:-1] if arg.endswith(")") else arg[1:]
            got, want = arity(body), declared[method]
            checked += 1
            if got != want:
                problems.append(
                    f"{name}:{line}  {method} takes {want} argument(s), the call passes {got}: {arg[:60]}"
                )

    print(f"{len(declared)} methods in the .did; {checked} literal call(s) checked, {skipped} templated")
    if problems:
        print(f"\n\033[31m✗ {len(problems)} call(s) would fail on contact:\033[0m")
        for p in problems:
            print(f"    {p}")
        return 1
    print("\033[32m✓ every documented call matches the .did\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
