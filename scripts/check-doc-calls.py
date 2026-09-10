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

Known limits, accepted rather than overlooked:

- **Arity, not types.** `orphans '("x", "y")'` passes: two arguments is what the
  method takes. Checking types needs a real candid parser and a type
  environment; arity is a small scanner that catches all four historical
  instances in this repo, both of the live ones included.
- **A templated argument is not checked at all**, only its method name.
- **The console's printed commands are not read from here.** They come from a
  typed table in `src/frontend/src/candid.ts`, and `candid.test.ts` asserts their
  arity against the generated `idlFactory`. Both halves are needed: the type
  binds each renderer's SIGNATURE, not the string it returns, so a renderer that
  accepts two arguments and emits one type-checks clean.
"""
import re
import sys
from pathlib import Path

DID = Path("src/backend/dist/backend.did")
TARGETS = ["RUNBOOK.md", "README.md", *sorted(str(p) for p in Path("docs").glob("*.md")),
           *sorted(str(p) for p in Path("scripts").glob("*.sh"))]
PLACEHOLDER = re.compile(r"[<$%]")
# The floor that stops a blind scanner passing. 72 literal calls today; a real
# change moves this by a few, and a broken pattern takes it to zero.
MIN_CHECKED = 60


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
    """(method, literal_arg_or_None, raw_span, line_no) for each call in one file."""
    starts = [m.start() for m in re.finditer(r"canister\s+call\s+backend", text)]
    for m in re.finditer(r"canister\s+call\s+backend\s+([A-Za-z_][\w]*)", text):
        line_no = text.count("\n", 0, m.start()) + 1
        method = m.group(1)
        # ⚠️ **Bounded at the NEXT call, not the end of the file.** Unbounded, a
        # zero-argument call written bare in prose picks up the argument of a later
        # command: `health` was reported as passing `(null, 50 : nat)`, which belongs to
        # an `orphans` line further down, at that line's number. Every documented call
        # happens to carry an argument today, so nothing triggered it -- but `health`,
        # `admin_status`, `operator_summary` and `orphan_depth` all take none and are
        # exactly what someone writes bare.
        nxt = next((s2 for s2 in starts if s2 > m.start()), len(text))
        rest = text[m.end() : nxt]

        # ⚠️ **A quote immediately followed by `(`, and EITHER quote character.** Taking
        # "the first single-quoted string" instead reported six calls in
        # `scripts/local-dev-seed.sh` as having no argument at all. Two are
        # double-quoted because they interpolate a shell variable
        # (`set_stripe_origin "(\"${ORIGIN}\")"`); the rest are `printf` lines whose
        # first quote closes the FORMAT string, so the scanner read past the argument
        # entirely. Anchoring on the parenthesis finds the argument in every one.
        arg = None
        opening = re.search(r"['\"]\(", rest)
        if opening:
            ch = rest[opening.start()]
            i = opening.start() + 1
            j = i
            while j < len(rest):
                # `\"` is an escaped quote inside a double-quoted shell word, not the end
                # of it. A single-quoted shell word cannot contain its own quote at all,
                # so this only ever matters for the double-quoted form.
                if ch == '"' and rest[j] == "\\":
                    j += 2
                    continue
                if rest[j] == ch:
                    break
                j += 1
            if j < len(rest):
                candidate = rest[i:j].strip()
                if candidate.startswith("("):
                    arg = candidate
        yield method, arg, rest, line_no


def self_test() -> None:
    """⚠️ **Unconditional, because every failure mode of this check is SILENT.**

    A green tick here means "every call matches", and the scanner going blind
    produces exactly that tick. Breaking the `canister call backend` pattern
    printed `0 literal call(s) checked` next to a pass and exited 0 -- the tick
    saying the opposite of what happened. The floor in `main` catches a total
    miss; this catches the subtler ones, where the scanner still finds calls but
    counts their arguments wrong.
    """
    cases = [
        ("()", 0),
        ("(null, 50 : nat)", 2),
        ("(vec { 500 : nat })", 1),
        # Commas inside a record, a vec and a nested paren must not count.
        ("(record { a = 1; b = vec { 1, 2, 3 } })", 1),
        ('("a, b", 2)', 2),
        ('(record { s = "x, y" }, opt true)', 2),
    ]
    for body, want in cases:
        got = arity(body[1:-1])
        if got != want:
            sys.exit(f"ABORT: self-test — arity({body}) gave {got}, expected {want}")

    sample = (
        "icp canister call backend health\n"
        "icp canister call backend orphans '(null, 50 : nat)' -e ic\n"
        # Double-quoted, because it interpolates: the shape that read as "no argument".
        'icp canister call backend set_stripe_origin "(\\"${ORIGIN}\\")" >/dev/null\n'
        # A printf whose FIRST quote closes the format string, not the argument.
        "printf '  icp canister call backend refresh_reserve %s\\n' \"'()'\"\n"
    )
    got = [(m, a) for m, a, _, _ in calls(sample)]
    want = [
        ("health", None),
        ("orphans", "(null, 50 : nat)"),
        ("set_stripe_origin", '(\\"${ORIGIN}\\")'),
        ("refresh_reserve", "()"),
    ]
    if got != want:
        sys.exit(f"ABORT: self-test — the scanner read {got}, expected {want}")


def main() -> int:
    self_test()
    if not DID.exists():
        sys.exit(f"ABORT: cannot read {DID} — run `mops build` first; cannot pass vacuously")
    declared = did_arities(DID.read_text())
    if not declared:
        sys.exit(f"ABORT: no methods found in {DID} — cannot pass vacuously")
    problems, checked, templated, bare = [], 0, 0, []

    for name in TARGETS:
        path = Path(name)
        if not path.exists():
            continue
        for method, arg, raw, line in calls(path.read_text()):
            if PLACEHOLDER.search(method):
                continue
            if method not in declared:
                problems.append(f"{name}:{line}  {method} is not in the .did")
                continue
            if arg is None:
                # A `%s`, a `$VAR` or a `<placeholder>` anywhere in the span means the
                # argument is templated rather than missing -- a printf that prints the
                # command for a human to fill in, most often.
                if PLACEHOLDER.search(raw):
                    templated += 1
                    continue
                # ⚠️ RUNBOOK §0: "Always pass an explicit `'()'`". Omitting it makes
                # `icp canister call` ask "Do you want to send this message? [y/N]" and
                # read stdin, which hangs any script, cron job or CI step. So a bare
                # call is a defect in its own right, not merely unchecked.
                bare.append(f"{name}:{line}  {method} is written with no argument")
                continue
            if PLACEHOLDER.search(arg):
                templated += 1
                continue
            body = arg[1:-1] if arg.endswith(")") else arg[1:]
            got, want = arity(body), declared[method]
            checked += 1
            if got != want:
                problems.append(
                    f"{name}:{line}  {method} takes {want} argument(s), the call passes {got}: {arg[:60]}"
                )

    print(
        f"{len(declared)} methods in the .did; {checked} literal call(s) checked, "
        f"{templated} templated, {len(bare)} bare"
    )
    # ⚠️ **The floor.** Without it, a scanner that matches nothing reports a pass.
    if checked < MIN_CHECKED:
        sys.exit(
            f"ABORT: only {checked} literal call(s) checked, expected at least {MIN_CHECKED} "
            "— the scanner is not finding the calls, so this cannot pass vacuously"
        )

    problems += bare
    if problems:
        print(f"\n\033[31m✗ {len(problems)} call(s) would fail on contact:\033[0m")
        for p in problems:
            print(f"    {p}")
        return 1
    print("\033[32m✓ every documented call matches the .did\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
