#!/usr/bin/env python3
"""Fetch and write a GitHub issue body byte-exactly, verifying the round trip.

    scripts/issue-body.py get  <number> <file>     # fetch, verify length, write
    scripts/issue-body.py put  <number> <file>     # write back, then re-fetch and diff
    scripts/issue-body.py diff <number> <file>     # is the remote still what this file says?

⚠️ **Why this is a versioned script and not a snippet.**

#52 destroyed #12's body: Markdown built inside an *unquoted* heredoc let the shell run
the backticks in the text, and a mangled 101k-char body went live in place of 53k. It was
recoverable only because a pre-edit fetch existed **with its length checked against the
API's own count** — which is what made the restore trustworthy rather than hopeful.

That check became a rule in #12's traps. Its tool then lived in a session scratchpad,
which does not persist, so the next agent to touch a large issue body had to re-derive it
from the trap text. **A rule whose tool is gone is a rule that gets skipped** — so the
tool lives here, next to every other rule in this repo that graduated from a comment into
something executable (`check-heredocs.sh`, `brand-lint.sh`, `test-all.sh`).

⚠️ **The abort is the feature.** Every failure mode here is silent: a truncated write
looks like a successful one, and a body that lost 40k characters still renders as a page
of Markdown. So each step compares against the API's own count and exits non-zero on any
mismatch rather than reporting what it hoped happened.

⚠️ **`put` verifies by re-fetching, not by trusting the write.** GitHub accepting the
request is not evidence the stored body matches the file: #12's corruption was accepted
cleanly. Only a read-back proves it.

Requires `gh` (authenticated). `GH_REPO`, or `--repo owner/name`, overrides the default.
"""

import argparse
import json
import subprocess
import sys

DEFAULT_REPO = "marc0olo/cyclepay"


def die(msg: str) -> "None":
    sys.exit(f"ABORT: {msg}")


def api(repo: str, number: str, *extra: str) -> dict:
    proc = subprocess.run(
        ["gh", "api", f"repos/{repo}/issues/{number}", *extra],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        # ⚠️ Print the real stderr. A swallowed reason paired with a guessed cause is
        # worse than no diagnosis — the reader chases the guess.
        die(f"gh api failed for {repo}#{number}:\n{proc.stderr.strip()}")
    return json.loads(proc.stdout)


def read_remote(repo: str, number: str) -> str:
    body = api(repo, number).get("body")
    if body is None:
        die(f"{repo}#{number} has no body (deleted, or a permissions problem)")
    return body


def write_local(path: str, body: str) -> None:
    # newline="" on both sides: Python's universal-newline translation would silently
    # rewrite CRLF and make a byte-exact comparison impossible to trust.
    with open(path, "w", newline="") as fh:
        fh.write(body)
    back = open(path, newline="").read()
    if back != body:
        die(f"wrote {len(back)} chars, API body is {len(body)} — do not edit {path}")


def cmd_get(args) -> int:
    body = read_remote(args.repo, args.number)
    write_local(args.file, body)
    print(f"ok: {args.repo}#{args.number} body = {len(body)} chars -> {args.file}")
    return 0


def cmd_diff(args) -> int:
    remote = read_remote(args.repo, args.number)
    local = open(args.file, newline="").read()
    if remote == local:
        print(f"ok: {args.repo}#{args.number} matches {args.file} ({len(local)} chars)")
        return 0
    print(
        f"DIFFERS: {args.repo}#{args.number} is {len(remote)} chars, "
        f"{args.file} is {len(local)}",
        file=sys.stderr,
    )
    return 1


def cmd_put(args) -> int:
    local = open(args.file, newline="").read()
    if not local.strip():
        die(f"{args.file} is empty or whitespace — refusing to blank a body")
    before = read_remote(args.repo, args.number)
    print(f"remote before: {len(before)} chars; sending {len(local)}")
    # --input with a JSON file, so nothing in the body is ever interpreted by a shell.
    proc = subprocess.run(
        [
            "gh", "api", "--method", "PATCH",
            f"repos/{args.repo}/issues/{args.number}",
            "--input", "-",
        ],
        input=json.dumps({"body": local}),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        die(f"PATCH failed, body unchanged:\n{proc.stderr.strip()}")
    after = read_remote(args.repo, args.number)
    if after != local:
        die(
            f"read-back MISMATCH: sent {len(local)} chars, remote now holds {len(after)}."
            f" The previous body was {len(before)} chars — restore from your pre-edit copy."
        )
    print(f"ok: {args.repo}#{args.number} verified byte-identical ({len(after)} chars)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Byte-exact GitHub issue body round trips.",
        epilog="The abort is the feature; see the module docstring.",
    )
    parser.add_argument("action", choices=("get", "put", "diff"))
    parser.add_argument("number")
    parser.add_argument("file")
    parser.add_argument("--repo", default=DEFAULT_REPO)
    args = parser.parse_args()
    return {"get": cmd_get, "put": cmd_put, "diff": cmd_diff}[args.action](args)


if __name__ == "__main__":
    sys.exit(main())
