#!/usr/bin/env bash
# Make a local network's gateway actually usable: rate, tiers, delivery timeline,
# and a funded cycles reserve.
#
# A freshly deployed gateway is **fail-closed by design** — no tiers, an empty
# cycles reserve, and (locally) no exchange rate. That is correct for production and
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
GATEWAY_PORT="$(icp network status --json | jq -r '.gateway_url' | sed -E 's#.*:([0-9]+)/?$#\1#')"
[ -n "$GATEWAY_PORT" ] || die "could not read a gateway port from icp network status"
# The process SERVING THIS GATEWAY, not just any pocket-ic. `pgrep -f pocket-ic |
# head -1` picked whichever instance started first, so with a second local network
# running anywhere on the machine — another project, or a stale one — the CMC
# message went to the wrong instance and this script failed with "the CMC did not
# take the rate" while the rate had in fact been set on someone else's network.
PIC_PID="$(lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
[ -n "$PIC_PID" ] || die "nothing is listening on the gateway port :$GATEWAY_PORT. Run: icp network start -d"
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
# $10, the smallest amount the gate now admits — quoting below the floor would
# "work" here (quote_previews is a pure quote and does not gate) and then be
# refused at create_order, which is a confusing thing for a seed to report as OK.
QUOTE="$(icp canister call backend quote_previews '(vec { 1_000 : nat })' 2>&1)"
if ! printf '%s' "$QUOTE" | grep -q 'cycles = opt'; then
  printf '\n\033[31m✗ the gateway still cannot price a $10 purchase.\033[0m\n' >&2
  icp canister call backend pricing_status '()' 2>&1 | grep -E 'ok = |detail = ' >&2
  exit 1
fi
ok "a \$10 purchase quotes (both XRC and CMC answered)"

if [ "$RATE_ONLY" -eq 1 ]; then
  printf '\n\033[32m✓ rate refreshed\033[0m — it goes stale again in 15 minutes.\n'
  exit 0
fi

# ── local dev config ─────────────────────────────────────────────────────────
# `scripts/.local-dev.env` is gitignored, so a value set there is set once instead
# of exported into every new shell — and it stays out of shell history, `ps` and
# any terminal transcript, which matters for `STRIPE_API_KEY`.
LINKS_FILE="scripts/.local-dev.env"
if [ -f "$LINKS_FILE" ]; then
  BEFORE_KEY="${STRIPE_API_KEY:-}"
  # shellcheck disable=SC1090
  . "$LINKS_FILE"
  # The environment wins over the file, so a one-off export still overrides it.
  [ -z "$BEFORE_KEY" ] || STRIPE_API_KEY="$BEFORE_KEY"
  ok "read local dev config from $LINKS_FILE"
fi

# ── presets ──────────────────────────────────────────────────────────────────
step "card presets"
# ⚠️ An empty list is NO LONGER a pause lever (#33): a custom amount is orderable
# without any preset, so an empty list just shows no tiles. The rail's switch is
# both Stripe secrets being provisioned.
#
# The `STRIPE_LINK_*` resolver that used to live here is gone: #33 removed
# `Tier.paymentLinkUrl`, so there was nothing left for it to populate.
#
# The presets are $10 / $20 / $50. The old $5 tier is gone because the gate's
# floor is $10, and registering it would be refused as `belowFloor`.
icp canister call backend set_card_tiers \
  '(vec { record { id = "t10"; usdCents = 1_000 : nat };
          record { id = "t20"; usdCents = 2_000 : nat };
          record { id = "t50"; usdCents = 5_000 : nat } })' \
  >/dev/null || die "set_card_tiers failed"
ok "3 presets (\$10 / \$20 / \$50); any amount from \$10 to \$100 is orderable"

