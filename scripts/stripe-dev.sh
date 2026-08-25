#!/usr/bin/env bash
# Local Stripe-sandbox loop against a local `icp network`.
#
# Wires the Stripe CLI's webhook forwarder to a locally deployed backend so the
# real §6.1 path runs end to end: genuine Stripe signatures, genuine event JSON,
# genuine retry behaviour on a non-2xx.
#
# ## Run scripts/local-dev-seed.sh FIRST
#
# The two scripts own different levers and this one assumes the other has run:
#
#   local-dev-seed.sh  the money levers — tiers, treasury, ICP float, the CMC rate,
#                      the canister's own cycles
#   this script        the Stripe levers — expected livemode, the forwarding
#                      session's signing secret, a dev-short order TTL, forwarding
#
# It used to set tiers and the treasury config too, which made the ORDER of the two
# scripts silently decide the outcome: run the seed with your real Payment Links and
# then this, and your links were replaced by a placeholder. The symptom is Stripe
# answering AccessDenied, which reads as a Stripe problem. It no longer touches
# either, and it refuses to start if the gateway cannot price.
#
# `npm --prefix test/integration run sandbox` is the scripted alternative when you do
# not need the frontend in a browser — it boots its own PocketIC and needs none of
# this.
#
# Usage:
#   scripts/stripe-dev.sh              # bootstrap Stripe config, wire the secret, forward
#   scripts/stripe-dev.sh --no-bootstrap   # only wire the secret and forward
#   scripts/stripe-dev.sh --print-only     # print the forward URL and exit
#
# Prerequisites:
#   brew install stripe/stripe-cli/stripe
#   stripe login          # choose a SANDBOX account, never a live one
#   icp network start -d && icp deploy && scripts/local-dev-seed.sh
set -euo pipefail

BOOTSTRAP=1
PRINT_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --no-bootstrap) BOOTSTRAP=0 ;;
    --print-only) PRINT_ONLY=1 ;;
    -h | --help)
      sed -n '2,18p' "$0" | sed 's|^# \{0,1\}||'
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

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH. $2"
}

need jq "Install with: brew install jq"
need icp "Install with: npm i -g @icp-sdk/icp-cli"
if [ "$PRINT_ONLY" -eq 0 ]; then
  need stripe "Install with: brew install stripe/stripe-cli/stripe"
fi

# --- locate the local network and the deployed backend ----------------------
# The local network runs with `gateway.port: 0`, so the port changes on every
# start — always read it rather than hardcoding one.
STATUS_JSON="$(icp network status --json 2>/dev/null)" ||
  die "no local network. Run: icp network start -d"
GATEWAY_URL="$(printf '%s' "$STATUS_JSON" | jq -r '.gateway_url')"
[ "$GATEWAY_URL" != "null" ] || die "could not read gateway_url from icp network status"
# Normalise http://localhost:PORT/ → 127.0.0.1:PORT (the Stripe CLI resolves
# 127.0.0.1 more predictably than 'localhost' on dual-stack hosts).
PORT="$(printf '%s' "$GATEWAY_URL" | sed -E 's#^https?://[^:]+:([0-9]+)/?$#\1#')"
[ -n "$PORT" ] || die "could not parse a port out of '$GATEWAY_URL'"

BACKEND_ID="$(icp canister status backend --json 2>/dev/null | jq -r '.id')" ||
  die "backend not deployed. Run: icp deploy backend"
[ "$BACKEND_ID" != "null" ] && [ -n "$BACKEND_ID" ] ||
  die "backend not deployed. Run: icp deploy backend"

# Http.mo strips the query string before route matching, so the gateway's
# ?canisterId= parameter coexists with the /webhook/stripe path.
FORWARD_URL="http://127.0.0.1:${PORT}/webhook/stripe?canisterId=${BACKEND_ID}"

echo "backend:     $BACKEND_ID"
echo "gateway:     $GATEWAY_URL"
echo "forward to:  $FORWARD_URL"

if [ "$PRINT_ONLY" -eq 1 ]; then
  exit 0
fi

# --- the gateway must already be sellable -----------------------------------
# Assert it rather than re-configuring it. A quote is the honest check: it proves
# tiers exist AND both rate inputs answered AND the canister is above the gate's
# own-cycles floor, which is every money lever this script does not own.
QUOTE="$(icp canister call backend quote_previews '(vec { 500 : nat })' 2>&1 || true)"
if ! printf '%s' "$QUOTE" | grep -q 'cycles = opt'; then
  echo "error: the gateway cannot price a \$5 purchase, so an order cannot be created." >&2
  echo "       Run this first, and note the CMC rate expires after 15 minutes:" >&2
  echo "         scripts/local-dev-seed.sh" >&2
  echo "       Diagnose with:" >&2
  echo "         icp canister call backend pricing_status '()'" >&2
  echo "         icp canister call backend cycles_status '()'" >&2
  exit 1
fi
echo "priceable:   a \$5 purchase quotes (tiers, both rates, and own-cycles are all fine)"

