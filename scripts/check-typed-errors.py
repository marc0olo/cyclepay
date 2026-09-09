#!/usr/bin/env python3
"""Fail if a public endpoint returns `Result<_, Text>`.

An untyped error forces every caller to match on prose to tell one failure from another
(`reviewing-motoko` T4). The sweep that removed the last one finished in #123; this is
what keeps it finished.

⚠️ **Enforced rather than achieved, because achieved uniformity decays.** Three surfaces
in this repo reached "complete" and then regressed while nothing was watching — the admin
command table, the doc-surface list, and the gate/CI script pair. A rule with no check is
a rule the next endpoint walks past.

Reads the generated `backend.did`, not the source: that is where a caller sees the error,
and it is the artifact the frontend's bindings come from.

⚠️ **What this does NOT reach:**

  - **A variant with a `Text` payload.** `#stripeFailed : { detail : Text }` is fine and
    stays fine — Stripe's own wording is a string an external system owns, which is the
    case T1 leaves alone. Only `Result`'s whole error position is checked.
  - **`Text` in an OK position.** A method returning text is not an error contract.
  - **Whether a variant's arms are well chosen.** It sees that the error is typed, never
    that the types are right.
"""

import re
import sys

DID = "src/backend/dist/backend.did"

# `type Result_N = variant { err: <type>; ok: ... }` — the shape bindgen emits.
RESULT = re.compile(
    r"^type\s+(Result[A-Za-z0-9_]*)\s*=\s*\n\s*variant\s*\{(.*?)\n\s*\};",
    re.M | re.S,
)


def untyped(did_text):
    """Result type names whose `err` position is bare `text`."""
    out = []
    for m in RESULT.finditer(did_text):
        body = m.group(2)
        if re.search(r"\berr\s*:\s*text\s*;", body):
            out.append(m.group(1))
    return out


def self_test():
    """⚠️ Unconditional: if the pattern stops matching, everything reads as typed."""
    sample = "\n".join([
        "type Result_1 = ",
        " variant {",
        "   err: text;",
        "   ok: Order;",
        " };",
        "type Result_2 = ",
        " variant {",
        "   err: CancelOrderError;",
        "   ok: Order;",
        " };",
        "type Result_3 = ",
        " variant {",
        "   err: record { detail: text };",
        "   ok;",
        " };",
        "service : {",
        "  cancel_order: (OrderId) -> (Result_2);",
        " }",
    ])
    got = untyped(sample)
    if got != ["Result_1"]:
        sys.exit(f"ABORT: self-test expected ['Result_1'], got {got}")
    if not RESULT.search(sample):
        sys.exit("ABORT: self-test — the Result pattern matched nothing at all")


def main():
    self_test()
    try:
        text = open(DID).read()
    except OSError as e:
        sys.exit(f"ABORT: cannot read {DID} ({e}) — cannot pass vacuously")

    results = RESULT.findall(text)
    if not results:
        sys.exit(f"ABORT: found no Result types in {DID} — cannot pass vacuously")

    bad = untyped(text)
    if bad:
        print("\n\033[31m✗ endpoint error type(s) are bare `text`\033[0m", file=sys.stderr)
        for name in bad:
            users = re.findall(rf"^\s+([a-z_0-9]+):.*\b{name}\b", text, re.M)
            print(f"    {name} — used by {', '.join(users) or '(no endpoint)'}", file=sys.stderr)
        print(
            "\n  Make the error a variant with the data each case needs (T4). A caller\n"
            "  cannot tell one failure from another by matching on prose, and the copy a\n"
            "  buyer or operator reads belongs where it can change without a canister\n"
            "  upgrade — see docs/DESIGN.md §7.2 for what may move and what may not.",
            file=sys.stderr,
        )
        return 1

    print(f"   {len(results)} Result types in the interface: every error position is typed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
