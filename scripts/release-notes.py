#!/usr/bin/env python3
"""Render `release/NOTES.md` — the release body — from the build output and CHANGELOG.

⚠️ **`MODULE-HASHES.txt` is NOT reformatted.** A verifier rebuilds the tag and diffs their
own `MODULE-HASHES.txt` against the published one, and `shasum -c` reads that exact
format, so the notes carry it **verbatim** in a code block. The table above it is for
people; the block is what tooling and a diff use. Turning the artifact itself into a
table would break both.

⚠️ **The notes say which hash is worth checking.** `frontend.wasm` is the pinned recipe's
pre-built certified-assets canister — the same module for every project that uses it — so
comparing it proves nothing about the page anyone is served. Someone who matches it and
concludes the frontend is verified has verified the recipe. The notes point that reader at
the asset check instead.

Usage: scripts/release-notes.py <version> [hashes-file] [out-file]
"""

import sys
from pathlib import Path

WHAT = {
    "backend.wasm": "the gateway canister — **this is the hash to check**",
    "frontend.wasm": "the pinned recipe's certified-assets canister (see the note below)",
    "backend.did": "the Candid interface, as embedded in the backend module",
}


def changelog_section(version: str, text: str) -> str:
    """The body of `## <version>`, up to the next `## ` heading."""
    lines = text.split("\n")
    head = f"## {version}"
    try:
        start = lines.index(head) + 1
    except ValueError:
        return ""
    body = []
    for line in lines[start:]:
        if line.startswith("## "):
            break
        body.append(line)
    return "\n".join(body).strip("\n")


def _self_test() -> None:
    """Unconditional: the extraction is the one part with a wrong-answer failure mode —
    a heading whose prefix matches another version, or running off into the next section."""
    sample = "# Changelog\n\n## Unreleased\n\n## 1.2.0\nnew stuff\n\nmore\n\n## 1.2.0-rc.1\nold\n"
    assert changelog_section("1.2.0", sample) == "new stuff\n\nmore", "exact-heading match failed"
    assert changelog_section("1.2.0-rc.1", sample) == "old", "suffix version failed"
    assert changelog_section("9.9.9", sample) == "", "absent version should be empty"
    assert changelog_section("Unreleased", sample) == "", "empty section should be empty"


def main() -> int:
    _self_test()
    if len(sys.argv) < 2:
        sys.exit("usage: scripts/release-notes.py <version> [hashes-file] [out-file]")
    version = sys.argv[1].lstrip("v")
    hashes_path = Path(sys.argv[2] if len(sys.argv) > 2 else "release/MODULE-HASHES.txt")
    out_path = Path(sys.argv[3] if len(sys.argv) > 3 else "release/NOTES.md")

    raw = hashes_path.read_text()
    arch = next((l.split(":", 1)[1].strip() for l in raw.split("\n") if l.startswith("# build arch:")), "unknown")
    rows = [(n, h) for h, n in (l.split() for l in raw.split("\n") if l and not l.startswith("#"))]
    if not rows:
        sys.exit(f"ABORT: no hashes parsed out of {hashes_path} — refusing to publish empty notes")

    changes = changelog_section(version, Path("CHANGELOG.md").read_text())
    if not changes:
        sys.exit(f"ABORT: CHANGELOG.md has no '## {version}' section")

    table = "\n".join(f"| `{n}` | `{h}` | {WHAT.get(n, '')} |" for n, h in rows)
    out = f"""{changes}

## Module hashes

Built in the pinned container on **`{arch}`**. The same commit produces different bytes on
a different architecture, so compare like for like.

| artifact | sha256 | what it is |
|---|---|---|
{table}

Verbatim, as `shasum -c` and a diff against your own build read it:

```
{raw.strip()}
```

## Verify this yourself

```bash
git clone --recurse-submodules <repo> && cd <repo> && git checkout v{version}
scripts/reproducible-build.sh v{version}
diff release/MODULE-HASHES.txt -   # paste the block above
icp canister status <backend-id> -n ic -p
```

All three must agree: your build, the block above, and the canister.

⚠️ **`frontend.wasm` is not a meaningful check.** It is the pinned recipe's pre-built
certified-assets canister — identical for every project using it, and unrelated to the
page anyone is served, which lives in canister state. To check the frontend, compare what
it serves against your own build:

```bash
npm --prefix src/frontend ci && npm --prefix src/frontend run build
scripts/check-frontend-assets.py -e ic
```

`docs/VERIFY.md` has the rest, including what only a buyer can check and the known limits.
"""
    out_path.write_text(out)
    print(f"   wrote {out_path} ({len(out.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
