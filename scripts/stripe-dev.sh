#!/usr/bin/env bash
# Local Stripe-sandbox development loop for the Card rail.
#
# Wires the Stripe CLI's webhook forwarder to a locally deployed backend so the
# real §6.1 path runs end to end: genuine Stripe signatures, genuine event JSON,
# genuine retry behaviour on a non-2xx.
#
# Usage:
#   scripts/stripe-dev.sh              # bootstrap config, wire the secret, forward
#   scripts/stripe-dev.sh --no-bootstrap   # only wire the secret and forward
#   scripts/stripe-dev.sh --print-only     # print the forward URL and exit
#
# Prerequisites:
#   brew install stripe/stripe-cli/stripe
#   stripe login          # choose a SANDBOX account, never a live one
#   icp network start -d && icp deploy backend
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

# --- bootstrap the fail-closed money levers ---------------------------------
# Everything ships dark: no tiers, burn cap 0, no secret. The admission gate
# refuses every order until the cap is sized, so a fresh local deploy cannot
# create an order at all without this step.
if [ "$BOOTSTRAP" -eq 1 ]; then
  echo
  echo "--- bootstrapping local config (dev values, never for mainnet) ---"

  # A single $5 tier. The Payment Link URL is a placeholder: `stripe trigger`
  # does not use it, and for a real sandbox checkout you paste your own link.
  icp canister call backend set_card_tiers \
    '(vec { record { id = "tier5"; usdCents = 500 : nat; paymentLinkUrl = "https://buy.stripe.com/test_PLACEHOLDER" } })' \
    >/dev/null
  echo "tiers:       tier5 (\$5.00)"

  # 100 ICP per 24 h, float gating off — enough for the gate to admit locally.
  # alertAfterNs must be shorter than maxHoldNs (validation enforces it); 2 min
  # here so the delay alert is reachable inside a dev session.
  icp canister call backend set_treasury_config \
    '(record { burnCapE8s = 10_000_000_000 : nat; burnWindowNs = 86_400_000_000_000 : int; alertAfterNs = 120_000_000_000 : int; maxHoldNs = 259_200_000_000_000 : int; lowFloatThresholdE8s = 0 : nat })' \
    >/dev/null
  echo "burn cap:    100 ICP / 24 h (alert 2 min, float gating off)"

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

  For the happy path, create an order and pay its link:
      1. icp canister call backend create_order \
             '("tier5", variant { canister = principal "<some-canister>" }, null)'
         (the third argument pins a minimum cycle quantity; null opts out)
      2. Take the returned clientReferenceId.
      3. Open YOUR sandbox Payment Link with ?client_reference_id=<ref> appended.
      4. Pay with test card 4242 4242 4242 4242.

  Inspect what happened:
      icp canister call backend audit_log
      icp canister call backend error_queue
      icp canister call backend order_for_payment '("pi_...")'

Two things to expect locally:

1. Signature timestamps are checked against the replica's OWN clock with a ±300 s
   tolerance. If local time has drifted further than that from real time, every
   live webhook is rejected with a 400.

2. **create_order will fail here with `rateUnavailable`.** The local network seeds
   the ICP ledger, the CMC and the cycles ledger, but NOT the Exchange Rate
   Canister — `refresh_rates` reports `xrc call rejected: Canister uf6dk-… not
   found`. No price means no order, by design.

   So this loop exercises everything that needs no order: real Stripe signatures,
   real event JSON, unattributed payments, unhandled/unprocessable events, and
   refunds of those entries. For attribution success, amount honouring, dedup and
   the mint/deliver half, use either the PocketIC suite
   (`cd test/integration && npm test`, which installs a pinned XRC mock) or a
   mainnet canister in Stripe test mode — see docs/SANDBOX-TESTPLAN.md.

Starting the forwarder (Ctrl-C to stop)...
NOTES

exec stripe listen --forward-to "$FORWARD_URL"
