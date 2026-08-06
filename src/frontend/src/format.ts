// Pure presentation/encoding helpers. No DOM, no agent, unit-tested.

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
      // §4 expiry is advisory. A genuine late payment still completes, so
      // the order stays pollable.
      return { label: "Expired. A completed payment still goes through", step: 0, terminal: false, tone: "warn" };
    case "paid":
      return { label: "Payment received", step: 1, terminal: false, tone: "active" };
    case "awaitingTreasury":
      return { label: "Queued. Waiting on treasury", step: 1, terminal: false, tone: "warn" };
    case "minting":
      return { label: "Minting cycles", step: 2, terminal: false, tone: "active" };
    case "icpAtCmc":
      return { label: "Minting cycles (ICP at the minting canister)", step: 2, terminal: false, tone: "active" };
    case "delivered":
      return { label: "Delivered", step: 3, terminal: true, tone: "ok" };
    case "errorQueue":
      return { label: "Needs operator attention. Contact support", step: -1, terminal: true, tone: "err" };
  }
}

/// Append client_reference_id to a Stripe Payment Link (§6.1). The one URL
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

// --- pricing (§3) ------------------------------------------------------------
//
// The backend prices everything. `quote_previews` runs the *same* `quoteCents`
// function `create_order` runs, so a quoted figure and the order that follows it
// cannot disagree. Nothing here reimplements the formula.
//
// The one deliberate exception is `cyclesForCents` below, used only to re-derive
// a *finished* order's price from its receipt. That duplication is the point: a
// backend confirming its own arithmetic proves nothing, so verification has to
// happen somewhere the operator does not control.

export interface FeeConfig {
  feeBps: bigint;
  feeFixedCents: bigint;
}

/// `netCents × xdrPermyriadPerIcp × 10¹² / usdPerIcpMicros`, floored. Mirrors
/// `Pricing.cyclesForCents`. Receipt verification only; see the note above.
export function cyclesForCents(
  net: bigint,
  xdrPermyriadPerIcp: bigint,
  usdPerIcpMicros: bigint,
): bigint | null {
  if (usdPerIcpMicros === 0n) return null;
  return (net * xdrPermyriadPerIcp * 1_000_000_000_000n) / usdPerIcpMicros;
}

/// The fee split in words, from the backend's own numbers. Ends with the margin
/// statement because "what is the operator taking?" is the question a fee line
/// actually raises. And on this gateway the answer is nothing.
export function feeBreakdown(
  grossCents: bigint,
  feeCents: bigint,
  netCents: bigint | undefined,
  fee: FeeConfig,
): string {
  if (netCents === undefined) {
    return `Payment processing (${formatUsdCents(feeCents)}) would exceed ${formatUsdCents(grossCents)} — pick a larger amount.`;
  }
  const rate = fee.feeBps === 0n && fee.feeFixedCents === 0n
    ? "no processor fee"
    : `${Number(fee.feeBps) / 100}% + ${formatUsdCents(fee.feeFixedCents)}`;
  return (
    `${formatUsdCents(grossCents)} charged · ${formatUsdCents(feeCents)} payment processing (${rate}) · ` +
    `${formatUsdCents(netCents)} buys cycles · operator margin: none`
  );
}

export type DestinationKind = "canister" | "cyclesLedgerAccount";

/// What actually lands, given where it is going. The cycles ledger charges a
/// flat fee to accept a deposit, so an account destination receives less than a
/// canister top-up. Not grossed up on-chain by design (minting extra to cover a
/// per-order fee would be griefable), so it has to be shown here instead.
///
/// `depositFee` comes from `quote_previews` rather than a constant in this file —
/// it is the ledger's number, not ours.
export function cyclesAtDestination(
  cycles: bigint | null,
  destination: DestinationKind,
  depositFee: bigint,
): bigint | null {
  if (cycles === null) return null;
  if (destination === "canister") return cycles;
  return cycles > depositFee ? cycles - depositFee : 0n;
}

