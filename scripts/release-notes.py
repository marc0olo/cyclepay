#!/usr/bin/env python3
"""Render `release/NOTES.md` — the release body — from the build output.

The notes are **generic and the same shape every release**: what changed is a link to the
CHANGELOG at this tag, not a copy of it. Embedding it made the entry half the page and
put the release-specific prose above the hashes, which are what a release page is for.

⚠️ **`MODULE-HASHES.txt` is NOT reformatted.** A verifier rebuilds the tag and diffs their
own `MODULE-HASHES.txt` against the published one, and `shasum -c` reads that exact
format, so the notes carry it **verbatim** in a code block. The table above it is for
people; the block is what tooling and a diff use. Turning the artifact itself into a
table would break both.

⚠️ **The notes say which hash is worth checking.** `frontend.wasm` is the pinned recipe's
pre-built certified-assets canister — the same module for every project that uses it — so
comparing it proves nothing about the page anyone is served. Someone who matches it and
concludes the frontend is verified has verified the recipe. The notes point that reader at
the frontend's STATE hash instead, which is the one that describes the page.

⚠️ **The verify instructions are generic, and must stay that way.** The same rendered
text ships with every release, including tags cut before a given helper existed, so it
offers the repo's check and the bare verifier side by side and lets the checked-out tree
decide which is available. Naming the release a script arrived in would make every future
set of notes carry a fact about the past that nothing checks.

⚠️ **The frontend state hash is published, and it has to be.** The procedure tells a
verifier to build a TAG, so they need a number that fixes what that tag produced.
Without it the only thing linking a tag to the running canister is our word about which
release is deployed — and a `main` build reports a mismatch that means nothing, since
`main` moves on after a release.

Usage: scripts/release-notes.py <version> [hashes-file] [out-file] [frontend-hash-file]
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _github_anchor import anchor, self_test as anchor_self_test  # noqa: E402
from _recipe_pin import pin_in, self_test as pin_self_test  # noqa: E402

# ⚠️ **Written out, not left as `<backend-id>`.** The notes' audience is precisely the
# people who do not know this canister's id, and it is a stable identifier rather than a
# perishable figure — unlike a hash, which is why no hash is hardcoded anywhere.
BACKEND = "saz2a-riaaa-aaaay-aadha-cai"
FRONTEND = "shy4u-4qaaa-aaaay-aadhq-cai"
REPO = "https://github.com/marc0olo/cyclepay"

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
    anchor_self_test()
    pin_self_test()
    if len(sys.argv) < 2:
        sys.exit("usage: scripts/release-notes.py <version> [hashes-file] [out-file]")
    version = sys.argv[1].lstrip("v")
    hashes_path = Path(sys.argv[2] if len(sys.argv) > 2 else "release/MODULE-HASHES.txt")
    out_path = Path(sys.argv[3] if len(sys.argv) > 3 else "release/NOTES.md")
    fe_path = Path(sys.argv[4] if len(sys.argv) > 4 else "release/FRONTEND-STATE-HASH.txt")

    if not hashes_path.exists():
        sys.exit(f"error: {hashes_path} is missing — the build has not run.\n"
                 f"    scripts/release.sh {sys.argv[1]}")
    # Required, not optional: see the module docstring. Notes without it publish a
    # backend a verifier can pin and a frontend they cannot.
    if not fe_path.exists():
        sys.exit(f"error: {fe_path} is missing — the frontend hash has not been computed.\n"
                 f"    scripts/release.sh {sys.argv[1]}")
    fe_hash = fe_path.read_text().strip()
    if not re.fullmatch(r"[0-9a-f]{64}", fe_hash):
        sys.exit(f"ABORT: {fe_path} holds no 64-char hex hash: {fe_hash!r}")
    raw = hashes_path.read_text()
    # ⚠️ Abort rather than degrade. Publishing "built on unknown" two lines above the rule
    # telling a verifier to compare like for like would be worse than failing here.
    arch = next((l.split(":", 1)[1].strip() for l in raw.split("\n") if l.startswith("# build arch:")), None)
    if arch is None:
        sys.exit(f"ABORT: {hashes_path} carries no '# build arch:' line — a hash without its"
                 " architecture cannot be compared, so these notes would mislead")
    rows = [(n, h) for h, n in (l.split() for l in raw.split("\n") if l and not l.startswith("#"))]
    if not rows:
        sys.exit(f"ABORT: no hashes parsed out of {hashes_path} — refusing to publish empty notes")

    # ⚠️ **The changelog comes from the REF when there is one.** Generating notes for a
    # tag from the working tree's changelog is how a backfill silently publishes a later
    # version's text. Falls back to the working tree for `HEAD` and bare commits.
    import subprocess
    ref = sys.argv[1]
    at_ref = subprocess.run(["git", "show", f"{ref}:CHANGELOG.md"], capture_output=True, text=True)
    changelog = at_ref.stdout if at_ref.returncode == 0 else Path("CHANGELOG.md").read_text()
    # ⚠️ Validated, not inlined. The link must not 404, and `release.sh` refuses a version
    # with no entry — but the notes carry a pointer so the changelog stays the one place
    # that describes a release.
    if not changelog_section(version, changelog):
        sys.exit(f"ABORT: CHANGELOG.md has no '## {version}' section — the notes would link to nothing")
    # ⚠️ **The pin comes from the REF too.** The state hash is frozen per certified-assets
    # release, so the number means nothing without the release it was computed under —
    # and reading that from the working tree would publish the CURRENT pin beside a hash
    # computed under the tag's. Same fallback as the changelog, for HEAD and bare commits.
    at_ref_yaml = subprocess.run(["git", "show", f"{ref}:icp.yaml"], capture_output=True, text=True)
    icp_yaml = at_ref_yaml.stdout if at_ref_yaml.returncode == 0 else Path("icp.yaml").read_text()
    # Imported from `_recipe_pin`, the same reader `check-frontend-hash.py` picks the
    # verifier with, so the published release and the computed hash cannot disagree.
    ca_version = pin_in(icp_yaml)
    if ca_version is None:
        sys.exit("ABORT: no `@dfinity/static-site@vX.Y.Z` pin found — the frontend hash would"
                 " be published with no release to interpret it under")
    # ⚠️ The SAME anchor rule `check-doc-links.py` verifies the docs with — imported, not
    # restated, because a second copy of it is exactly the class of duplication this repo
    # keeps finding, and this is the copy nothing gates: `release/NOTES.md` is build
    # output that no check reads.
    frag = anchor(version)
    changes = f"**What changed:** [`CHANGELOG.md`, {version}]({REPO}/blob/v{version}/CHANGELOG.md#{frag})"

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
git clone --recurse-submodules {REPO} && cd cyclepay && git checkout v{version}
scripts/reproducible-build.sh v{version}

# paste the block above into release/PUBLISHED.txt, then check YOUR binaries
# against THOSE hashes — this fails loudly and names the file that differs
cd release && shasum -a 256 -c PUBLISHED.txt

# and the canister must report the same backend hash
icp canister status {BACKEND} -n ic -p
```

All three must agree: your build, the hashes above, and the canister.

## Frontend state hash

```
{fe_hash}  certified-assets v{ca_version}
```

One SHA-256 over everything the frontend canister serves: every asset's bytes in every
encoding, its `content_type` and response headers, and the redirect rules in match order.
Built from `src/frontend/dist` at this tag.

⚠️ **`frontend.wasm` above is not a meaningful check.** It is the pinned recipe's
pre-built certified-assets canister — identical for every project using it, and unrelated
to the page anyone is served. This state hash is the one that describes the page.

Build this tag's frontend, then compare, either way round. Both need a Rust toolchain:
the hash is defined by certified-assets' own preparation code, so computing it means
running that project's verifier, built once from source and then cached.

```bash
# from the v{version} checkout above
npm --prefix src/frontend ci && npm --prefix src/frontend run build

# (a) the repo's check, if this tree has it: it reads the pin, builds a matching
#     verifier, confirms the canister runs that release, and compares for you
scripts/check-frontend-hash.py -e ic

# (b) the verifier on its own, which works in any tree and depends on nothing of ours
cargo install --git https://github.com/dfinity/certified-assets \\
  --tag v{ca_version} --locked state-hash-cli
state-hash src/frontend/dist
icp canister call {FRONTEND} state_hash '()' -n ic -o hex | tail -c 65
```

Three things must agree, as with the backend: your build, the hash above, and the live
canister. ⚠️ **Build the tag, not `main`** — `main` moves on after a release, and one
changed HTML comment is enough to change this number.

`docs/VERIFY.md` has the rest, including what only a buyer can check and the known limits.
"""
    out_path.write_text(out)
    print(f"   wrote {out_path} ({len(out.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
