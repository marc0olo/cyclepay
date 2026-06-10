// Pure presentation/encoding helpers — no DOM, no agent, unit-tested.

/// OrderStatus variant keys as the Candid wrapper surfaces them.
export type StatusKey =
  | "created"
  | "expired"
  | "paid"
  | "minting"
  | "icpAtCmc"
  | "awaitingTreasury"
  | "delivered"
  | "errorQueue";

export interface StatusInfo {
  label: string;
  /// Index into STEPS for the progress timeline; -1 = off the happy path.
  step: number;
  /// Stop polling: the backend will never move this order again.
  terminal: boolean;
  tone: "pending" | "active" | "ok" | "warn" | "err";
}

export const STEPS = ["Awaiting payment", "Paid", "Minting", "Delivered"] as const;

export function statusInfo(key: StatusKey): StatusInfo {
  switch (key) {
    case "created":
      return { label: "Awaiting payment", step: 0, terminal: false, tone: "active" };
    case "expired":
      // §4 expiry is advisory — a genuine late payment still completes, so
      // the order stays pollable.
      return { label: "Expired — a completed payment still goes through", step: 0, terminal: false, tone: "warn" };
    case "paid":
      return { label: "Payment received", step: 1, terminal: false, tone: "active" };
    case "awaitingTreasury":
      return { label: "Queued — waiting on treasury", step: 1, terminal: false, tone: "warn" };
    case "minting":
      return { label: "Minting cycles", step: 2, terminal: false, tone: "active" };
    case "icpAtCmc":
      return { label: "Minting cycles (ICP at the minting canister)", step: 2, terminal: false, tone: "active" };
    case "delivered":
      return { label: "Delivered", step: 3, terminal: true, tone: "ok" };
    case "errorQueue":
      return { label: "Needs operator attention — contact support", step: -1, terminal: true, tone: "err" };
  }
}

/// Append client_reference_id to a Stripe Payment Link (§6.1) — the one URL
/// param the whole attribution flow hangs off.
export function paymentLinkWithRef(url: string, clientReferenceId: string): string {
  const sep = url.includes("?") ? "&" : "?";
  return `${url}${sep}client_reference_id=${encodeURIComponent(clientReferenceId)}`;
}

/// "3.353 T" style cycle quantities; exact below 1M.
export function formatCycles(n: bigint): string {
  const units: Array<[bigint, string]> = [
    [1_000_000_000_000n, "T"],
    [1_000_000_000n, "G"],
    [1_000_000n, "M"],
  ];
  for (const [unit, suffix] of units) {
    if (n >= unit) {
      const thousandths = (n * 1000n + unit / 2n) / unit;
      const whole = thousandths / 1000n;
      const frac = (thousandths % 1000n).toString().padStart(3, "0").replace(/0+$/, "");
      return frac.length > 0 ? `${whole}.${frac} ${suffix}` : `${whole} ${suffix}`;
    }
  }
  return n.toString();
}

export function formatUsdCents(cents: bigint): string {
  return `$${cents / 100n}.${(cents % 100n).toString().padStart(2, "0")}`;
}

export function shortPrincipal(text: string): string {
  return text.length <= 16 ? text : `${text.slice(0, 5)}…${text.slice(-5)}`;
}

export function nsToMillis(ns: bigint): number {
  return Number(ns / 1_000_000n);
}

export type SubaccountParse =
  | { ok: true; value: Uint8Array | null }
  | { ok: false; error: string };

/// Optional ICRC-1 subaccount as hex: empty = none; up to 64 hex digits,
/// left-padded to 32 bytes (the conventional short form for low subaccounts).
export function parseSubaccountHex(input: string): SubaccountParse {
  const hex = input.trim().replace(/^0x/i, "");
  if (hex.length === 0) return { ok: true, value: null };
  if (!/^[0-9a-fA-F]+$/.test(hex)) return { ok: false, error: "subaccount must be hex" };
  if (hex.length > 64) return { ok: false, error: "subaccount is at most 32 bytes (64 hex digits)" };
  const padded = hex.padStart(64, "0");
  const bytes = new Uint8Array(32);
  for (let i = 0; i < 32; i++) {
    bytes[i] = parseInt(padded.slice(i * 2, i * 2 + 2), 16);
  }
  return { ok: true, value: bytes };
}

