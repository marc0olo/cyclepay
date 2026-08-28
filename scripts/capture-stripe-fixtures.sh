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
checkout.session.completed.unpaid|arrives free with 'stripe trigger checkout.session.async_payment_succeeded'
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
      # ⚠️ **Print the command that works in THIS shell, not the tidy one.** Our own calls
      # go through `stripe_cli`, but a hint the operator pastes runs in their shell — where
      # an exported STRIPE_API_KEY makes the CLI use the restricted backend key and fail
      # with "more_permissions_required". Protecting the script and printing bare copy is
      # the same split #52 rejected: two of that round's eleven key-scope sites were
      # terminal output, and they counted because that is the copy people follow.
      case "${STRIPE_API_KEY:-}|$how" in
        ?*'|stripe '*) how="env -u STRIPE_API_KEY $how" ;;
      esac
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

# ⚠️ **Run the CLI with STRIPE_API_KEY UNSET, deliberately.**
#
# The Stripe CLI prefers `STRIPE_API_KEY` from the environment over its own `stripe login`
# credential — and the key we tell operators to export is the **restricted** `rk_` one,
# scoped to write Checkout Sessions and nothing else. `stripe listen` opens a CLI session,
# which needs `stripecli_session_write`; a correctly-scoped rk_ key does not have it and
# **must not**. So exporting the key for the backend silently breaks the CLI:
#
#   FATAL Error while authenticating with Stripe: Authorization failed, status=403
#   "code": "more_permissions_required" … key 'rk_test_…' does not have the required
#   permissions … Enabling Debugging Tools Write ('stripecli_session_write') …
#
# The wrong fix is widening that key. The right one is this: the CLI uses its keychain
# login, the canister uses the restricted key, and neither borrows the other's credential.
stripe_cli() { env -u STRIPE_API_KEY stripe "$@"; }

if [ -n "${STRIPE_API_KEY:-}" ]; then
  printf '\033[33m!\033[0m STRIPE_API_KEY is set in this shell; ignoring it for the Stripe CLI.\n'
  printf '  It is the restricted backend key and cannot open a CLI session — see the note in this script.\n\n'
fi

# ⚠️ **Preflight the SESSION, not a read.** The first version of this check ran
# `stripe events list`, which a restricted key is allowed to do — so it passed, printed
# nothing, and the failure still happened later inside the pipe. Checking a *proxy* for a
# credential rather than the capability actually needed is how a preflight gives false
# confidence. `--print-secret` opens the same CLI session `listen` does, so it fails for
# the same reason and says so here, where the message is visible.
if ! STRIPE_PREFLIGHT="$(stripe_cli listen --print-secret 2>&1)"; then
  printf '\n\033[31m✗ the Stripe CLI cannot open a session.\033[0m\n\n%s\n\n' "$STRIPE_PREFLIGHT" >&2
  die "run 'stripe login' (choose a SANDBOX account) and try again"
fi

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

⚠️ `checkout.session.completed.unpaid` needs no special effort: triggering
`checkout.session.async_payment_succeeded` emits the WHOLE delayed sequence, which
begins with a real `completed` carrying `payment_status: unpaid`. An earlier version
of this script sent you to create a SEPA session by hand and pay it with a test
IBAN — unnecessary, and nobody found out until someone ran the triggers and got the
fixture anyway.

⚠️ A `payment_intent: null` fixture was on this list and was REMOVED, deliberately.
Since #33 this app pins `payment_method_types[]=card` at a fixed unit_amount above
the $10 floor with no promo codes, so `payment_intent` is never absent — and an
explicit `payment_method_types` overrides whatever the account has enabled, so the
old justification here ("a delayed method could be enabled at account level") was
simply wrong. The handler stays and is covered by a crafted body in
`test/webhook.test.mo`, which is honest: #4 exists because crafted JSON encodes our
assumptions about what Stripe *sends us*, and for a payload it will never send there
is nothing to be wrong about. If a non-card method is ever enabled — a product
decision, not a config accident — capture becomes necessary again, because then the
real shape is load-bearing.

Ctrl-C when the list is complete.

NOTES

# `--print-json` emits one JSON object per line. Sort by type, and by the field that
# distinguishes the variants we care about — paid vs unpaid, full vs partial refund,
# and the missing-payment_intent case a zero-amount or subscription session produces.
# ⚠️ **`--format json`, not the deprecated `--print-json`.** The CLI now warns on the old
# flag ("Please use `--format json` instead"), and a deprecated flag eventually stops being
# accepted — at which point this script would fail in the way described just below.
#
# ⚠️ **stderr is NOT redirected, and that is a fix rather than an oversight.** This line
# used to end `2>/dev/null`, which hid Stripe's "Ready! … signing secret" banner *and*
# every reason it might refuse: an expired session, a revoked key, an account problem. The
# pipeline then ended, the script exited **0**, and the operator got their prompt back with
# no output and no error — indistinguishable from "nothing happened". That is exactly the
# quiet-inertness this repo keeps removing from the canister, in our own tooling. The
# banner on stderr is noise worth paying for.
stripe_cli listen --format json "${FORWARD_ARGS[@]}" | node -e '
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
    //
    // ⚠️ **This set is a deliberate SUPERSET of `wanted()` and the difference is not
    // drift.** `wanted()` drives the checklist and the missing-report, and no longer asks
    // for `completed.no-intent` — unreachable since #33 pinned card. This set still
    // accepts it, because if such a body ever does arrive it is worth having on disk
    // rather than discarded. Asking for it and accepting it are different questions:
    // do not "fix" one list to match the other.
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