# ── delivery timeline ────────────────────────────────────────────────────────
step "delivery timeline"
# The gateway ships with a 2 h alert and a 72 h terminate bound, which is what you
# want locally too — an order that cannot deliver should end up on the worklist
# rather than retrying in silence. Set explicitly so the seed states the numbers a
# reader will see in `error_queue_unresolved`.
icp canister call backend set_delivery_config \
  '(record { maxHoldNs = 259_200_000_000_000 : int;
             alertAfterNs = 7_200_000_000_000 : int })' \
  >/dev/null || die "set_delivery_config failed"
ok "2 h alert, 72 h max hold"


# ── the admission gate ───────────────────────────────────────────────────────
# ── Stripe API key + return origin (#33) ─────────────────────────────────────
step "Stripe session config"
# ⚠️ **`STRIPE_API_KEY` belongs in `scripts/.local-dev.env`, not on a command
# line.** That file is gitignored and is sourced above, so the key never appears
# in your shell history, in `ps` output, or in a terminal transcript. An
# `export`-then-run also works and wins over the file, but it leaves the value
# where something can read it back.
#
#   echo 'STRIPE_API_KEY=rk_test_...' >> scripts/.local-dev.env
# The rail is live only when BOTH the API key and the webhook secret are
# provisioned. This step does the KEY and the ORIGIN; `scripts/stripe-dev.sh`
# does the webhook secret, because that one belongs to a `stripe listen` session
# rather than to the deployment.
#
# ⚠️ A reinstall wipes both secrets and this script only restores the key, so
# after `--mode reinstall` you still need `scripts/stripe-dev.sh` before paying.
if [ -n "${STRIPE_API_KEY:-}" ]; then
  icp canister call backend set_stripe_api_key "(\"${STRIPE_API_KEY}\")" >/dev/null \
    || die "set_stripe_api_key was refused (too short?)"
  ok "Stripe API key provisioned from STRIPE_API_KEY"
else
  # A placeholder, deliberately: it lets every non-paying path work — browsing,
  # signing in, quoting — while `create_order` fails at the outcall with a real
  # Stripe 401 rather than at a config check. That is a better local default than
  # refusing to create orders at all, and the failure names itself.
  icp canister call backend set_stripe_api_key '("rk_test_PLACEHOLDER_set_STRIPE_API_KEY_to_create_sessions")' >/dev/null \
    || die "set_stripe_api_key was refused"
  printf '  \033[33m!\033[0m placeholder API key set — export STRIPE_API_KEY=rk_... to create real sessions\n'
fi

