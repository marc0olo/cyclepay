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
  - **A doc absorbed onto an endpoint from a NON-endpoint neighbour.** Invisible in
    source by construction: the block sits correctly above the state declaration that
    owns it, and the endpoint has its own `///`, so thief and victim both read clean.
    Only the `.did` shows it. Four live instances existed at the tip of #120 —
    `webhookSecret`'s doc published on `get_order`, the price tiles' on
    `resolve_problem`, `rateRefreshFailures`' on `set_recovery_interval`, and
    `allowedBuyers`' on `withdraw_reserve` — so `no_leaked_docs()` below covers this
    one from the `.did` side, which is the only side that can see it.
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


DID = "src/backend/dist/backend.did"

# A service method plus, on the line before, a doc line.
DID_METHOD = re.compile(r"^\s*([a-z_][a-z_0-9]*):\s")


def leaked_docs(did_text):
    """Endpoints the `.did` documents, which since #120 means endpoints documented with
    somebody ELSE's doc.

    ⚠️ **The invariant is "none", and it holds for a mechanical reason.** moc does not
    emit doc comments for mixin members, and no endpoint lives outside a mixin — A1
    forbids a public method in the composition root. So every endpoint's own doc is
    dropped, and any doc that DOES appear in the service block floated there from a
    declaration candid does not emit: a state `let`/`var` in `Main.mo`. Measured: only
    4 of that file's 786 `///` lines leaked, onto endpoints they have no relation to,
    by position aliasing inside the compiler that source-side scanning cannot see.

    ⚠️ **The one case that would make this unsound — a documented endpoint declared in
    `Main.mo` — is refused by `main()` before the scan runs**, with its own message. That
    check is what turns the premise above from prose into an invariant; without it, the
    remedy printed below ("make it `//`") would be handed to a case it destroys.
    """
    lines = did_text.split("\n")
    service = next((i for i, l in enumerate(lines) if l.startswith("service")), None)
    if service is None:
        sys.exit(f"ABORT: no `service` block in {DID} — cannot pass vacuously")
    out = []
    for i in range(service, len(lines)):
        m = DID_METHOD.match(lines[i])
        if m and i > 0 and lines[i - 1].strip().startswith("///"):
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

    did = "\n".join([
        "type Order = record { id : nat };",
        "service : {",
        "  /// Somebody else's doc, floated here.",
        "  get_order: (OrderId) -> (opt Order) query;",
        "  health: () -> (Health) query;",
        "}",
    ])
    got = leaked_docs(did)
    if got != ["get_order"]:
        sys.exit(f"ABORT: self-test expected ['get_order'] leaked, got {got}")


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
    # ⚠️ **`leaked_docs()`'s soundness rests on this, so it is asserted, not asserted-in-
    # prose.** "Any doc in the service block floated there" is only true while no endpoint
    # is declared in the composition root — and one that IS declared there arrives with a
    # legitimate doc, which the leak scan would then report with a remedy that strips it
    # (#89's shape: an unrecognised case handed the wrong fix). Checked first, so that
    # case gets its own message and never reaches the other one.
    root = "src/backend/Main.mo"
    root_endpoints = len(ENDPOINT.findall(open(root).read())) if root in files else 0
    if root_endpoints:
        print(
            f"\n\033[31m✗ {root} declares {root_endpoints} public endpoint(s)\033[0m",
            file=sys.stderr,
        )
        print(
            "\n  The composition root holds state and `include`s, no endpoints\n"
            "  (`reviewing-motoko` A1). Move it to the mixin that owns the feature.\n"
            "  This also keeps the .did leak scan below sound: it reads any doc in the\n"
            "  service block as floated off private state, which stops being true the\n"
            "  moment a documented endpoint is declared here.",
            file=sys.stderr,
        )
        return 1

    leaked = leaked_docs(open(DID).read())
    if leaked:
        print(
            "\n\033[31m✗ the .did documents endpoint(s) with a doc that is not theirs\033[0m",
            file=sys.stderr,
        )
        for name in leaked:
            print(f"    {name}", file=sys.stderr)
        print(
            "\n  moc drops mixin members' docs, and every endpoint is in a mixin — so a\n"
            "  doc in the service block did not come from the endpoint it sits on. It\n"
            "  floated off a state declaration in Main.mo. Find the block whose text\n"
            "  matches, and make it `//` instead of `///`: candid emits nothing for\n"
            "  private state, which is exactly why the doc leaks instead of landing.",
            file=sys.stderr,
        )
        return 1

    # ⚠️ Counts the files that HOLD endpoints, not the files scanned. `Main.mo` is in the
    # scan list and declares none since #120, so reporting the scan size would read as
    # though the composition root still had some.
    holders = sum(1 for f in files if ENDPOINT.search(open(f).read()))
    print(
        f"   {total} public endpoints across {holders} file(s): every one documented,"
        " and the .did documents none with a neighbour's"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
