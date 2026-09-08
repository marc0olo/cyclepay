/// Candid **text** for `icp canister call`, and the typed command table (#97).
///
/// ⚠️ **Why a table of per-method renderers rather than one generic value walker**, and
/// not the reason first assumed. The guess was that `opt T` and `vec T` are both arrays
/// in the bindings, making an empty one ambiguous — that is true of the RAW
/// declarations, and false of the actor-enabled ones used here, which map `opt T` to
/// `T | null` and leave `vec T` as `T[]`. No ambiguity to resolve.
///
/// The real reason is #97's first acceptance item: each renderer's parameters come from
/// `Parameters<Backend[M]>`, so the table is coupled to the canister's interface. A
/// generic walker takes `unknown` and would happily format a signature that changed
/// underneath it.
///
/// ⚠️ **Every renderer is typed off the actor, never off a string template.** A
/// rendered `icp canister call` is a hand-written mirror of the canister's interface —
/// the exact thing #66/#85 removed from the test suite — and it fails asymmetrically: a
/// wrong argument is refused loudly, a signature that changed underneath produces a
/// command that runs and does the wrong thing. `Parameters<Backend[M]>` makes that a
/// typecheck failure instead.
///
/// ⚠️ **The two secret setters are permanently absent** and it is not an oversight:
/// `set_webhook_secret` and `set_stripe_api_key` are excluded because a rendered
/// command containing the key would land in a page's DOM and clipboard. The console
/// shows only their `*_status` reads. `scripts/check-admin-commands.py` fails if either
/// ever appears here.
import type { Principal } from "@icp-sdk/core/principal";
import type { Backend } from "./actor";

/// A Candid `nat`/`int`. Unannotated on purpose: measured against the running canister,
/// `(0)` and `(0 : nat)` behave identically because `icp canister call` infers the type
/// from the interface.
export function nat(value: bigint | number): string {
  return value.toString();
}

/// A Candid `text`. Escapes what the grammar needs and nothing else.
export function text(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

export function bool(value: boolean): string {
  return value ? "true" : "false";
}

/// A payload-free Candid variant, e.g. `variant { duplicate }`.
///
/// ⚠️ **Takes the bindings' ENUM, and that is where the guarantee lives.** The
/// actor-enabled bindings render a payload-free Candid variant as a TypeScript string
/// enum (`ProblemKindTag.duplicate === "duplicate"`), so the value is already a string
/// at runtime — this function only wraps it. What matters is the *type*: a bare
/// `"refundAfterDelivery"` is not assignable to the enum, so
/// `renderCall("resolve_problem", id, "refundAfterDelivery", ref)` no longer compiles.
/// That was the whole point of #122, and it is enforced at the call rather than here.
///
/// Typed `string` rather than a union of every enum in the interface: each of those is a
/// string enum, all are assignable to `string`, and naming them would be a hand-written
/// mirror of the bindings — the thing this module exists not to do.
export function tag(value: string): string {
  // Defensive, because a value that is not a bare tag would render a command that looks
  // right and means something else. Candid tag names are Motoko identifiers.
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(value)) {
    throw new Error(`not a bare variant tag: ${JSON.stringify(value)}`);
  }
  return `variant { ${value} }`;
}

export function principal(value: Principal | string): string {
  return `principal ${text(typeof value === "string" ? value : value.toText())}`;
}

/// `opt T`. The actor bindings render an absent optional as `null`, so that is what
/// this takes — see the note at the top about the shape that was assumed instead.
export function opt<T>(value: T | null | undefined, inner: (v: T) => string): string {
  return value === null || value === undefined ? "null" : `opt ${inner(value)}`;
}

/// `vec T`.
export function vec<T>(values: readonly T[], inner: (v: T) => string): string {
  return values.length === 0 ? "vec {}" : `vec { ${values.map(inner).join("; ")} }`;
}

/// A Candid record. Field order is the caller's, and it does not matter: record fields
/// are matched by name.
export function record(fields: Readonly<Record<string, string>>): string {
  const body = Object.entries(fields).map(([k, v]) => `${k} = ${v}`).join("; ");
  return `record { ${body} }`;
}

/// The methods the console offers as a command. Keyed so a new entry is deliberate and
/// `scripts/check-admin-commands.py` can compare this list against the canister's own
/// interface.
export type CommandMethod =
  | "set_pricing_config"
  | "set_gate_config"
  | "set_delivery_config"
  | "set_card_tiers"
  | "set_expected_livemode"
  | "set_stripe_origin"
  | "set_recovery_interval"
  | "add_allowed_buyer"
  | "remove_allowed_buyer"
  | "add_admin"
  | "remove_admin"
  | "abandon_order"
  | "record_delivered"
  | "resolve_problem"
  | "resolve_orphan"
  | "process_order"
  | "expire_order"
  | "refresh_reserve"
  | "refresh_rates"
  | "recount_orders"
  | "withdraw_reserve";

/// ⚠️ `Parameters<Backend[M]>` is what couples this to the canister. A setter that
/// gains a field, or an action whose argument order changes, becomes a TYPE ERROR here
/// rather than a command that still runs.
type Renderer<M extends CommandMethod> = (...args: Parameters<Backend[M]>) => string;

type Spec<M extends CommandMethod> = {
  /// The Candid argument list, without the enclosing parentheses.
  readonly args: Renderer<M>;
  /// What running it does that cannot be undone, or undefined when nothing is.
  /// Rendered next to the command, because the whole point of a command over a button
  /// is that a human reads an irreversible instruction before running it.
  readonly irreversible?: string;
};