# The origin Stripe returns the buyer to. The frontend canister's own URL, since
# no domain is chosen yet (#40/#23). Must be https, so a local run uses the
# canister's icp0.io origin rather than the localhost gateway.
# `icp canister id` does not exist; the deploy records the mapping here.
# `canister status` would also print it, but it needs a running network and a
# reachable canister, where this is just a read.
FRONTEND_ID="$(sed -n 's/.*"frontend": *"\([^"]*\)".*/\1/p' .icp/cache/mappings/local.ids.json 2>/dev/null || true)"
if [ -n "$FRONTEND_ID" ]; then
  ORIGIN="https://${FRONTEND_ID}.icp0.io"
  icp canister call backend set_stripe_origin "(\"${ORIGIN}\")" >/dev/null \
    || die "set_stripe_origin refused ${ORIGIN} — it must be https with no query or fragment"
  ok "return origin set to ${ORIGIN}"
else
  printf '  \033[33m!\033[0m could not read the frontend canister id; set_stripe_origin skipped\n'
fi

step "admission gate"
# The one that is genuinely confusing: `minCanisterCycles` defaults to 5 T, and
# `icp deploy` creates the canister with less. So a freshly deployed local gateway
# refuses EVERY purchase with "temporarily unavailable while the gateway is
# topped up" — which reads as a problem with what it sells and is actually about
# the canister's own gas.
#
# Fix the CONDITION, not the gate: top the canister up, which is exactly what you
# would do on mainnet. `icp canister top-up` (icp-cli 1.2.0) does this; it is not
# `icp cycles transfer`, which credits the cycles LEDGER and is a different thing.
#
# This used to lower `minCanisterCycles` to 0.5 T instead. That works, and it is
# the wrong lever twice over: it moves a safety floor to accommodate an
# under-funded canister, and it means local development never exercises a gate
# that is load-bearing on mainnet.
CYCLES_TOP_UP=20t
icp canister top-up backend --amount "$CYCLES_TOP_UP" >/dev/null 2>&1 ||
  die "could not top up the backend canister with $CYCLES_TOP_UP cycles.
    Needs icp-cli 1.2.0 or newer (\`icp canister top-up --help\`)."

step "cycles reserve"
# Delivery is a TRANSFER out of the gateway's own cycles-ledger account. So the
# gateway needs cycles in that account, and it is a different pot from the gas balance
# topped up above — the comment there spells out the distinction, and this is the
# other half of it.
#
# `icp cycles transfer` is the mainnet procedure too: nothing creates cycles here, and
# there is deliberately no `mint_reserve` — it would mean holding ICP and an
# ICP-ledger dependency for one operator convenience.
#
# ⚠️ **Read the id here, where it is used.** It used to be set in the treasury block
# above; deleting that block left this line reading an unbound variable, which `set -u`
# turned into a hard stop three quarters of the way through the seed. Nothing catches
# that but running it.
BACKEND_ID="$(icp canister status backend --json | jq -r '.id')"
[ -n "$BACKEND_ID" ] && [ "$BACKEND_ID" != "null" ] ||
  die "could not read the backend canister id — is the network up and the canister deployed?"
RESERVE_TOP_UP=100t
if icp cycles transfer "$RESERVE_TOP_UP" "$BACKEND_ID" >/dev/null 2>&1; then
  # ⚠️ **A funded reserve is not a SELLABLE reserve until the gateway looks.** #30
  # PR-B decides solvency against a maintained lower bound on this account, and that
  # bound only ever rises by observation: it starts at zero on a fresh install, and a
  # transfer into the account is invisible to it. Without this call the seed produces
  # a gateway that refuses every purchase with `#reserveShort{available = 0}` while
  # the ledger holds 100 T — and nothing fails, compiles differently, or says why.
  #
  # The hourly sweep would eventually pick it up. "Eventually" is the wrong answer
  # for a script whose whole job is to hand over a working gateway.
  if ! icp canister call backend refresh_reserve '()' >/dev/null 2>&1; then
    printf '  \033[33m!\033[0m funded the reserve but refresh_reserve failed.\n'
    printf '    The gateway will refuse every sale until it observes the balance:\n'
    printf '      icp canister call backend refresh_reserve %s\n' "'()'"
  fi
  echo "reserve:     $RESERVE_TOP_UP cycles in the gateway's own ledger account, observed"
else
  printf '  \033[33m!\033[0m could not fund the cycles reserve with %s.\n' "$RESERVE_TOP_UP"
  printf '    Orders will be created and PAID and then retry delivery forever.\n'
  printf '    Fund it by hand, then let the gateway observe it:\n'
  printf '      icp cycles transfer %s %s\n' "$RESERVE_TOP_UP" "$BACKEND_ID"
  printf '      icp canister call backend refresh_reserve %s\n' "'()'"
fi

step "admission gate"
# The #33 bounds: a $10 floor and a $100 ceiling. One pair governs presets AND
# custom amounts — do not add a custom-amount-specific limit.
icp canister call backend set_gate_config \
  '(record { maxOpenOrdersPerPrincipal = 3 : nat;
             maxPurchaseUsdCents = 10_000 : nat;
             minPurchaseUsdCents = 1_000 : nat;
             minCanisterCycles = 5_000_000_000_000 : nat })' \
  >/dev/null || die "set_gate_config failed"

# Re-read the balance and compare it to the floor the gate now holds, rather than
# trusting the top-up's exit code.
CYCLES="$(icp canister call backend cycles_status '()' 2>/dev/null)"
BALANCE="$(printf '%s' "$CYCLES" | grep -oE 'balance = [0-9_]+' | tr -d '_' | grep -oE '[0-9]+$' || echo 0)"
FLOOR="$(printf '%s' "$CYCLES" | grep -oE 'floor = [0-9_]+' | tr -d '_' | grep -oE '[0-9]+$' || echo 0)"
if [ "${BALANCE:-0}" -le "${FLOOR:-0}" ]; then
  die "the canister still holds ${BALANCE:-0} cycles against a ${FLOOR:-0} floor, so
    every purchase is still refused. The top-up reported success, so check:
      icp canister call backend cycles_status '()'"
fi
ok "cycles floor kept at $((FLOOR / 1000000000000)) T; canister holds $((BALANCE / 1000000000000)) T"

icp canister call backend can_purchase '(1_000 : nat)' 2>&1 | grep -q 'variant { ok }' ||
  die "the gateway still refuses a \$10 purchase. Check: icp canister call backend can_purchase '(1_000 : nat)'"
ok "a \$10 purchase is admitted"

# ⚠️ `can_purchase` above does NOT cover solvency, and cannot: it is a query, and
# reading the reserve is what the gate does synchronously inside `create_order`. So
# the reserve is verified separately, against the same figure the gate decides on —
# otherwise a missing `refresh_reserve` sails past every check in this script and
# surfaces as a refusal on the first real order.
RESERVE="$(icp canister call backend reserve_status '()' 2>/dev/null)"
AVAILABLE="$(printf '%s' "$RESERVE" | grep -oE 'availableToSell = [0-9_]+' | tr -d '_' | grep -oE '[0-9]+$' || echo 0)"
if [ "${AVAILABLE:-0}" -eq 0 ]; then
  die "the gateway will sell 0 cycles even though the reserve was funded — its floor
    has not observed the balance. Fix:
      icp canister call backend refresh_reserve '()'
      icp canister call backend reserve_status '()'"
fi
ok "reserve floor observed; $((AVAILABLE / 1000000000000)) T available to sell"

printf '\n\033[32m✓ local gateway seeded\033[0m\n'
cat <<NOTES

  Open http://frontend.local.localhost:${GATEWAY_PORT}/

  What works now, and what needs Stripe:
    - Browsing amounts, signing in, creating an order, cancelling: all work.
    - PAYING needs BOTH Stripe secrets. There are no Payment Links any more:
      the canister creates a Checkout Session per order and sets
      client_reference_id on it through the API, so nothing has to be
      configured in the Dashboard.

        1. A restricted API key (rk_...) scoped to write Checkout Sessions and
           nothing else. Put it in scripts/.local-dev.env (gitignored, sourced
           by this script) rather than on a command line, then re-run.
        2. A signed webhook to deliver: scripts/stripe-dev.sh starts the
           forwarder and provisions the signing secret from that session.

      Check both with stripe_api_key_status and webhook_secret_status.

  Two things in a paying run that look like bugs and are not:
    - After paying, Stripe redirects to the configured origin
      (https://<frontend-id>.icp0.io), which does NOT serve your local
      frontend, so that tab shows an error. The payment completes and the
      webhook still fires — watch the order in the tab you already had open.
      There is no local https origin to point at, and a caller-supplied
      success_url is deliberately impossible: it would be an open redirect
      Stripe renders after a real payment.
    - The session expires 35 minutes after creation, enforced by Stripe. The
      pay button disappears at the deadline, and it goes before the
      checkout.session.expired webhook lands, because the UI renders expiry
      from expiresAtNs rather than from the status.

  ⚠️ The CMC rate goes stale in 15 minutes. Re-run with --rate-only.
NOTES
