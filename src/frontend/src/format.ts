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
