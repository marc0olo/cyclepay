#!/usr/bin/env python3
"""Assert the docs' method lists match the canister's ACTUAL public surface.

⚠️ **Why this is a gate step and not a review habit.** `docs/STRIPE.md` carried a table
introduced with "this table is the whole admin surface" while missing **11 of 29**
admin methods — every one added by #37 and #38, plus `expire_order` from #52, plus the
two secret-status queries `RUNBOOK.md` tells an operator to call to confirm a rotation.
`RUNBOOK.md` told them to call `webhook_status`, which has never existed; the method is
`webhook_secret_status`.

Neither failure is visible by reading either document: a list of plausible method names
reads as complete, and a name that does not exist reads exactly like one that does. The
only thing that can tell them apart is the interface itself, so the check is mechanical.

**Authority is the committed `.did`** (regenerated and diff-checked one step earlier in
`test-all.sh`, so by the time this runs it is known current) for *what exists*, and
`Main.mo`'s guards for *who may call it*.

Two things are deliberately NOT enforced, because enforcing them would make the check
a nuisance rather than a tripwire:

  - **Prose descriptions.** Only names are compared. A stale *description* is a real
    problem (`recount_orders` "rebuild… from the store" survived #63) but it is not
    mechanically checkable, and a check that cannot see it must not imply it can.
  - **Every mention.** Only the explicitly-marked list blocks are compared. A method
    named in passing mid-paragraph is prose.

Marked blocks are delimited in the Markdown by HTML comments, so the checker never has
to guess where a list starts:

    <!-- surface:admin -->      ... <!-- /surface -->
    <!-- surface:public -->     ... <!-- /surface -->
    <!-- surface:owner -->      ... <!-- /surface -->

Within a block, every `` `identifier` `` is taken as a claimed member. `surface:public`
blocks may omit the HTTP-gateway plumbing (`http_request`, `http_request_update`,
`transform_stripe_response`) and `create_order`, which are public but are not
*monitoring* queries — that allowance is listed explicitly below rather than inferred,
so adding a method never silently lands in it.
"""

import re
import sys

DID = "src/backend/dist/backend.did"
MAIN = "src/backend/Main.mo"

# Public, but not part of any documented "queries you can poll" list. Explicit, so a
# newly added method is a failure rather than something that quietly qualifies.
PUBLIC_NOT_LISTED = {
    "http_request",            # HTTP gateway plumbing, not an API
    "http_request_update",     # ditto
    "transform_stripe_response",  # the outcall consensus transform
    "create_order",            # public, but an update on the buyer path
    "cancel_order",            # owner-scoped in effect; listed under owner
}

# Public, and they legitimately read `caller`. ⚠️ **Explicit because the scope detection
# below FAILS on any other method that takes the caller and does nothing it recognises
# with it** — so a new caller-aware method has to be classified deliberately, rather than
# defaulting to "public" and forcing the docs to assert it.
PUBLIC_WITH_CALLER = {
    "create_order",  # public update on the buyer path; the caller BECOMES the owner
    "can_purchase",  # the admission gate's cap is per principal, so it must read caller
    # ⚠️ Ungated ON PURPOSE (#68): an admin who is NOT yet granted has to be able to read
    # their own principal and see that it is not granted. A guarded version would reject
    # exactly the caller who needs the answer, and a UI could not tell "not granted" from
    # "not reachable". It discloses nothing about anyone else — the answer is about
    # `caller`.
    "admin_status",
}

FAIL = []


def real_surface():
    names = sorted(set(re.findall(r"^  ([a-z_][a-z0-9_]*):", open(DID).read(), re.M)))
    if not names:
        sys.exit(f"ABORT: parsed no methods out of {DID} — the check would pass vacuously")
    lines = open(MAIN).read().split("\n")
    decls = []
    for i, l in enumerate(lines):
        m = re.search(r"\bpublic\b.*\bfunc\s+([a-z_][A-Za-z0-9_]*)\s*[(<]", l)
        if m:
            decls.append((i, m.group(1)))
    starts = sorted(i for i, _ in decls)
    by = {n: i for i, n in decls}
    out = {}
    for n in names:
        if n not in by:
            sys.exit(f"ABORT: {n} is in {DID} but no public func in {MAIN} — parser is wrong")
        i = by[n]
        nxt = [s for s in starts if s > i]
        body = "\n".join(lines[i:(nxt[0] if nxt else len(lines))])
        # Comments mention guards they do not call; compare code only.
        code = "\n".join(
            l for l in body.split("\n") if not l.strip().startswith("//")
        )
        # ⚠️ **Both guards mean admin scope here.** #68 split authz into two tiers —
        # `requireController` (the rules) and `requireAdmin` (individual cases) — and the
        # docs' vocabulary has three blocks, public/owner/admin, which is coarser. The
        # tier a method sits in is enforced by `check-admin-tiers.py`; this check only
        # cares that the method is not reachable by a buyer.
        #
        # When the split landed, this line said `"requireAdmin" in code` and the nine
        # rewired setters came out as `unclassifiable` — which is the fourth outcome doing
        # its job: it failed naming them, rather than quietly filing canister-control
        # methods as public.
        admin = re.search(r"\brequire(?:Admin|Controller)\s*\(", code) is not None
        # ⚠️ **Owner scope is detected by CONVENTION, and keeping the convention is the
        # point: an owner-scoped read delegates to an `Orders` helper whose NAME says so
        # — `getOwned`, `ownerPage`. If you add one, name it that way.**
        #
        # Enumerating literal call forms broke this TWICE, both times in the same
        # direction. First a regex looked only for `order.owner` and missed
        # `getOwned(store, id, caller)`. Then #70 replaced `owner = ?caller` with
        # `ownerPage` and the third form was missing again. Both times an owner-scoped
        # read was reported as PUBLIC — and since the .did is authoritative by then, the
        # remedy on offer is to go and assert a false scope in the docs.
        owner = re.search(r"Orders\.\w*(?:[Oo]wned|[Oo]wner)\w*\s*\(", code) is not None
        # ⚠️ **`unclassifiable` is load-bearing for a DIFFERENT check — do not relax it.**
        # `check-admin-tiers.py` derives its population from the guards, so a method MEANT
        # to be admin-gated that forgot the guard entirely is invisible there: it just
        # looks public. This outcome is what names it. The two checks compose, and neither
        # covers that gap alone.
        #
        # ⚠️ **The DEFAULT was the defect, not the pattern.** Falling through to "public"
        # is what let both earlier breaks offer "go assert a false scope in the docs" as
        # the remedy. A method that destructures `{ caller }` and then calls neither
        # `requireAdmin` nor a recognised owner helper has been handed the caller and
        # done nothing this check understands with it — so say so and fail, rather than
        # guessing the least safe answer. This alone would have caught #70's regression.
        # ⚠️ A PATTERN, not the literal `"{ caller }"`. All 36 caller-taking declarations
        # use that exact spelling today, so the substring worked — and a formatter
        # producing `({caller})`, or a declaration wrapped across lines, would fall
        # through to `public`, which is the old bad default returning silently for the
        # one case it cannot see. Enumerating a form is what this check keeps getting
        # wrong.
        takes_caller = re.search(r"\(\s*\{[^}]*\bcaller\b", lines[i]) is not None
        if admin:
            out[n] = "admin"
        elif owner:
            out[n] = "owner"
        elif takes_caller and n not in PUBLIC_WITH_CALLER:
            out[n] = "unclassifiable"
        else:
            out[n] = "public"
    return out


