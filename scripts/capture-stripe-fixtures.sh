#!/usr/bin/env bash
# Capture REAL Stripe event bodies as test fixtures (issue #4).
#
# Why: every Stripe payload in this repo is JSON we wrote from the API docs. The
# suites therefore prove the canister matches *our reading* of Stripe, not Stripe.
# That has already bitten once — a unit test "covered" delayed-payment settlement by
# sending a second `checkout.session.completed`, an event Stripe does not send.
#
# This script listens with `stripe listen --print-json`, sorts each event into
# test/integration/fixtures/<name>.json, and tells you which are still missing. Run
# it, perform the actions it lists, Ctrl-C. No copy-pasting from the Dashboard.
#
# Usage:
#   scripts/capture-stripe-fixtures.sh                 # capture + forward to a local gateway
#   scripts/capture-stripe-fixtures.sh --no-forward    # capture only, do not deliver anywhere
#   scripts/capture-stripe-fixtures.sh --status        # what has been captured so far
#
# Prerequisites:
#   brew install stripe/stripe-cli/stripe jq
#   stripe login            # choose a SANDBOX account, never live
set -euo pipefail

cd "$(dirname "$0")/.."
FIXTURES="test/integration/fixtures"
FORWARD=1

for arg in "$@"; do
  case "$arg" in
    --no-forward) FORWARD=0 ;;
    --status) FORWARD=2 ;;
    -h | --help)
      sed -n '2,20p' "$0" | sed 's|^# \{0,1\}||'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

die() {
  echo "error: $*" >&2
  exit 1
}

# The fixtures we want, and what produces each. Kept in one place so --status and
# the closing summary cannot drift apart.
wanted() {
  cat <<'LIST'
checkout.session.completed.paid|pay a test-mode Payment Link with 4242 4242 4242 4242
checkout.session.completed.unpaid|pay with a DELAYED method (e.g. SEPA debit) enabled on the link
checkout.session.completed.no-intent|use a 100%-off promo code, or a subscription-mode link
checkout.session.async_payment_succeeded|let the delayed payment above settle
checkout.session.async_payment_failed|stripe trigger checkout.session.async_payment_failed
charge.refunded.full|refund a charge IN FULL in the Dashboard
charge.refunded.partial|refund PART of a charge (e.g. $1 of $5) — the case that survived 3 review rounds
charge.dispute.created|stripe trigger charge.dispute.created
LIST
}

report_status() {
  local have=0 total=0
  echo
  echo "fixtures in $FIXTURES:"
  while IFS='|' read -r name how; do
    total=$((total + 1))
    if [ -s "$FIXTURES/$name.json" ]; then
      printf '  \033[32m✓\033[0m %-46s\n' "$name"
      have=$((have + 1))
    else
      printf '  \033[33m·\033[0m %-46s %s\n' "$name" "$how"
    fi
  done < <(wanted)
  echo
  echo "  $have of $total captured"
}

if [ "$FORWARD" -eq 2 ]; then
  report_status
  exit 0
fi

command -v stripe >/dev/null 2>&1 || die "stripe CLI not found. brew install stripe/stripe-cli/stripe"
command -v jq >/dev/null 2>&1 || die "jq not found. brew install jq"
command -v node >/dev/null 2>&1 || die "node not found"

mkdir -p "$FIXTURES"

FORWARD_ARGS=()
if [ "$FORWARD" -eq 1 ]; then
  # Forwarding is optional but recommended: it exercises the canister at the same
  # time, so a captured fixture is one the gateway actually accepted.
  STATUS_JSON="$(icp network status --json 2>/dev/null)" ||
    die "no local network. Run: icp network start -d && icp deploy  (or pass --no-forward)"
  PORT="$(printf '%s' "$STATUS_JSON" | jq -r '.gateway_url' | sed -E 's#^https?://[^:]+:([0-9]+)/?$#\1#')"
  BACKEND_ID="$(icp canister status backend --json 2>/dev/null | jq -r '.id')" ||
    die "backend not deployed. Run: icp deploy"
  FORWARD_ARGS=(--forward-to "http://127.0.0.1:${PORT}/webhook/stripe?canisterId=${BACKEND_ID}")
  echo "forwarding to: http://127.0.0.1:${PORT}/webhook/stripe?canisterId=${BACKEND_ID}"
  echo
  echo "⚠ The canister's webhook secret must match this session's signing secret:"
  echo "    icp canister call backend set_webhook_secret \"(\\\"\$(stripe listen --print-secret)\\\")\""
fi

report_status
cat <<'NOTES'
Perform the actions listed above. Each captured event is written as it arrives;
re-running an action overwrites its fixture, so a bad capture is easy to redo.

Ctrl-C when the list is complete.

NOTES

# `--print-json` emits one JSON object per line. Sort by type, and by the field that
# distinguishes the variants we care about — paid vs unpaid, full vs partial refund,
# and the missing-payment_intent case that a promo code or subscription link produces.
stripe listen --print-json "${FORWARD_ARGS[@]}" 2>/dev/null | node -e '
const fs = require("fs");
const dir = process.argv[1];
let buf = "";
process.stdin.on("data", (chunk) => {
  buf += chunk;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line.startsWith("{")) continue;
    let ev;
    try { ev = JSON.parse(line); } catch { continue; }
    const o = ev?.data?.object ?? {};
    let name = ev.type;
    if (ev.type === "checkout.session.completed") {
      if (o.payment_intent == null) name += ".no-intent";
      else if (o.payment_status === "paid") name += ".paid";
      else name += ".unpaid";
    } else if (ev.type === "charge.refunded") {
      name += o.amount_refunded >= o.amount ? ".full" : ".partial";
    }
    const path = `${dir}/${name}.json`;
    fs.writeFileSync(path, JSON.stringify(ev, null, 2) + "\n");
    process.stdout.write(`  captured ${name}\n`);
  }
});
' "$FIXTURES"
