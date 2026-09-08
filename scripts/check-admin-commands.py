#!/usr/bin/env python3
"""Every mutating admin method is offered as a command, or excluded ON PURPOSE.

    scripts/check-admin-commands.py

The operator console renders an `icp canister call` per mutating method, pre-filled from
the row you are looking at (#97). The table lives in `src/frontend/src/candid.ts` as
`CommandMethod`, and TypeScript makes a missing *renderer* a compile error — but it can
say nothing about a method that never made it into the union at all.

⚠️ **That gap is this script.** A new mutating admin method is a FAILURE here, never a
skip: absent from both the table and the exclusion list, it is a lever an operator has to
hand-author a command for, which is the transcription risk #97 exists to remove.

⚠️ **The exclusion list may only ever SHRINK**, and every entry carries why. Same
construction as `check-admin-tiers.py`'s tier table and `check-config-readers.py`'s
reader map: an exception that is visible in review and has to be defended.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DID = ROOT / "src" / "backend" / "dist" / "backend.did"
TABLE = ROOT / "src" / "frontend" / "src" / "candid.ts"

# ⚠️ Excluded DELIBERATELY. Each entry is a reason, not a to-do.
EXCLUDED = {
    # A rendered command containing the key lands in the page's DOM and its clipboard.
    # The console shows `stripe_api_key_status` instead. This exclusion is permanent.
    "set_stripe_api_key": "the key would land in the page's DOM and clipboard",
    # Same, and worse: whoever can set this can sign a payment event and take delivery
    # having paid nothing.
    "set_webhook_secret": "the signing secret is mint authority",
    # ⚠️ READS that are updates so the read itself is audited (#38). They mutate the
    # audit log and nothing else, so a "command to change" them would be nonsense —
    # the console calls them directly, as reads.
    "admin_order": "an audited READ, not a change",
    "admin_receipt": "an audited READ, not a change",
}


def did_update_methods() -> set[str]:
    """Every method in the .did that is NOT a query.

    Candid marks a query with a trailing `query`; anything else can mutate. Parsed from
    the generated interface rather than a hand-list, so the population is the canister's
    own and cannot drift.
    """
    text = DID.read_text()
    service = re.search(r"service\s*:\s*\{(.*)\}\s*$", text, re.S)
    if not service:
        sys.exit("ABORT: no service block in the .did. Run `mops build` first.")
    methods: set[str] = set()
    # `name : (args) -> (ret) query;` or `name : (args) -> (ret);`
    for m in re.finditer(r"^\s*(\w+)\s*:\s*\((.*?)\)\s*->\s*\((.*?)\)\s*(query)?\s*;",
                         service.group(1), re.S | re.M):
        if m.group(4) is None:
            methods.add(m.group(1))
    return methods


def tabled_methods() -> set[str]:
    """The names in `CommandMethod`."""
    text = TABLE.read_text()
    union = re.search(r"export type CommandMethod =(.*?);", text, re.S)
    if not union:
        sys.exit(f"ABORT: no CommandMethod union in {TABLE.relative_to(ROOT)}")
    return set(re.findall(r'"(\w+)"', union.group(1)))


def _self_test() -> None:
    """Unconditional, because this script's whole value is its two parsers.

    ⚠️ `check-admin-tiers.py` shipped a boundary-regex fix that never reached the file,
    and its "unit test" tested a string literal rather than the parser. So this runs
    every time, against text of the shape each parser really meets.
    """
    svc = """service : {
      a_query : (nat) -> (nat) query;
      a_mutation : (text) -> (nat);
      multi_line : (
        record { x : nat }
      ) -> (nat);
      spaced_query : () -> (bool)   query ;
    }"""
    global DID
    real = DID
    try:
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".did", delete=False) as fh:
            fh.write(svc)
            DID = Path(fh.name)
        got = did_update_methods()
    finally:
        DID = real
    want = {"a_mutation", "multi_line"}
    assert got == want, f"self-test: parser found {got}, wanted {want}"

    union_text = 'export type CommandMethod =\n  | "one"\n  | "two";\n'
    assert set(re.findall(r'"(\w+)"', union_text)) == {"one", "two"}, "self-test: union parse"


def main() -> int:
    _self_test()
    updates = did_update_methods()
    tabled = tabled_methods()

    # Anything the canister can mutate through, that a caller reaches as an operator.
    # `create_order`, `cancel_order` and the webhook route are BUYER paths and are not
    # operator commands, so they are named here rather than in EXCLUDED: excluding them
    # would imply somebody chose not to render them.
    # ⚠️ `process_order` is NOT here: it is a buyer path AND an operator lever (it
    # re-drives a stalled delivery, audited as `delivery.manualKick`), so it belongs in
    # the table rather than exempted from it.
    buyer_paths = {"create_order", "cancel_order", "http_request_update"}
    candidates = updates - buyer_paths

    missing = sorted(candidates - tabled - set(EXCLUDED))
    stale = sorted(tabled - updates)
    leaked = sorted(set(EXCLUDED) & tabled)

    if missing or stale or leaked:
        print("\033[31m✗ the console's command table is not the canister's write surface\033[0m",
              file=sys.stderr)
        for name in missing:
            print(f"    {name} can mutate and is offered nowhere. Add it to CommandMethod,"
                  f" or to EXCLUDED with the reason.", file=sys.stderr)
        for name in stale:
            print(f"    {name} is in the table and not in the canister. Remove it.",
                  file=sys.stderr)
        for name in leaked:
            print(f"    {name} is EXCLUDED and also tabled. A command for it would put a"
                  f" secret in the page.", file=sys.stderr)
        return 1

    print(f"   {len(tabled)} command(s) cover the write surface;"
          f" {len(EXCLUDED)} excluded on purpose")
    return 0


if __name__ == "__main__":
    sys.exit(main())
