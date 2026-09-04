// Pure presentation/encoding helpers. No DOM, no agent, unit-tested.

import type { CreateOrderError, OrderStatus, Reason } from "./bindings/backend";

/// OrderStatus variant keys, DERIVED from the generated enum.
///
/// ⚠️ **This was a hand-written union of seven strings, and `main.ts` reached it through
/// `order.status as unknown as StatusKey`.** A double cast launders the real type away: add
/// a status to the canister and the cast still compiles, `statusInfo`'s switch falls off
/// the end returning `undefined`, and `.label` throws on the buyer's order page. The
/// interface grew a status and the mirror did not.
///
/// The template literal is what makes an enum usable as a plain string union: bindgen
/// renders an all-empty Candid variant as a TypeScript `enum`, whose members are nominal,
/// so `"delivered"` is not assignable to `OrderStatus` and every comparison against a
/// literal would break. `${OrderStatus}` yields the VALUES as a union, so the comparisons
/// keep working and a new status becomes a non-exhaustive-switch compile error instead.
export type StatusKey = `${OrderStatus}`;

export interface StatusInfo {
  label: string;
  /// Index into STEPS for the progress timeline; -1 = off the happy path.
  step: number;
  /// Stop polling: the backend will never move this order again.
  terminal: boolean;
  tone: "pending" | "active" | "ok" | "warn" | "err";
}

/// The buyer's progress timeline.
///
/// ⚠️ **Three steps, and every one of them reachable — that is the invariant.** Money
/// out is a single transfer from `#paid` to `#delivered`, so there is no intermediate
/// state for a buyer to sit in and no segment that can never light up. A timeline with
/// a segment nothing enters is worse than a shorter one: the buyer reads the gap as
/// their purchase being stuck.
///
/// Before adding a step, check a status actually maps to it. Off the happy path is where an unreachable
/// status belongs.
export const STEPS = ["Awaiting payment", "Paid", "Delivered"] as const;

export function statusInfo(key: StatusKey): StatusInfo {
  switch (key) {
    case "created":
      return { label: "Awaiting payment", step: 0, terminal: false, tone: "active" };
    case "cancelled":
      // The buyer's own decision, and its own status — so a reload no longer
      // tells someone who cancelled that their order "expired" (#34).
      return { label: "Cancelled", step: -1, terminal: true, tone: "warn" };
    case "expired":
      // TERMINAL as of #34, which deleted `#expired → #paid`. It used to say a
      // completed payment still went through; that is no longer true, and a
      // payment arriving now becomes an operator obligation to refund rather
      // than cycles.
      return { label: "Expired. This order can no longer be paid", step: -1, terminal: true, tone: "warn" };
    case "paid":
      return { label: "Payment received", step: 1, terminal: false, tone: "active" };
    case "delivered":
      return { label: "Delivered", step: 2, terminal: true, tone: "ok" };
    case "needsReview":
      // NOT terminal: the operator can still end it, and until they do the order
      // holds its promise. Polling continues so the buyer sees that happen.
      return { label: "Needs operator attention. Contact support", step: -1, terminal: false, tone: "err" };
    case "abandoned":
      return { label: "Ended by support. Contact us about a refund", step: -1, terminal: true, tone: "err" };
  }
}

/// The payment reference for an order: `<principal>_<orderId>`.
///
/// Computed here rather than returned by `create_order`, which used to hand it
/// back so the frontend could append it to a Payment Link URL (#33 removed that).
/// It still appears on the order page, because it is the reference on the buyer's
/// card receipt and therefore the thing they quote to support.
///
/// It must match `Orders.clientReferenceId` exactly — the whole webhook
/// attribution path parses this shape.
export function clientReferenceFor(principalText: string, orderId: string): string {
  return `${principalText}_${orderId}`;
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
    return `Payment processing (${formatUsdCents(feeCents)}) would exceed ${formatUsdCents(grossCents)}. Pick a larger amount.`;
  }
  const rate = fee.feeBps === 0n && fee.feeFixedCents === 0n
    ? "no processor fee"
    : `${Number(fee.feeBps) / 100}% + ${formatUsdCents(fee.feeFixedCents)}`;
  return (
    `${formatUsdCents(grossCents)} charged · ${formatUsdCents(feeCents)} payment processing (${rate}) · ` +
    `${formatUsdCents(netCents)} buys cycles · operator margin: none`
  );
}

/// What actually lands. The cycles ledger charges a flat fee to accept a
/// deposit, so the buyer receives less than the order locks, on every order.
/// Not grossed up on-chain by design (covering a per-order fee out of the reserve
/// would be griefable), so it has to be shown here instead.
///
/// `transferFee` comes from `quote_previews` rather than a constant in this file —
/// it is the ledger's number, not ours.
export function cyclesCredited(cycles: bigint | null, transferFee: bigint): bigint | null {
  if (cycles === null) return null;
  return cycles > transferFee ? cycles - transferFee : 0n;
}

