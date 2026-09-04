#!/usr/bin/env python3
"""Every admin-gated method is in exactly one tier, and CALLS the guard its tier declares.

    scripts/check-admin-tiers.py

⚠️ **Membership is not the property that matters.** A list of methods plus a check that
every admin method appears in it proves the list is COMPLETE — it proves nothing about
whether the code honours it. A method filed as controller-only whose body calls the
delegable guard would satisfy such a check while being delegable in fact. So this asserts,
per method, that the guard in its body is the one its tier requires.

⚠️ **The population is DERIVED from the source, never declared.** A method is admin-gated
if its body calls one of the guards, so a new one that is in neither tier fails here. A
hand-written population would let a new method be admin-gated and unlisted at the same
time, which is the state this exists to make impossible.

⚠️ **This check and `check-doc-surface.py` COMPOSE, and neither covers the gap alone.** The
population here is guard-derived, so a method MEANT to be admin-gated that forgot the guard
entirely is invisible here — it simply looks public. What catches that is the
`unclassifiable` outcome in `check-doc-surface.py`: a method taking `{ caller }` calling
neither guard nor an owner helper fails there by name. **Relaxing `unclassifiable` when it
gets noisy reopens an authz hole this file cannot see.**

The tiers, and the line between them: **an admin resolves individual cases; a controller
changes the rules.** Anything that moves secrets, pricing, the gate, the mode, the
delivery bounds or the admin list itself is the RULES tier — a controller can already
upgrade and drain the canister, so that tier is canister control. The per-order decisions,
the operator reads and the idempotent levers are the CASES tier: an admin can end one
order and cannot upgrade the canister.
"""

import re
import sys

MAIN = "src/backend/Main.mo"
GUARDS = {"requireController": "controller", "requireAdmin": "admin"}

# A top-level declaration in the actor: two-space indent, `func` anywhere after it.
#
# ⚠️ `.*?` may be EMPTY, so a line beginning `  func …` matches. The lookahead keeps
# deeper-indented closures out — several bodies pass a `func(order, entry) { … }` to a
# fold, and treating those as boundaries would truncate the body before its guard.
#
# ⚠️ Named once so `_self_test` cannot drift from the parser it is testing. The first
# version of this fix was verified against a string literal typed into the test rather
# than against the file, and the file kept the broken pattern.
BOUNDARY = r"^  (?=\S).*?\bfunc\s+[A-Za-z_]"

# method -> tier. ⚠️ Absent = FAILURE, never a skip.
TIERS = {
    # ── RULES: a controller changes the rules ───────────────────────────────────────────
    "set_webhook_secret": "controller",     # HMAC verification is the trust root: whoever
                                            # sets it can sign a completed-session event
                                            # for an order they made and take delivery
    "set_stripe_api_key": "controller",     # session-creation authority
    "set_expected_livemode": "controller",  # removes the guard that stops a test-mode
                                            # payment delivering
    "set_gate_config": "controller",        # the purchase ceiling and the gas floor
    "set_pricing_config": "controller",     # the fee — selling below cost
    "set_card_tiers": "controller",         # the presets, validated against the gate
    "set_recovery_interval": "controller",  # huge stalls deliveries; small burns cycles
    "set_delivery_config": "controller",    # `maxHoldNs` decides when a stuck delivery
                                            # surfaces at all
    "set_stripe_origin": "controller",      # where Stripe returns the buyer
    "add_admin": "controller",              # granting the other tier
    "remove_admin": "controller",
    "admins": "controller",                 # who holds the tier is a controller's business
    "add_allowed_buyer": "controller",      # who may take cycles out of a funded reserve
                                            # for free test money is a RULE, not a case —
                                            # and removing the last entry stops the
                                            # gateway selling at all (#99 2b)
    "remove_allowed_buyer": "controller",
    "allowed_buyers": "controller",         # the list bounds a giveaway; who is on it is a
                                            # controller's business, like `admins`
    "withdraw_reserve": "controller",       # ⚠️ a money-OUT edge, and the second
                                            # destination class in the whole design.
                                            # Controller-only not as a hardening choice
                                            # but because it grants no new capability at
                                            # that tier: a controller can already move
                                            # the reserve by upgrading the canister
                                            # (Auth.mo's tier note). Granting it to the
                                            # admin tier WOULD be new authority (#103)
    # ── CASES: an admin resolves one case ───────────────────────────────────────────────
    "abandon_order": "admin",               # irreversible RECORD on one identified order,
                                            # audited under the actor's own principal, and
                                            # checkable against the ledger. ⚠️ It releases
                                            # the reserve promise — not "moves no cycles"
    "record_delivered": "admin",            # ditto, and demands the ledger block as
                                            # evidence
    "expire_order": "admin",                # only moves a `#created` order, and only when
                                            # Stripe says it is unpayable
    "resolve_orphan": "admin",              # bookkeeping on one obligation
    "resolve_problem": "admin",
    "refresh_reserve": "admin",             # idempotent, no arguments, no policy
    "refresh_rates": "admin",
    "recount_orders": "admin",
    # ── CASES: the operator reads ───────────────────────────────────────────────────────
    "admin_order": "admin",                 # audited on every use, deliberately
    "admin_orders": "admin",
    "admin_receipt": "admin",
    "audit_log": "admin",
    "delayed_deliveries": "admin",
    "delivery_journal": "admin",
    "order_for_payment": "admin",
    "orphans": "admin",
    "orphans_unresolved": "admin",
    "pending_deliveries": "admin",
    "stripe_api_key_status": "admin",       # status only — never the value
    "webhook_secret_status": "admin",
}


