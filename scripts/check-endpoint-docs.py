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

⚠️ **Two checks over two oracles, and neither subsumes the other.**

  1. `undocumented()` reads the SOURCE and asks "does every endpoint have a doc". The
     first version asked this of `backend.did`, the tidier oracle — until endpoints moved
     into `mixin` blocks (#120) and moc dropped every one of their docs from the
     interface, so the `.did` could no longer answer it. The source always could.
  2. `misattributed()` reads BOTH and asks "is the doc the interface publishes the one
     written above that endpoint". Only the `.did` can answer this, because the class it
     catches is invisible in source by construction.

⚠️ **moc 1.16.0 emits mixin members' docs, which is why (2) has this shape.** Measured on
this project: 0 doc lines inside the `service` block on 1.15.1, **613 on 1.16.0**, with
all 62 endpoints' published blocks byte-equal to their source blocks. The previous version
of (2) asserted the `.did` documented *no* endpoint — sound only while the docs were being
dropped — and its remedy said *make it `//` instead of `///`*, which under 1.16.0 would
delete a deliberately published doc. Comparing the two texts replaces an absence
assertion with a direct one.

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
    `allowedBuyers`' on `withdraw_reserve` — so `misattributed()` below covers this one
    from the `.did` side, which is the only side that can see it.
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


def doc_above(lines, i):
    """The `///` block immediately above line `i`, in source order, markers stripped."""
    out, j = [], i - 1
    while j >= 0 and lines[j].strip().startswith("///"):
        out.append(lines[j].strip()[3:].strip())
        j -= 1
    return list(reversed(out))


def published_docs(did_text):
    """endpoint name -> the doc block the `.did` carries for it."""
    lines = did_text.split("\n")
    service = next((i for i, l in enumerate(lines) if l.startswith("service")), None)
    if service is None:
        sys.exit(f"ABORT: no `service` block in {DID} — cannot pass vacuously")
    out = {}
    # ⚠️ **`service + 1`, and the `+ 1` is load-bearing.** `service : {` escapes
    # `DID_METHOD` only because moc puts a space before the colon. Scanning from
    # `service` itself would report `service` as an endpoint the day that whitespace
    # changes, and the line above it is `Main.mo`'s file header, which moc emits as the
    # service doc — so it would look like a misattribution nobody could connect back to
    # a compiler's spacing.
    for i in range(service + 1, len(lines)):
        m = DID_METHOD.match(lines[i])
        if m:
            doc = doc_above(lines, i)
            if doc:
                out[m.group(1)] = doc
    return out


def written_docs(files):
    """endpoint name -> the doc block written above its declaration in the source."""
    out = {}
    for f in files:
        lines = open(f).read().split("\n")
        for i, line in enumerate(lines):
            m = ENDPOINT.match(line)
            if m:
                doc = doc_above(lines, i)
                if doc:
                    out[m.group(1)] = doc
    return out


def misattributed(published, written):
    """Endpoints whose PUBLISHED doc is not the one written above their declaration.

    ⚠️ **This replaced a check asserting the `.did` documented NO endpoint.** That
    invariant held for a mechanical reason — moc did not emit doc comments for mixin
    members, and every endpoint is in a mixin — so any doc that appeared in the service
    block had floated there off a private declaration. **moc 1.16.0 emits mixin members'
    docs**, measured at 0 -> 613 doc lines inside this project's service block, so the old
    premise is gone and its remedy (*make it `//`*) would now delete a correct doc.

    The class it existed for survives, and this is the direct form of it: a doc absorbed
    onto an endpoint during EMISSION is invisible in the source — the block sits correctly
    above the declaration that owns it — and shows up only as a `.did` that publishes
    something other than what was written. Comparing the two catches it by construction,
    rather than by asserting the absence of all docs.

    ⚠️ **What this does NOT catch, and `undocumented()` does.** A SOURCE-level theft — a
    declaration moved in between a `///` block and its function — relocates the doc to the
    neighbour, and moc then publishes it there. `.did` and source agree, so this function
    is silent; the tell is the victim, which loses its doc entirely. The two checks are
    complementary and neither subsumes the other.
    """
    out = []
    for name in sorted(published):
        if written.get(name) != published[name]:
            out.append(name)
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

    # ⚠️ **Both directions, because a comparison that never reports is the failure mode
    # here.** The old check asserted an absence, so "no docs found" and "scanner broken"
    # produced the same pass. This one compares two parsers, so BOTH have to be shown
    # working: one endpoint that agrees must stay silent, one that disagrees must report.
    did = "\n".join([
        "type Order = record { id : nat };",
        "service : {",
        "  /// Fetch one order.",
        "  get_order: (OrderId) -> (opt Order) query;",
        "  /// Liveness.",
        "  health: () -> (Health) query;",
        "  undocumented_here: () -> ();",
        "}",
    ])
    pub = published_docs(did)
    if pub != {"get_order": ["Fetch one order."], "health": ["Liveness."]}:
        sys.exit(f"ABORT: self-test — published_docs parsed {pub}")

    agreeing = {"get_order": ["Fetch one order."], "health": ["Liveness."]}
    if misattributed(pub, agreeing) != []:
        sys.exit("ABORT: self-test — matching docs reported as misattributed")

    # A doc published on an endpoint that is not the doc written above it.
    disagreeing = {"get_order": ["Cancel an order."], "health": ["Liveness."]}
    if misattributed(pub, disagreeing) != ["get_order"]:
        sys.exit(
            "ABORT: self-test — a published doc differing from the written one was not "
            f"reported: {misattributed(pub, disagreeing)}"
        )

    # An endpoint the source has no doc for at all, published with one anyway: the exact
    # shape of an absorbed doc, and it must not be silently tolerated.
    if misattributed(pub, {"health": ["Liveness."]}) != ["get_order"]:
        sys.exit("ABORT: self-test — a published doc with no written counterpart passed")

    # ⚠️ The service line itself, spelled without moc's space, must not read as an
    # endpoint — see the note in `published_docs`. This case is what pins the `+ 1`.
    tight = "\n".join([
        "/// The actor's own doc, which moc DOES emit.",
        "service: {",
        "  health: () -> (Health) query;",
        "}",
    ])
    if published_docs(tight) != {}:
        sys.exit(f"ABORT: self-test — the service line read as an endpoint: {published_docs(tight)}")

    # `written_docs` shares `doc_above` with the above, but its ENDPOINT matcher is its
    # own; a regex that stops matching would make every endpoint look undocumented in
    # source and therefore misattributed, so it is exercised too.
    import tempfile, os
    fd, path = tempfile.mkstemp(suffix=".mo")
    with os.fdopen(fd, "w") as fh:
        fh.write(sample)
    got_written = written_docs([path])
    os.unlink(path)
    if got_written != {"alpha": ["Documented."], "gamma": ["Also documented."]}:
        sys.exit(f"ABORT: self-test — written_docs parsed {got_written}")


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
    # ⚠️ **This used to be a SOUNDNESS precondition and is now only an architecture
    # rule.** The old leak scan read any doc in the service block as floated off private
    # state, which held only while no endpoint was declared in the composition root.
    # `misattributed()` compares published against written wherever the endpoint lives,
    # so it no longer depends on this. Kept because A1 is worth enforcing on its own, and
    # checked first so a stray root endpoint still gets its own message.
    root = "src/backend/Main.mo"
    root_endpoints = len(ENDPOINT.findall(open(root).read())) if root in files else 0
    if root_endpoints:
        print(
            f"\n\033[31m✗ {root} declares {root_endpoints} public endpoint(s)\033[0m",
            file=sys.stderr,
        )
        print(
            "\n  The composition root holds state and `include`s, no endpoints\n"
            "  (`reviewing-motoko` A1). Move it to the mixin that owns the feature.",
            file=sys.stderr,
        )
        return 1

    published = published_docs(open(DID).read())
    written = written_docs(files)
    # ⚠️ **A FLOOR, not an emptiness test, and the difference is the whole guard.**
    # `if not published` fires only when every doc disappears. Lose 30 of 62 and the
    # comparison would run over the surviving 32, report "all 32 match", and pass — with
    # half the interface's documentation gone and `undocumented()` blind to it, because it
    # reads only the source. Same shape as `MIN_VECTORS` in check-crypto-vectors.sh.
    #
    # ⚠️ **A floor rather than `len(published) == total`.** `ENDPOINT` also matches a plain
    # `public func` in a mixin, so equality would quietly couple this guard to "no
    # non-shared public func lives in a mixin" — true at 62/62 today, and not a property
    # this check should start enforcing by accident.
    MIN_PUBLISHED = 55
    if len(published) < MIN_PUBLISHED:
        sys.exit(
            f"ABORT: {DID} documents only {len(published)} endpoint(s), expected at least"
            f" {MIN_PUBLISHED}. Since moc 1.16.0 every endpoint's doc is published, so this"
            " means an older compiler built the .did, or the scan stopped matching, or docs"
            " were dropped in bulk — all of which compare nothing and read as a clean run."
        )
    wrong = misattributed(published, written)
    if wrong:
        print(
            "\n\033[31m✗ the .did publishes a doc that is not the one written above the"
            " endpoint\033[0m",
            file=sys.stderr,
        )
        for name in wrong:
            print(f"    {name}", file=sys.stderr)
            pub, wri = published[name], written.get(name)
            if wri is None:
                print("      written:   (no doc above the declaration)", file=sys.stderr)
                print(f"      published: {' '.join(pub)[:96]}", file=sys.stderr)
                continue
            # ⚠️ **Show the first line that DIFFERS, not the first line of each.** These
            # blocks routinely share a long opening paragraph, so printing each one's head
            # produced two identical-looking lines under a "these differ" heading — a
            # message that names the right endpoint and then shows nothing wrong with it.
            at = next(
                (i for i in range(max(len(pub), len(wri)))
                 if (pub[i] if i < len(pub) else None) != (wri[i] if i < len(wri) else None)),
                None,
            )
            print(f"      first difference at doc line {at + 1} of {len(pub)}:", file=sys.stderr)
            print(f"        published: {(pub[at] if at < len(pub) else '(block ends)')[:88]}", file=sys.stderr)
            print(f"        written:   {(wri[at] if at < len(wri) else '(block ends)')[:88]}", file=sys.stderr)
        print(
            "\n  The doc reached the interface from something other than this endpoint's\n"
            "  own block — absorbed during emission, which the source cannot show: every\n"
            "  block sits correctly above whatever owns it and only the .did disagrees.\n"
            "  Compare the two texts above and move the block that belongs here.\n"
            "  ⚠️ Or the .did is simply STALE — run `mops build`. The gate and CI both\n"
            "  rebuild before this step so it cannot land there, but a direct run on a\n"
            "  dirty tree reports a real mismatch with a doc nobody misfiled.\n"
            "  ⚠️ Do NOT silence this by making the doc `//`. Since moc 1.16.0 endpoint\n"
            "  docs are published deliberately, so that deletes part of the interface.",
            file=sys.stderr,
        )
        return 1

    # ⚠️ Counts the files that HOLD endpoints, not the files scanned. `Main.mo` is in the
    # scan list and declares none since #120, so reporting the scan size would read as
    # though the composition root still had some.
    holders = sum(1 for f in files if ENDPOINT.search(open(f).read()))
    print(
        f"   {total} public endpoints across {holders} file(s): every one documented,"
        f" and all {len(published)} published doc(s) match their own source"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
