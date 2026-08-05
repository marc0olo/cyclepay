#!/usr/bin/env bash
# Deploy-and-wiring smoke test against a real local network (issue #7).
#
# Why this exists: the PocketIC suite installs wasms directly and never runs
# `icp deploy`, so four things it covers perfectly well in-canister have **no
# automated coverage at all** at the deployment layer:
#
#   1. the deploy itself — recipe pipeline, `shrink: true`, the embedded
#      candid:service metadata, the Candid compatibility check;
#   2. the `PUBLIC_CANISTER_ID:xrc` override branch — in PocketIC the mock sits
#      *at* the mainnet id, so no env var is injected and only the fallback
#      branch ever runs. The override executes solely on a local network;
#   3. the asset canister and its `ic_env` cookie — the frontend serving at all;
#   4. `icp.yaml` environment scoping, i.e. that the `ic` environment excludes
#      the local-only `xrc` mock so it can never reach mainnet.
#
# None of these is a canister behaviour, which is exactly why the canister test
# suite misses them. A broken `icp.yaml` or a bad recipe pin would ship silently.
#
# Deliberately NOT covered: the money path. Reaching `delivered` locally also
# needs the CMC rate set by impersonating governance through the local network's
# PocketIC control API, which is not a supported `icp` interface — the port is
# unpublished and may change between releases. That recipe is in
# docs/SANDBOX-TESTPLAN.md for manual use; nothing scripted depends on it. Every
# money-path assertion stays in the PocketIC suite, where it needs none of this.
#
# Usage:
#   scripts/e2e-local.sh              # start a network if needed, deploy, assert, tear down
#   scripts/e2e-local.sh --keep       # leave the network running afterwards
#   scripts/e2e-local.sh --no-deploy  # assert against what is already deployed
#
# A network this script did not start is never stopped, --keep or not.
#
# Prerequisites: icp-cli ≥ 1.2.0, jq, node, python3, curl.
set -euo pipefail

cd "$(dirname "$0")/.."

KEEP=0
DEPLOY=1
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --no-deploy) DEPLOY=0 ;;
    -h | --help)
      sed -n '2,32p' "$0" | sed 's|^# \{0,1\}||'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