/// The line under an amount, stating what arrives and that the rate is now
/// locked once the order exists.
///
/// **The rate is what gets locked, not the quantity.** Money-out never re-reads
/// a rate, so market movement after creation changes nothing. But if a payment
/// arrives for a different amount than quoted, the quantity is re-derived at
/// that same locked rate. Saying "cycles are locked" would be wrong in that one
/// case; saying the rate is locked is always true.
export function estimateLine(
  cycles: bigint | null,
  destination: DestinationKind,
  depositFee: bigint,
): string {
  if (cycles === null) {
    return "No exchange rate available right now. Orders are paused until one is.";
  }
  const landing = cyclesAtDestination(cycles, destination, depositFee);
  if (destination === "cyclesLedgerAccount" && landing !== null) {
    // Only spell out the split when the two figures actually *read* differently.
    // `formatCycles` shows three decimals, so on a multi-trillion order the
    // deposit fee rounds away entirely. And "3.5 T credited (3.5 T minted, less
    // the 100 M deposit fee)" reads as a contradiction rather than a disclosure.
    // The fee is still disclosed unconditionally next to the destination choice.
    const shown = formatCycles(landing);
    if (shown !== formatCycles(cycles)) {
      return (
        `≈ ${shown} cycles credited ` +
        `(${formatCycles(cycles)} minted, less the cycles ledger's ${formatCycles(depositFee)} deposit fee)`
      );
    }
    return `≈ ${shown} cycles credited (after the cycles ledger's ${formatCycles(depositFee)} deposit fee)`;
  }
  return `≈ ${formatCycles(cycles)} cycles`;
}

/// Tolerance the UI allows between the figure a buyer was shown and the one the
/// gateway locks: 5%.
///
/// Rates refresh on a timer, so an exact match would bounce a purchase for a
/// move too small to care about. And every bounce is a buyer wondering whether
/// their card was charged. 5% is wide enough that ordinary drift passes and
/// narrow enough that a real dislocation still stops and asks.
///
/// Only ever applied downward: more cycles than shown is never a reason to
/// refuse. The tolerance lives here, not in the backend, because it is a
/// *client policy* — the backend enforces exactly the minimum it is handed, so a
/// caller that needs an exact quantity can pin one.
export const QUOTE_SLIPPAGE_BPS = 500n;

/// The `minCycles` to pin for a displayed estimate.
export function minAcceptableCycles(shown: bigint): bigint {
  return (shown * (10_000n - QUOTE_SLIPPAGE_BPS)) / 10_000n;
}

/// Stated when the locked quantity differs from the estimate the buyer saw —
/// within tolerance, so the order went through. Silence here would be the
/// surprise; the number changed and they should hear it from us.
export function lockedVsEstimate(locked: bigint, shown: bigint | null): string | null {
  if (shown === null || locked === shown) return null;
  const direction = locked > shown ? "more" : "fewer";
  return (
    `The rate moved slightly between the estimate and the lock: this order is for ` +
    `${formatCycles(locked)} cycles, ${direction} than the ${formatCycles(shown)} shown. ` +
    `This is the locked quantity and it will not change again.`
  );
}

/// Why the estimate carries a "≈" before the order exists, and stops once it
/// does. Shown next to the estimate so nobody has to guess whether the number
/// they are looking at can still move.
export const RATE_LOCK_NOTE =
  "The exchange rate is locked when you create the order. It never changes afterwards, however long you take to pay or however far the market moves.";

export function shortPrincipal(text: string): string {
  return text.length <= 16 ? text : `${text.slice(0, 5)}…${text.slice(-5)}`;
}

export function nsToMillis(ns: bigint): number {
  return Number(ns / 1_000_000n);
}

// --- receipts (§8) -----------------------------------------------------------

export interface ReceiptVerification {
  netCents?: bigint;
  usdPerIcpMicros: bigint;
  xdrPermyriadPerIcp: bigint;
  rateReceivedRates: bigint;
  rateQueriedSources: bigint;
}

export interface ReceiptCheck {
  /// The quantity recomputed from the receipt's own inputs.
  recomputed: bigint | null;
  /// Whether it equals the cycles the order locked.
  matches: boolean;
  /// One line stating the arithmetic, with the numbers filled in.
  formula: string;
}

/// Recompute the quote from a receipt and compare it to what was locked.
///
/// The point is that this runs on the buyer's machine from values they can fetch
/// from the XRC and the CMC themselves. So "you were charged correctly" is
/// something they check, not something the operator asserts.
export function checkReceipt(v: ReceiptVerification, lockedCycles: bigint): ReceiptCheck {
  const net = v.netCents;
  if (net === undefined) {
    return {
      recomputed: null,
      matches: false,
      formula: "This order has no net amount: the fee formula would have consumed it.",
    };
  }
  const recomputed = cyclesForCents(net, v.xdrPermyriadPerIcp, v.usdPerIcpMicros);
  const usdPerIcp = (Number(v.usdPerIcpMicros) / 1e6).toFixed(2);
  const xdrPerIcp = (Number(v.xdrPermyriadPerIcp) / 1e4).toFixed(4);
  return {
    recomputed,
    matches: recomputed !== null && recomputed === lockedCycles,
    formula:
      `${formatUsdCents(net)} net × ${xdrPerIcp} XDR/ICP ÷ $${usdPerIcp}/ICP × 10¹² = ` +
      `${recomputed === null ? "not yet" : formatCycles(recomputed)}`,
  };
}

