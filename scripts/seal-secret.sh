#!/usr/bin/env bash
# Provision a Stripe secret into the backend, sealed with vetKD (#11).
#
# Usage:
#   scripts/seal-secret.sh api-key         [environment]   # reads STRIPE_API_KEY
#   scripts/seal-secret.sh webhook-secret  [environment]   # reads STRIPE_WEBHOOK_SECRET
#
# `environment` is an icp-cli environment name and defaults to `local`. Pass `ic` for
# mainnet.
#
# ⚠️ **THE MASTER KEY IS DERIVED FROM THE ENVIRONMENT, NEVER TYPED.**
#
# Mainnet and a local network both have a vetKD key called `key_1`, backed by different
# master keys — necessarily, since a local network cannot hold mainnet's master secret. So
# the key *name* does not identify the key, and sealing against the wrong one produces a
# ciphertext **nobody can ever open**, with nothing to notice until the canister tries.
#
# That is why this mapping lives in code rather than in a flag a human passes:
#
#     environment `ic`  ->  mainnet  master key
#     anything else     ->  pocketic master key   (a managed local network IS PocketIC)
#
# The sealer refuses to default `--source`, so if this script ever stops passing it the
# result is an error rather than a wrong guess.
#
# ⚠️ **The secret is read from the environment, never from an argument.** A value on the
# command line lands in shell history and in CI logs — the very exposure sealing exists to
# close. Closing it in transit while opening it in `~/.zsh_history` would be theatre.
set -euo pipefail

cd "$(dirname "$0")/.."

die() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
note() { printf '\033[36m·\033[0m %s\n' "$1"; }

WHICH="${1:-}"
ENVIRONMENT="${2:-local}"

case "$WHICH" in
  api-key)
    METHOD="set_stripe_api_key"; STATUS="stripe_api_key_status"
    VAR="STRIPE_API_KEY"; WHAT="restricted Stripe API key"
    ;;
  webhook-secret)
    METHOD="set_webhook_secret"; STATUS="webhook_secret_status"
    VAR="STRIPE_WEBHOOK_SECRET"; WHAT="Stripe webhook signing secret"
    ;;
  *)
    die "usage: scripts/seal-secret.sh <api-key|webhook-secret> [environment]"
    ;;
esac

# The environment decides the master key. See the header — this is the whole point.
case "$ENVIRONMENT" in
  ic) SOURCE="mainnet" ;;
  *)  SOURCE="pocketic" ;;
esac

# One flag array, so every icp call below targets the same environment and `local` stays
# the flagless default the rest of scripts/ uses.
ENV_FLAG=()
[ "$ENVIRONMENT" = "local" ] || ENV_FLAG=(-e "$ENVIRONMENT")

# ⚠️ **SET-BUT-EMPTY is a different state from UNSET, and conflating them sealed the
# wrong key.** `read -rs` prints nothing as you type, so a paste that silently fails
# leaves the variable set to "". This used to fall through to `scripts/.local-dev.env`
# for ANY environment, so an empty paste during a mainnet provisioning sealed the
# SANDBOX key to the mainnet canister — and printed the same byte count, the same
# `isSet = true` and the same `generation = 1`. Both keys are 107 characters, so even
# the length disclosure could not tell them apart. Nothing anywhere reported it.
if [ -n "${!VAR+set}" ] && [ -z "${!VAR}" ]; then
  die "$VAR is set but EMPTY — the paste did not take.
    Nothing was sealed. Re-run the read and check the length it echoes before continuing.
    Refusing to fall back to scripts/.local-dev.env: for '$ENVIRONMENT' that would seal a
    different key than the one you meant, indistinguishably."
fi

# ⚠️ **The file is for LOCAL development and is only read for a local environment.** It
# holds sandbox values; a mainnet or any other named environment must get its secret from
# the caller, so a stale local value can never reach a deployment it was not meant for.
if [ "$ENVIRONMENT" = "local" ] && [ -z "${!VAR:-}" ] && [ -f scripts/.local-dev.env ]; then
  # shellcheck disable=SC1091
  . scripts/.local-dev.env
fi

SECRET="${!VAR:-}"
if [ -z "$SECRET" ]; then
  if [ "$ENVIRONMENT" = "local" ]; then
    die "$VAR is unset. Put it in scripts/.local-dev.env (gitignored) or export it.
    Do NOT pass it as an argument — it would land in shell history and CI logs."
  fi
  die "$VAR is unset, and scripts/.local-dev.env is NOT consulted for '$ENVIRONMENT'.
    Export it for this shell instead:
      printf 'value: '; read -rs $VAR; echo \"\${#$VAR} chars\"; export $VAR
    Do NOT pass it as an argument — it would land in shell history and CI logs."
fi

command -v node >/dev/null || die "node is required (>=18)"
if [ ! -d scripts/seal/node_modules ]; then
  note "installing the sealer's dependencies (first run only)"
  npm --prefix scripts/seal ci --silent 2>/dev/null || npm --prefix scripts/seal install --silent
fi

# ── the canister id, read from the environment we are about to call ──────────────────
# Read rather than assumed: the canister id is a derivation input, so sealing to one
# canister and calling another produces a ciphertext the target cannot open.
CANISTER_ID="$(icp canister status backend "${ENV_FLAG[@]}" -i 2>/dev/null || true)"
[ -n "$CANISTER_ID" ] || die "could not read the backend canister id for environment '$ENVIRONMENT'.
    Is it deployed?  icp deploy${ENV_FLAG[*]:+ ${ENV_FLAG[*]}}"

# ── seal, then send ─────────────────────────────────────────────────────────────────
# Kept visibly apart because only the second step involves your identity: anyone can seal
# a secret TO this canister, and only a controller can install one.
ARGS_FILE="$(mktemp)"
# The ciphertext is not secret — it is useless to anyone but this canister — but the temp
# file goes regardless, so nothing accumulates.
trap 'rm -f "$ARGS_FILE"' EXIT

note "sealing the $WHAT for '$ENVIRONMENT' using the $SOURCE master key"
CYCLEPAY_SEAL_SECRET="$SECRET" npm --prefix scripts/seal run --silent seal -- \
  --canister "$CANISTER_ID" --source "$SOURCE" --out "$ARGS_FILE" \
  || die "sealing failed"

icp canister call backend "$METHOD" --args-file "$ARGS_FILE" "${ENV_FLAG[@]}" >/dev/null \
  || die "$METHOD failed. Are you a controller of $CANISTER_ID?
    A '#notSealedToThisCanister' error means the ciphertext was sealed to a different
    key — most often the other network's master key. This script derives that from the
    environment, so check you passed the right one: you used '$ENVIRONMENT' -> $SOURCE."

printf '\033[32m✓\033[0m %s provisioned — the plaintext never left this machine\n' "$WHAT"

# Confirms the rotation landed without ever reading the secret back out.
#
# ⚠️ `'()'` is passed explicitly: `icp canister call` with NO argument opens an
# interactive prompt and reads stdin, so a status read written without it hangs — and here
# it would report nothing under `|| true`. Same trap `stripe-dev.sh` already documents.
icp canister call backend "$STATUS" '()' "${ENV_FLAG[@]}" 2>/dev/null | sed 's/^/    /' || true
