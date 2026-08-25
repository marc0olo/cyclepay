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
checkout.session.completed.paid|create an order in the app and pay its session URL with 4242 4242 4242 4242
checkout.session.completed.unpaid|OUT OF BAND: hand-make a session with a DELAYED method (see the note below)
checkout.session.completed.no-intent|OUT OF BAND: hand-make a session at unit_amount=0 (see the note below)
checkout.session.async_payment_succeeded|stripe trigger checkout.session.async_payment_succeeded
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

Anything shown as `stripe trigger …` needs no Dashboard setup — run it in another
terminal while this is listening. Those bodies are Stripe's own canned fixtures
rather than the output of a real payment, which is still far better than the
hand-written JSON they replace, but note the distinction for the async pair: a
real SEPA settlement is the thing group F of docs/SANDBOX-TESTPLAN.md exercises.

⚠️ The two marked OUT OF BAND cannot be produced by this app at all since #33.
Its sessions are card-only, mode=payment, at a fixed unit_amount above the $10
floor, with no promo codes — so `payment_status` is never `unpaid` and
`payment_intent` is never absent. Both used to come from Payment Link settings,
which no longer exist here.

To capture them, create the session yourself against the sandbox and pay it:

  stripe checkout sessions create --mode=payment \
    --payment-method-types=sepa_debit --success-url=https://example.com \
    -d "line_items[0][price_data][currency]=eur" \
    -d "line_items[0][price_data][unit_amount]=1000" \
    -d "line_items[0][price_data][product_data][name]=fixture" \
    -d "line_items[0][quantity]=1"

(and the same at unit_amount=0 for the no-intent case). The handlers they
exercise are still live — a delayed method could be enabled at account level, and
a zero-amount session is still a shape Stripe can send — which is why the
fixtures are still wanted even though the app cannot produce them.

Ctrl-C when the list is complete.

NOTES

# `--print-json` emits one JSON object per line. Sort by type, and by the field that
# distinguishes the variants we care about — paid vs unpaid, full vs partial refund,
# and the missing-payment_intent case a zero-amount or subscription session produces.
stripe listen --print-json "${FORWARD_ARGS[@]}" 2>/dev/null | node -e '
const fs = require("fs");
const dir = process.argv[1];
const WANTED = new Set([
  "checkout.session.completed.paid",
  "checkout.session.completed.unpaid",
  "checkout.session.completed.no-intent",
  "checkout.session.async_payment_succeeded",
  "checkout.session.async_payment_failed",
  "charge.refunded.full",
  "charge.refunded.partial",
  "charge.dispute.created",
]);
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
    // Only the fixtures the parity suite asserts on. Stripe emits a dozen
    // incidental events per checkout (product.created, charge.succeeded, …) and
    // writing those files clutters the directory with payloads nothing reads.
    if (!WANTED.has(name)) {
      process.stdout.write(`  (ignored ${ev.type})\n`);
      continue;
    }
    // Scrub identifying fields before writing. These fixtures get committed, and a
    // sandbox checkout still records whatever real name and email you typed. The
    // parser in Card.mo reads none of these, so replacing them cannot affect an
    // assertion — and doing it on write means nobody has to remember to.
    // (No apostrophes in here: this whole block lives inside node -e '...'.)
    const SCRUB = {
      email: "buyer@example.com",
      name: "Test Buyer",
      phone: null,
      customer_email: null,
      receipt_email: null,
    };
    const scrub = (n) => {
      if (Array.isArray(n)) return n.map(scrub);
      if (n && typeof n === "object") {
        return Object.fromEntries(Object.entries(n).map(([k, v]) =>
          [k, k in SCRUB && v !== null ? SCRUB[k] : scrub(v)]));
      }
      return n;
    };
    const path = `${dir}/${name}.json`;
    fs.writeFileSync(path, JSON.stringify(scrub(ev), null, 2) + "\n");
    const o2 = ev?.data?.object ?? {};
    let note = "";
    // Flag the capture that is easy to get wrong: a paid session with no
    // client_reference_id means the URL parameter was not appended, and that
    // fixture cannot verify attribution.
    if (name === "checkout.session.completed.paid" && o2.client_reference_id == null) {
      note = "  ⚠ client_reference_id is null — re-pay with ?client_reference_id=… appended";
    }
    process.stdout.write(`  captured ${name}${note}\n`);
  }
});
' "$FIXTURES"
