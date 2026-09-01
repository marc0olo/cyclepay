# Design decisions — the `§N` record

**The decision record for the cycles gateway.** Code comments say what the code *does*;
this says *why it is that way*. When those disagree, the code is right and this file is a
bug — fix it in the same change.

⚠️ **This file is load-bearing and enforced.** `scripts/check-spec-glossary.py` runs in
the verification gate and fails if a `§N` cited in the backend or the tests has no section
here, or if a section here is cited by nothing. It cannot check whether a section is
*true* — that is the obligation below.

> ## The obligation, for agents and humans
>
> **Change the behaviour, change this file in the same commit.** Not afterwards.
>
> Its predecessor was a 697-line spec that accumulated **67** mentions of architecture
> three issues had deleted, while `Main.mo` still cited it by section number. It was not
> abandoned — it was updated less often than the code. The rule that would have saved it
> is the one above.
>
> ⚠️ **Keep it lean, and delete rather than annotate.** A section describing something
> that no longer exists must be *removed*, not marked historical. History belongs in
> commit messages and GitHub issues, which are dated and attributable. Every paragraph
> here must be a decision someone could otherwise get wrong.

---

## §1 — Scope and sequencing

One rail: **Card, via Stripe**. Cycles are sold at cost from a pre-funded cycles reserve.
The plan and its order live in GitHub issues (#12 is the index).

## §2 — Identity and ownership

**Internet Identity for every purchase.** It costs no anonymity: II is pseudonymous and
issues a **per-origin principal** unlinkable to the same user elsewhere. Destinations are
arbitrary — you may fund any canister — so sign-in governs *ownership and history*, not
what you may buy. It exists to fix the lost-receipt problem.

⚠️ **The origin is irreversible after the first real purchase.** II derives the principal
*from* the origin, so changing it later gives every returning buyer a different principal:
they cannot see their old orders, and the cycles behind them are unreachable.

Authz is `caller == order.owner`. **Order ids are random (`raw_rand`), not a counter** —
the id travels in the public `client_reference_id`, so randomness avoids enumeration and
avoids leaking order volume. It is **not** a bearer secret; there are no secret order
handles.

## §3 — Economics

**At cost, net of fees.** The rate applies to the **net** amount received (gross minus the
Stripe fee, from a configurable formula), so there is no structural per-order loss. The
operator absorbs the variance on international and FX cards, because reading Stripe's
actual fee needs a key scope we refuse to hold (§7).

⚠️ **What is locked at creation is the cycle QUANTITY, and it is immutable afterwards.**
The reserve tally is `Σ lockedCycles` over non-terminal orders, so anything that rewrote
that field would break the tally silently. This is what makes "no quote drift" literally
rather than approximately true.

⚠️ **Cycles are priced in XDR, not ICP.** Per-order ICP exposure cancels; the operator's
ICP risk sits in topping up the reserve, not in any individual sale.

### §3.1 — Rates

Both inputs come from on-chain sources: **XRC** for USD/ICP and the **CMC** for
XDR/cycles. A refresh that fails leaves the previous rates standing, and orders stop being
quotable once the cache passes its staleness window — **refusing to sell is the safe
direction**; selling at a stale rate is not.

## §4 — One order, one state machine

```
Created ──▶ Cancelled                     the buyer gave up
   │
   ├──────▶ Expired                       Stripe's deadline passed; unpayable
   │
   └──────▶ Paid ──────▶ Delivered
                │
                ├──────▶ NeedsReview ──▶ Delivered    operator read the ledger
                │              └───────▶ Abandoned    operator refunded by hand
                └──────▶ Abandoned
```

⚠️ **Illegal transitions are ABSENT from the matrix, not guarded at runtime.**
`Expired → Paid` and `Cancelled → Paid` do not exist, and that absence *is* the guarantee
that a late payment cannot be honoured. A runtime check is something someone has to
remember; a missing edge is not.

⚠️ **Stripe owns the deadline.** The session expires, its webhook tells us, and `Expired`
is terminal. An earlier design made expiry advisory — a late genuine payment was honoured
— and that stopped being affordable once a `Created` order held reserve capacity.

### §4.1 — Money positions needing a human

Two structures, because they answer different questions:

- **Problems live on the order** (`Order.problems`). A problem earns its place only if it
  holds information that exists nowhere else **and** an action nobody has taken yet.
- **Orphans** are payments that cannot be attributed to any order — there is nothing to
  attach them to, so they keep a narrow list of their own.

Nothing drops from either.

**`NeedsReview` — every route to it, because a census beats a claim.** The status means
*"we can no longer ask safely"*, and it is reachable with the money position both unknown
and known:

*Unknown position* — a human must establish what happened:

1. **A stale transfer intent**: the intent is past the ledger's ~24 h dedup window, so a
   replay is no longer protected against double-paying. Reaching it takes a day-long
   ledger outage with an hourly sweep hammering it throughout — **expected never**, and
   documented as such rather than as a routine branch.
2. **The ledger's own escalating answers.** ⚠️ Not a second cause: a too-old rejection *is*
   case 1 told to us by the ledger instead of derived from our clock. Same position,
   different messenger.

*Known position* — nothing to establish, and this is the correction to a tidier claim of
"one trigger":

3. **The max-wait bound (§5.3)** fires on an order paid too long ago *whatever* the
   reason, including one where **nothing was ever sent** — position certain, instruction
   "refund in the Stripe Dashboard". So read any "one trigger" claim as scoped to the
   *unknown-position* routes.

*Unreachable guard*:

4. **The intent's amount exceeding the order's locked quantity**, which cannot happen
   because the amount was derived by subtracting a fee from that very quantity. ⚠️ If it
   ever fires it is not a counter-example to the census — it means `lockedCycles` acquired
   a second writer (§3), which is a much larger problem than one escalated order.

⚠️ **An escalation records the CAUSE and the MONEY POSITION separately, because they can
legitimately disagree.** The cause is why we stopped trying; the position is what a
transfer did or did not do. A stale intent stops the driver for one reason while the
position depends on whether a block was recorded — and *"establish its fate, never
rebuild"* is the right action regardless of why we stopped. The runbook's triage is
organised by position, because that is what determines the action; the cause is what
identifies the incident.

### §4.2 — Data model

One `persistent actor`. Orders are never deleted, which is what makes every index over
them a projection that can be rebuilt rather than a second source of truth.

## §5 — Money-out

**One transfer from the cycles reserve**, and one transition (`Paid → Delivered`) that
performs it. One edge means one place a double-spend could live.

⚠️ **`icrc1_transfer` is the only declared way out**, enforced by a gate step that greps
the whole backend for a second one. The reserve floor is a *lower bound* only while that
holds: any other outflow makes the balance fall in a way the floor cannot see, and the
gate would then admit sales against cycles that already left.

### §5.1 — Ambiguous transfers

The corner that makes a delivery retryable with no risk of paying twice:

1. Persist the deterministic transfer arguments (`created_at_time`, amount, target, memo)
   **before** transferring.
2. Execute; on success persist the `block_index`.
3. On recovery, **replay the identical transfer.** The ledger either performs it once or
   answers `Duplicate { block_index }` — either way the block index is recovered.

⚠️ **Bounded by the ledger's ~24 h dedup window**, so the recovery cadence must stay well
inside it (enforced: cadence ≤ window ÷ 4). An intent older than the window with no known
block index must **not** be auto-replayed — it escalates to `NeedsReview`, whose whole
meaning is "the money position is unknown; a human must read the ledger".

### §5.4 — The reserve floor: why the gate needs no ledger call

The admission gate decides against a **maintained lower bound** on the reserve balance,
synchronously, with no ledger read. That is sound because of one asymmetry in who can move
the balance:

- it can only **decrease** when we transfer out, and there is exactly one such outflow;
- it can only **increase** when someone tops the account up, which we cannot see without
  asking — and which is always positive.

So every unobserved change is in our favour, and a floor maintained from our own outflows
is never optimistic. Deciding against it can refuse a sale the reserve could have covered;
it can never admit one it cannot.

⚠️ **This replaced an awaited balance read on the order-creation path**, which is where a
whole class of bug lived: the awaited value was correct when computed and historical when
used, and pairing it with a live tally made the available figure optimistic by a full
order. The decision still reads **two** numbers — the floor and the promise tally — but
both are now *maintained*, so what is gone is the awaited-versus-live pairing, not the
second operand.

**Three rules keep it a bound:**

1. **A fresh observation is adopted only in a quiet window, and a shortfall is shouted
   about.** "Quiet" means nothing was in flight before the read, nothing after it, and
   nothing was issued in between — see below for why that condition is the whole safety
   property. The ledger holding *less* than the floor means an outflow we did not cause,
   which the asymmetry says is impossible.
2. **A transfer decrements the floor when it is ISSUED, not when it settles, by
   `amount + the fee for this attempt`.** The only way the balance can surprise us
   downward is one of our own transfers landing without our learning it did — our reply
   callback traps, so the debit stands while our bookkeeping rolls back. Assuming the
   debit at issue time makes that case exact instead of optimistic.

   ⚠️ **The fee is in the FLOOR decrement but not in the promise tally**, and the
   asymmetry is deliberate: the ledger charges its fee on top of the amount, so an
   outflow moves the balance by `amount + fee` while what an order *promises* is the
   amount alone (§3). Adding a fee term to the tally double-counts.
3. **A definitively-failed transfer credits the floor back**, `#Duplicate` included — that
   answer says *this* call moved nothing, so its decrement was never a real debit even
   though an earlier attempt's was. A `#BadFee` re-issue therefore credits back
   `amount + fee` and decrements `amount + the corrected fee`; if the re-issue then fails
   with no reply, the **larger** decrement stands, which is correctly pessimistic.

   ⚠️ **A call that failed with no reply is NOT credited back.** It says nothing about
   whether the ledger acted, and rule 2 exists for exactly that case.

⚠️ **Adoption is conditional, and the condition is the whole safety property.** Adopting a
read that was taken before an outflow erases that outflow's decrement while the transfer
still debits. So a balance is adopted only when nothing was in flight before the read,
nothing after it, and nothing was issued in between. Skipping is cheap — the sweep tries
again; a top-up waits but is never lost.

**The quiet-window predicate is a conservative superset of "in flight".** It counts any
journalled intent with no recorded block on an order still `Paid` — which includes a
delivery *parked between retries*, when nothing is in the air at all. That is deliberate:
a transfer issued before a balance read can land after it, and the journal cannot
distinguish "awaiting a reply" from "failed, waiting for the next sweep". Tracking true
in-flight state would need a counter incremented before the await, which leaks upward
permanently if a reply callback traps — trading bounded pessimism for unbounded.

⚠️ **Escalated orders must be excluded from it, or one escalation freezes the reserve for
the life of the canister.** An escalated order keeps the intent-without-block shape
*forever*, so without the `Paid` clause every reconcile skips, every manual refresh skips,
and top-ups silently stop registering — the rail slowly closing with no lever. Excluding
them is sound because they have no outstanding callback: escalation is decided either
before a call is made or after its response arrived, never with one in flight. Their
pessimism is not lost — the promise tally still holds them.

**The cost, and why it is not a deadlock.** While a delivery is retrying, a top-up is not
adopted, so *new sales* are refused against cycles the ledger already holds. Deliveries
never consult the floor, so delivery itself is unaffected: a dry reserve fails with
insufficient funds, the operator tops up, the retry succeeds *because the ledger has the
cycles regardless of our floor*, and the next reconcile adopts. The remaining pessimistic
case is a ledger outage, where refusing to sell is the correct posture anyway.

⚠️ **The floor and the promise tally overlap while a transfer is in flight, deliberately.**
The floor drops at issue; the promise is released one response later at `Delivered`. In
between the same order is subtracted twice, so the available figure reads a full order low
for the length of one ledger call. **Do not close the gap by moving either end**: releasing
the promise at issue frees capacity for a sale while the transfer consuming it is
unresolved, and decrementing the floor at settle time lets the balance surprise us
downward. Both ends sit on the pessimistic side of the same unknown.

### §5.2 — Recovery

A recurring timer sweeps orders with money-out work outstanding, single-flight, re-armed
after upgrade. Bookkeeping checks run **detached in their own message**: a check must
never be able to stop orders from delivering.

### §5.3 — Delivery time bounds

Two: an **alert** threshold (the delivery is late; a human should look) and a **max-wait**
bound (the position is now unresolvable automatically, so it escalates). Both are operator
configurable.

## §6 — Rails

### §6.0 — Ingress

Two paths, and the webhook **cannot** be caller-authenticated: Stripe is the caller, and
it authenticates by signing the payload. So exactly one anonymous, payload-authed HTTP
route exists, and it verifies an HMAC before trusting anything in the body.

### §6.1 — Card

Inbound-only in the sense that matters: the canister holds a **restricted** key scoped to
Checkout Sessions, never an `sk_`. It can create sessions and read them back; it cannot
refund, read customers, or reach the account.

## §7 — Security and trust

⚠️ **The webhook secret is plaintext canister state.** HMAC is symmetric, so *verify =
forge*: anything that can check a signature can forge one, and encrypting the stored blob
would only move the problem to the key that decrypts it.

⚠️ **The blast radius is the reserve balance, and sizing it is the control.** A forged
"paid" webhook delivers from the reserve. An earlier design bounded this with a per-period
ICP burn cap; there is no cap now, so the trade is "size the reserve to what a leak could
cost", not "the cap bounds it". SEV-SNP is the intended confidentiality layer and launch
does not block on it — `RUNBOOK.md` §9 is the verification checklist, hardest item first.

⚠️ **A leaked API key can only create sessions that pay us.** That asymmetry is why the
key's *scope* matters more than its storage.

**Governance is a flat controller allowlist with equal privileges.** Any controller can
upgrade, rotate either secret, resolve obligations, set tiers and adjust pricing. The
honest trust model is "trust the operator set; any one of them can upgrade and then
drain". There is deliberately **no** method that moves money (§5). True M-of-N needs a
multisig *canister* as controller, since IC controllers are OR-semantics.

## §8 — Verifiability

The thesis: **the number an operator monitors is the number a buyer can check.** The
reserve is an account on the cycles ledger, so anyone can read its balance without this
canister's cooperation. What the canister adds is the part only it knows — how much of
that balance is already promised.

## §9 — Layout and the test bar

One Motoko backend canister plus a static asset canister, a hand-rolled `Http.mo` rather
than a framework, and Candid bindings for the ledgers this canister actually calls.
Modules take their dependencies as records, which is why the whole ingestion path is
unit-testable with no IC environment.

⚠️ **The go-live bar is PocketIC, not the unit suites.** Unit tests wherever logic is
isolable — HMAC, fee and rate arithmetic, parsers, state-machine transitions, dedup — and
a PocketIC scenario for everything that needs a replica: upgrades mid-delivery, ledger
outages, real HTTP ingress, the §5.1 replay contract. A change is not done on a build or a
unit pass alone. `test/integration/README.md` maps the scenarios to the items here.

## §11 — Deferred

A second rail, M-of-N or SNS governance, an external audit of the delivery and
secret-handling paths, and archival once volume warrants. Events this gateway does not
subscribe to (disputes, for instance) are acked rather than refused, so a Dashboard
configuration cannot disable the endpoint.

### §11.1 — Seams that are binding

A second rail should *add* rather than force an unwind. Four seams are deliberate, and
each is stated at the code it constrains:

1. **`Owner` stays a one-case variant** (`{ #ii : Principal }`). Adding a case to a stable
   variant is migration-free; widening a bare `Principal` is a stable-state migration plus
   an audit of every authz site. The variant also makes the compiler force every authz
   check to pattern-match.
2. **HTTP dispatch goes through a route *table*.** "Exactly one route" is policy, not
   architecture.
3. **Ownership is captured at the API edge.** `Orders.create` takes the owner as a
   parameter and never reads `msg.caller`.
4. **Expiry is per-rail money-in policy, not core behaviour.** The state machine owns
   transitions, not expiry policy — §4's reversal is why this seam matters.