# The webhook secret this run provisions. Local-only and printed below: it exists
# to prove the signature path executes, not to protect anything.
WEBHOOK_SECRET='whsec_e2e_local_smoke_test'
XRC_WASM='test/integration/wasm/xrc_mock.wasm.gz'
STARTED_NETWORK=0
CHECKS=0

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok() {
  CHECKS=$((CHECKS + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}
die() {
  printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2
  exit 1
}

# An upgrade that trapped in `register_stable_type` means the stable signature
# changed incompatibly — Motoko's enhanced orthogonal persistence refuses to
# reinterpret existing memory under a new layout, so `post_upgrade` traps rather
# than corrupting state. Nothing is wrong with the new build; it simply cannot
# inherit this canister's memory.
#
# Locally the answer is `--mode reinstall`: the network is disposable and this
# script provisions everything it asserts on. **On mainnet reinstall wipes the
# order store, the journals and the dedup sets** — there the answer is a
# migration expression, or a deliberate decision made before any real order
# exists. Printed loudly because those two situations look identical from here.
reinstall_or_die() {
  local log="$1"
  if ! grep -q 'Memory-incompatible program upgrade' "$log"; then
    cat "$log" >&2
    die "icp deploy failed"
  fi
  printf '\n\033[33m⚠ STABLE-SHAPE CHANGE — this build cannot upgrade the deployed canister:\033[0m\n'
  printf '    the upgrade trapped in register_stable_type (EOP memory-incompatible).\n'
  printf '    Reinstalling locally, which WIPES orders, journals and dedup sets.\n'
  printf '    On mainnet this needs a migration expression instead.\n\n'
  icp deploy --mode reinstall --yes || {
    cat "$log" >&2
    die "icp deploy failed even with --mode reinstall"
  }
  ok "deployed (reinstalled after an incompatible stable shape, reported above)"
}

cleanup() {
  local code=$?
  if [ "$STARTED_NETWORK" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
    step "tearing down the network this run started"
    icp network stop >/dev/null 2>&1 || true
    printf '  stopped\n'
  elif [ "$STARTED_NETWORK" -eq 1 ]; then
    printf '\nnetwork left running (--keep). Stop it with: icp network stop\n'
  fi
  if [ "$code" -ne 0 ]; then
    printf '\n\033[31m✗ smoke test FAILED after %d passing check(s)\033[0m\n' "$CHECKS" >&2
  fi
}
trap cleanup EXIT

# ── 0. preflight ──────────────────────────────────────────────────────────────
step "0. preflight"
for tool in icp jq node python3 curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH"
done
python3 -c 'import yaml' 2>/dev/null ||
  die "python3 needs PyYAML for the environment-scoping check (pip3 install pyyaml)"
ok "icp $(icp --version | awk '{print $2}'), jq, node, python3+yaml, curl"

# The xrc mock is fetched and hash-verified by test/integration's pretest, and
# icp.yaml pins the same file by sha256. Without it the deploy fails on a missing
# path rather than on anything interesting.
if [ ! -s "$XRC_WASM" ]; then
  printf '  %s missing — fetching\n' "$XRC_WASM"
  npm --prefix test/integration run fetch:wasm >/dev/null
fi
ok "xrc mock present"

# ── 1. network ────────────────────────────────────────────────────────────────
step "1. local network"
if icp network status >/dev/null 2>&1; then
  ok "already running (this run will not stop it)"
else
  icp network start -d >/dev/null || die "icp network start failed"
  STARTED_NETWORK=1
  ok "started"
fi

GATEWAY="$(icp network status --json | jq -r '.gateway_url' | sed 's|/$||')"
[ -n "$GATEWAY" ] || die "could not read the gateway url"
ok "gateway at $GATEWAY"

# ── 2. deploy ─────────────────────────────────────────────────────────────────
if [ "$DEPLOY" -eq 1 ]; then
  step "2. icp deploy"
  # The whole pipeline: moc build, ic-wasm shrink, candid:service metadata, the
  # Candid compatibility check against the *deployed* canister, the asset build
  # and sync, and the PUBLIC_CANISTER_ID injection every later assertion needs.
  #
  # Run without --yes first, so a breaking interface change is *reported* rather
  # than bypassed silently — that check is the only automated warning this repo
  # gets before an incompatible upgrade. A local network is disposable, so on
  # failure we surface the diff and retry with --yes; on mainnet the same output
  # is a decision, not a speed bump.
  DEPLOY_LOG="$(mktemp)"
  # The xrc mock stores its canned response in heap only and sets it from
  # `init_args` at INSTALL time, so a routine `icp deploy` upgrades it and the
  # response is gone — every later rate call then traps with "Response has not
  # been set". Reinstalling it first is free (it holds nothing worth keeping) and
  # makes the pricing check mean something.
  if icp canister status xrc >/dev/null 2>&1; then
    icp deploy --mode reinstall --yes xrc >/dev/null 2>&1 ||
      die "could not reinstall the xrc mock"
    ok "xrc mock reinstalled (its response is install-time only)"
  fi
  if icp deploy >"$DEPLOY_LOG" 2>&1; then
    ok "deployed (interface compatible with what was already there)"
  elif grep -q 'Candid interface compatibility check failed' "$DEPLOY_LOG"; then
    printf '\n\033[33m⚠ BREAKING interface change vs the deployed canister:\033[0m\n'
    grep -E '^Method |is not a subtype' "$DEPLOY_LOG" | sed 's|^|    |'
    printf '    Retrying with --yes because a local network is disposable. On\n'
    printf '    mainnet, decide deliberately: existing clients may stop working.\n\n'
    if icp deploy --yes >"$DEPLOY_LOG" 2>&1; then
      ok "deployed (breaking change accepted locally, reported above)"
    else
      reinstall_or_die "$DEPLOY_LOG"
    fi
  elif grep -q 'Memory-incompatible program upgrade' "$DEPLOY_LOG"; then
    reinstall_or_die "$DEPLOY_LOG"
  else
    cat "$DEPLOY_LOG" >&2
    die "icp deploy failed"
  fi
  rm -f "$DEPLOY_LOG"
else
  step "2. icp deploy — skipped (--no-deploy)"
fi

BACKEND_ID="$(icp canister status backend --json | jq -r '.id')"
[ "$BACKEND_ID" != "null" ] && [ -n "$BACKEND_ID" ] || die "backend not deployed"
ok "backend is $BACKEND_ID"

# ── 3. the env-var override branch ────────────────────────────────────────────
step "3. PUBLIC_CANISTER_ID:xrc override"
# THE assertion this script exists for. PocketIC puts the mock at the mainnet id,
# so `Runtime.envVar` returns null there and only the fallback branch is ever
# exercised. Here the id differs, so a broken lookup shows up as the mainnet id.
INJECTED="$(icp canister status backend --json |
  jq -r '.settings.environment_variables[] | select(.name == "PUBLIC_CANISTER_ID:xrc") | .value')"
[ -n "$INJECTED" ] || die "icp deploy did not inject PUBLIC_CANISTER_ID:xrc"
ok "deploy injected xrc = $INJECTED"

# `pricing_status.xrcCanisterId` reports the id an XRC call actually *resolved*,
# and is null until one has — so force a refresh rather than reading a field that
# has not been populated. (Its being null rather than defaulting to the mainnet id
# is deliberate: a detection signal must not read all-clear before it has looked.)
icp canister call backend refresh_rates '()' >/dev/null 2>&1 || true
PRICING="$(icp canister call backend pricing_status '()')"
REPORTED="$(printf '%s' "$PRICING" |
  sed -n 's/.*xrcCanisterId = opt "\([^"]*\)".*/\1/p' | head -1)"
[ -n "$REPORTED" ] ||
  die "pricing_status.xrcCanisterId is still null after a refresh — no XRC call has
    resolved an id, so the override is unverified. Full response:
$PRICING"
[ "$REPORTED" = "$INJECTED" ] ||
  die "backend resolved the XRC to '$REPORTED', expected the injected '$INJECTED'.
    Reading the mainnet id (uf6dk-hyaaa-aaaaq-qaaaq-cai) means the env-var
    override is not working and every local order would price off mainnet."
ok "backend resolved the XRC to the injected local id"

# And the id it resolved can actually answer — a correct id that returns nothing
# prices no orders. `rates` is null until a refresh succeeds end to end.
# `rates` staying null locally is EXPECTED, not a failure: caching a pair needs a
# fresh CMC rate too, and a local network's CMC has none until governance is
# impersonated through the PocketIC control API — the unsupported interface this
# script deliberately avoids (see the header). So this is a soft note: it means
# local orders cannot be priced, which is why the money path lives in the PocketIC
# suite and the manual recipe lives in docs/SANDBOX-TESTPLAN.md.
if printf '%s' "$PRICING" | grep -q 'rates = null'; then
  printf '  \033[33m·\033[0m no rate pair cached — expected locally (the CMC rate needs governance;\n'
  printf '    see docs/SANDBOX-TESTPLAN.md). The XRC id above is still proven.\n'
else
  ok "a rate pair is cached, priced from the local mock"
fi

# ── 4. the asset canister and its ic_env cookie ───────────────────────────────
step "4. frontend"
HEADERS="$(mktemp)"
FRONT_STATUS="$(curl -sS -o /dev/null -D "$HEADERS" -w '%{http_code}' \
  "http://frontend.local.localhost:${GATEWAY##*:}/" || true)"
[ "$FRONT_STATUS" = "200" ] || die "frontend returned $FRONT_STATUS, expected 200"
ok "http://frontend.local.localhost:${GATEWAY##*:}/ → 200"

# The cookie is how the frontend learns the local root key and the canister ids
# without a build-time bake. No cookie means the app boots pointing at mainnet.
# Its contents are percent-encoded (`ic%5Froot%5Fkey`), so decode before matching —
# grepping the raw header for `ic_root_key` finds nothing even when it is there.
grep -qi '^set-cookie:.*ic_env' "$HEADERS" || die "no ic_env cookie on the frontend response"
COOKIE="$(grep -i '^set-cookie:.*ic_env' "$HEADERS" | head -1 |
  python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))')"
