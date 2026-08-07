#!/usr/bin/env bash
# Make a local network's gateway actually usable: rate, tiers, treasury, float.
#
# A freshly deployed gateway is **fail-closed by design** — no tiers, no burn cap,
# no float, and (locally) no exchange rate. That is correct for production and
# indistinguishable from "broken" when you are trying to click through the app,
# where it shows as "No amounts are configured yet" and "No exchange rate
# available yet".
#
# ## The part that is not obvious: the CMC rate
#
# Pricing needs BOTH rates. The XRC comes from the local mock (icp.yaml), but the
# CMC's conversion rate is only settable by NNS **governance**, and no local
# identity is governance. Docs in this repo previously called that a hard local
# blocker.
#
# It is not: a local `icp network` IS a PocketIC instance, and PocketIC's control
# API — on a second port of the same process — can submit an ingress message from
# an arbitrary sender. That is what this script does.
#
# ⚠️ That control port is **not a supported `icp` interface.** It is unpublished
# and may move or disappear between icp-cli releases. This script discovers it
# from the running process rather than assuming, and fails with an explanation
# rather than a stack trace. Nothing in CI or the test gate depends on it; the
# PocketIC suite drives its own instance through the supported pic-js API.
#
# ## The rate goes stale after 15 minutes
#
# `Cmc.cmcRateMaxAgeNs` is a security control, not a tuning knob. Re-run this
# script (or just `--rate-only`) whenever the app starts refusing orders again.
#
# Usage:
#   scripts/local-dev-seed.sh              # everything
#   scripts/local-dev-seed.sh --rate-only  # just refresh the CMC rate
set -euo pipefail

cd "$(dirname "$0")/.."

RATE_ONLY=0
[ "${1:-}" = "--rate-only" ] && RATE_ONLY=1
if [ -n "${1:-}" ] && [ "$1" != "--rate-only" ]; then
  echo "usage: $0 [--rate-only]" >&2
  exit 2
fi

XDR_PERMYRIAD=35000        # 3.5 XDR/ICP, matching the PocketIC suite's vector
FLOAT_ICP=100              # plenty for local clicking; the gateway holds it as float

ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
die() {
  printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2
  exit 1
}

icp network status >/dev/null 2>&1 || die "no local network. Run: icp network start -d && icp deploy"

# ── the PocketIC control port ────────────────────────────────────────────────
step "PocketIC control API"
# Same process as the gateway, second listening port. Discovered, never assumed.
PIC_PID="$(pgrep -f 'pocket-ic' | head -1 || true)"
[ -n "$PIC_PID" ] || die "no pocket-ic process found. Is this network managed by icp-cli?"
GATEWAY_PORT="$(icp network status --json | jq -r '.gateway_url' | sed -E 's#.*:([0-9]+)/?$#\1#')"
CONTROL_PORT="$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$PIC_PID" 2>/dev/null |
  awk '{print $9}' | grep -oE '[0-9]+$' | grep -v "^${GATEWAY_PORT}$" | head -1 || true)"
[ -n "$CONTROL_PORT" ] || die "could not find the PocketIC control port beside the gateway on :$GATEWAY_PORT.
    This port is unpublished and may have changed in a newer icp-cli. Everything
    below except the CMC rate can still be done by hand — see RUNBOOK §§3-5."
ok "control API on 127.0.0.1:$CONTROL_PORT (gateway on :$GATEWAY_PORT)"

# ── the XRC mock ─────────────────────────────────────────────────────────────
step "XRC mock"
# It keeps its canned response in HEAP and sets it from `init_args` at INSTALL
# time, so any routine `icp deploy` upgrades it and the response is gone. Every
# later rate fetch then fails with "Response has not been set", which surfaces as
# "No exchange rate available" — indistinguishable from the CMC problem below and
# the reason this script exists at all. Reinstalling is free: it holds nothing.
icp deploy --mode reinstall --yes xrc >/dev/null 2>&1 ||
  die "could not reinstall the xrc mock. Is it in icp.yaml and fetched? Try:
    npm --prefix test/integration run fetch:wasm"
ok "xrc mock reinstalled (its response does not survive an upgrade)"

