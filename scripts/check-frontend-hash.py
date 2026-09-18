#!/usr/bin/env python3
"""Compare the state hash the frontend canister reports against a local `dist` build.

This is the whole frontend check. The hash is a SHA-256 over the canister's
served-content model: every asset by key with its `content_type`, response headers
and per-encoding content hashes, plus the redirect rules in match order. Matching it
means the canister serves exactly the build in `src/frontend/dist`.

⚠️ **Not the module hash.** The `@dfinity/static-site` recipe installs a pre-built
certified-assets wasm, so that hash describes the recipe — identical for every project
using it, and unrelated to the page anyone is served. The page lives in canister state.

⚠️ **The verifier is version-locked to the canister, and this script enforces it.**
The hash is bound to how content is prepared — the compressor builds, `MAX_CHUNK_SIZE`,
the digest layout, and the 404/clean-URL rules the preparation synthesizes — all of
which are frozen per release. A `state-hash` from the wrong release computes a
different number from identical files, so the comparison would fail for no reason. So
the tag comes from `icp.yaml`'s recipe pin, never from a human, and the canister's own
`version()` must agree with it before any hash is compared.

⚠️ **`--locked` is part of the version match, not a precaution.** `cargo install`
re-resolves dependencies without it, and a newer `brotli` patch emits different bytes
for the same input, so the right tag with a fresh lock still computes a different hash.

What this does NOT prove: that each compressed encoding is an honest compression of
its identity bytes is exactly what IS proved here (the hash covers every encoding),
but only for the compressors this release links. A canister synced by some other
program that injected its own compressors matches no hash this tool computes.

Usage: scripts/check-frontend-hash.py [-e ENV | -n NETWORK]   (default: -e ic)
       scripts/check-frontend-hash.py --print [TREE]          (no canister; prints the hash)

`--print` computes the hash of a tree's built `dist` and prints it, for `release.sh` to
publish. It takes a TREE ROOT rather than a `dist` path so the pin and the directory
always come from the same tree: pairing one release's `dist` with another's recipe pin
would publish a number that no verifier can reproduce.
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _recipe_pin import pin_of_tree, self_test as pin_self_test  # noqa: E402

DIST = Path("src/frontend/dist")
REPO = "https://github.com/dfinity/certified-assets"
# Built verifiers, one directory per release, so the path itself records the version
# and a bumped pin can never silently reuse the previous binary.
CACHE = Path(".cache/state-hash")

VERSION_REPLY = re.compile(
    r"major\s*=\s*(\d+)\s*:\s*nat32;\s*minor\s*=\s*(\d+)\s*:\s*nat32;\s*patch\s*=\s*(\d+)"
)
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def icp(method: str, args: str, net: list[str], *extra: str) -> str:
    out = subprocess.run(
        ["icp", "canister", "call", "frontend", method, args, *net, *extra],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"error: `icp canister call frontend {method}` failed:\n{out.stderr.strip()}")
    return out.stdout


def canister_version(net: list[str]) -> str:
    m = VERSION_REPLY.search(icp("version", "()", net, "--query"))
    if not m:
        sys.exit("ABORT: could not parse `version()` — cannot confirm the verifier matches")
    return ".".join(m.groups())


def served_hash(net: list[str]) -> str:
    """`state_hash` as 64 hex chars. `-o hex` prints the Candid-encoded reply, whose
    last 32 bytes are the hash, which avoids unescaping a Candid blob by hand."""
    raw = icp("state_hash", "()", net, "-o", "hex").strip()
    if len(raw) < 64:
        sys.exit(f"ABORT: `state_hash` reply too short to contain a hash: {raw!r}")
    return raw[-64:]


def verifier(version: str) -> Path:
    """`state-hash` built from the pinned tag, cached per version. Built from source on
    purpose: a binary someone hands you is one more thing to trust."""
    binary = CACHE / version / "bin" / "state-hash"
    if binary.is_file():
        return binary
    if not shutil.which("cargo"):
        sys.exit("error: this check builds the verifier from source and needs cargo.\n"
                 "    Install Rust (https://rustup.rs), then re-run.")
    # ⚠️ **stderr, not stdout.** `--print` writes the hash to stdout and `release.sh`
    # captures it, so a progress line on stdout lands in the published hash file. It
    # only shows up on a COLD cache, which is a fresh machine and the first release
    # after a recipe bump — the runs where a release is least able to absorb it.
    print(f"   building state-hash v{version} from {REPO} (once, then cached)",
          file=sys.stderr)
    out = subprocess.run(
        ["cargo", "install", "--git", REPO, "--tag", f"v{version}",
         "--locked", "state-hash-cli", "--root", str(CACHE / version)],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"error: building state-hash v{version} failed:\n{out.stderr.strip()}")
    return binary


def local_hash(binary: Path, dist: Path) -> str:
    out = subprocess.run([str(binary), str(dist)], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"error: `state-hash {dist}` failed:\n{out.stderr.strip()}")
    return out.stdout.strip()


def _self_test() -> None:
    """⚠️ Unconditional. Three parsers stand between this check and a false result, and
    each reads text some other tool formats: `icp.yaml` (in `_recipe_pin`, whose own
    self-test is called here), and two shapes of `icp` output. A formatting change would
    otherwise surface as an unexplained hash mismatch."""
    pin_self_test()
    v = VERSION_REPLY.search(
        "(record { major = 0 : nat32; minor = 3 : nat32; patch = 3 : nat32 })"
    )
    assert ".".join(v.groups()) == "0.3.3", "version reply parser failed"
    # `-o hex` prepends the Candid envelope (`DIDL`, type table, a length byte); the
    # hash is the tail, so a changed envelope width must not shift what we read.
    envelope = "4449444c016d7b010020"
    digest = "3241a30f2ec322a0c3b605053c36bd2293966d18628c896fcfd43243d925a864"
    assert (envelope + digest)[-64:] == digest, "hex tail extraction failed"
    assert HEX64.match(digest) and not HEX64.match(digest.upper())


def print_only(argv: list[str]) -> int:
    """The hash of one tree's built `dist`, and nothing else on stdout, so `release.sh`
    can capture it. Same code path as the comparison below, so the number a release
    publishes and the number a verifier checks cannot come from different logic."""
    if len(argv) > 1:
        sys.exit("usage: scripts/check-frontend-hash.py --print [TREE]")
    tree = Path(argv[0]) if argv else Path(".")
    dist = tree / DIST
    if not dist.is_dir():
        sys.exit(f"error: {dist} is missing. Build it first:\n"
                 f"    npm --prefix {tree / 'src/frontend'} ci && "
                 f"npm --prefix {tree / 'src/frontend'} run build")
    h = local_hash(verifier(pin_of_tree(tree)), dist)
    if not HEX64.match(h):
        sys.exit(f"ABORT: state-hash printed no 64-char hex hash: {h!r}")
    print(h)
    return 0


def main() -> int:
    _self_test()
    if sys.argv[1:2] == ["--print"]:
        return print_only(sys.argv[2:])
    net = sys.argv[1:] or ["-e", "ic"]
    if not DIST.is_dir():
        sys.exit(f"error: {DIST} is missing. Build it first:\n"
                 f"    npm --prefix src/frontend ci && npm --prefix src/frontend run build")

    pinned = pin_of_tree()
    deployed = canister_version(net)
    if deployed != pinned:
        sys.exit(f"ABORT: the canister runs certified-assets v{deployed}, icp.yaml pins "
                 f"v{pinned}.\n    The hash is frozen per release, so comparing across "
                 f"versions proves nothing.\n    Deploy the pinned version, or check out "
                 f"the commit whose pin matches the deployment.")
    print(f"   certified-assets v{deployed} (canister) == v{pinned} (icp.yaml pin)")

    served = served_hash(net)
    if served == "00" * 32:
        sys.exit("ABORT: the canister reports 32 zero bytes, meaning it has no hash: it has "
                 "either never\n    completed a sync, or one is running now. Re-read it once "
                 "`icp deploy frontend` finishes.")

    local = local_hash(verifier(pinned), DIST)
    if not HEX64.match(local):
        sys.exit(f"ABORT: state-hash printed no 64-char hex hash: {local!r}")

    print(f"   served {served}")
    print(f"   built  {local}")
    if served != local:
        print("\n\033[31m✗ the canister is not serving this build\033[0m", file=sys.stderr)
        print("  Either the build is not the deployed one, or the deploy did not land.\n"
              "  The hash is one value over every asset, its headers and the redirect rules,\n"
              "  so it cannot say WHICH of those differs: rebuild from the deployed commit\n"
              "  and re-run, then `icp deploy frontend` if it is the deployment that is stale.",
              file=sys.stderr)
        return 1
    print("   ✓ the canister serves exactly this build: every asset, its headers, and the "
          "redirect rules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
