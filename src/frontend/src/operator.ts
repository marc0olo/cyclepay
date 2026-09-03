/// Operator-facing meaning: what each state IS, and what to do about it (#68).
///
/// ⚠️ **The hint tables are `Record<Tags<…>, Hint>`, so a missing hint is a COMPILE
/// error** — and so is a hint for a tag the canister no longer has. A gate step could only
/// have caught the first. The tags come from the generated bindings, so the exhaustiveness
/// is against the canister's actual interface rather than a list someone maintains: the
/// gate regenerates those bindings immediately before the frontend typecheck.
///
/// ⚠️ **Why this is not in RUNBOOK's prose.** It is the same content, and two copies drift.
/// Here it is at least checked for completeness against the interface; RUNBOOK stays the
/// place for the procedures a hint points at.
import type { Backend, Order } from "./actor";

/// The tags of a Candid variant, as a string union.
///
/// ⚠️ **THREE representations, one helper, and getting this wrong is silent.** bindgen
/// renders a variant three different ways:
///
///   - cases carrying PAYLOADS → a `__kind__` discriminator
///     (`{ __kind__: "duplicate", duplicate: {…} }`). `ProblemKind`, `Kind`, `Reason`.
///   - all cases EMPTY → a TypeScript `enum` of string members. `OrderStatus`.
///   - the raw declarations (which the integration suite uses) → a union of single-key
///     records. Kept here so this helper works against either binding.
///
/// ⚠️ **The enum branch is not tidiness — without it `Tags<OrderStatus>` was `never`**, an
/// enum member being a string literal rather than an object. `Record<never, Hint>` accepts
/// ANY object, so the order-status table — the one that matters most — had no
/// exhaustiveness at all while looking exactly like the three that did. Found by mutation:
/// renaming `needsReview` typechecked clean. `ExpiredBy`, `OriginError`,
/// `ProcessOrderError` and `Rail` are enums too, so anything added here inherits the trap.
///
/// Distributive on purpose: without it a bare `keyof` over a union yields `never`.
type Tags<T> = T extends { __kind__: infer K }
  ? K
  : T extends string
    ? T
    : T extends object
      ? keyof T
      : never;

/// ⚠️ **Projected off the actor, never imported by generated type name.** `actor.ts`
/// already does this for `Order` and `Tier` — "immune to whatever type names bindgen
/// exports" — and #85 is why: `Result_1`…`Result_12` are numbered by position in the
/// `.did`, so adding a method renumbers them.
type OrphanEntry = Awaited<ReturnType<Backend["orphans_unresolved"]>>["entries"][number];
type CanPurchase = Awaited<ReturnType<Backend["can_purchase"]>>;
type Refusals = Awaited<ReturnType<Backend["refusal_counts"]>>["counts"];

export type OrderStatusTag = Tags<Order["status"]>;
export type ProblemKindTag = Tags<Order["problems"][number]["kind"]>;
export type OrphanKindTag = Tags<OrphanEntry["kind"]>;
export type GateReasonTag = Tags<Extract<CanPurchase, { err: unknown }>["err"]>;

/// ⚠️ **The console shows refusal COUNTS, and there are seven of them against the gate's
/// five reasons.** `railClosed` and `stripeApiFailing` are rail-state conditions that
/// refuse before a reason is ever computed, so they are counted and are not
/// `can_purchase` answers. Keying the table on the counts is what makes it exhaustive for
/// what is actually rendered; `operator.test.ts` pins that every gate reason is also a
/// count, so the two cannot drift apart.
export type RefusalTag = keyof Refusals;

/// ⚠️ **`urgency` is the operator's whole question, and it is not severity.** "wait" means
/// the state clears itself and acting is the mistake; "act" means nothing will move without
/// a human. A UI that ranked these by badness would put a self-clearing retry next to an
/// unattributed payment.
export type Urgency = "wait" | "act";

export interface Hint {
  /// What the state means, in the operator's terms rather than the code's.
  readonly means: string;
  /// What to do. For a "wait" state this says so explicitly, because "no action" has to be
  /// an answer rather than an absence.
  readonly then: string;
  readonly urgency: Urgency;
}

