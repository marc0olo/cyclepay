# Deleted-mechanism vocabulary — the sweep list

**When you delete a mechanism, add its vocabulary here. When you sweep, start from this
file.**

⚠️ **This exists because the failure is *reconstructed from memory each sweep*, not
*nobody is checking*.** Three consecutive sweeps in this repo were run with a term list
assembled from the mechanisms someone happened to remember naming, and a reviewer found
the population incomplete each time. The clearest case: `ring`, `capacity`, `float`,
`treasury` and `burn cap` were swept, and **`evict`** — the *verb* for what the deleted
mechanism did — was not. Five survivors, including a second dangling `AddResult.evicted`
**118 lines from the one that had just been fixed**, and an operator-facing RUNBOOK line
stating a cap that no longer exists as a parameter.

This is `AGENTS.md`'s population rule applied one level up. That rule says *a rule
introduced to fix specific instances is not applied until it has been run against the full
population once* — and a sweep scoped to remembered terms is that rule failing at the level
of **terms** rather than **sites**.

## What to add, when you delete something

Three kinds of term, because missing any one of them has already cost a sweep:

1. **The noun** — what the thing was called (`ring`, `treasury`).
2. ⚠️ **The verb** — what it *did* (`evict`, `mint`, `reprice`). This is the one that gets
   forgotten, and prose cites verbs more often than nouns.
3. ⚠️ **The names of deleted variants and fields** (`#deliveryDelayed`,
   `AddResult.evicted`). These hide in tables and doc comments that a code-shaped grep
   never reads — two of them were **live operator triage rows** for entries that can never
   appear.

## Why it scans the DIFF, prints, and does not fail on a hit

**A fixed target can be enforced; a judgement call can only be surfaced.** Most hits are
*correct*:

- `mint` is legitimate: the CMC is literally the Cycles **Minting** Canister.
- `retention` is legitimate: `Idempotency.mo` has real dedup-key retention.
- *"Nothing is ever evicted (#37)"* is legitimate — a statement of the end state.

So the step prints its hits and exits zero. A check that fires on correct code teaches
people to ignore it, and this project has rejected that trade before: widening a lint
pattern flagged a script's deliberate interpolation, and it was reverted.

⚠️ **What it DOES fail on is an undeterminable base ref**, because that is the didn't-run
case. A scan that silently had nothing to scan reads exactly like a clean one.

⚠️ **An empty diff is a pass, not an abort** — unlike every other gate step, where empty
input means the step is aimed at nothing. Here it means the change added no lines, which
is a true answer to the question asked.

⚠️ **Scoped to added lines, and keeping no counts, for two reasons that are not
convenience.** A count cannot distinguish "removed two legitimate uses, added one stale
claim" from "removed one" — offsetting moves net out, so a prose-purging change that also
introduces a stale claim reads clean. And a count needs a population, so it needs globs,
and a glob list goes stale in silence. Added lines have neither hole: every added line in
the tree is in scope, wherever it lives, and a stale claim is a stale claim regardless of
what else the change did.

## ⚠️ Three row types, and they are cleared differently

A future sweeper treating every row the same will clear the second kind by **rewording**
when the check it needs is **whether anything now calls it**.

1. **Dead vocabulary** (most rows). The term should appear only in end-state or historical
   statements. Clear a new hit by fixing the prose.
2. ⚠️ **A tripwire on a LIVE name** — `icrc1_fee`. The concept still exists; what must
   never happen is a *call*. Its absence from the ledger's service type is the guard behind
   the fee-derivation rule (§5.1), the one rule here **no test can catch**. Clear a new hit
   only by confirming it is still not a call.
3. ⚠️ **A live name colliding with a deleted one** — `#abandoned` is a live order
   **status**; only the queue *kind* of that name went. A bare count for this row is
   actively misleading, and high is normal.

## Known-collision terms

⚠️ **These four are live names, and their hits are almost always correct.** The scan prints
them in a separate section BELOW its main list, because the value of a print-only step is
entirely a reader's willingness to look at it — and a real hit buried among three
predictable ones is something to triage rather than something to see.

Measured on #86: of four hits, three were these and the fourth was the defect.

- `\bmint` — the CMC is the Cycles **Minting** Canister, a live dependency.
- `\bretention\b` — `Idempotency.mo` prunes dedup keys on a real retention window.
- `#abandoned` — a live order **status**; only the deleted queue *kind* shared the name.
- `icrc1_fee` — a live ledger method. Row type 2: the hit is fine, a *call* is not.

⚠️ **A term listed here is de-emphasised, never skipped.** If this section is renamed or
emptied, every term prints in the main list — the failure direction is more prominence,
not less.

## Running it

`scripts/sweep-vocabulary.py` scans the lines your change adds, against the terms below,
and prints what it finds with the disposition alongside. It is the LAST gate step — placed
there deliberately, so its output sits immediately above the summary, where it gets read —
so a normal run reports it for you. Run it directly with `--base <ref>` to scan against
something other than the default branch.

⚠️ **The script excludes THIS file.** Every term appears here by construction, so
including it would report the question as the answer. That is not an exemption — it is the
difference between scanning the corpus and scanning the list.

⚠️ **A disposition is durable; a count was not.** These rows say what the word meant, that
the thing is gone, and what makes a new use wrong. That stays true as the code moves. The
numbers that used to sit here did not, and nothing ran to catch them expiring.

| term | disposition |
|---|---|
| `ring buffer` | AGENTS.md, describing this very failure class |
| `\bring\b` | all end-state statements — "#37 removed the ring", "the capacity parameter and the eviction loop are gone" |
| `4,?096` | all stating the ring is gone; one is PocketIC's 4096-**byte page** requirement, unrelated |
| `\bfloat\b` | all "there is no float" statements |
| `treasury` | AGENTS.md, listing what was deleted |
| `burn cap` | DESIGN.md §7 contrasts the old cap against today's reserve-sizing argument; the others list it as deleted |
| `ck-?USDC` | AGENTS.md scope statement |
| `\bmint` | ⚠️ **all legitimate** — the Cycles **Minting** Canister is a live dependency, and `Cmc.mo` says "nothing here mints, and nothing may" |
| `\bretention\b` | ⚠️ **all legitimate** — `Idempotency.mo` prunes dedup keys on a real retention window |
| `\bevict` | all end-state statements after the #77 follow-up sweep |
| `error.?queue` | historical references to a *status* split (#34) plus RUNBOOK's account of it; the structure references are cleared |
| `Payment Link` | all "#33 deleted this" statements |
| `attach_payment` | all "#33 deleted this" statements |
| `Retention.mo` | both naming it as deleted |
| `icrc1_fee` | ⚠️ **all "no longer awaits" / "never await" — none calls it.** Its absence from the ledger's service type is a load-bearing guard (§5.1); if a hit ever becomes a call, that guard is gone |
| `delayedAlerts` | all "not the `delayedAlerts` map returning" prohibitions |
| `#deliveryDelayed` | naming what replaced it (`delayed_deliveries`). ⚠️ Was a **live triage row** in RUNBOOK §6 until #77's follow-up |
| `#abandoned` | ⚠️ **legitimate — this is a live order STATUS.** Only the deleted *queue kind* of the same name was removed, which is why a bare count is not evidence here |
| `#icpAtCmc` | clean |
| `AwaitingTreasury` | clean |
| `promisedForDecision` | TEST-COVERAGE, recording the defect its deletion closed |
| `order_stats` | clean |