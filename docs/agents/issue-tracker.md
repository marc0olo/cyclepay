# Issue tracker: GitHub

**GitHub Issues is the single source of truth for task and progress tracking.** `PRD.md`
is a frozen historical artifact — never update it.

Use **`gh-axi`** for issue and PR operations; it is the wrapper this project expects, and
its output is compact enough to read without `jq` gymnastics. Plain `gh api` is the escape
hatch when you need a raw field. The repo is inferred from `git remote -v`.

## Conventions

- **Create**: `gh-axi issue create --title "..." --body-file <path>`
- **Read**: `gh-axi issue view <number> --comments` (add `--full` for a long body — the
  default truncates, and a truncated body reads exactly like a short one)
- **List**: `gh-axi issue list --state open` (`--label`, `--state`, `--limit`)
- **Comment**: `gh-axi issue comment <number> --body-file <path>`
- **Labels**: `gh-axi issue edit <number> --add-label ...` / `--remove-label ...`
- **Close**: `gh-axi issue close <number> --reason completed --comment "..."`

⚠️ **Pass bodies as `--body-file`, not `--body "..."`.** A multi-line body written inline
goes through the shell, and an unquoted heredoc containing backticks **executes them** —
that destroyed #12's body once (53k characters replaced by a mangled 101k). `scripts/`
carries a gate step (`check-heredocs.sh`) that refuses the unquoted form.

## ⚠️ Rewriting an existing issue BODY goes through the script

```bash
scripts/issue-body.py get  12 /tmp/i12.md   # fetch, verified against the API's own count
#   ...edit /tmp/i12.md...
scripts/issue-body.py put  12 /tmp/i12.md   # write, then RE-FETCH to prove it stored
scripts/issue-body.py diff 12 /tmp/i12.md   # is the remote still what this file says?
```

`put` verifies by reading back, because GitHub accepting the request is **not** evidence
the stored body is right: the corrupting write was accepted cleanly. Every guard exits
non-zero, and the abort is the feature.

**Adding a comment needs none of this** — it is additive and cannot destroy a body. Prefer
a comment whenever the content is additive; reach for a body rewrite only when the issue's
own statement of the problem has changed.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

`gh-axi issue view <number> --comments --full`.