def claimed(path, kind):
    text = open(path).read()
    blocks = re.findall(
        rf"<!--\s*surface:{kind}\s*-->(.*?)<!--\s*/surface\s*-->", text, re.S
    )
    names = set()
    for b in blocks:
        for line in b.split("\n"):
            if line.lstrip().startswith("|"):
                # ⚠️ Table rows: FIRST cell only. Parsing the whole row picks up
                # backticked words out of the prose in the Purpose column (`seq`,
                # `limit`, `rk_`) and reports them as methods that do not exist —
                # a checker crying wolf gets switched off.
                cells = [c for c in line.split("|")]
                cell = cells[1] if len(cells) > 1 else ""
                names |= set(re.findall(r"`([a-z_][a-z0-9_]*)`", cell))
            else:
                names |= set(re.findall(r"`([a-z_][a-z0-9_]*)`", line))
    return names, len(blocks)


def main() -> int:
    surface = real_surface()
    real = {
        k: {n for n, v in surface.items() if v == k} for k in ("public", "owner", "admin")
    }
    print(
        f"   canister surface: {len(real['public'])} public, "
        f"{len(real['owner'])} owner-scoped, {len(real['admin'])} admin"
    )

    unclassifiable = sorted(n for n, v in surface.items() if v == "unclassifiable")
    if unclassifiable:
        print(
            "\n\033[31m✗ cannot determine the scope of: "
            + ", ".join(unclassifiable)
            + "\033[0m",
            file=sys.stderr,
        )
        print(
            "  Each takes `{ caller }` and calls neither `requireAdmin` nor an `Orders`\n"
            "  helper whose name says owner. Either route it through one, or add it to\n"
            "  PUBLIC_WITH_CALLER with the reason. ⚠️ Do NOT resolve this by editing a\n"
            "  doc: the scope is undetermined, so any block you put it in is a guess.",
            file=sys.stderr,
        )
        return 1

    checked = 0
    for path in ("docs/STRIPE.md", "RUNBOOK.md"):
        for kind in ("public", "owner", "admin"):
            names, nblocks = claimed(path, kind)
            if nblocks == 0:
                continue
            checked += 1
            expected = set(real[kind])
            if kind == "public":
                expected -= PUBLIC_NOT_LISTED
            missing = expected - names
            extra = names - real[kind]
            if missing:
                FAIL.append(
                    f"{path}: the surface:{kind} block omits {len(missing)} "
                    f"{kind} method(s): {', '.join(sorted(missing))}"
                )
            if extra:
                unknown = extra - set(surface)
                wrong = extra & set(surface)
                if unknown:
                    FAIL.append(
                        f"{path}: the surface:{kind} block names method(s) that DO NOT "
                        f"EXIST: {', '.join(sorted(unknown))}"
                    )
                if wrong:
                    detail = ", ".join(f"{n} (really {surface[n]})" for n in sorted(wrong))
                    FAIL.append(
                        f"{path}: the surface:{kind} block claims the wrong scope for: {detail}"
                    )

    if checked == 0:
        # ⚠️ A check with nothing to check must fail. Silently passing is how a marker
        # deleted in a doc rewrite turns this into a green tick that verifies nothing.
        sys.exit("ABORT: found no <!-- surface:… --> blocks to check — this check cannot pass vacuously")

    if FAIL:
        print("\n\033[31m✗ the docs disagree with the canister's actual surface\033[0m", file=sys.stderr)
        for f in FAIL:
            print(f"    {f}", file=sys.stderr)
        print(
            "\n  Fix the doc, not this check. The .did is regenerated and diff-checked\n"
            "  one step earlier, so it is the current interface by construction.",
            file=sys.stderr,
        )
        return 1
    print(f"   {checked} documented surface list(s) agree with the .did")
    return 0


if __name__ == "__main__":
    sys.exit(main())