/// The line under an amount, stating what arrives and that the rate is now
/// locked once the order exists.
///
/// **The rate is what gets locked, not the quantity.** Money-out never re-reads
/// a rate, so market movement after creation changes nothing. But if a payment
/// arrives for a different amount than quoted, the quantity is re-derived at
/// that same locked rate. Saying "cycles are locked" would be wrong in that one
/// case; saying the rate is locked is always true.
export function estimateLine(cycles: bigint | null, transferFee: bigint): string {
  if (cycles === null) {
    return "No exchange rate available right now. Orders are paused until one is.";
  }
  const shown = formatCycles(cyclesCredited(cycles, transferFee)!);
  // Only spell out the split when the two figures actually *read* differently.
  // `formatCycles` shows three decimals, so on a multi-trillion order the 100 M
  // transfer fee rounds away entirely, and "3.5 T credited (3.5 T sent, less the
  // 100 M transfer fee)" reads as a contradiction rather than a disclosure.
  if (shown !== formatCycles(cycles)) {
    return (
      `≈ ${shown} cycles credited ` +
      `(${formatCycles(cycles)} sent, less the cycles ledger's ${formatCycles(transferFee)} transfer fee)`
    );
  }
  // Just the number that lands. The fee is disclosed once, in `#dest-fee-note`
  // under the destination; naming it here as well puts the same parenthetical on
  // every amount tile and in the note below them, three copies of one sentence
  // around the figure a buyer is choosing between. Visible in a screenshot only —
  // every assertion passes either way.
  return `≈ ${shown} cycles`;
}

/// How long until a deadline, for a live countdown.
///
/// ⚠️ **A countdown, not a timestamp.** #33 requires this because the window is
/// thirty-five minutes: "reserved until 14:32" misleads a buyer who looked away,
/// and a buyer who starts paying near the deadline loses the attempt — they are
/// not charged, but the session closes under them. So the copy leans on the
/// remaining time rather than the wall clock.
///
/// Returns null when the deadline has passed, which the caller renders as expired
/// rather than as "0 minutes left".
export function timeUntil(deadlineMs: number, nowMs: number): string | null {
  const remainingMs = deadlineMs - nowMs;
  if (remainingMs <= 0) return null;
  const totalMinutes = Math.floor(remainingMs / 60_000);
  if (totalMinutes >= 1) {
    const seconds = Math.floor((remainingMs % 60_000) / 1_000);
    return `${totalMinutes} min ${String(seconds).padStart(2, "0")} s`;
  }
  return `${Math.max(1, Math.ceil(remainingMs / 1_000))} s`;
}

/// How long ago something happened, for an operator reading a staleness figure.
///
/// ⚠️ **Separate from `timeUntil`, which returns null for anything in the past.** Reusing
/// it here would render every observation as absent, which reads as "never observed" for a
/// reserve that was observed a minute ago: the one number this line exists to report.
///
/// Coarse on purpose. An operator asks "is this stale", not "how many seconds".
export function formatDuration(ms: number): string {
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return "under a minute";
  if (minutes === 1) return "1 minute";
  if (minutes < 60) return `${minutes} minutes`;
  const hours = Math.floor(minutes / 60);
  if (hours === 1) return "1 hour";
  if (hours < 24) return `${hours} hours`;
  const days = Math.floor(hours / 24);
  return days === 1 ? "1 day" : `${days} days`;
}