/// ⚠️ **`Record<CommandMethod, …>` — a missing renderer is a compile error.**
export const COMMANDS: { readonly [M in CommandMethod]: Spec<M> } = {
  set_pricing_config: {
    args: (c) => record({
      feeBps: nat(c.feeBps),
      feeFixedCents: nat(c.feeFixedCents),
      maxAgeNs: nat(c.maxAgeNs),
      maxRateDeltaBps: nat(c.maxRateDeltaBps),
      minRateSources: nat(c.minRateSources),
      divisor: nat(c.divisor),
    }),
    irreversible:
      "The simulation divisor cannot be changed back while any order is stored, so"
      + " setting it commits this deployment until a reinstall.",
  },
  set_gate_config: {
    args: (c) => record({
      maxOpenOrdersPerPrincipal: nat(c.maxOpenOrdersPerPrincipal),
      minCanisterCycles: nat(c.minCanisterCycles),
      minPurchaseUsdCents: nat(c.minPurchaseUsdCents),
      maxPurchaseUsdCents: nat(c.maxPurchaseUsdCents),
    }),
  },
  set_delivery_config: {
    args: (c) => record({ alertAfterNs: nat(c.alertAfterNs), maxHoldNs: nat(c.maxHoldNs) }),
  },
  set_card_tiers: {
    args: (tiers) => vec(tiers, (t) => record({ id: text(t.id), usdCents: nat(t.usdCents) })),
  },
  set_expected_livemode: {
    args: (expected) => opt(expected, bool),
    irreversible:
      "Refused while a simulation divisor is set, and it is the guard that stops real"
      + " money being taken at a scaled cycle quantity.",
  },
  set_stripe_origin: { args: (origin) => text(origin) },
  set_recovery_interval: { args: (ns) => nat(ns) },
  add_allowed_buyer: { args: (p) => principal(p) },
  remove_allowed_buyer: {
    args: (p) => principal(p),
    irreversible:
      "Removing the last entry does not open the gateway up, it closes it: an empty"
      + " list against a funded reserve refuses every buyer.",
  },
  add_admin: { args: (p) => principal(p) },
  remove_admin: { args: (p) => principal(p) },
  abandon_order: {
    args: (id, reason) => `${text(id)}, ${text(reason)}`,
    irreversible: "Voids a PAID order. The buyer is owed a refund you have to issue yourself.",
  },
  record_delivered: {
    args: (id, blockIndex) => `${text(id)}, ${nat(blockIndex)}`,
    irreversible:
      "Records that cycles reached the buyer. If they did not, this closes the only"
      + " worklist entry that would have said so.",
  },
  resolve_problem: {
    args: (orderId, kindTag, paymentRef) =>
      `${text(orderId)}, ${tag(kindTag)}, ${opt(paymentRef, text)}`,
    irreversible:
      "Marks an obligation settled. Dropping the payment reference over-resolves:"
      + " one order can carry several unresolved problems of the same kind.",
  },
  resolve_orphan: {
    args: (id) => nat(id),
    irreversible: "Marks a payment settled off-chain. Nothing re-opens it.",
  },
  process_order: { args: (id) => text(id) },
  expire_order: {
    args: (id) => text(id),
    irreversible: "Releases the order's reserve capacity and makes it unpayable.",
  },
  refresh_reserve: { args: () => "" },
  refresh_rates: { args: () => "" },
  recount_orders: { args: () => "" },
  withdraw_reserve: {
    args: () => "",
    irreversible:
      "Sends the whole reserve to the caller. It is refused while any order still holds"
      + " a promise, so nothing owed to a buyer can leave. But once it runs the gateway"
      + " sells nothing until the reserve is funded again, and there is no lever that"
      + " brings the cycles back.",
  },
};

/// The methods that take no arguments, derived from the actor rather than listed.
///
/// ⚠️ **The one place a string could have laundered the union.** The console renders
/// these from a table of its own, and a table typed as `CommandMethod` needed a cast at
/// the call — `renderCall(m as "refresh_reserve")` — which is a hand-written claim that
/// the method takes nothing. Adding an argument-bearing method to that table then
/// compiled, and rendered `abandon_order '()'`: a command that runs and does the wrong
/// thing, the exact failure `Parameters<Backend[M]>` exists to make impossible.
export type ArgumentFreeMethod = {
  [M in CommandMethod]: Parameters<Backend[M]> extends readonly [] ? M : never;
}[CommandMethod];

/// The full command line, ready to paste.
///
/// `'(…)'` single-quoted as one shell word, because Candid text contains double quotes
/// and braces that a shell would otherwise eat.
///
/// ⚠️ **An apostrophe inside the payload is escaped, not assumed absent.** The Candid
/// escaping in `text()` is correct for Candid and says nothing about the shell: a single
/// quote in a tier id or an origin would close the quoting early and hand the shell a
/// broken command, in the one surface whose entire purpose is a command that is already
/// right. `'\''` is the POSIX idiom: close, literal quote, reopen.
export function renderCall<M extends CommandMethod>(
  method: M,
  ...args: Parameters<Backend[M]>
): string {
  const body = (COMMANDS[method].args as (...a: unknown[]) => string)(...args);
  const word = `(${body})`.replace(/'/g, `'\\''`);
  return `icp canister call backend ${method} '${word}'`;
}

export function irreversibleNote(method: CommandMethod): string | undefined {
  return COMMANDS[method].irreversible;
}
