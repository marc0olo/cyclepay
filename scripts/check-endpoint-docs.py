#!/usr/bin/env python3
"""Fail if a public endpoint has no documentation.

⚠️ **Why this is a gate step, and why it is phrased as the VICTIM rather than the
defect.** A `///` block sits above a declaration; insert or move a declaration between
them and the block silently attaches to the wrong one. In Motoko that reaches the
canister's published interface — the doc lands on the wrong method in `backend.did`, so
the interface documents the wrong contract.

This class produced **five** separate instances in this repo before anything checked it:
`cancel_order`'s contract published on `expire_order`; `feeBreakdown`'s doc over
`feeRows`; `estimateLine`'s over `creditedSplit`; a direction warning stranded above a
function that computes no direction; and `refusal_counts` plus `orphan_depth` both glued
above `admin_order`, which the interface therefore documented with three unrelated
contracts. Every one was found by a human reading.

⚠️ **The orphan cannot be detected; the victim can.** Adjacent `///` lines are
indistinguishable from one multi-paragraph doc, so a text heuristic over doc blocks is
hopeless — the one written for this produced 70 candidates, of which 1 was real. But a
declaration whose doc was absorbed by a neighbour has **none of its own**, which is a
fixed syntactic target and therefore gate-able.

⚠️ **Scans the SOURCE, not the generated `.did`, and that changed for a measured
reason.** The first version parsed `backend.did`, which is the tidier oracle — until
endpoints moved into `mixin` blocks (#120) and every one of them lost its doc from the
interface. Measured on moc 1.15.1, via `mops build`, `moc --idl` directly, and
`mops generate candid` (byte-identical): **moc does not emit doc comments for mixin
members.** So the `.did` stopped being able to answer "is this endpoint documented",
while the source still can. Tracked upstream against moc; when it is fixed the `.did`
regains the docs and this check is unaffected either way.

⚠️ **What this does NOT reach**, stated because a check implying more than it verifies is
worse than no check:

  - **Whether a doc describes the declaration it sits on.** A method documented with the
    WRONG contract passes: it has a doc. This catches the victim, never the thief — so it
    makes the class *detectable*, not impossible. Two glued blocks over one undocumented
    neighbour is the shape it sees.
  - **Types, fields, and private helpers.** Only `public shared` / `public query`
    endpoints are checked.
  - **Doc quality.** A single `///` line satisfies it.
"""

import glob
import re
import sys

# Every file that may declare a public endpoint: the composition root and the mixins.
SOURCES = ("src/backend/Main.mo", "src/backend/mixins/*.mo")

ENDPOINT = re.compile(
    r"^\s*public\s+(?:shared\s+)?(?:query\s+)?(?:shared\s+)?(?:query\s+)?"
    r"(?:\([^)]*\)\s*)?func\s+([a-z_][A-Za-z0-9_]*)",
    # ⚠️ `re.M` so `^` means line-start: without it `findall` matched nothing and the
    # count went to zero. The abort guard caught that rather than reporting a clean scan,
    # which is the whole reason it is there.
    re.M,
)


def undocumented(text):
    """Endpoint names with no `///` line immediately above their declaration."""
    out = []
    lines = text.split("\n")
    for i, line in enumerate(lines):
        m = ENDPOINT.match(line)
        if not m:
            continue
        # Walk back over the declaration's own wrapped lines is unnecessary: the doc, if
        # any, is the line directly above the `public` line.
        prev = lines[i - 1].strip() if i > 0 else ""
        if not prev.startswith("///"):
            out.append(m.group(1))
    return out


def self_test():
    """⚠️ Unconditional, like the other parsers here. If the scan silently stops matching
    endpoints, this step passes while checking nothing."""
    sample = "\n".join([
        "  /// Documented.",
        "  public shared ({ caller }) func alpha() : async () {};",
        "  public query func beta() : async Nat { 0 };",
        "  /// Also documented.",
        "  public shared query ({ caller }) func gamma() : async Nat { 0 };",
        "  public shared func delta() : async () {};",
        "  // not a doc comment",
        "  public func epsilon() : async () {};",
        "  func privateHelper() : Nat { 0 };",
    ])
    got = undocumented(sample)
    if got != ["beta", "delta", "epsilon"]:
        sys.exit(f"ABORT: self-test expected ['beta', 'delta', 'epsilon'], got {got}")


def main():
    self_test()
    files = []
    for pattern in SOURCES:
        files.extend(sorted(glob.glob(pattern)))
    if not files:
        sys.exit(f"ABORT: no sources matched {SOURCES} — cannot pass vacuously")

    total = 0
    missing = []
    for f in files:
        text = open(f).read()
        total += len(ENDPOINT.findall(text))
        for name in undocumented(text):
            missing.append((f, name))
    if total == 0:
        sys.exit(f"ABORT: parsed no endpoints out of {files} — cannot pass vacuously")

    if missing:
        print("\n\033[31m✗ public endpoint(s) with no documentation\033[0m", file=sys.stderr)
        for f, name in missing:
            print(f"    {name}  ({f})", file=sys.stderr)
        print(
            "\n  Two causes, and the second is the one worth looking for:\n"
            "    1. It was never documented. Write the doc.\n"
            "    2. ⚠️ Its doc was ABSORBED by a neighbour — a declaration moved in\n"
            "       between a `///` block and the function it belonged to, so another\n"
            "       declaration now carries this one's contract. Look directly above\n"
            "       for a doc block with two unrelated summary lines, and move the\n"
            "       first one down.",
            file=sys.stderr,
        )
        return 1
    # ⚠️ Counts the files that HOLD endpoints, not the files scanned. `Main.mo` is in the
    # scan list and declares none since #120, so reporting the scan size would read as
    # though the composition root still had some.
    holders = sum(1 for f in files if ENDPOINT.search(open(f).read()))
    print(f"   {total} public endpoints across {holders} file(s): every one documented")
    return 0


if __name__ == "__main__":
    sys.exit(main())