rm -f "$HEADERS"
printf '%s' "$COOKIE" | grep -q 'ic_root_key=' ||
  die "the ic_env cookie carries no ic_root_key — the app would verify certificates against the mainnet key"
ok "ic_env cookie carries ic_root_key"

# The same cookie carries the ids the app calls, so a stale one points a working
# frontend at a canister that no longer exists.
printf '%s' "$COOKIE" | grep -q "PUBLIC_CANISTER_ID:backend=${BACKEND_ID}" ||
  die "the ic_env cookie does not name the deployed backend ($BACKEND_ID)"
ok "ic_env cookie names the deployed backend"

# ── 5. local Internet Identity ────────────────────────────────────────────────
step "5. local Internet Identity"
II_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' \
  "http://id.ai.localhost:${GATEWAY##*:}/" || true)"
[ "$II_STATUS" = "200" ] ||
  die "local II returned $II_STATUS, expected 200. Is \`ii: true\` still set on the local network in icp.yaml?"
ok "http://id.ai.localhost:${GATEWAY##*:}/ → 200"

# ── 6. the webhook route through the real gateway ─────────────────────────────
step "6. signed webhook through the HTTP gateway"
icp canister call backend set_webhook_secret "(\"$WEBHOOK_SECRET\")" >/dev/null ||
  die "set_webhook_secret failed (are you the controller?)"
