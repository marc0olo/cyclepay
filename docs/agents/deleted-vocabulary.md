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

## Why this is NOT a gate step

Deliberate, and by the same test this project uses everywhere: **a fixed target can be
enforced; a judgement call can only be surfaced.** The outflow census is three method
names, so it is a gate step. This list is different — every hit needs per-hit judgement,
and most hits are *correct*:

- `mint` is legitimate: the CMC is literally the Cycles **Minting** Canister.
- `retention` is legitimate: `Idempotency.mo` has real dedup-key retention.
- *"Nothing is ever evicted (#37)"* is legitimate — a statement of the end state.

A standing gate over this list would fire on correct prose, and this project has already
rejected that trade once: widening a lint pattern flagged a script's deliberate
interpolation, and it was reverted, because **a check that fires on correct code teaches
people to ignore it.**

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

## The baseline

⚠️ **The COMMAND is the source of truth; these numbers are a dated snapshot for
diffing.** Run `scripts/sweep-vocabulary.py` (add `--hits` to adjudicate). The table used
to say "update them when you sweep" — a rule requiring memory, which is what this artifact
exists to remove, and a stale count reads exactly like a measured one.

⚠️ **The script excludes THIS file**, and its first run is why: every term appears here by
construction, so including it drifted five counts the moment the file existed. Several
remaining hits are `AGENTS.md`'s rule text quoting these very terms — documenting the rule
adds occurrences of it.

⚠️ **Measured, not remembered — and that is the point of recording it.** The next sweep
**diffs against this**, so a new hit stands out against a known-legitimate set instead of
being re-adjudicated from scratch. Re-adjudicating is how "is `mint` a problem?" gets
answered a fourth time, and occasionally answered wrongly.

Counts cover `src/backend/*.mo`, `src/frontend/src/*.ts` and the root/`docs` Markdown,
excluding this file. Snapshot taken 2026-09-01.

| term | hits | disposition |
|---|---|---|
| `ring buffer` | 1 | AGENTS.md, describing this very failure class |
| `\bring\b` | 23 | all end-state statements — "#37 removed the ring", "the capacity parameter and the eviction loop are gone" |
| `4,?096` | 7 | all stating the ring is gone; one is PocketIC's 4096-**byte page** requirement, unrelated |
| `\bfloat\b` | 4 | all "there is no float" statements |
| `treasury` | 1 | AGENTS.md, listing what was deleted |
| `burn cap` | 3 | DESIGN.md §7 contrasts the old cap against today's reserve-sizing argument; the others list it as deleted |
| `ck-?USDC` | 1 | AGENTS.md scope statement |
| `\bmint` | 20 | ⚠️ **all legitimate** — the Cycles **Minting** Canister is a live dependency, and `Cmc.mo` says "nothing here mints, and nothing may" |
| `\bretention\b` | 15 | ⚠️ **all legitimate** — `Idempotency.mo` prunes dedup keys on a real retention window |
| `\bevict` | 15 | all end-state statements after the #77 follow-up sweep |
| `error.?queue` | 6 | historical references to a *status* split (#34) plus RUNBOOK's account of it; the structure references are cleared |
| `Payment Link` | 13 | all "#33 deleted this" statements |
| `attach_payment` | 8 | all "#33 deleted this" statements |
| `Retention.mo` | 2 | both naming it as deleted |
| `icrc1_fee` | 16 | ⚠️ **all "no longer awaits" / "never await" — none calls it.** Its absence from the ledger's service type is a load-bearing guard (§5.1); if a hit ever becomes a call, that guard is gone |
| `delayedAlerts` | 5 | all "not the `delayedAlerts` map returning" prohibitions |
| `#deliveryDelayed` | 5 | naming what replaced it (`delayed_deliveries`). ⚠️ Was a **live triage row** in RUNBOOK §6 until #77's follow-up |
| `#abandoned` | 29 | ⚠️ **legitimate — this is a live order STATUS.** Only the deleted *queue kind* of the same name was removed, which is why a bare count is not evidence here |
| `#icpAtCmc` | 0 | clean |
| `AwaitingTreasury` | 0 | clean |
| `promisedForDecision` | 1 | TEST-COVERAGE, recording the defect its deletion closed |
| `order_stats` | 0 | clean |
