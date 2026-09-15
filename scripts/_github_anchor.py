#!/usr/bin/env python3
"""GitHub's heading-anchor rule, in one place.

⚠️ **One implementation, imported, not restated.** Two scripts need it —
`check-doc-links.py` to verify the anchors written in the docs, `release-notes.py` to
build the link into `CHANGELOG.md` at a tag — and a second copy is the same class as a
restated figure: identical today, silently divergent later. The release-notes copy is the
one nothing would catch, because `release/NOTES.md` is build output that no gate step ever
reads.

The rule: lowercase, drop everything that is not a word character, space or hyphen, then
spaces to hyphens. Two consequences that look like bugs and are not — an em dash is
dropped and leaves the spaces either side, so `Mode 1 — local` is `mode-1--local` with two
hyphens; and a version's dots vanish, so `0.1.0-beta.1` is `010-beta1`. The second was
verified against GitHub's rendered page, not derived.

⚠️ Leading underscore: this is a module, not a gate step. `scripts/test-all.sh` and
`.github/workflows/mops-test.yml` name their checks explicitly, so nothing tries to run it.
"""

import re


def anchor(heading: str) -> str:
    s = heading.strip().lower()
    s = re.sub(r"[^\w\s-]", "", s)
    return s.replace(" ", "-")


def self_test() -> None:
    """Unconditional at both call sites: a wrong rule fails every link or none, and both
    read as "the check ran"."""
    assert anchor("Mode 1 — local") == "mode-1--local"
    assert anchor("Mode 2 — mainnet simulation") == "mode-2--mainnet-simulation"
    assert anchor("What is pinned") == "what-is-pinned"
    assert anchor("`state_hash` is a fingerprint, not a check") == "state_hash-is-a-fingerprint-not-a-check"
    assert anchor("1. The one-sentence version") == "1-the-one-sentence-version"
    # a released version, as the release notes link to it
    assert anchor("0.1.0-beta.1") == "010-beta1"