def guarded_methods(text):
    """name -> the tier its body's guard implies, for every public method that has one."""
    lines = text.split("\n")
    starts = [
        (i, m.group(1))
        for i, l in enumerate(lines)
        if (m := re.search(r"\bpublic\b.*\bfunc\s+([a-z_][A-Za-z0-9_]*)\s*[(<]", l))
    ]
    # ⚠️ **Bodies end at the next TOP-LEVEL declaration, not the next PUBLIC one.** A
    # private helper between two public methods would otherwise be folded into the
    # preceding body, so a helper calling a guard would misattribute it to its neighbour.
    # Two-space indentation is the actor's top level; a closure inside a body is indented
    # further and so is not a boundary — which matters, because several bodies pass a
    # `func(order, entry) { … }` to a fold.
    bounds = sorted(
        # `.*?` may be EMPTY so a line starting `  func …` matches — `\S.*` consumed the
        # `f` and then needed a SECOND `func`, which is why the first attempt at this was
        # behaviourally identical to having no fix. The lookahead still excludes closures,
        # which matters: several bodies pass a `func(order, entry) { … }` to a fold.
        i for i, l in enumerate(lines) if re.match(BOUNDARY, l)
    )
    out = {}
    for i, name in starts:
        nxt = [b for b in bounds if b > i]
        body = "\n".join(lines[i:(nxt[0] if nxt else len(lines))])
        code = "\n".join(l for l in body.split("\n") if not l.strip().startswith("//"))
        found = {tier for g, tier in GUARDS.items() if re.search(r"\b%s\s*\(" % g, code)}
        if len(found) > 1:
            out[name] = "BOTH"
        elif found:
            out[name] = found.pop()
    return out


def _self_test():
    r"""The boundary logic, checked against a synthetic source on every run.

    ⚠️ **This exists because the boundary silently no-opped once.** The first attempt at it
    was `^  \S.*\bfunc\s+` — which cannot match a line beginning `  func …`, because `\S`
    consumes the `f` and then a second `func` is required. It was committed with a comment
    asserting the protection, and the check stayed green **by an accident of file
    ordering**: the only private top-level funcs calling a guard are the guard definitions
    themselves, and no public method precedes them.

    ⚠️ It runs unconditionally rather than behind a flag, because a self-test you have to
    remember to run is the thing it is guarding against.
    """
    for line, want in [
        ("  func requireAdmin(caller : Principal) {", True),
        ("  public shared query ({ caller }) func admin_orders(", True),
        ("  public query func delivery_stats() : async {", True),
        ("      func(order, entry) {", False),          # a closure passed to a fold
        ("        case (?order) { n += 1 };", False),
    ]:
        if (re.match(BOUNDARY, line) is not None) != want:
            sys.exit(f"ABORT: the body boundary is broken — {line.strip()!r} should "
                     f"{'' if want else 'not '}be a boundary")

    # The dangerous fold, end to end: an UNGUARDED public method followed by a private
    # helper that calls a guard must NOT inherit it. With the broken boundary this
    # returned {"unguarded": "admin"} — an authz hole reading as a correctly tiered method.
    synthetic = "\n".join([
        "  public shared ({ caller }) func unguarded() : async () {",
        "    ();",
        "  };",
        "  func helper(caller : Principal) { requireAdmin(caller) };",
        "  public shared ({ caller }) func guarded() : async () {",
        "    requireAdmin(caller);",
        "  };",
    ])
    got = guarded_methods(synthetic)
    if got != {"guarded": "admin"}:
        sys.exit(f"ABORT: the body boundary folds a neighbouring helper's guard in — "
                 f"expected {{'guarded': 'admin'}}, got {got}")


def main() -> int:
    _self_test()
    text = open(MAIN).read()
    actual = guarded_methods(text)
    if not actual:
        sys.exit(f"ABORT: found no guarded methods in {MAIN} — the parser is wrong")

    fail = []
    for name, tier in sorted(actual.items()):
        if tier == "BOTH":
            fail.append(f"{name} calls BOTH guards — it cannot be in one tier")
            continue
        if name not in TIERS:
            fail.append(
                f"{name} is admin-gated and in NEITHER tier. Classify it: does it resolve "
                f"one case (admin) or change the rules (controller)?"
            )
        elif TIERS[name] != tier:
            fail.append(
                f"{name} is declared {TIERS[name]!r} but its body calls the "
                f"{tier!r} guard — the tier is not enforced, only written down"
            )
    for name in sorted(set(TIERS) - set(actual)):
        fail.append(
            f"TIERS names {name}, which calls no guard in {MAIN} — either it lost its "
            f"guard (an authz hole) or the entry is stale"
        )

    if fail:
        print("\n\033[31m✗ the admin tiers are not what the code does\033[0m", file=sys.stderr)
        for f in fail:
            print(f"    {f}", file=sys.stderr)
        return 1
    n_c = sum(1 for t in actual.values() if t == "controller")
    n_a = sum(1 for t in actual.values() if t == "admin")
    print(f"   {len(actual)} guarded method(s): {n_c} controller-only, {n_a} admin, each calling its declared guard")
    return 0


if __name__ == "__main__":
    sys.exit(main())