# ── the CMC rate ─────────────────────────────────────────────────────────────
step "CMC conversion rate (as governance)"
# node needs @icp-sdk/core on its resolution path, which lives in test/integration.
( cd test/integration && node --input-type=module -e "
import { IDL } from '@icp-sdk/core/candid';
import { Principal } from '@icp-sdk/core/principal';
const CONTROL = 'http://127.0.0.1:${CONTROL_PORT}';
const Payload = IDL.Record({
  data_source: IDL.Text, timestamp_seconds: IDL.Nat64, xdr_permyriad_per_icp: IDL.Nat64,
  reason: IDL.Opt(IDL.Variant({ OldRate: IDL.Null, DivergedRate: IDL.Null, EnableAutomaticExchangeRateUpdates: IDL.Null })),
});
const b64 = (u8) => Buffer.from(u8).toString('base64');
const body = {
  sender: b64(Principal.fromText('rrkah-fqaaa-aaaaa-aaaaq-cai').toUint8Array()),
  canister_id: b64(Principal.fromText('rkp4c-7iaaa-aaaaa-aaaca-cai').toUint8Array()),
  method: 'set_icp_xdr_conversion_rate',
  payload: b64(new Uint8Array(IDL.encode([Payload], [{
    data_source: 'local-dev-seed',
    timestamp_seconds: BigInt(Math.floor(Date.now() / 1000)),
    xdr_permyriad_per_icp: ${XDR_PERMYRIAD}n,
    reason: [],
  }]))),
  effective_principal: 'None',
};
// PocketIC answers 409 with the operation currently in flight: this is a LIVE
// network with its own auto-tick loop, so a request from outside routinely
// races it. pic-js retries internally; a hand-rolled client has to as well, or
// it works once and then fails for a reason that looks like a bad endpoint.
const post = async (p, payload) => {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const r = await fetch(CONTROL + '/instances/0' + p, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload),
    });
    const text = await r.text();
    if (r.status !== 409) return { status: r.status, body: text };
    await new Promise((res) => setTimeout(res, 150));
  }
  return { status: 409, body: 'still busy after 40 attempts' };
};
const s = await post('/update/submit_ingress_message', body);
if (s.status !== 200) { console.error('submit failed', s.status, s.body.slice(0,300)); process.exit(1); }
const a = await post('/update/await_ingress_message', JSON.parse(s.body).Ok);
if (a.status !== 200) { console.error('await failed', a.status, a.body.slice(0,300)); process.exit(1); }
// DECODE the CMC's reply. HTTP 200 only means PocketIC delivered the message;
// the CMC can still answer Err, and treating 200 as success reported a rate that
// was never set and left the gateway unable to price.

" ) || die "could not set the CMC rate through the PocketIC control API on :$CONTROL_PORT"
# HTTP 200 only means PocketIC delivered the message; the CMC can still refuse it.
# Ask the CMC what it now holds instead of decoding the reply — this checks the
# thing we actually depend on, and it caught a fresh network where the rate never
# landed and the CMC was still serving its hardcoded 2021 default.
STORED="$(icp canister call rkp4c-7iaaa-aaaaa-aaaca-cai get_icp_xdr_conversion_rate '()' 2>/dev/null |
  grep -oE 'xdr_permyriad_per_icp = [0-9_]+' | tr -d '_' | grep -oE '[0-9]+$' || echo 0)"
STAMP="$(icp canister call rkp4c-7iaaa-aaaaa-aaaca-cai get_icp_xdr_conversion_rate '()' 2>/dev/null |
  grep -oE 'timestamp_seconds = [0-9_]+' | tr -d '_' | grep -oE '[0-9]+$' || echo 0)"
if [ "$STORED" != "$XDR_PERMYRIAD" ]; then
  die "the CMC did not take the rate: it still reports $STORED permyriad, stamped $STAMP
    (its hardcoded default is 35200 stamped 1620633601, i.e. 10 May 2021).
    The submit reached PocketIC, so this is the CMC refusing the proposal rather
    than a transport problem."
fi
ok "CMC rate set to ${XDR_PERMYRIAD} permyriad XDR/ICP (stamped $STAMP)"

icp canister call backend refresh_rates '()' >/dev/null 2>&1 || true

# Assert a real QUOTE, not the presence of a cached pair. `rates = opt` survives a
# failed refresh and a pair too old to use, so grepping for it reported success on
# a gateway that refused every purchase — the same mistake the rate line in the UI
# was making.
QUOTE="$(icp canister call backend quote_previews '(variant { card }, vec { 500 : nat })' 2>&1)"
if ! printf '%s' "$QUOTE" | grep -q 'cycles = opt'; then
  printf '\n\033[31m✗ the gateway still cannot price a $5 purchase.\033[0m\n' >&2
  icp canister call backend pricing_status '()' 2>&1 | grep -E 'ok = |detail = ' >&2
  exit 1
fi
ok "a \$5 purchase quotes (both XRC and CMC answered)"

if [ "$RATE_ONLY" -eq 1 ]; then
  printf '\n\033[32m✓ rate refreshed\033[0m — it goes stale again in 15 minutes.\n'
  exit 0
fi

