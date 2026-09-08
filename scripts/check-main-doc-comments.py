#!/usr/bin/env python3
"""Fail if `Main.mo` uses `///` anywhere but its leading block.

⚠️ **A `///` on a declaration candid does not emit cannot land anywhere legitimate — it
is either dropped or LEAKED onto an unrelated endpoint.** That is not a style rule, it is
the whole failure mode: moc assigns doc comments to emitted declarations by position, and
the composition root emits nothing except the service itself (A1 — no public methods
here). So a doc block on a state `let`, a private helper, or a `transient var` has no
destination, and the compiler gives it the nearest one it can find.

**Four live instances existed before this check.** `webhookSecret`'s doc was published on
`get_order`, the price tiles' on `resolve_problem`, `rateRefreshFailures`' on
`set_recovery_interval`, and `allowedBuyers`' on `withdraw_reserve` — so the interface
told a reader that `get_order` was the Stripe webhook signing key. It reached the
generated TypeScript too, which is what shows on hover in an editor.

⚠️ **`check-endpoint-docs.py`'s `leaked_docs()` detects the same class from the `.did`,
and this check exists because detecting it is the wrong end.** The leak is POSITIONAL:
measured while reviewing #125, inserting a single declaration into `Main.mo` shifted two
FURTHER endpoints into leaking, from private-state docs unrelated to them. So the
detector fires on edits that did not cause it, with "find the block whose text matches"
as the recurring fix. Refusing the input at the source means the diagnostic names the
line responsible and needs no rebuild to fire. `leaked_docs()` stays as the backstop for
whatever this cannot see.

**The one legitimate `///`: the file's leading block.** moc emits it as the service
documentation — verified in `backend.did`, where it sits directly above `service : {`,
not at the top of the file. In the source it sits above the first `import` rather than
above `persistent actor`, which is why this check is positional rather than looking for
the actor line. ⚠️ That placement is what `leaked_docs()`'s `service + 1` accounts for:
the emitted doc is permanently the line before the service line.

⚠️ **What this does NOT reach**, stated because a check implying more than it verifies is
worse than no check:

  - **Any other file.** Modules and mixins are unaffected: a `///` on a module's `public
    func` is the right convention, and mixin members' docs are dropped rather than
    leaked. Only the composition root has a service to leak ONTO.
  - **Whether the comment is any good.** `//` and `///` are equally unpublished here, so
    this is purely about where moc may send the text.
  - ⚠️ **The cost this does impose, stated rather than waved away.** `///` is what a
    Motoko LSP surfaces on hover, and `//` is not — so the 742 converted blocks lose
    hover, and only that. Nothing *publishes* them (no `mo-doc` or `mops docs` here, and
    `backend.did` never carried the text), and they document actor-private declarations,
    so anyone reading them is already in the file. If moc stops aliasing docs onto
    unrelated endpoints, converting back is one `sed` — which is how this direction was
    proven in the first place.
"""

import re
import sys

MAIN = "src/backend/Main.mo"


def offenders(text):
    """Line numbers (1-based) of `///` lines outside the file's leading block."""
    lines = text.split("\n")
    # The leading block: the run of `///` lines at the very top of the file.
    lead = 0
    while lead < len(lines) and lines[lead].startswith("///"):
        lead += 1
    return [i + 1 for i in range(lead, len(lines)) if lines[i].lstrip().startswith("///")]


def self_test():
    """⚠️ Unconditional, like the other parsers here. A scan that silently stops matching
    passes while checking nothing."""
    sample = "\n".join([
        "/// The service doc. Emitted by candid.",
        "/// Second line of it.",
        'import Array "mo:core/Array";',
        "persistent actor {",
        "  /// Leaks onto whichever endpoint moc aliases it to.",
        "  let webhookSecret = Secret.emptyStore();",
        "  // Fine: not a doc comment.",
        "  let admins = Set.empty<Principal>();",
        "};",
    ])
    got = offenders(sample)
    if got != [5]:
        sys.exit(f"ABORT: self-test expected [5], got {got}")
    # A file with no leading block must not treat its first `///` as the exempt one.
    if offenders("persistent actor {\n  /// nope\n};") != [2]:
        sys.exit("ABORT: self-test — a `///` with no leading block should be reported")


def main():
    self_test()
    try:
        text = open(MAIN).read()
    except OSError as e:
        sys.exit(f"ABORT: cannot read {MAIN} ({e}) — cannot pass vacuously")
    if "///" not in text:
        sys.exit(
            f"ABORT: {MAIN} has no `///` at all, not even its service doc block — that "
            "block is emitted into backend.did and should not have been removed"
        )

    bad = offenders(text)
    if bad:
        lines = text.split("\n")
        print(
            f"\n\033[31m✗ {MAIN} uses `///` outside its leading block "
            f"({len(bad)} line(s))\033[0m",
            file=sys.stderr,
        )
        for n in bad[:10]:
            print(f"    {MAIN}:{n}: {lines[n - 1].strip()[:76]}", file=sys.stderr)
        if len(bad) > 10:
            print(f"    … and {len(bad) - 10} more", file=sys.stderr)
        print(
            "\n  Use `//`. Candid emits nothing for a declaration in the composition\n"
            "  root, so a `///` here has no destination and moc gives it the nearest\n"
            "  one it can find — an unrelated endpoint in the service block, which the\n"
            "  interface then documents with the wrong contract. `//` says the same\n"
            "  thing to a reader and cannot leak.\n"
            "\n  The leading block is the exception: moc emits it as the service doc.",
            file=sys.stderr,
        )
        return 1

    print(f"   {MAIN}: `///` only where candid emits it — the service doc block")
    return 0


if __name__ == "__main__":
    sys.exit(main())