/// ⚠️ **Split from `formatDuration` because "ago" is not always the right suffix.** A
/// delayed delivery has WAITED three hours; it did not start waiting "3 hours ago" as a
/// separate fact. The first version of the worklist row rendered "waiting 213 days ago",
/// which a screenshot caught and no assertion would have.
export function formatAgo(pastMs: number, nowMs: number): string {
  const elapsed = nowMs - pastMs;
  // A clock that is behind reads as the future. Say so rather than printing a negative.
  if (elapsed < 0) return "in the future (check the clock)";
  return `${formatDuration(elapsed)} ago`;
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
export function checkReceipt(
  v: ReceiptVerification,
  lockedCycles: bigint,
  /// The simulation divisor from `pricing_status().config` (#99). `1n` in
  /// production, where every term below is unchanged.
  ///
  /// ⚠️ **Read from config rather than from the order.** The divisor is expected
  /// constant for the life of the data — `set_pricing_config` refuses to change it
  /// while orders exist — so reading it here gives the same answer storing it on
  /// the order would have, without a stable-shape change for a test-phase feature.
  divisor: bigint = 1n,
): ReceiptCheck {
  const net = v.netCents;
  if (net === undefined) {
    return {
      recomputed: null,
      matches: false,
      formula: "This order has no net amount: the fee formula would have consumed it.",
    };
  }
  // ⚠️ **`recomputed` stays the UNSCALED quantity, and that is the point.** It is
  // what production would have locked for this purchase, recomputed here from the
  // two rate inputs the order carries — so in simulation mode the receipt shows
  // both legs: what production would send, and what this gateway actually did.
  const recomputed = cyclesForCents(net, v.xdrPermyriadPerIcp, v.usdPerIcpMicros);
  const scaled = recomputed === null ? null : recomputed / divisor;
  const usdPerIcp = (Number(v.usdPerIcpMicros) / 1e6).toFixed(2);
  const xdrPerIcp = (Number(v.xdrPermyriadPerIcp) / 1e4).toFixed(4);
  const base =
    `${formatUsdCents(net)} net × ${xdrPerIcp} XDR/ICP ÷ $${usdPerIcp}/ICP × 10¹² = ` +
    `${recomputed === null ? "not yet" : formatCycles(recomputed)}`;
  return {
    recomputed,
    matches: scaled !== null && scaled === lockedCycles,
    // The divisor appears as a term only when there is one, so a production
    // receipt reads exactly as it did before this feature existed.
    formula:
      divisor === 1n || scaled === null
        ? base
        : `${base}, ÷ ${divisor} simulation divisor = ${formatCycles(scaled)}`,
  };
}

/// How well-sourced the quoted ICP price was. A rate assembled from two
/// exchanges is not the same product as one from twelve, and the difference is
/// otherwise invisible to the buyer.
export function rateSourceNote(received: bigint, queried: bigint): string {
  if (queried === 0n) return "";
  return `priced from ${received} of ${queried} exchange sources`;
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
/// except the two amount bounds, so the copy has to tell the user whether to change
/// something or come back later. A generic failure would leave them retrying a
/// button that cannot succeed.
///
/// ⚠️ **Aliased from the GENERATED bindings, never re-declared.** It WAS a
/// hand-written mirror, and it had silently drifted two variants in each direction:
/// it still carried `burnCapExhausted` and `floatLow`, which #30 PR-B deleted, and it
/// was missing `amountBelowMin` (#33 PR-B) and `reserveShort` (#30 PR-B) — so the two
/// refusals a buyer is most likely to see rendered as `undefined`. Nothing caught it,
/// because the switch was exhaustive over the *stale* union and `main.ts` reached it
/// through an `as` cast. Aliasing makes the next backend change a compile error here.
/// A type-only import, so this module stays runtime-dependency-free.
export type GateReason = Reason;

export function gateReasonMessage(reason: GateReason): string {
  switch (reason.__kind__) {
    case "amountAboveMax":
      return `The maximum for a single purchase is ${formatUsdCents(reason.amountAboveMax.maxUsdCents)}.`;
    case "amountBelowMin":
      return `The minimum for a single purchase is ${formatUsdCents(reason.amountBelowMin.minUsdCents)}.`;
    case "tooManyOpenOrders":
      return `You already have ${reason.tooManyOpenOrders.open} unpaid orders open (limit ${reason.tooManyOpenOrders.max}). Pay or abandon one before starting another.`;
    case "reserveShort":
      // The one refusal a smaller amount can fix, so it says so and says how much
      // is actually available rather than "try again later" — which would send the
      // buyer away from a purchase the gateway can still make.
      return (
        `The gateway can only deliver ${formatCycles(reason.reserveShort.available)} cycles right now, ` +
        `and this amount asks for ${formatCycles(reason.reserveShort.requested)}. ` +
        `Nothing was charged. Try a smaller amount, or come back later.`
      );
    case "canisterCyclesLow":
      return "Purchases are temporarily unavailable while the gateway is topped up. Nothing was charged; please try again later.";
    case "unboundedGiveaway":
      // ⚠️ Says nothing about an allow-list, deliberately. This refusal means the
      // OPERATOR has a funded reserve behind an empty allow-list, and every buyer
      // is refused — so telling this buyer they are "not authorized" would name
      // the wrong problem and send them asking for access that would not help.
      return "Purchases are not open on this gateway yet. Nothing was charged.";
    case "buyerNotAllowed":
      // The list IS populated, so this really is about this buyer, and the fix is
      // something they can act on.
      return "This gateway is in testing and only invited testers can buy. Nothing was charged.";
  }
}

/// The same two refusals, worded for a buyer who has **not attempted anything yet**
/// (#99 2b).
///
/// ⚠️ **Why a second table rather than reusing `gateReasonMessage`: "Nothing was
/// charged" is true after an attempt and misleading before one.** In a pre-emptive
/// notice it implies a purchase was tried and reversed, which is confusing at exactly
/// the moment the page is trying to be clear. Everything else about the copy is
/// unchanged — neither message names an allow-list to a buyer who cannot act on it,
/// and neither describes the gateway's misconfiguration in operator vocabulary.
///
/// ⚠️ **This table IS the filter.** A key present here means "invariant for this
/// caller until an operator acts, so pre-announcing it cannot go stale"; absent means
/// the refusal belongs at the moment of the attempt. `Partial<Record<GateReasonTag,
/// …>>` keys it on the real Candid tag union, so there is no second hand-written list
/// of tags for the caller to drift from — the mistake this repo has now removed four
/// times.
///
/// ⚠️ Deliberately NOT extended to `#reserveShort` or `#canisterCyclesLow`: both are
/// volatile and amount-dependent (a smaller amount may work), so a banner rendered
/// from them is stale by construction. That is the rule `main.ts`'s `loadMarket`
/// documents, and this table is the narrow exception to it, not its replacement.
export const PRE_ANNOUNCED_GATE_REASONS: Partial<Record<GateReason["__kind__"], string>> = {
  unboundedGiveaway: "This gateway is not accepting purchases right now.",
  buyerNotAllowed: "This gateway is in testing, and only invited testers can buy.",
};

/// The `#quoteChanged` refusal, in the buyer's terms. Leads with "nothing was
/// charged" because that is the first thing someone wants to know when a payment
/// flow refuses.
export function quoteChangedMessage(quoted: bigint, transferFee: bigint): string {
  return (
    `The exchange rate moved while this page was open. Nothing was charged. ` +
    `This amount now buys ${estimateLine(quoted, transferFee)}. ` +
    `Click again to create the order and lock that rate.`
  );
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
    case "destinationNotOwned":
      // Unreachable from this app — it only ever sends the signed-in
      // principal's own account. Worded for the buyer anyway, because the one
      // way to see it is a page running against a gateway that disagrees with
      // it about who the caller is.
      return "Cycles can only be delivered to your own account. Nothing was charged. Reload the page and try again.";
    case "simulationScaleTooSmall":
      // ⚠️ Names the SIMULATION as the cause, not payment processing (#99 review
      // finding 2). `tierBelowFees` above says fees would exceed the amount, which
      // is true for its own cause and false for this one: here the amount is fine
      // and the operator's divisor scaled the cycles below what the cycles ledger
      // charges to accept a deposit. A larger amount can still help, so it says so.
      return (
        "This gateway is running a scaled-down simulation, and at that scale this amount " +
        "delivers too few cycles to cover the ledger's deposit fee. Nothing was charged. " +
        "Try a larger amount."
      );
    case "reserveUnavailable":
      // #30 PR-B fails closed: selling against an unknown balance is what the
      // check exists to prevent.
      return "The gateway could not confirm its cycle reserve. Nothing was charged. Try again in a minute.";
    case "sessionUnavailable":
      return "Card payments are unavailable right now. Nothing was charged. Please try again later.";
    case "cancelledDuringCreation":
      return "This order was cancelled while it was being created. Nothing was charged. Start a new order if you still want it.";
    default:
      // ⚠️ **Kept as a runtime escape hatch, NOT as the place a missing variant
      // lands.** A canister upgraded ahead of the frontend can send a tag this
      // build has never heard of, and showing its name beats showing nothing. An
      // omission for a variant this build DOES know about is a compile error in
      // `CREATE_ORDER_ERROR_KEYS` below.
      return `Order creation failed: ${key}`;
  }
}

/// Every `create_order` variant this build knows about.
///
/// ⚠️ **This exists because the switch above takes a `string`, so a new backend
/// variant cannot be a compile error there.** Three variants —
/// `reserveUnavailable`, `sessionUnavailable` and `cancelledDuringCreation` —
/// silently rendered as `"Order creation failed: reserveUnavailable"` for exactly
/// that reason, and the test meant to catch it iterated a **hand-written** list of
/// five keys, so it passed while three cases were missing. The list is derived
/// from the type now, and `format.test.ts` iterates *this* rather than its own copy.
export const CREATE_ORDER_ERROR_KEYS: Record<CreateOrderError["__kind__"], true> = {
  anonymous: true,
  cancelledDuringCreation: true,
  destinationNotOwned: true,
  idGeneration: true,
  notAdmitted: true,
  quoteChanged: true,
  rateUnavailable: true,
  reserveUnavailable: true,
  sessionUnavailable: true,
  simulationScaleTooSmall: true,
  tierBelowFees: true,
  unknownTier: true,
};
