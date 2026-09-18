#!/usr/bin/env python3
"""The `@dfinity/static-site` recipe pin in `icp.yaml`, read in one place.

⚠️ **One implementation, imported, not restated.** Two scripts need it —
`check-frontend-hash.py` to pick the verifier that computes the frontend state hash, and
`release-notes.py` to publish the certified-assets release that hash was computed under —
and the two must agree or the notes pair a number with the wrong release, which reproduces
for nobody. A second copy is the same class as a restated figure: identical today,
silently divergent later. Same reason [`_github_anchor.py`](_github_anchor.py) exists.

The pin IS the canister version: the recipe and the canister ship as a version-locked
pair, so the recipe a project pins is the release its canister runs.

⚠️ Leading underscore: this is a module, not a gate step. `scripts/test-all.sh` and
`.github/workflows/mops-test.yml` name their checks explicitly, so nothing tries to run it.

⚠️ **Being importable costs a trap: `rm -rf scripts/__pycache__` before trusting a
mutation test on this file** — CPython invalidates a `.pyc` on (mtime, size), and editing
one character changes neither within the same second. See `_github_anchor.py`, where that
reported a passing self-test over a broken rule.
"""

import re
import sys
from pathlib import Path

PIN = re.compile(r'type:\s*"@dfinity/static-site@v(\d+\.\d+\.\d+)"')


def pin_in(text: str) -> str | None:
    """The pinned certified-assets version in an `icp.yaml`'s text, or None."""
    m = PIN.search(text)
    return m.group(1) if m else None


def pin_of_tree(tree: Path = Path(".")) -> str:
    """The pin in `tree/icp.yaml`. Exits rather than returning a default: a wrong
    version computes a different hash from identical files, so a guess would surface
    as an unexplained mismatch."""
    path = tree / "icp.yaml"
    if not path.is_file():
        sys.exit(f"error: {path} does not exist — expected a repo root")
    version = pin_in(path.read_text())
    if version is None:
        sys.exit(f"error: no `@dfinity/static-site@vX.Y.Z` recipe pin found in {path}")
    return version


def self_test() -> None:
    """Unconditional at every call site. The pattern reads a file another tool owns, and
    its wrong-answer mode is picking a DIFFERENT recipe's version, not failing to match."""
    assert pin_in('      type: "@dfinity/static-site@v0.3.3"') == "0.3.3"
    # The same file pins other recipes; matching one of those would publish a version
    # that has nothing to do with the assets canister.
    assert pin_in('type: "@dfinity/motoko@v5.1.0"') is None, "matched the wrong recipe"
    assert pin_in('type: "@dfinity/prebuilt@v2.1.0"') is None, "matched the wrong recipe"
    assert pin_in("no pin here") is None
    # Quoting and spacing are the recipe author's, not ours.
    assert pin_in('type:"@dfinity/static-site@v1.2.3"') == "1.2.3"


if __name__ == "__main__":
    self_test()
    print("_recipe_pin self-test passed")