ok "webhook secret provisioned"

# A `charge.dispute.created` body on purpose: it is a type the canister does not
# subscribe to, so it verifies, acks 200, and files **nothing**. That proves the
# route, the signature check and the secret without leaving an obligation behind
# on the local canister — which a payment-shaped body would.
# The signature covers the body BYTE FOR BYTE, so node writes the body to a file
# and curl sends that same file. Piping it through a text filter is what breaks
# this: `jq -r` appends a newline, and a one-byte difference is a 400 that looks
# exactly like a broken verifier.
BODY_FILE="$(mktemp)"
SIG_HEADER="$(node -e '
const crypto = require("crypto");
const fs = require("fs");
const [secret, bodyFile] = process.argv.slice(1);
const body = JSON.stringify({
  id: "evt_e2e_local_smoke",
  type: "charge.dispute.created",
  livemode: false,
  data: { object: { id: "dp_smoke" } },
});
fs.writeFileSync(bodyFile, body);
const t = Math.floor(Date.now() / 1000);
const sig = crypto.createHmac("sha256", secret).update(`${t}.${body}`).digest("hex");
process.stdout.write(`t=${t},v1=${sig}`);
' "$WEBHOOK_SECRET" "$BODY_FILE")"

WEBHOOK_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "${GATEWAY}/webhook/stripe?canisterId=${BACKEND_ID}" \
  -H 'content-type: application/json' \
  -H "stripe-signature: $SIG_HEADER" \
  --data-binary "@$BODY_FILE" || true)"
rm -f "$BODY_FILE"
[ "$WEBHOOK_STATUS" = "200" ] ||
  die "the signed webhook returned $WEBHOOK_STATUS, expected 200.
    400 means signature verification rejected a body we signed correctly;
    503 means the secret did not stick."
ok "POST ${GATEWAY}/webhook/stripe → 200"

# An unsigned body must NOT be accepted — otherwise the 200 above proves nothing.
UNSIGNED_STATUS="$(printf '{}' | curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "${GATEWAY}/webhook/stripe?canisterId=${BACKEND_ID}" \
  -H 'content-type: application/json' --data-binary @- || true)"
[ "$UNSIGNED_STATUS" = "400" ] ||
  die "an unsigned body returned $UNSIGNED_STATUS, expected 400 — the route is not verifying signatures"
ok "an unsigned body is refused 400"

# ── 7. environment scoping keeps the mock off mainnet ─────────────────────────
step "7. the ic environment excludes the local-only xrc mock"
# Structural, not procedural: an unlisted canister is never created, never
# installed, and its PUBLIC_CANISTER_ID is never injected — so a mainnet backend
# falls back to the real Exchange Rate Canister no matter who runs the deploy.
IC_CANISTERS="$(icp project show | python3 -c '
import sys, yaml
# `icp project show` emits custom tags (e.g. `!Text` on init args), which
# safe_load refuses outright. Ignore unknown tags rather than whitelisting them:
# this only reads the canister list, and the tag set is the CLIs to change.
yaml.SafeLoader.add_multi_constructor("", lambda loader, suffix, node: None)
doc = yaml.safe_load(sys.stdin)
env = (doc.get("environments") or {}).get("ic")
if env is None:
    sys.exit("no `ic` environment in the effective configuration")
canisters = env.get("canisters")
if not canisters:
    sys.exit("the `ic` environment lists no canisters — it would deploy EVERYTHING, mock included")
print(" ".join(sorted(canisters)))
')" || die "$IC_CANISTERS"
[ "$IC_CANISTERS" = "backend frontend" ] ||
  die "the ic environment lists [$IC_CANISTERS], expected [backend frontend].
    Anything more risks deploying the XRC mock to mainnet."
ok "ic environment lists exactly: $IC_CANISTERS"

# ── 8. the deployed wasm is the committed interface ───────────────────────────
step "8. deployed module matches a local build"
# `icp deploy` runs a Candid compatibility check, but only against the .did in
# the repo — it cannot notice that the .did itself is stale. This is the same
# check scripts/test-all.sh makes, repeated here because a deploy is exactly when
# a stale interface becomes a live one.
mops build >/dev/null 2>&1 || die "mops build failed"
git diff --quiet -- src/backend/dist/backend.did ||
  die "src/backend/dist/backend.did is out of date — the deployed candid:service metadata is stale"
ok "committed .did is current"

printf '\n\033[32m✓ %d checks passed\033[0m\n' "$CHECKS"