# --- bootstrap the STRIPE-side config ---------------------------------------
# Tiers, treasury, float, the CMC rate and the canister's own cycles belong to
# scripts/local-dev-seed.sh and are deliberately not touched here. Setting tiers
# from both scripts meant whichever ran last decided which Payment Links the app
# would open.
if [ "$BOOTSTRAP" -eq 1 ]; then
  echo
  echo "--- bootstrapping Stripe-side config (dev values, never for mainnet) ---"

  # Short TTL so expiry is reachable in a dev session instead of 48 h. There is
  # no horizon: orders are never deleted.
  icp canister call backend set_retention_config \
    '(record { orderTtlNs = 600_000_000_000 : nat })' \
    >/dev/null
  echo "retention:   TTL 10 min (dev-short; nothing is ever deleted)"

  # Declare the Stripe world. A sandbox forwarder sends livemode=false events, so
  # without this every honoured payment records `stripe.livemodeUnset`. On mainnet
  # this must be `opt true` — see RUNBOOK §1.
  icp canister call backend set_expected_livemode '(opt false)' >/dev/null
  echo "livemode:    expecting TEST events (mainnet must be 'opt true')"
fi

# --- wire the forwarding session's signing secret ---------------------------
# `stripe listen` mints a secret for the forwarding session. It is NOT the
# Dashboard endpoint's secret, and it changes per `stripe login` — so read it
# rather than pasting one.
echo
echo "--- reading the forwarding session's signing secret ---"
WHSEC="$(stripe listen --print-secret 2>/dev/null || true)"
case "$WHSEC" in
  whsec_*) ;;
  *) die "could not read a signing secret from 'stripe listen --print-secret'. Run 'stripe login' first (choose a SANDBOX account)." ;;
esac

icp canister call backend set_webhook_secret "(\"${WHSEC}\")" >/dev/null

# ── the OTHER secret (#33) ───────────────────────────────────────────────────
# The rail is live only when both are provisioned, so a webhook secret alone is
# not enough any more: without an API key `create_order` cannot create a session
# and nobody can pay. Checked rather than set, because the key is yours and it
# does not come from the forwarding session.
KEY_SET="$(icp canister call backend stripe_api_key_status '()' 2>/dev/null | grep -c 'isSet = true' || true)"
if [ "$KEY_SET" = "0" ]; then
  printf '\n\033[33m! no Stripe API key is provisioned, so create_order cannot make a session.\033[0m\n'
  printf '  Create a RESTRICTED key (rk_...) scoped to write Checkout Sessions and nothing else, then:\n'
  printf '    icp canister call backend set_stripe_api_key '"'"'("rk_...")'"'"'\n'
  printf '  Or re-run the seed with it in the environment:\n'
  printf '    STRIPE_API_KEY=rk_... ./scripts/local-dev-seed.sh\n\n'
else
  echo "api key:     provisioned (generation $(icp canister call backend stripe_api_key_status '()' 2>/dev/null | grep -oE 'generation = [0-9_]+' | grep -oE '[0-9_]+' || echo '?'))"
fi
# NOTE: pass an explicit '()' for zero-argument methods. Omitting the argument
# makes `icp canister call` ask "Do you want to send this message? [y/N]" and
# read stdin, which hangs any script or CI job.
GENERATION="$(icp canister call backend webhook_secret_status '()' --query 2>/dev/null |
  tr -d ' _' | sed -nE 's/.*generation=([0-9]+).*/\1/p')"
echo "secret set:  generation ${GENERATION:-?} (the secret itself is never readable back)"

cat <<'NOTES'

--- ready ---
In a second terminal:

  stripe trigger checkout.session.completed
      Builds a SYNTHETIC session with no client_reference_id, so it lands as a
      Type 1 #unattributed entry. That is a real test of the attribution guard,
      not the happy path.

  For the happy path, buy through the UI at the URL `icp deploy` printed for the
  frontend, which is the whole point of running against a local network. The
  browser path and the CLI path below produce the same order.

  Or from the CLI:
      1. icp canister call backend create_order \
             '("t5", variant { cyclesLedgerAccount = record {
                  owner = principal "<your-principal>"; subaccount = null } }, null)'
         The account must be the caller's own, default subaccount — anything else
         is refused with #destinationNotOwned. Get yours with
         `icp identity principal`, and pass the same --identity to the call.
         (the third argument pins a minimum cycle quantity; null opts out)
      2. Take the returned clientReferenceId.
      3. Open YOUR sandbox Payment Link with ?client_reference_id=<ref> appended.
      4. Pay with test card 4242 4242 4242 4242.

  Inspect what happened:
      icp canister call backend audit_log '()'
      icp canister call backend error_queue_unresolved '(null, 50)'
      icp canister call backend order_for_payment '("pi_...")'

Two things to expect locally:

1. Signature timestamps are checked against the replica's OWN clock with a ±300 s
   tolerance. If local time has drifted further than that from real time, every
   live webhook is rejected with a 400.

2. **The CMC rate expires 15 minutes after the seed script set it**, and pricing
   then refuses every new order. It does not affect an order that already exists:
   the rate is locked at creation. Refresh with:
       scripts/local-dev-seed.sh --rate-only

Starting the forwarder (Ctrl-C to stop)...
NOTES

exec stripe listen --forward-to "$FORWARD_URL"
