#!/usr/bin/env python3
"""Every configuration SETTER must have a reader, so no parameter is write-only.

    scripts/check-config-readers.py

⚠️ **Found by a UI spec, not by any check.** `set_delivery_config` could set `maxHoldNs`
(when a paid order escalates) and `alertAfterNs` (the delay-alert threshold), and **no
method returned either** — they appeared in the setter's argument and its error variant and
nowhere else. An operator could set the two bounds that decide when a stuck delivery
surfaces and never read them back. That went unnoticed through five PRs touching this
surface, because nothing was looking.

⚠️ **A setter missing from `READERS` is a FAILURE, not a skip.** That is the whole
mechanism: a new `set_*` method has to be classified deliberately, so the next write-only
parameter fails here instead of being discovered by a UI three months later.

The requirement is derived, not declared, wherever it can be: if a setter takes a single
NAMED type, the mapped reader must return that same type — so a config record gaining a
field is covered automatically. Where the argument is a primitive there is no type to
trace, and the entry names the field or settles for the reader existing.
"""

import re
import sys

DID = "src/backend/dist/backend.did"

# setter -> (reader method, required field in the reader's return, or None)
#
# ⚠️ The two secrets are here on purpose, with a reader that reports STATUS only. Their
# value must never be readable, so "has a reader" means "an operator can tell whether it is
# provisioned and which generation" — not that they can read it back.
READERS = {
    "set_gate_config":       ("lifecycle_config", None),
    "set_delivery_config":   ("lifecycle_config", None),
    "set_pricing_config":    ("pricing_status", None),
    "set_card_tiers":        ("card_tiers", None),
    "set_expected_livemode": ("expected_livemode", None),
    "set_stripe_origin":     ("stripe_origin", None),
    "set_recovery_interval": ("recovery_status", "intervalNs"),
    "set_stripe_api_key":    ("stripe_api_key_status", None),
    "set_webhook_secret":    ("webhook_secret_status", None),
}


def methods(text):
    """name -> (args, return) source, split at the method's first `->`."""
    out = {}
    starts = [(m.start(), m.group(1)) for m in re.finditer(r"^  ([a-z_][a-z0-9_]*):", text, re.M)]
    for i, (pos, name) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
        block = text[pos:end]
        head, _, tail = block.partition("->")
        out[name] = (head, tail)
    return out


def main() -> int:
    text = open(DID).read()
    m = methods(text)
    if not m:
        sys.exit(f"ABORT: parsed no methods out of {DID} — this check would pass vacuously")

    setters = sorted(n for n in m if n.startswith("set_"))
    if not setters:
        sys.exit(f"ABORT: found no set_* methods in {DID} — the parser is wrong")

    fail = []
    for s in setters:
        if s not in READERS:
            fail.append(
                f"{s} has no entry in READERS — classify it: name the query that reports its\n"
                f"      current value, or add a status-only reader and say why the value must not\n"
                f"      be readable. Defaulting to 'no reader needed' is what made\n"
                f"      set_delivery_config write-only."
            )
    for s in sorted(set(READERS) - set(setters)):
        fail.append(f"READERS names {s}, which is not a set_* method in the interface — stale entry")

    for s in setters:
        if s not in READERS:
            continue
        reader, field = READERS[s]
        if reader not in m:
            fail.append(f"{s}: its reader `{reader}` is not in the interface")
            continue
        args, _ = m[s]
        ret = m[reader][1]
        # Derived requirement: a single NAMED argument type must come back out.
        named = re.search(r"\(\s*[a-zA-Z_]+:\s*([A-Z][A-Za-z0-9_]*)\s*\)", args)
        if named:
            t = named.group(1)
            if not re.search(r"\b%s\b" % t, ret):
                fail.append(
                    f"{s} takes `{t}` and `{reader}` does not return it — the parameter is "
                    f"WRITE-ONLY"
                )
        if field and not re.search(r"\b%s:" % field, ret):
            fail.append(f"{s}: `{reader}` does not report `{field}`")

    if fail:
        print("\n\033[31m✗ a configuration parameter has no reader\033[0m", file=sys.stderr)
        for f in fail:
            print(f"    {f}", file=sys.stderr)
        print(
            "\n  An operator who cannot read a value back cannot check it, and a UI cannot\n"
            "  show it. Add the reader; do not relax this check.",
            file=sys.stderr,
        )
        return 1
    print(f"   {len(setters)} config setter(s), each with a reader")
    return 0


if __name__ == "__main__":
    sys.exit(main())