// --- ck-USDC rail (§6.2) -----------------------------------------------------

/// 1¢ = 10⁴ ck-USDC units (6 decimals, 1:1 USD peg) — mirrors CkUsdc.unitsForCents.
export const CK_UNITS_PER_CENT = 10_000n;

export function ckUnitsForCents(cents: bigint): bigint {
  return cents * CK_UNITS_PER_CENT;
}

/// "5.01 ckUSDC" — 6-decimal token amount, trailing zeros trimmed but always
/// at least two decimals (money reads wrong as "5.0").
export function formatCkUsdcUnits(units: bigint): string {
  const whole = units / 1_000_000n;
  const frac = (units % 1_000_000n).toString().padStart(6, "0");
  const trimmed = frac.replace(/0+$/, "");
  const shown = trimmed.length < 2 ? frac.slice(0, 2) : trimmed;
  return `${whole}.${shown} ckUSDC`;
}

export type UsdAmountParse = { ok: true; cents: bigint } | { ok: false; error: string };

/// User-typed dollar amount → cents. Strict shape (optional $, up to two
/// decimals) — anything fancier silently guessing at money is worse than
/// asking the user to retype.
export function parseUsdAmount(input: string): UsdAmountParse {
  const text = input.trim().replace(/^\$/, "");
  const match = /^(\d+)(?:\.(\d{1,2}))?$/.exec(text);
  if (!match) return { ok: false, error: "Enter a dollar amount like 5 or 5.50." };
  const cents = BigInt(match[1] ?? "0") * 100n + BigInt((match[2] ?? "0").padEnd(2, "0"));
  if (cents === 0n) return { ok: false, error: "Amount must be more than $0." };
  return { ok: true, cents };
}

export type CkCreateError =
  | { __kind__: "anonymous" }
  | { __kind__: "idGeneration" }
  | { __kind__: "railDisabled" }
  | { __kind__: "rateUnavailable" }
  | { __kind__: "zeroAmount" }
  | { __kind__: "amountBelowFees" }
  | { __kind__: "belowMinimum"; belowMinimum: bigint }
  | { __kind__: "aboveMaximum"; aboveMaximum: bigint };

export function createCkOrderErrorMessage(err: CkCreateError): string {
  switch (err.__kind__) {
    case "railDisabled":
      return "The ck-USDC rail is not enabled yet — check back soon.";
    case "zeroAmount":
      return "Amount must be more than $0.";
    case "belowMinimum":
      return `The minimum is ${formatUsdCents(err.belowMinimum)}.`;
    case "aboveMaximum":
      return `The maximum is ${formatUsdCents(err.aboveMaximum)}.`;
    case "amountBelowFees":
      return "Fees would swallow this amount — enter a larger one.";
    case "rateUnavailable":
      return "Exchange rate temporarily unavailable — nothing was charged. Try again in a minute.";
    case "anonymous":
      return "Sign in with Internet Identity first.";
    case "idGeneration":
      return "Could not generate an order id — try again.";
  }
}

export type ClaimError =
  | { __kind__: "anonymous" }
  | { __kind__: "notFound" }
  | { __kind__: "wrongRail" }
  | { __kind__: "inFlight" }
  | { __kind__: "staleIntent" }
  | { __kind__: "notClaimable"; notClaimable: string }
  | { __kind__: "retryable"; retryable: string }
  | { __kind__: "ledgerRejected"; ledgerRejected: string }
  | { __kind__: "badFee"; badFee: { expectedFee: bigint } }
  | { __kind__: "insufficientAllowance"; insufficientAllowance: { allowance: bigint; required: bigint } }
  | { __kind__: "insufficientFunds"; insufficientFunds: { balance: bigint; required: bigint } };