# ── tiers ────────────────────────────────────────────────────────────────────
step "card tiers"
# The tier list IS the card rail's on/off switch (RUNBOOK §3), so an empty list is
# the fail-closed default rather than a missing step.
#
# Payment links come from the environment when you have real ones. The fallback is
# a URL that does not exist, and "Pay with card" then lands on Stripe's bucket
# returning `AccessDenied` — which looks like a broken integration and is really
# just an unconfigured link. Set these to your sandbox links to click all the way
# through:
#
#   export STRIPE_LINK_T5=https://buy.stripe.com/test_xxx
#   export STRIPE_LINK_T20=…  STRIPE_LINK_T50=…
PLACEHOLDER="https://buy.stripe.com/PLACEHOLDER-set-STRIPE_LINK_T5"
LINK_T5="${STRIPE_LINK_T5:-$PLACEHOLDER}"
LINK_T20="${STRIPE_LINK_T20:-$PLACEHOLDER}"
LINK_T50="${STRIPE_LINK_T50:-$PLACEHOLDER}"
icp canister call backend set_card_tiers \
  "(vec { record { id = \"t5\"; usdCents = 500 : nat; paymentLinkUrl = \"$LINK_T5\" };
          record { id = \"t20\"; usdCents = 2_000 : nat; paymentLinkUrl = \"$LINK_T20\" };
          record { id = \"t50\"; usdCents = 5_000 : nat; paymentLinkUrl = \"$LINK_T50\" } })" \
  >/dev/null || die "set_card_tiers failed"
if [ "$LINK_T5" = "$PLACEHOLDER" ]; then
  printf '  \033[33m·\033[0m 3 tiers ($5 / $20 / $50) with PLACEHOLDER payment links.\n'
  printf '    "Pay with card" will land on a Stripe AccessDenied page until you set\n'
  printf '    STRIPE_LINK_T5 / _T20 / _T50 and re-run. Everything up to that point works.\n'
else
  ok "3 tiers (\$5 / \$20 / \$50) with your Stripe links"
fi

# ── treasury ─────────────────────────────────────────────────────────────────
step "treasury"
# burnCapE8s defaults to 0, which holds every mint. That is the §5.3 pause lever
# and the right production default; locally it just looks like nothing works.
icp canister call backend set_treasury_config \
  '(record { burnCapE8s = 10_000_000_000 : nat;
             burnWindowNs = 86_400_000_000_000 : int;
             lowFloatThresholdE8s = 0 : nat;
             maxHoldNs = 259_200_000_000_000 : int;
             alertAfterNs = 7_200_000_000_000 : int })' \
  >/dev/null || die "set_treasury_config failed"
ok "burn cap 100 ICP / 24 h, 2 h alert, 72 h max hold"

BACKEND_ID="$(icp canister status backend --json | jq -r '.id')"
icp token transfer "$FLOAT_ICP" "$BACKEND_ID" >/dev/null 2>&1 ||
  die "could not fund the float. Check: icp token balance"
icp canister call backend refresh_float '()' >/dev/null 2>&1 || true
ok "float funded with $FLOAT_ICP ICP"

# ── the admission gate ───────────────────────────────────────────────────────
step "admission gate"
# The one that is genuinely confusing: `minCanisterCycles` defaults to 5 T, and
# `icp deploy` creates a canister with 2 T. So a freshly deployed local gateway
# refuses EVERY purchase with "temporarily unavailable while the gateway is
# topped up" — which reads as a treasury problem and is actually about the
# canister's own gas.
#
# On mainnet the fix is to top the canister up. Locally there is no supported CLI
# path to deposit into a canister's gas balance (`icp cycles transfer` credits the
# cycles LEDGER, which is a different thing), so lower the floor instead. It is an
# operator lever that exists for exactly this, and locally the risk it guards
# against — running out of gas mid-mint — is not real.
BALANCE="$(icp canister call backend cycles_status '()' 2>/dev/null |
  grep -oE 'balance = [0-9_]+' | tr -d '_' | grep -oE '[0-9]+' || echo 0)"
icp canister call backend set_gate_config \
  '(record { maxOpenOrdersPerPrincipal = 3 : nat;
             maxPurchaseUsdCents = 100_000 : nat;
             minCanisterCycles = 500_000_000_000 : nat })' \
  >/dev/null || die "set_gate_config failed"
ok "cycles floor lowered to 0.5 T (canister holds ${BALANCE:-?})"

icp canister call backend can_purchase '(500 : nat)' 2>&1 | grep -q 'variant { ok }' ||
  die "the gateway still refuses a \$5 purchase. Check: icp canister call backend can_purchase '(500 : nat)'"
ok "a \$5 purchase is admitted"

printf '\n\033[32m✓ local gateway seeded\033[0m\n'
cat <<NOTES

  Open http://frontend.local.localhost:${GATEWAY_PORT}/

  What works now, and what needs Stripe:
    - Browsing amounts, signing in, creating an order, cancelling: all work.
    - PAYING needs two things Stripe owns: a real Payment Link (set
      STRIPE_LINK_T5 / _T20 / _T50 above) and a signed webhook to deliver.
      Run scripts/capture-stripe-fixtures.sh to forward real sandbox events
      here, or drive the webhook by hand per docs/SANDBOX-TESTPLAN.md.

  ⚠️ The CMC rate goes stale in 15 minutes. Re-run with --rate-only.
NOTES
