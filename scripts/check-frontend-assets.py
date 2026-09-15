#!/usr/bin/env python3
"""Compare what the frontend canister SERVES against a local `dist` build.

Three decisions, because each is a thing someone would otherwise "fix":

⚠️ **Not the module hash.** The `@dfinity/static-site` recipe installs a **pre-built**
certified-assets wasm, so that hash describes the recipe — identical for every project
using it, and unrelated to the page anyone is served. The content lives in canister
state, uploaded by the sync plugin.

⚠️ **Not `state_hash`.** It is one root hash over everything the canister certifies,
computed inside the canister, so reproducing it locally would mean reimplementing its
certification tree and would break whenever that internal shape changed. It is printed
as a fingerprint to publish with a release; `get_asset_details` is what can be compared
to a build, and it names *which* asset drifted.

⚠️ **Identity encodings only.** Matching Gzip and Brotli would mean reproducing the
compressor's settings, which is a property of the uploader rather than of the content.

Usage: scripts/check-frontend-assets.py [-e ENV | -n NETWORK]   (default: -e ic)
"""
import hashlib
import re
import subprocess
import sys
from pathlib import Path

DIST = Path("src/frontend/dist")
# Read as configuration by the sync plugin, never uploaded as assets.
NOT_SERVED = {"_headers", "_redirects"}

# ⚠️ **Assets the CANISTER provides, which no build produces.** The certified-assets
# canister serves its own certified 404 page unless the build ships one, so this key
# appears in `get_asset_details` with nothing local to compare it to — that is a correct
# deployment, not drift, and treating it as a mismatch would fail every clean run. If the
# build does ship one, it is compared like any other asset: only the ABSENT case is
# excused.
CANISTER_DEFAULTS = {"/404.html"}


def icp(method: str, args: str, net: list[str]) -> str:
    out = subprocess.run(
        ["icp", "canister", "call", "frontend", method, args, *net],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"error: `icp canister call frontend {method}` failed:\n{out.stderr.strip()}")
    return out.stdout


def unblob(text: str) -> bytes:
    """Candid blob text -> bytes. Hex escapes, and literal characters for printable bytes."""
    out, i = bytearray(), 0
    while i < len(text):
        if text[i] == "\\" and i + 2 < len(text):
            out.append(int(text[i + 1:i + 3], 16)); i += 3
        else:
            out.append(ord(text[i])); i += 1
    return bytes(out)


ENCODING = re.compile(r'sha256 = blob "((?:\\[0-9a-fA-F]{2}|[^"])*)";\s*encoding = variant \{ (\w+) \}')


def served(net: list[str]) -> dict[str, str]:
    """asset key -> hex sha256 of its Identity encoding."""
    raw = icp("get_asset_details", "(null)", net)
    out = {}
    # Each asset record starts with its key, so splitting on that boundary keeps each
    # asset's encodings with the asset they belong to.
    for chunk in raw.split('record { key = "')[1:]:
        key = chunk[: chunk.index('"')]
        for blob, enc in ENCODING.findall(chunk):
            if enc == "Identity":
                out[key] = unblob(blob).hex()
                break
    return out


def main() -> int:
    net = sys.argv[1:] or ["-e", "ic"]
    if not DIST.is_dir():
        sys.exit(f"error: {DIST} is missing. Build it first:\n"
                 f"    npm --prefix src/frontend ci && npm --prefix src/frontend run build")

    remote = served(net)
    if not remote:
        sys.exit("ABORT: parsed no assets out of get_asset_details — this check cannot pass vacuously")

    local = {
        "/" + str(p.relative_to(DIST)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in DIST.rglob("*") if p.is_file() and p.name not in NOT_SERVED
    }

    bad = []
    for key in sorted(set(remote) | set(local)):
        r, l = remote.get(key), local.get(key)
        if r is None:
            bad.append(f"{key}: built locally, NOT served by the canister")
        elif l is None:
            if key not in CANISTER_DEFAULTS:
                bad.append(f"{key}: served by the canister, absent from {DIST}")
        elif r != l:
            bad.append(f"{key}: DIFFERS\n      served {r}\n      built  {l}")

    defaults = sorted((set(remote) & CANISTER_DEFAULTS) - set(local))
    print(f"   {len(remote)} asset(s) served, {len(local)} built"
          + (f", {len(defaults)} canister default(s): {', '.join(defaults)}" if defaults else ""))
    fingerprint = unblob(re.search(r'blob "((?:\\[0-9a-fA-F]{2}|[^"])*)"', icp("state_hash", "()", net)).group(1)).hex()
    print(f"   state_hash {fingerprint}")

    if bad:
        print("\n\033[31m✗ the canister is not serving this build\033[0m", file=sys.stderr)
        for b in bad:
            print(f"    {b}", file=sys.stderr)
        print("\n  Either the build is not the deployed one, or the deploy did not land.\n"
              "  `icp deploy frontend` syncs the assets; the module hash cannot tell you this.",
              file=sys.stderr)
        return 1
    print("   ✓ every served asset matches the local build, byte for byte")
    return 0


if __name__ == "__main__":
    sys.exit(main())