/// How well-sourced the quoted ICP price was. A rate assembled from two
/// exchanges is not the same product as one from twelve, and the difference is
/// otherwise invisible to the buyer.
export function rateSourceNote(received: bigint, queried: bigint): string {
  if (queried === 0n) return "";
  return `priced from ${received} of ${queried} exchange sources`;
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

/// 1¢ = 10⁴ ck-USDC units (6 decimals, 1:1 USD peg). Mirrors CkUsdc.unitsForCents.
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
/// decimals). Anything fancier silently guessing at money is worse than
/// asking the user to retype.
export function parseUsdAmount(input: string): UsdAmountParse {
  const text = input.trim().replace(/^\$/, "");
  const match = /^(\d+)(?:\.(\d{1,2}))?$/.exec(text);
  if (!match) return { ok: false, error: "Enter a dollar amount like 5 or 5.50." };
  const cents = BigInt(match[1] ?? "0") * 100n + BigInt((match[2] ?? "0").padEnd(2, "0"));
  if (cents === 0n) return { ok: false, error: "Amount must be more than $0." };
  return { ok: true, cents };
}

/// Gate.mo admission refusal. Every case is a *temporary operational* state
/// except `amountAboveMax`, so the copy has to tell the user whether to change
/// something or come back later. A generic failure would leave them retrying a
/// button that cannot succeed.
export type GateReason =
  | { __kind__: "tooManyOpenOrders"; tooManyOpenOrders: { open: bigint; max: bigint } }
  | { __kind__: "canisterCyclesLow"; canisterCyclesLow: { balance: bigint; min: bigint } }
  | { __kind__: "burnCapExhausted"; burnCapExhausted: { burnedE8s: bigint; capE8s: bigint } }
  // `observedE8s` is an `opt nat`, which the bindgen wrapper models as an
  // optional property rather than a 0/1-element tuple.
  | { __kind__: "floatLow"; floatLow: { observedE8s?: bigint; thresholdE8s: bigint } }
  | { __kind__: "amountAboveMax"; amountAboveMax: { usdCents: bigint; maxUsdCents: bigint } };

export function gateReasonMessage(reason: GateReason): string {
  switch (reason.__kind__) {
    case "amountAboveMax":
      return `The maximum for a single purchase is ${formatUsdCents(reason.amountAboveMax.maxUsdCents)}.`;
    case "tooManyOpenOrders":
      return `You already have ${reason.tooManyOpenOrders.open} unpaid orders open (limit ${reason.tooManyOpenOrders.max}). Pay or abandon one before starting another.`;
    case "burnCapExhausted":
      // The operator's rolling blast-radius bound is spent for this window.
      return "Purchases are paused right now. The gateway has hit its limit for this period. Nothing was charged; please try again later.";
    case "floatLow":
    case "canisterCyclesLow":
      return "Purchases are temporarily unavailable while the gateway is topped up. Nothing was charged; please try again later.";
  }
}

export type CkCreateError =
  | { __kind__: "anonymous" }
  | { __kind__: "idGeneration" }
  | { __kind__: "railDisabled" }
  | { __kind__: "rateUnavailable" }
  | { __kind__: "zeroAmount" }
  | { __kind__: "amountBelowFees" }
  | { __kind__: "belowMinimum"; belowMinimum: bigint }
  | { __kind__: "aboveMaximum"; aboveMaximum: bigint }
  | { __kind__: "notAdmitted"; notAdmitted: GateReason };

export function createCkOrderErrorMessage(err: CkCreateError): string {
  switch (err.__kind__) {
    case "railDisabled":
      return "The ck-USDC rail is not available.";
    case "zeroAmount":
      return "Amount must be more than $0.";
    case "belowMinimum":
      return `The minimum is ${formatUsdCents(err.belowMinimum)}.`;
    case "aboveMaximum":
      return `The maximum is ${formatUsdCents(err.aboveMaximum)}.`;
    case "amountBelowFees":
      return "Fees would swallow this amount. Enter a larger one.";
    case "rateUnavailable":
      return "Exchange rate temporarily unavailable. Nothing was charged. Try again in a minute.";
    case "anonymous":
      return "Sign in with Internet Identity first.";
    case "idGeneration":
      return "Could not generate an order id. Try again.";
    case "notAdmitted":
      return gateReasonMessage(err.notAdmitted);
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
/// they read as clean "fix and retry". Never as a stuck order.
export function claimErrorInfo(err: ClaimError): ClaimErrorInfo {
  switch (err.__kind__) {
    case "insufficientAllowance": {
      const { allowance, required } = err.insufficientAllowance;
      return {
        message: `You approved ${formatCkUsdcUnits(allowance)} but ${formatCkUsdcUnits(required)} is needed (price + ledger fee). Approve at least that and claim again. Nothing was charged.`,
        action: "approve",
        requiredUnits: required,
      };
    }
    case "insufficientFunds": {
      const { balance, required } = err.insufficientFunds;
      return {
        message: `Your ck-USDC balance is ${formatCkUsdcUnits(balance)}; ${formatCkUsdcUnits(required)} is needed (price + ledger fee). Top up and claim again. Nothing was charged.`,
        action: "fund",
      };
    }
    case "retryable":
      return { message: "The ledger is temporarily unavailable. Try claiming again in a moment.", action: "retry" };
    case "inFlight":
      return { message: "A claim for this order is already in progress. Give it a moment.", action: "retry" };
    case "badFee":
      return {
        message: `The ledger's transfer fee changed (it now expects ${formatCkUsdcUnits(err.badFee.expectedFee)}). The operator needs to update the rail config. Nothing was charged.`,
        action: "none",
      };
    case "staleIntent":
      return {
        message: "This order's payment needs operator attention. You will not be charged twice. Contact support with the order id.",
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

/// The `#quoteChanged` refusal, in the buyer's terms. Leads with "nothing was
/// charged" because that is the first thing someone wants to know when a payment
/// flow refuses.
export function quoteChangedMessage(
  quoted: bigint,
  destination: DestinationKind,
  depositFee: bigint,
): string {
  return (
    `The exchange rate moved while this page was open. Nothing was charged. ` +
    `This amount now buys ${estimateLine(quoted, destination, depositFee)}. ` +
    `Click again to create the order and lock that rate.`
  );
}

/// icrc2_approve errors come from the raw (non-bindgen) ledger actor, so the
/// variant is a one-key record. Key on it structurally.
export function approveErrorMessage(err: Record<string, unknown>): string {
  if ("InsufficientFunds" in err) {
    const balance = (err.InsufficientFunds as { balance: bigint }).balance;
    return `Your ck-USDC balance (${formatCkUsdcUnits(balance)}) cannot cover the approval fee. Top up first.`;
  }
  if ("BadFee" in err) {
    const expected = (err.BadFee as { expected_fee: bigint }).expected_fee;
    return `The ledger expects a ${formatCkUsdcUnits(expected)} approval fee. Reload and try again.`;
  }
  if ("TemporarilyUnavailable" in err) return "The ledger is temporarily unavailable. Try again in a moment.";
  if ("GenericError" in err) {
    return `The ledger rejected the approval: ${(err.GenericError as { message: string }).message}`;
  }
  const key = Object.keys(err)[0] ?? "unknown";
  return `Approval failed (${key}). Try again.`;
}

/// User-facing messages for create_order errors (variant key → text).
///
/// `notAdmitted` carries a payload, so callers with the full error value should
/// pass its reason to `gateReasonMessage` instead of only the key. The key
/// alone cannot say whether the user should change the amount or wait.
export function createOrderErrorMessage(key: string): string {
  switch (key) {
    case "quoteChanged":
      // Callers with the full error should use `quoteChangedMessage`. The key
      // alone cannot say what the amount buys now.
      return "The exchange rate moved past the accepted tolerance. Nothing was charged. Check the updated amount and confirm.";
    case "notAdmitted":
      return "Purchases are temporarily unavailable. Nothing was charged. Please try again later.";
    case "rateUnavailable":
      // §3.1 fail-closed: never price on a stale rate.
      return "Exchange rate temporarily unavailable. Nothing was charged. Try again in a minute.";
    case "tierBelowFees":
      return "This tier is misconfigured (payment fees would exceed it). Pick another tier.";
    case "unknownTier":
      return "That tier no longer exists. Reload the page for current tiers.";
    case "anonymous":
      return "Sign in with Internet Identity first.";
    case "idGeneration":
      return "Could not generate an order id. Try again.";
    default:
      return `Order creation failed: ${key}`;
  }
}