export const ORDER_STATUS_HINTS: Record<OrderStatusTag, Hint> = {
  created: {
    means: "A buyer has an order and has not paid yet.",
    then: "Wait. It expires on the Stripe session's own deadline, and nothing is owed.",
    urgency: "wait",
  },
  paid: {
    means: "Money is in and the cycles have not been delivered yet.",
    then: "Wait. Delivery retries on its own. Past the alert threshold it appears in the delayed list, which is when it is worth reading.",
    urgency: "wait",
  },
  delivered: {
    means: "The cycles reached the buyer and the ledger block is recorded.",
    then: "Nothing. This is the finished state.",
    urgency: "wait",
  },
  cancelled: {
    means: "The buyer withdrew before paying.",
    then: "Nothing. No money moved.",
    urgency: "wait",
  },
  expired: {
    means: "The Stripe session ended unpaid, so the order is provably unpayable.",
    then: "Nothing. A late payment against it is refunded, never converted.",
    urgency: "wait",
  },
  needsReview: {
    means: "A delivery stopped where it cannot continue on its own, and the money position is unknown: the transfer may or may not have landed.",
    then: "Establish the fate on the cycles ledger first (the order id is in the transfer's memo). If the cycles arrived, record_delivered with the block. If they did not, refund by hand and abandon_order with the reason.",
    urgency: "act",
  },
  abandoned: {
    means: "An operator ended the order, asserting a refund was issued by hand.",
    then: "Nothing here. The refund itself is tracked on the Stripe side.",
    urgency: "wait",
  },
};

export const PROBLEM_KIND_HINTS: Record<ProblemKindTag, Hint> = {
  duplicate: {
    means: "A second, distinct payment arrived for an order already handled.",
    then: "Refund the duplicate charge in Stripe, then resolve_problem with this order id, the kind tag and the payment reference.",
    urgency: "act",
  },
  deliveryStuck: {
    means: "A delivery stopped and the reason is recorded on the order. Not refund-resolvable: the money is in, and what happens next depends on where the cycles are.",
    then: "Read the delivery journal for this order. The stage is advisory; the journal is the authority on whether a transfer was issued.",
    urgency: "act",
  },
  refundAfterDelivery: {
    means: "A refund was issued in Stripe after the cycles had already been delivered.",
    then: "Cycles cannot be recalled. Record the loss, then resolve_problem once it is accounted for.",
    urgency: "act",
  },
  paidNotCredited: {
    means: "A payment verified but could not be attributed to an order that was still creditable.",
    then: "Match the payment reference against the session id, then either credit or refund. resolve_problem when it is settled.",
    urgency: "act",
  },
};

export const ORPHAN_KIND_HINTS: Record<OrphanKindTag, Hint> = {
  unattributed: {
    means: "A verified payment could not be attributed to an order that can accept it: the claimed reference resolved to no order, or to one that is cancelled or expired and so is not payable.",
    then: "Refund it. The claimed reference is caller-supplied, so treat it as a lead and not as evidence; the payment reference is what to search Stripe for. resolve_orphan once the refund is issued.",
    urgency: "act",
  },
  unprocessable: {
    means: "A Stripe event passed signature verification and cannot be processed: a required field is absent. A subscription-mode link or a 100 percent off promo code produces a session with no payment intent.",
    then: "Look the event id up in the Stripe Dashboard, because the money position is not knowable from here. It is queued rather than refused on purpose: answering non-2xx would fail identically on every Stripe retry and risk the endpoint being disabled, which loses every legitimate webhook.",
    urgency: "act",
  },
};

export const REFUSAL_HINTS: Record<RefusalTag, Hint> = {
  amountBelowMin: {
    means: "A buyer asked for less than the configured floor.",
    then: "Nothing: they ask for more. Distinct from amountAboveMax because a buyer acts on them oppositely, and with custom amounts both are reachable by typing.",
    urgency: "wait",
  },
  amountAboveMax: {
    means: "A buyer asked for more than the configured per-purchase ceiling.",
    then: "Nothing: they ask for less. Move the ceiling with set_gate_config only if the ceiling itself is wrong.",
    urgency: "wait",
  },
  tooManyOpenOrders: {
    means: "A buyer already held the maximum number of open orders.",
    then: "Nothing. Their own orders settle or expire on their deadlines and free the slot.",
    urgency: "wait",
  },
  canisterCyclesLow: {
    means: "The canister's own cycle balance is at or under the floor, so it refuses to sell rather than risk running out part way through a delivery.",
    then: "Top up the canister's gas, not the reserve. They are different balances, and topping up the wrong one changes nothing.",
    urgency: "act",
  },
  reserveShort: {
    means: "The reserve could not cover an order on top of what was already promised.",
    then: "Transfer cycles to the reserve account, then refresh_reserve. Without the refresh the floor stays stale and the gate keeps refusing against a fully funded reserve, which is the most confusing failure in this system.",
    urgency: "act",
  },
  railClosed: {
    means: "The card rail is not open: one or both Stripe secrets are not provisioned. This refuses before an amount is even considered.",
    then: "Provision them from a terminal. stripe_api_key_status and webhook_secret_status say which is missing, and neither reads a secret back.",
    urgency: "act",
  },
  stripeApiFailed: {
    means: "Creating a Stripe Checkout Session failed, so an order could not be offered for payment.",
    then: "Check the Stripe status page and the key's permissions: a restricted key needs Checkout Sessions write. Repeated failures with a healthy Stripe mean the key.",
    urgency: "act",
  },
};
