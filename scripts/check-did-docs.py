#!/usr/bin/env python3
"""Fail if a public method in the generated `.did` carries no documentation.

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
indistinguishable from one multi-paragraph doc, so a text heuristic over the source is
hopeless — the one written for this produced 70 candidates, of which 1 was real. But a
declaration whose doc was absorbed by a neighbour has **none of its own**, and the
generated interface names it. That is a fixed syntactic target, so it is gate-able.

⚠️ **What this does NOT reach**, stated because a check implying more than it verifies is
worse than no check:

  - **Whether a doc describes the method it sits on.** A method documented with the WRONG
    contract passes: it has a doc. This catches the victim, never the thief — so it makes
    the class *detectable*, not impossible. Two glued blocks over one undocumented
    neighbour is the shape it sees.
  - **Types, fields and variant cases.** Only `service :` methods are checked.
  - **Doc quality.** An empty-but-present `///` line satisfies it.
"""

import re
import sys

DID = "src/backend/dist/backend.did"


def undocumented(did_text):
    body = did_text[did_text.index("service : {") :]
    out = []
    prev_doc = False
    for line in body.split("\n"):
        method = re.match(r"\s{2}([a-z_][a-z0-9_]*):\s", line)
        if method and not prev_doc:
            out.append(method.group(1))
        # A doc block is `///` lines; a wrapped method signature continues the previous
        # line, so it must not reset the flag.
        stripped = line.strip()
        prev_doc = (
            stripped.startswith("///")
            or (prev_doc and not method and stripped and not re.match(r"\s{2}[a-z_]", line))
        )
    return out


def self_test():
    """⚠️ Unconditional, like the other parsers here. If the scan silently stops finding
    methods, this step passes while checking nothing."""
    sample = """service : {
  /// Documented.
  alpha: () -> ();
  beta: () -> ();
  /// Wrapped signature, documented.
  gamma: (a: nat, b: nat) ->
   (nat) query;
  delta: (a: nat) -> ();
}"""
    got = undocumented(sample)
    if got != ["beta", "delta"]:
        sys.exit(f"ABORT: self-test expected ['beta', 'delta'], got {got}")


def main():
    self_test()
    try:
        text = open(DID).read()
    except OSError as e:
        sys.exit(f"ABORT: cannot read {DID} ({e}) — run `mops build` first")
    if "service : {" not in text:
        sys.exit(f"ABORT: no service block in {DID} — cannot pass vacuously")

    total = len(re.findall(r"^\s{2}[a-z_][a-z0-9_]*:\s", text[text.index("service : {"):], re.M))
    if total == 0:
        sys.exit(f"ABORT: parsed no methods out of {DID} — cannot pass vacuously")

    missing = undocumented(text)
    if missing:
        print("\n\033[31m✗ public method(s) with no documentation in the interface\033[0m", file=sys.stderr)
        for m in missing:
            print(f"    {m}", file=sys.stderr)
        print(
            "\n  Two causes, and the second is the one worth looking for:\n"
            "    1. It was never documented. Write the doc.\n"
            "    2. ⚠️ Its doc was ABSORBED by a neighbour — a declaration moved in\n"
            "       between a `///` block and the function it belonged to, so the\n"
            "       interface now documents another method with this one's contract.\n"
            "       Look at the method directly above it in `Main.mo` for a doc block\n"
            "       with two unrelated summary lines, and move the first one down.\n"
            "  Then `mops build` and read the .did diff: the doc should move from the\n"
            "  wrong method onto the right one.",
            file=sys.stderr,
        )
        return 1
    print(f"   {total} interface methods: every one documented")
    return 0


if __name__ == "__main__":
    sys.exit(main())