export interface ClaimErrorInfo {
  message: string;
  /// What the user can actually do next: re-approve a bigger allowance, retry
  /// the claim, fund their account, or nothing (operator/support territory).
  action: "approve" | "retry" | "fund" | "none";
  /// For action === "approve": the ledger-authoritative allowance to approve
  /// (supersedes whatever the UI derived from config).
  requiredUnits?: bigint;
}

/// §6.2 claim-error → user-action mapping. The two amount-short arms are
/// definite rejections (the backend dropped the intent; nothing moved), so
/// they read as clean "fix and retry" — never as a stuck order.
export function claimErrorInfo(err: ClaimError): ClaimErrorInfo {
  switch (err.__kind__) {
    case "insufficientAllowance": {
      const { allowance, required } = err.insufficientAllowance;
      return {
        message: `You approved ${formatCkUsdcUnits(allowance)} but ${formatCkUsdcUnits(required)} is needed (price + ledger fee). Approve at least that and claim again — nothing was charged.`,
        action: "approve",
        requiredUnits: required,
      };
    }
    case "insufficientFunds": {
      const { balance, required } = err.insufficientFunds;
      return {
        message: `Your ck-USDC balance is ${formatCkUsdcUnits(balance)}; ${formatCkUsdcUnits(required)} is needed (price + ledger fee). Top up and claim again — nothing was charged.`,
        action: "fund",
      };
    }
    case "retryable":
      return { message: "The ledger is temporarily unavailable — try claiming again in a moment.", action: "retry" };
    case "inFlight":
      return { message: "A claim for this order is already in progress — give it a moment.", action: "retry" };
    case "badFee":
      return {
        message: `The ledger's transfer fee changed (it now expects ${formatCkUsdcUnits(err.badFee.expectedFee)}) — the operator needs to update the rail config. Nothing was charged.`,
        action: "none",
      };
    case "staleIntent":
      return {
        message: "This order's payment needs operator attention — you will not be charged twice. Contact support with the order id.",
        action: "none",
      };
    case "ledgerRejected":
      return { message: `The ledger rejected the payment: ${err.ledgerRejected}. Contact support with the order id.`, action: "none" };
    case "notClaimable":
      return { message: `This order is past payment (status: ${err.notClaimable}).`, action: "none" };
    case "wrongRail":
      return { message: "This order is not a ck-USDC order.", action: "none" };
    case "notFound":
      return { message: "Order not found.", action: "none" };
    case "anonymous":
      return { message: "Sign in with Internet Identity first.", action: "none" };
  }
}

/// icrc2_approve errors come from the raw (non-bindgen) ledger actor, so the
/// variant is a one-key record — key on it structurally.
export function approveErrorMessage(err: Record<string, unknown>): string {
  if ("InsufficientFunds" in err) {
    const balance = (err.InsufficientFunds as { balance: bigint }).balance;
    return `Your ck-USDC balance (${formatCkUsdcUnits(balance)}) cannot cover the approval fee — top up first.`;
  }
  if ("BadFee" in err) {
    const expected = (err.BadFee as { expected_fee: bigint }).expected_fee;
    return `The ledger expects a ${formatCkUsdcUnits(expected)} approval fee — reload and try again.`;
  }
  if ("TemporarilyUnavailable" in err) return "The ledger is temporarily unavailable — try again in a moment.";
  if ("GenericError" in err) {
    return `The ledger rejected the approval: ${(err.GenericError as { message: string }).message}`;
  }
  const key = Object.keys(err)[0] ?? "unknown";
  return `Approval failed (${key}) — try again.`;
}

/// User-facing messages for create_order errors (variant key → text).
export function createOrderErrorMessage(key: string): string {
  switch (key) {
    case "rateUnavailable":
      // §3.1 fail-closed: never price on a stale rate.
      return "Exchange rate temporarily unavailable — nothing was charged. Try again in a minute.";
    case "tierBelowFees":
      return "This tier is misconfigured (payment fees would exceed it). Pick another tier.";
    case "unknownTier":
      return "That tier no longer exists — reload the page for current tiers.";
    case "anonymous":
      return "Sign in with Internet Identity first.";
    case "idGeneration":
      return "Could not generate an order id — try again.";
    default:
      return `Order creation failed: ${key}`;
  }
}
