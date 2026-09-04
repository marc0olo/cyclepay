// DOM-level tests for main.ts.
//
// `main.ts` is ~800 lines of state machine and DOM wiring with no coverage at all:
// format.test.ts only exercises pure functions. The bugs that live here are
// *reaction* bugs — does the acknowledged quote clear when the tier changes, does
// the cancel button disappear once an order is paid, does the second click after a
// #quoteChanged actually go through — and none of them are visible to a typecheck.
//
// The backend is **stubbed on purpose, and that is not a weakness here.** Its
// behaviour is already proven by 67 PocketIC scenarios; re-proving it in jsdom would
// add nothing. What is unproven is the UI's reaction to it, and a stub is the only
// way to drive those reactions deterministically (a #quoteChanged, a rate that moved,
// a delivered order with a matching receipt).
//
// What this cannot show: that the Candid shapes match reality, or that the page
// works in a real browser. Those need Playwright against `pic.makeLive()` — see
// docs/TEST-COVERAGE.md.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { beforeEach, describe, expect, test, vi } from "vitest";
// Type-only: `vi.mock` replaces the module's VALUES at runtime, so the real module's
// types are still what the stub is checked against.
import { Principal } from "@icp-sdk/core/principal";
import type { Backend } from "./actor";

type OrphanPage = Awaited<ReturnType<Backend["orphans_unresolved"]>>;
type DelayedPage = Awaited<ReturnType<Backend["delayed_deliveries"]>>;
type PendingDeliveries = Awaited<ReturnType<Backend["pending_deliveries"]>>;
type Refusals = Awaited<ReturnType<Backend["refusal_counts"]>>;
type AdminOrdersPage = Awaited<ReturnType<Backend["admin_orders"]>>;

// ── stub state, reconfigured per test ──────────────────────────────────────────

type Quote = {
  usdCents: bigint;
  feeCents: bigint;
  netCents: bigint | undefined;
  cycles: bigint | undefined;
};

/// $10 — the new floor (#33). The old $5 fixture is below it, so `Gate.admit`
/// would refuse it and every downstream assertion would be about the wrong bound.
const TIER_CENTS = 1_000n;
const TIER_CYCLES = 3_500_000_000_000n;

const state = {
  tiers: [{ id: "tier10", usdCents: TIER_CENTS }],
  /// The simulation divisor `pricing_status` reports (#99). `1n` is production,
  /// which is what almost every test wants; the simulation-mode tests set it.
  divisor: 1n,
  /// What `can_purchase` refuses with, or null for admitted (#99).
  canPurchase: null as { __kind__: string } | null,
  quote: {
    usdCents: TIER_CENTS,
    feeCents: 45n,
    netCents: 455n,
    cycles: TIER_CYCLES,
  } as Quote,
  /// What `admin_status` answers. ⚠️ Three states, not two: a controller is not on the
  /// granted list and does not need to be, so "granted" and "isController" are
  /// independent.
  // ⚠️ **Derived from the actor, not restated.** I first hand-wrote these row shapes,
  // which is the same mirror this PR spent four commits removing.
  orphans: { entries: [], nextCursor: undefined } as OrphanPage,
  delayed: { entries: [], nextCursor: undefined } as DelayedPage,
  pending: [] as PendingDeliveries,
  problemOrders: { orders: [], nextCursor: undefined } as AdminOrdersPage,
  /// Captures the cursor `admin_orders` was called with, so a test can assert the pager
  /// restarts on a filter change.
  onAdminOrders: undefined as ((filter: unknown, after: string | null) => void) | undefined,
  refusals: {
    counts: {
      amountAboveMax: 0n,
      stripeApiFailed: 0n,
      unboundedGiveaway: 0n,
      buyerNotAllowed: 0n,
      canisterCyclesLow: 0n,
      amountBelowMin: 0n,
      reserveShort: 0n,
      railClosed: 0n,
      tooManyOpenOrders: 0n,
    },
    refusingNow: {
      stripeApiFailing: false,
      unboundedGiveaway: false,
      canisterCyclesLow: false,
      reserveShort: false,
      railClosed: false,
    },
  } as Refusals,
  /// The nine counts. ⚠️ Split by whether a human is required, not by severity.
  operatorSummary: {
    deliveriesOutstanding: 0n,
    deliveriesDelayed: 0n,
    ordersNeedingReview: 0n,
    orphansUnresolved: 0n,
    problemsUnresolved: 0n,
    ordersWithProblems: 0n,
    refusingNow: {
      reserveShort: false,
      canisterCyclesLow: false,
      railClosed: false,
      stripeApiFailing: false,
      unboundedGiveaway: false,
    },
    availableToSell: 775_000_000_000_000n,
    reserveObservedAtNs: undefined as bigint | undefined,
  },
  adminStatus: {
    // ⚠️ A REAL Principal. I duck-typed this in commit 1 and the untyped `vi.mock`
    // factory accepted it, so the panel was driven by an object the canister cannot
    // return.
    caller: Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"),
    granted: false,
    isController: false,
  },
  transferFee: 100_000_000n,
  transferFeeError: false,
  ckMaxUsdCents: 0n,
  /// When set, the next create_order returns #quoteChanged with this quantity.
  quoteChangedTo: undefined as bigint | undefined,
  /// Captured minCycles from the last create_order call.
  lastMinCycles: undefined as bigint | null | undefined,
  /// Captured destination from the last create_order call — the app builds it
  /// from the session rather than reading it off the form (#29).
  lastDestination: undefined as unknown,
  /// Captured Amount variant, so a test can assert which of the two shapes the
  /// app sent (#33).
  lastAmount: undefined as unknown,
  order: undefined as Record<string, unknown> | undefined,
  receipt: undefined as Record<string, unknown> | undefined,
  /// When set, the next `signIn()` rejects with it.
  signInError: undefined as unknown,
};

/// A session URL and a deadline far in the future, so an order is payable by
/// default. `expiresAtNs` is what the UI renders expiry from — see the deadline
/// tests below.
const SESSION_URL = "https://checkout.stripe.com/c/pay/cs_test_a1b2";
const FUTURE_NS = 4_000_000_000_000_000_000n;

function anOrder(status: string, lockedCycles = TIER_CYCLES) {
  return {
    id: "abcdef0123456789abcdef0123456789",
    owner: { __kind__: "ii", ii: { toText: () => "aaaaa-aa" } },
    rail: "card",
    // The caller's own cycles-ledger account: the only destination `create_order`
    // accepts (#29), so every fixture in this file has this shape.
    destination: {
      __kind__: "cyclesLedgerAccount",
      cyclesLedgerAccount: { owner: { toText: () => "aaaaa-aa" }, subaccount: undefined },
    },
    lockedCycles,
    pricing: {
      usdCents: TIER_CENTS,
      usdPerIcpMicros: 4_550_000n,
      xdrPermyriadPerIcp: 35_000n,
      rateStandardDeviation: 0n,
      rateReceivedRates: 5n,
      rateQueriedSources: 6n,
      feeBps: 290n,
      feeFixedCents: 30n,
    },
    status,
    paidUsdCents: status === "created" || status === "expired" ? undefined : TIER_CENTS,
    expiredBy: undefined,
    expiresAtNs: FUTURE_NS,
    stripeSessionId: "cs_test_a1b2",
    stripeSessionUrl: SESSION_URL,
    createdAtNs: 1_700_000_000_000_000_000n,
    updatedAtNs: 1_700_000_000_000_000_000n,
  };
}

/// ⚠️ **The order-shaped stubs, kept SEPARATE because they cannot be checked yet.**
/// They build `Record<string, unknown>` orders, so typing them needs real `Order`
/// fixtures: substantial, and pre-existing debt rather than anything this PR added.
///
/// The point of separating them is that everything else is checked BY DEFAULT. A new
/// stub added to `backend` below is verified against the real service; adding one here
/// is a deliberate, visible exception. This list should only ever shrink.
const untypedOrderStubs = {
  create_order: async (amount: unknown, dest: unknown, minCycles: bigint | null) => {
    state.lastMinCycles = minCycles;
    state.lastDestination = dest;
    state.lastAmount = amount;
    if (state.quoteChangedTo !== undefined) {
      const quoted = state.quoteChangedTo;
      state.quoteChangedTo = undefined;
      return { __kind__: "err", err: { __kind__: "quoteChanged", quoteChanged: { quoted, minimum: minCycles ?? 0n } } };
    }
    state.order = anOrder("created");
    return { __kind__: "ok", ok: { order: state.order } };
  },
  get_order: async () => state.order ?? null,
  list_orders: async () => ({ orders: state.order ? [state.order] : [], nextCursor: null }),
  cancel_order: async () => {
    state.order = anOrder("cancelled");
    return { __kind__: "ok", ok: state.order };
  },
  receipt: async () => state.receipt ?? null,
  // ⚠️ **`satisfies Partial<Backend>`: `vi.mock`'s factory is UNTYPED, which is exactly
  // how `refusingNow.stripeApiFailed` survived here in two places.** The real field on
  // `RailStateLatch` is `stripeApiFailing`; `stripeApiFailed` belongs to `RefusalCounts`,
  // a different type. The fixtures produced four silent wrong shapes from precisely this
  // cause, so this file gets the same treatment before the worklists grow it.
  //
  // `Partial` checks SHAPES, not completeness: a method the app calls and this object
  // lacks fails at runtime with "not a function", which is loud. The wrong-shape class is
  // the silent one.
};

const typedStubs = {
  card_tiers: async () => state.tiers,
  /// #99: what the gate answers for this caller at the minimum purchase. `null` is
  /// "admitted", which is what almost every test wants.
  // ⚠️ The `as unknown as` hop, for the reason documented on `fixtures.ts`'s
  // boundary: a ternary over the two Result arms widens to a union with optional
  // `undefined` members, so neither direction of assignability holds.
  can_purchase: (async () =>
    state.canPurchase === null
      ? { ok: null }
      : { err: state.canPurchase }) as unknown as Backend["can_purchase"],
  lifecycle_config: async () => ({
    gate: {
      maxOpenOrdersPerPrincipal: 1n,
      minCanisterCycles: 5_000_000_000_000n,
      // The #33 bounds: $10 floor, $100 ceiling.
      minPurchaseUsdCents: 1_000n,
      maxPurchaseUsdCents: 10_000n,
    },
    // ⚠️ Added by the `satisfies`, not by anyone noticing. THIRD location with this same
    // gap: `lifecycle_config` gained `delivery` in #68 step 1, and neither the fixtures
    // nor this stub was updated. Both suites stayed green.
    delivery: { alertAfterNs: 7_200_000_000_000n, maxHoldNs: 259_200_000_000_000n },
  }),
  admin_status: async () => state.adminStatus,
  orphans_unresolved: async (_after: bigint | null, _limit: bigint) => state.orphans,
  delayed_deliveries: async (_after: string | null, _limit: bigint) => state.delayed,
  pending_deliveries: async () => state.pending,
  refusal_counts: async () => state.refusals,
  admin_orders: async (_f: unknown, _a: string | null, _l: bigint) => {
    state.onAdminOrders?.(_f, _a);
    return state.problemOrders;
  },
  operator_summary: async () => state.operatorSummary,
  delivery_stats: async () => ({
    availableToSell: 775_000_000_000_000n,
    deliveredOrders: 0n,
    deliveredCycles: 0n,
    deliveredUsdCents: 0n,
    nullPaid: 0n,
    refusingNow: {
      reserveShort: false,
      canisterCyclesLow: false,
      railClosed: false,
      stripeApiFailing: false,
      unboundedGiveaway: false,
    },
  }),
  pricing_status: async () => ({
    rates: {
      usdPerIcpMicros: 4_550_000n,
      xdrPermyriadPerIcp: 35_000n,
      fetchedAtNs: 1n,
      quality: { standardDeviation: 0n, receivedRates: 5n, queriedSources: 6n },
    },
    // Five fields, not two: the staleness window, the delta bound and the minimum rate
    // sources are part of the pricing config too.
    config: {
      feeBps: 290n,
      feeFixedCents: 30n,
      maxAgeNs: 900_000_000_000n,
      maxRateDeltaBps: 500n,
      minRateSources: 3n,
      divisor: state.divisor,
    },
    lastAttempt: undefined,
  }),
  quote_previews: async (amounts: bigint[]) => ({
    quotes: amounts.map(() => state.quote),
    rates: undefined,
  }),
  // ⚠️ **`vi.mock`'s factory is UNTYPED, which is how `refusingNow.stripeApiFailed`
  // survived here in two places.** The real field on `RailStateLatch` is
  // `stripeApiFailing`; `stripeApiFailed` belongs to `RefusalCounts`, a different type.
  // The fixtures produced four silent wrong shapes from exactly this cause.
  //
  // `Partial` checks SHAPES, not completeness: a method the app calls and this object
  // lacks fails at runtime with "not a function", which is loud. The wrong-shape class is
  // the silent one, and it is the one this closes.
} satisfies Partial<Backend>;

const backend = { ...typedStubs, ...untypedOrderStubs };

/// ⚠️ **A realistic 63-character principal, not `aaaaa-aa`.** `shortPrincipal` only
/// truncates past 16 characters, so a short stub makes every assertion about the
/// truncated-versus-full distinction pass without testing it — including the one that
/// the header copies the FULL value rather than what it displays.
const FULL_PRINCIPAL = "eoyfw-2h5xd-hy7ba-kzsyz-2vhy4-xnpnb-qmowk-vknpi-tsqwc-p7ubm-4qe";
const identity = { getPrincipal: () => ({ toText: () => FULL_PRINCIPAL }) };

vi.mock("./actor", () => ({
  backendCanisterId: "aaaaa-aa",
  makeBackend: () => backend,
  // #30 PR-A: the ledger's fee is read from the LEDGER, not disclosed by
  // `quote_previews`. `state.transferFee` still drives it, so every existing
  // assertion about how the fee is displayed keeps its lever — only where the
  // number comes from changed.
  makeCyclesLedger: () => ({
    icrc1_fee: async () => {
      if (state.transferFeeError) throw new Error("cycles ledger unreachable");
      return state.transferFee;
    },
    icrc1_balance_of: async () => 0n,
  }),
  agentOptions: () => ({}),
  Rail: { card: "card" },
}));
vi.mock("./auth", () => ({
  currentIdentity: async () => identity,
  signIn: async () => {
    if (state.signInError !== undefined) throw state.signInError;
    return identity;
  },
  signOut: async () => undefined,
}));

// ── harness ───────────────────────────────────────────────────────────────────

/// Load the real index.html body, then import main.ts so its `void init()` runs
/// against it. Using the shipped markup rather than a hand-written fixture is the
/// point: a renamed id breaks the test, which is exactly the class of bug that a
/// typecheck cannot see.
/// `from` decides where the visitor is standing. "buy" clicks the landing page's
/// one call to action, the way a visitor reaches the form; "landing" leaves them
/// on the landing view, for the tests that are about routing or sign-in.
///
/// Not a convenience: the purchase flow is hidden until the visitor asks for it,
/// and jsdom neither renders nor respects `hidden`. A test that skips the click
/// still finds every element and still passes, while asserting a path no real
/// visitor can reach.
/// Window listeners the current mount installed, so the next one can detach them.
///
/// jsdom gives one window per FILE, and `main.ts` registers a `hashchange`
/// listener at import. Without this, every earlier test's copy of the app is still
/// listening: they all react to the current test's navigation, each from its own
/// stale module state, and each renders into the one shared document. The visible
/// symptom is a view being hidden by a previous test's idea of where the visitor
/// is — which is indistinguishable from the routing bug under test.
let installedListeners: Array<[string, EventListener]> = [];
const realAddEventListener = window.addEventListener.bind(window);
window.addEventListener = ((type: string, fn: EventListener, opts?: unknown) => {
  installedListeners.push([type, fn]);
  realAddEventListener(type, fn, opts as never);
}) as typeof window.addEventListener;

async function mount(from: "buy" | "landing" = "buy", hash = ""): Promise<void> {
  // jsdom has no layout, so these are absent. main.ts calls them.
  Element.prototype.scrollIntoView ??= () => undefined;
  window.localStorage.clear();
  for (const [type, fn] of installedListeners) window.removeEventListener(type, fn);
  installedListeners = [];
  // jsdom keeps `location` across tests in a file, so a previous test's #/buy
  // would be parsed as the starting route and land the visitor past the landing
  // view a test is about. A real first-time visitor arrives with no hash; `hash`
  // is for the deep-link tests, which need the route to exist BEFORE `init`
  // reads it.
  window.location.hash = hash;
  const html = readFileSync(resolve(__dirname, "..", "index.html"), "utf-8");
  const body = /<body>([\s\S]*)<\/body>/.exec(html);
  if (!body) throw new Error("could not extract <body> from index.html");
  document.body.innerHTML = body[1]!.replace(/<script[\s\S]*?<\/script>/g, "");
  vi.resetModules();
  await import("./main");
  // let init()'s awaits settle
  await new Promise((r) => setTimeout(r, 0));
  if (from === "buy") {
    el("start-buy").click();
    await new Promise((r) => setTimeout(r, 0));
  }
}

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (!node) throw new Error(`missing #${id}`);
  return node as T;
}

function tierButton(): HTMLButtonElement {
  const btn = el("tiers").querySelector<HTMLButtonElement>("button.tier");
  if (!btn) throw new Error("no tier button rendered");
  return btn;
}

async function settle(): Promise<void> {
  await new Promise((r) => setTimeout(r, 0));
}

beforeEach(() => {
  state.divisor = 1n;
  state.canPurchase = null;
  state.quote = { usdCents: TIER_CENTS, feeCents: 45n, netCents: 455n, cycles: TIER_CYCLES };
  state.transferFee = 100_000_000n;
  state.transferFeeError = false;
  state.ckMaxUsdCents = 0n;
  state.quoteChangedTo = undefined;
  state.lastMinCycles = undefined;
  state.lastDestination = undefined;
  state.lastAmount = undefined;
  state.order = undefined;
  state.receipt = undefined;
  state.signInError = undefined;
  state.orphans = { entries: [], nextCursor: undefined };
  state.delayed = { entries: [], nextCursor: undefined };
  state.pending = [];
  state.problemOrders = { orders: [], nextCursor: undefined };
  state.onAdminOrders = undefined;
  state.refusals = {
    counts: {
      amountAboveMax: 0n, stripeApiFailed: 0n, canisterCyclesLow: 0n, amountBelowMin: 0n,
      reserveShort: 0n, railClosed: 0n, tooManyOpenOrders: 0n,
      unboundedGiveaway: 0n, buyerNotAllowed: 0n,
    },
    refusingNow: {
      stripeApiFailing: false,
      unboundedGiveaway: false, canisterCyclesLow: false, reserveShort: false, railClosed: false,
    },
  };
  // ⚠️ Reset here, not spread from the previous test. Leaving these out let one test's
  // `ordersWithProblems` leak into the next and made a data-hook assertion fail for a
  // reason that had nothing to do with the code under test.
  state.adminStatus = {
    caller: Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"),
    granted: false,
    isController: false,
  };
  state.operatorSummary = {
    deliveriesOutstanding: 0n,
    deliveriesDelayed: 0n,
    ordersNeedingReview: 0n,
    orphansUnresolved: 0n,
    problemsUnresolved: 0n,
    ordersWithProblems: 0n,
    refusingNow: {
      reserveShort: false,
      canisterCyclesLow: false,
      railClosed: false,
      stripeApiFailing: false,
      unboundedGiveaway: false,
    },
    availableToSell: 775_000_000_000_000n,
    reserveObservedAtNs: undefined,
  };
});

// ── tests ─────────────────────────────────────────────────────────────────────

describe("tier rendering", () => {
  test("a tier button shows the CYCLE QUANTITY, not the tier id", async () => {
    // The original bug: `label.textContent = tier.id` in the span whose class is
    // literally `cycles`, so a buyer saw "tier5" where the quantity belonged.
    await mount();
    const label = tierButton().querySelector(".cycles")!;
    expect(label.textContent).toContain("3.5 T");
    expect(label.textContent).not.toContain("tier10");
    expect(tierButton().querySelector(".amount")!.textContent).toBe("$10.00");
  });

  test("selecting a tier reveals the fee split and the rate-lock note", async () => {
    await mount();
    expect(el("tier-detail").hidden).toBe(true);
    tierButton().click();
    await settle();
    const detail = el("tier-detail");
    expect(detail.hidden).toBe(false);
    expect(detail.textContent).toContain("$0.45 payment processing");
    expect(detail.textContent).toContain("operator margin: none");
    expect(detail.textContent).toContain("locked when you create the order");
  });

  test("an unpriceable quote disables the submit button with a reason", async () => {
    state.quote = { ...state.quote, cycles: undefined };
    await mount();
    tierButton().click();
    await settle();
    const btn = el<HTMLButtonElement>("create-order");
    expect(btn.disabled).toBe(true);
    expect(btn.textContent).toContain("Pricing unavailable");
  });
});

describe("the deposit fee is disclosed on every order", () => {
  test("the tier label and the destination note both name it, with nothing to toggle", async () => {
    // This used to depend on a radio: a canister top-up paid no deposit fee, so
    // the note appeared only after switching to the account option. With one
    // destination (#29) the fee applies always, so it is stated always — there is
    // no longer a state of this form in which it is hidden.
    await mount();

    // At 3.5 T the 100 M fee is 0.003%, so it rounds away at display precision.
    // The tile therefore states the figure alone: three tiles each repeating
    // "(the cycles ledger takes 100 M…)" above a note saying the same thing is
    // noise around the one number a buyer is choosing between.
    const label = tierButton().querySelector(".cycles")!.textContent!;
    expect(label).toBe("≈ 3.5 T cycles");

    // The note is where the fee is disclosed, and it is unconditional.
    const note = el("dest-fee-note");
    expect(note.hidden).toBe(false);
    expect(note.textContent).toContain("not added to your price");
  });

  test("an unreachable ledger hides the fee rather than inventing one", async () => {
    // #30 PR-A moved the fee from `quote_previews` (always answered, because the
    // backend was already being called) to the cycles ledger (a second canister
    // that can be down on its own). That is a NEW failure mode, and the safe
    // direction is to show the locked quantity with no fee note: shown-too-high
    // costs a buyer nothing, while a guessed fee promises cycles that will not
    // arrive.
    state.transferFeeError = true;
    await mount();
    expect(el("dest-fee-note").hidden).toBe(true);
    // And the tile still prices, because the quote came from the backend.
    expect(tierButton().querySelector(".cycles")!.textContent).toContain("cycles");
  });

  test("a fee large enough to move the figure is shown as a split", async () => {
    state.transferFee = 500_000_000_000n;
    await mount();
    const label = tierButton().querySelector(".cycles")!.textContent!;
    expect(label).toContain("3 T cycles credited");
    // "3.5 T sent", not "minted" (#30 PR-C): the gateway transfers from its reserve.
    expect(label).toContain("3.5 T sent");
    expect(label).not.toContain("minted");
  });
});

describe("quote pinning", () => {
  test("the shown figure is pinned as a 5%-tolerance minimum", async () => {
    await mount();
    tierButton().click();
    await settle();
    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    // 3.5 T less 5%
    expect(state.lastMinCycles).toBe((TIER_CYCLES * 9_500n) / 10_000n);
  });

  test("a moved quote asks for confirmation, and the second click goes through", async () => {
    const moved = 2_500_000_000_000n;
    state.quoteChangedTo = moved;
    await mount();
    tierButton().click();
    await settle();

    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    // Nothing created; the new figure is on screen and the button asks again.
    expect(el("active-order").hidden).toBe(true);
    const notice = el("quote-notice");
    expect(notice.hidden).toBe(false);
    expect(notice.textContent).toContain("2.5 T");
    expect(notice.textContent).toMatch(/nothing was charged/i);
    expect(el<HTMLButtonElement>("create-order").textContent).toContain("Confirm at the new rate");

    // Second click: pinned to the acknowledged figure, and it succeeds.
    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    expect(state.lastMinCycles).toBe((moved * 9_500n) / 10_000n);
    expect(el("active-order").hidden).toBe(false);
    expect(el("quote-notice").hidden).toBe(true);
  });

  test("changing tier clears an acknowledged quote", async () => {
    state.quoteChangedTo = 2_500_000_000_000n;
    await mount();
    tierButton().click();
    await settle();
    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    expect(el("quote-notice").hidden).toBe(false);

    // Re-selecting a tier is a change of intent; the stale acknowledgement must go.
    tierButton().click();
    await settle();
    expect(el("quote-notice").hidden).toBe(true);
    expect(el<HTMLButtonElement>("create-order").textContent).toContain("lock the rate");
  });
});

describe("the active order", () => {
  test("cancel is offered while an order is unpaid", async () => {
    await mount();
    tierButton().click();
    await settle();
    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    expect(el("cancel-area").hidden).toBe(false);
  });

  test("cancel is NOT offered once an order is paid", async () => {
    // Offering it there would promise something untrue: a paid order is going to
    // deliver. Asserted on the rule by opening a paid order; the poll's own
    // arrival at a new status is covered separately, under fake timers installed
    // before the interval exists (see "the POLL finding an order delivered").
    state.order = anOrder("paid");
    await mount();
    el("orders").querySelector("tr")!.dispatchEvent(new Event("click"));
    await settle();
    await settle();
    expect(el("order-status-line").textContent).toContain("Payment received");
    expect(el("cancel-area").hidden).toBe(true);
  });

  test("cancelling reads as cancelled, and closes the order out", async () => {
    // Inverted by #34. Cancelling used to transition to `#expired`, which was
    // still payable — so the copy said a completed payment would still go
    // through, and a buyer who had cancelled was told their order "expired".
    // Now it is its own terminal status: `#cancelled → #paid` is absent from the
    // matrix, so the order genuinely cannot be paid.
    await mount();
    tierButton().click();
    await settle();
    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    el("cancel-order").click();
    await settle();
    await settle();
    expect(el("order-status-line").textContent).toBe("Cancelled");
    expect(el("order-status-line").textContent).not.toMatch(/expired/i);
    expect(el("order-status-line").textContent).not.toMatch(/still goes through/i);
    // Nothing left to cancel, and nothing left to pay.
    expect(el("cancel-area").hidden).toBe(true);
    expect(el("pay-area").hidden).toBe(true);
  });

  test("the locked figure is stated without a '≈', and the locked rate is shown", async () => {
    await mount();
    tierButton().click();
    await settle();
    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    expect(el("order-cycles").textContent).toBe("3.5 T cycles");
    expect(el("order-rate").textContent).toContain("$4.55/ICP");
    expect(el("order-rate").textContent).toContain("locked at creation");
  });
});

describe("receipt", () => {
  test("a delivered order's receipt recomputes and reports a match", async () => {
    state.order = anOrder("delivered");
    state.receipt = {
      order: state.order,
      paidUsdCents: TIER_CENTS,
      cyclesDelivered: TIER_CYCLES,
      deliveryBlockIndex: 42n,
      verification: {
        netCents: 455n,
        usdPerIcpMicros: 4_550_000n,
        xdrPermyriadPerIcp: 35_000n,
        rateReceivedRates: 5n,
        rateQueriedSources: 6n,
      },
    };
    await mount();
    // Reopen the delivered order from history.
    el("orders").querySelector("tr")!.dispatchEvent(new Event("click"));
    await settle();
    await settle();
    expect(el("receipt-area").hidden).toBe(false);
    expect(el("receipt-block").textContent).toBe("42");
    expect(el("receipt-sources").textContent).toContain("5 of 6");
    expect(el("receipt-verdict").textContent).toContain("Verified");
    expect(el("receipt-formula").textContent).toContain("3.5 T");
  });
});

// ── one path in (#29) ─────────────────────────────────────────────────────────

describe("one way into the buy view", () => {
  test("the landing page offers a single call to action, and the form waits behind it", async () => {
    // Asserted first because jsdom ignores `hidden`: every other test in this
    // file would still pass if the landing view stopped gating anything.
    await mount("landing");
    expect(el("buy-flow").hidden).toBe(true);
    expect(el("view-landing").hidden).toBe(false);
    expect(el("start-buy").hidden).toBe(false);
  });

  test("clicking it lands on the form, and the destination is stated rather than asked", async () => {
    await mount("landing");
    el("start-buy").click();
    await settle();
    expect(el("buy-flow").hidden).toBe(false);
    expect(el("view-landing").hidden).toBe(true);
    expect(el("dest-own").hidden).toBe(false);
    expect(window.location.hash).toBe("#/buy");
  });

  test("the form asks nothing at all about where the cycles go", async () => {
    // The chooser, the radios, the canister-id field and the other-account
    // disclosure were all deleted with the destinations they named. Asserted on
    // the real index.html body, so a reintroduced field fails here.
    await mount();
    for (const id of [
      "chooser",
      "choose-new",
      "choose-live",
      "chooser-back",
      "dest-choice",
      "dest-canister",
      "canister-principal",
      "dest-ledger-advanced",
      "ledger-owner",
      "ledger-subaccount",
      "tour-third-party",
    ]) {
      expect(document.getElementById(id), `#${id} is still in the markup`).toBeNull();
    }
    expect(document.querySelectorAll('input[name="dest-kind"]').length).toBe(0);
  });

  test("the order it creates is addressed to the signed-in principal", async () => {
    // The destination is read from the session, not from the form — so this is
    // the assertion that the app cannot send cycles anywhere else. The gateway
    // refuses the alternative too (see the PocketIC scenario); this is the
    // client half.
    await mount();
    tierButton().click();
    await settle();
    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    // Compared through `toText`, not by deep equality: the stubbed principal is
    // a fresh object per call, so its `toText` closure never matches by
    // reference.
    const sent = state.lastDestination as {
      __kind__: string;
      cyclesLedgerAccount: { owner: { toText(): string }; subaccount: unknown };
    };
    expect(sent.__kind__).toBe("cyclesLedgerAccount");
    expect(sent.cyclesLedgerAccount.owner.toText()).toBe(identity.getPrincipal().toText());
    expect(sent.cyclesLedgerAccount.subaccount).toBeUndefined();
  });
});

/// Open a past order the way a returning buyer does — from the history table.
/// The purchase path cannot be used here: the create_order stub replaces
/// state.order with a freshly `created` one, so a delivered fixture set before
/// the click never survives it.
async function openFromHistory(): Promise<void> {
  const row = el("orders").querySelector("tr");
  if (!row) throw new Error("no history row rendered");
  row.click();
  await settle();
}

describe("the delivered tour", () => {
  test("a delivered account order leads with the tour, above the order facts", async () => {
    // The failure this prevents: the bare `icp identity link web dev` form
    // derives a principal from a different origin, so the buyer lands on an
    // empty balance and reads it as theft.
    state.order = anOrder("delivered");
    await mount();
    await openFromHistory();

    expect(el("tour").hidden).toBe(false);
    const cmd = el("cmd-link").textContent ?? "";
    expect(cmd).toContain("icp identity link web");
    // A bare DOMAIN, never an origin with a scheme. Verified against icp-cli
    // 1.2.0: `--app <APP>` is the "Delegation domain (e.g. oisy.com)". Passing
    // `https://host` is not the documented form, and the wrong shape here yields
    // a different principal — the exact failure this command exists to prevent.
    expect(cmd).toContain(`--app ${window.location.host}`);
    expect(cmd).not.toContain("--app http");
    // And never omitted: without it icp-cli lets the auth domain pick its own
    // default, which is a different principal again.
    expect(cmd).toContain("--app");
    // The principal is shown beside it so a mismatch is self-diagnosable.
    expect(el("credited-principal").textContent).toBe("aaaaa-aa");
    // Verified against icp-cli 1.2.0, not invented: `icp identity principal`
    // exists and takes --identity. The link command is NOT claimed to print a
    // principal, because the CLI guide does not say it does.
    expect(el("cmd-verify").textContent).toBe("icp identity principal --identity dev");
    // Order matters: on delivery the next action leads and the facts collapse.
    const details = el<HTMLDetailsElement>("order-details");
    expect(details.open).toBe(false);
    expect(el("tour").compareDocumentPosition(details) & Node.DOCUMENT_POSITION_FOLLOWING)
      .toBeTruthy();
  });

  test("an undelivered order shows no commands yet", async () => {
    state.order = anOrder("paid");
    await mount();
    await openFromHistory();
    expect(el("tour").hidden).toBe(true);
  });

  test("the POLL finding an order delivered brings up the tour", async () => {
    // The defect this pins. A buyer creating an order and paying never navigates
    // again: the poll is what discovers `delivered`. It updated the order facts
    // and left the view machine unrun, so the tour, the stepper state and the
    // collapsed facts — the whole delivered view — appeared only if you reopened
    // the order from history. Every earlier test did exactly that, which is why
    // none of them saw it.
    state.order = anOrder("paid");
    await mount();
    // Fake timers must be installed BEFORE `openOrder` creates the interval;
    // vitest cannot control one created under real timers.
    vi.useFakeTimers();
    try {
      el("orders").querySelector("tr")!.click();
      await vi.advanceTimersByTimeAsync(0);
      expect(el("active-order").hidden).toBe(false);
      expect(el("tour").hidden).toBe(true);

      // The gateway delivers. The visitor does nothing.
      state.order = anOrder("delivered");
      await vi.advanceTimersByTimeAsync(7_000); // two 3 s poll intervals

      expect(el("tour").hidden).toBe(false);
      expect(el("cmd-link").textContent).toContain("icp identity link web");
      // Step 3 is now the current one, and the facts have collapsed under it.
      expect(el("stepper").querySelectorAll(".step")[2]!.className).toContain("current");
      expect(el<HTMLDetailsElement>("order-details").open).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  test("a poll tick cannot repaint the order over a view the visitor moved to", async () => {
    // `renderOrder` unhid `#active-order` itself while `renderView` also owned it.
    // Two owners of one decision: a tick arriving after the visitor navigated to
    // their orders painted the order back over the table.
    await mount();
    vi.useFakeTimers();
    try {
      tierButton().click();
      await vi.advanceTimersByTimeAsync(0);
        el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
      await vi.advanceTimersByTimeAsync(0);
      expect(el("active-order").hidden).toBe(false);

      // The header link routes synchronously, which is the path a click takes.
      el("history-link").click();
      expect(el("active-order").hidden).toBe(true);
      expect(el("history").hidden).toBe(false);

      state.order = anOrder("paid");
      await vi.advanceTimersByTimeAsync(7_000);
      expect(el("active-order").hidden).toBe(true);
      expect(el("history").hidden).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("sign-in failures are explained wherever they start", () => {
  /// The header button and the CTA can fail the same three ways, and the header
  /// one used to swallow all of them. A button that does nothing when clicked is
  /// the worst of the outcomes: it reads as the app ignoring you.
  async function signOutInHeader(): Promise<void> {
    // ⚠️ By id, not by position. This read `querySelector("button")` and therefore
    // meant "whichever button comes first", which stopped being Sign out the moment a
    // copy button was added beside the principal.
    el<HTMLButtonElement>("sign-out").click();
    await settle();
  }

  async function signInInHeader(): Promise<void> {
    el<HTMLButtonElement>("sign-in").click();
    await settle();
  }

  test("the header reports a blocked pop-up in the CTA's own words", async () => {
    await mount("landing");
    await signOutInHeader();
    state.signInError = new Error("popup was blocked by the browser");
    await signInInHeader();
    const error = el("auth-error");
    expect(error.hidden).toBe(false);
    expect(error.textContent).toMatch(/allow pop-ups/i);
  });

  test("the header distinguishes a cancelled sign-in from an unreachable one", async () => {
    // The distinction that matters: cancelling needs no action, so reporting it
    // for an unreachable provider tells the user to relax about a real problem.
    await mount("landing");
    await signOutInHeader();
    state.signInError = new Error("UserInterrupt");
    await signInInHeader();
    expect(el("auth-error").textContent).toMatch(/cancelled/i);

    state.signInError = new Error("connection reset");
    await signInInHeader();
    expect(el("auth-error").textContent).toMatch(/could not reach the sign-in service/i);
  });

  test("a successful sign-in clears the previous failure", async () => {
    await mount("landing");
    await signOutInHeader();
    state.signInError = new Error("UserInterrupt");
    await signInInHeader();
    expect(el("auth-error").hidden).toBe(false);

    state.signInError = undefined;
    await signInInHeader();
    expect(el("auth-error").hidden).toBe(true);
  });
});

describe("routes that name nothing", () => {
  test("#/buy resolves straight to the form, deep-linked or reloaded", async () => {
    // It used to redirect to the landing page: with no arm chosen the form had no
    // destination question on it at all, so an armless `#/buy` was incomplete.
    // With one destination the form is complete on arrival, and a bookmark of it
    // has to work.
    await mount("landing");
    window.location.hash = "#/buy";
    await settle();
    expect(el("buy-flow").hidden).toBe(false);
    expect(el("view-landing").hidden).toBe(true);
  });

  test("a reload on an order deep link resolves it as the SIGNED-IN buyer", async () => {
    // `get_order` answers per caller. Resolving the route before the session was
    // restored looked the order up anonymously, got nothing, and landed the owner
    // on "we could not find that order" — on a plain reload of their own order.
    state.order = anOrder("delivered");
    // No call-to-action click: that would navigate to the buy view and throw the
    // deep link away, which is the whole thing under test.
    await mount("landing", "#/order/abcdef0123456789abcdef0123456789");
    await settle();
    expect(el("order-missing").hidden).toBe(true);
    expect(el("active-order").hidden).toBe(false);
    expect(el("tour").hidden).toBe(false);
  });

  test("an unknown order id says so rather than showing the last one", async () => {
    state.order = anOrder("delivered");
    await mount();
    await openFromHistory();
    expect(el("active-order").hidden).toBe(false);

    // The gateway holds no such order.
    state.order = undefined;
    window.location.hash = "#/order/deadbeefdeadbeefdeadbeefdeadbeef";
    await settle();
    await settle();
    expect(el("active-order").hidden).toBe(true);
    expect(el("order-missing").hidden).toBe(false);
    expect(el("order-missing-detail").textContent).toMatch(/not one this gateway holds/i);
  });
});

describe("buy again", () => {
  test("prefills the amount from a past order without submitting", async () => {
    // One click plus payment is the shortest flow the design allows for a repeat
    // buyer. It must NOT submit: the price is re-quoted at today's rate and the
    // buyer has to see the number.
    //
    // The amount is now the whole prefill. The destination used to be carried
    // across too — a canister id, or an owner and subaccount pair — and there is
    // nothing left to carry: every order goes to the caller's own account (#29).
    state.order = anOrder("delivered");
    await mount();
    const again = el("orders").querySelector<HTMLButtonElement>("button.buy-again");
    expect(again).not.toBeNull();
    again!.click();
    await settle();

    expect(tierButton().classList.contains("selected")).toBe(true);
    // Still on the form, not on a fresh order.
    expect(el("buy-flow").hidden).toBe(false);
  });

  test("driven from the history view, it lands the visitor on the form", async () => {
    // The masked defect. `repeatOrder` prefilled and never navigated, and the
    // original test mounted on the buy view — so "the form is on screen" passed
    // because the form had never left. From the history view, where the button
    // actually lives, the prefill happened on a screen nobody was looking at.
    state.order = anOrder("delivered");
    await mount();
    window.location.hash = "#/history";
    await settle();
    expect(el("history").hidden).toBe(false);

    el("orders").querySelector<HTMLButtonElement>("button.buy-again")!.click();
    await settle();

    expect(el("buy-flow").hidden).toBe(false);
    expect(el("history").hidden).toBe(true);
    expect(window.location.hash).toBe("#/buy");
    expect(tierButton().classList.contains("selected")).toBe(true);
  });

  test("clicking buy again does not also open the order row", async () => {
    // Both handlers live on the same row; without stopPropagation the prefill is
    // immediately replaced by the order view.
    state.order = anOrder("delivered");
    await mount();
    el("orders").querySelector<HTMLButtonElement>("button.buy-again")!.click();
    await settle();
    expect(el("active-order").hidden).toBe(true);
  });
});

describe("the rate strip never contradicts the tiers", () => {
  test("a cached but unusable rate is not printed as if it were live", async () => {
    // Found on a real local network: the strip read "ICP $4.55 · 3.5000 XDR/ICP"
    // directly above three tiles each saying "No exchange rate available right
    // now". `pricing_status.rates` returns the LAST pair fetched even when the
    // most recent refresh failed, so rendering on its presence alone had the page
    // quoting a price it would refuse to honour.
    state.quote = { usdCents: TIER_CENTS, feeCents: 45n, netCents: 455n, cycles: undefined };
    await mount();

    const strip = el("rate-line").textContent ?? "";
    expect(strip).toMatch(/no exchange rate/i);
    expect(strip).not.toContain("XDR/ICP");
    // And the tiers agree, which is the whole point.
    expect(tierButton().querySelector(".cycles")!.textContent).toMatch(/no exchange rate/i);
  });

  test("a usable rate is printed in full", async () => {
    await mount();
    const strip = el("rate-line").textContent ?? "";
    expect(strip).toContain("XDR/ICP");
    expect(strip).not.toMatch(/no exchange rate/i);
  });
});

// ── paying an order, and still being able to after a reload (#33) ─────────────

describe("the pay button comes from the ORDER, not from browser memory", () => {
  test("a created order with a session offers it, pointing at Stripe's URL", async () => {
    await mount();
    tierButton().click();
    await settle();
    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    expect(el("pay-area").hidden).toBe(false);
    expect(el<HTMLAnchorElement>("pay-link").getAttribute("href")).toBe(SESSION_URL);
  });

  test("A RELOAD KEEPS IT — the defect this replaces", async () => {
    // THE REGRESSION. The URL used to live in a session-scoped `Map` populated
    // only when `create_order` returned, so any reload lost the pay button on an
    // order that was still payable — and with a one-open-order cap the buyer
    // could not even start over. Found in a real manual run, not by a test.
    //
    // Opening from history is the reload: `create_order` never ran in this
    // session, so nothing could have been cached.
    state.order = anOrder("created");
    await mount();
    await openFromHistory();
    expect(el("pay-area").hidden).toBe(false);
    expect(el<HTMLAnchorElement>("pay-link").getAttribute("href")).toBe(SESSION_URL);
  });

  test("the payment reference is shown, derived rather than handed back", async () => {
    // It is the reference on the buyer's card receipt, so it stays on screen —
    // but `create_order` no longer returns it (#33 dropped a Payment-Link relic
    // from a public response type), so the page computes it.
    state.order = anOrder("created");
    await mount();
    await openFromHistory();
    // ⚠️ Derived from the identity rather than hardcoded. This read
    // `"aaaaa-aa_abcdef…"`, a literal copy of a principal defined 700 lines above —
    // so changing the stub identity broke it, which is the mirror this repo keeps
    // removing. The reference is `<principal>_<orderId>` and both halves come from
    // their sources.
    expect(el("client-ref").textContent)
      .toBe(`${FULL_PRINCIPAL}_abcdef0123456789abcdef0123456789`);
  });

  test("no session yet means no button, rather than a broken one", async () => {
    const noSession = anOrder("created") as Record<string, unknown>;
    noSession.stripeSessionUrl = undefined;
    noSession.expiresAtNs = undefined;
    state.order = noSession;
    await mount();
    await openFromHistory();
    expect(el("pay-area").hidden).toBe(true);
  });
});

describe("expiry renders from the DEADLINE, not the status", () => {
  test("past expiresAtNs the pay button is gone, even while status is created", async () => {
    // An order can sit in `#created` past its deadline whenever the
    // `checkout.session.expired` webhook is late or lost. Stripe has closed the
    // session on its own clock, so offering the button would send the buyer to
    // spend money the gateway would then have to refund.
    const stale = anOrder("created") as Record<string, unknown>;
    stale.expiresAtNs = 1_700_000_000_000_000_000n; // long past
    state.order = stale;
    await mount();
    await openFromHistory();
    expect(el("pay-area").hidden).toBe(true);
    // And the page SAYS expired rather than "Awaiting payment", which would tell
    // the buyer to do something that cannot work.
    expect(el("order-status-line").textContent).toMatch(/expired/i);
    // Cancel is hidden too, and that is deliberate rather than incidental:
    // Stripe's expire endpoint accepts open sessions only, so past the deadline
    // `cancel_order` can only fail. A button that always fails is worse than
    // none. (Freeing the buyer's slot in this state is #30's open-order-cap work.)
    expect(el("cancel-area").hidden).toBe(true);
  });
});

// ── custom amounts, bounded by the BACKEND's numbers (#33) ────────────────────

describe("a buyer can type an amount", () => {
  function customField(): HTMLInputElement {
    return el<HTMLInputElement>("custom-amount");
  }

  async function type(value: string): Promise<void> {
    customField().value = value;
    customField().dispatchEvent(new Event("input"));
    await settle();
  }

  test("the range shown is the gate's, not a number written in the frontend", async () => {
    // A second copy of the bounds would drift from `Gate.admit`, which is the one
    // that decides. So the label is rendered from lifecycle_config.
    await mount();
    expect(el("custom-amount-range").textContent).toBe("Any amount from $10.00 to $100.00");
    expect(customField().disabled).toBe(false);
  });

  test("a usable amount is quoted by the BACKEND and becomes the order", async () => {
    await mount();
    await type("25");
    expect(el("custom-amount-error").hidden).toBe(true);
    // Priced through quote_previews — the same code create_order calls — so what
    // the buyer sees and what the gateway locks cannot disagree.
    expect(el("tier-detail").hidden).toBe(false);

    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    expect(state.lastAmount).toEqual({ __kind__: "custom", custom: 2_500n });
  });

  test("below the floor and above the ceiling both refuse, in the buyer's terms", async () => {
    await mount();
    await type("5");
    expect(el("custom-amount-error").hidden).toBe(false);
    expect(el("custom-amount-error").textContent).toContain("between $10.00 and $100.00");
    expect(el<HTMLButtonElement>("create-order").textContent).toContain("Pick an amount");

    await type("500");
    expect(el("custom-amount-error").hidden).toBe(false);
  });

  test("exactly one amount is ever chosen, in both directions", async () => {
    // Two selected amounts would make "what am I buying" ambiguous, and the
    // submit path would have to pick one.
    await mount();
    tierButton().click();
    await settle();
    expect(tierButton().classList.contains("selected")).toBe(true);

    await type("25");
    // Typing cleared the tile.
    expect(tierButton().classList.contains("selected")).toBe(false);

    tierButton().click();
    await settle();
    // And the tile cleared the field.
    expect(customField().value).toBe("");
    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    expect(state.lastAmount).toEqual({ __kind__: "tier", tier: "tier10" });
  });

  test("clearing the field goes back to needing a choice", async () => {
    await mount();
    await type("25");
    await type("");
    expect(el("custom-amount-error").hidden).toBe(true);
    expect(el<HTMLButtonElement>("create-order").textContent).toContain("Pick an amount");
  });
});

describe("the deadline is a countdown, not a timestamp", () => {
  test("a payable order shows the time remaining and warns about the edge", async () => {
    // Thirty-five minutes is short enough that "reserved until 14:32" misleads a
    // buyer who looked away — and one who starts paying near the deadline loses
    // the attempt, so the copy has to say so.
    const soon = anOrder("created") as Record<string, unknown>;
    soon.expiresAtNs = BigInt(Date.now() + 10 * 60_000) * 1_000_000n;
    state.order = soon;
    await mount();
    await openFromHistory();
    expect(el("order-deadline").hidden).toBe(false);
    expect(el("order-deadline").textContent).toMatch(/9 min|10 min/);
    expect(el("order-deadline").textContent).toMatch(/not charged/i);
  });

  test("no countdown once the order is past payment", async () => {
    // A timer next to "Delivered" would read as something still at risk.
    state.order = anOrder("delivered");
    await mount();
    await openFromHistory();
    expect(el("order-deadline").hidden).toBe(true);
  });
});

describe("operator console (#68)", () => {
  test("#/admin owns the screen, and the buyer views are not on it", async () => {
    await mount("landing", "#/admin");
    expect(el("admin").hidden).toBe(false);
    // ⚠️ One view owns the screen. This is the property #24 broke by hiding with
    // `hidden` and un-hiding with a class; the browser suite is what can see that,
    // and this only says the attribute is right.
    expect(el("view-landing").hidden).toBe(true);
    expect(el("history").hidden).toBe(true);
    expect(el("buy-flow").hidden).toBe(true);
  });

  test("an ungranted identity is told its own principal and what to do with it", async () => {
    state.adminStatus = {
      caller: Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"),
      granted: false,
      isController: false,
    };
    await mount("landing", "#/admin");
    expect(el("admin-principal").textContent).toBe("ryjl3-tyaaa-aaaaa-aaaba-cai");
    expect(el("admin-grant-state").textContent).toMatch(/Not granted/);
    expect(el("admin-grant-state").textContent).toMatch(/controller, who can grant it/);
  });

  test("a granted identity is told what it can and cannot do", async () => {
    state.adminStatus = {
      caller: Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"),
      granted: true,
      isController: false,
    };
    await mount("landing", "#/admin");
    const text = el("admin-grant-state").textContent ?? "";
    expect(text).toMatch(/Granted operator access/);
    // The tier split, in the operator's words: cases yes, rules no.
    expect(text).toMatch(/changing configuration or secrets is not/);
  });

  test("⚠️ a controller is NOT reported as ungranted", async () => {
    // The tiers are nested. A controller passes the admin guard without being on the
    // list, so "not granted" would be true and useless.
    state.adminStatus = {
      caller: Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"),
      granted: false,
      isController: true,
    };
    await mount("landing", "#/admin");
    const text = el("admin-grant-state").textContent ?? "";
    expect(text).toMatch(/A controller of this canister/);
    expect(text).not.toMatch(/Not granted/);
  });

  test("⚠️ the link command carries --app with THIS page's domain", async () => {
    // #83: Internet Identity derives a principal per origin, and without `--app` the
    // CLI links one derived from the auth domain's own default. That principal is not
    // the one shown above it, so the grant would land on the wrong identity.
    await mount("landing", "#/admin");
    const command = el("admin-link-command").textContent ?? "";
    expect(command).toContain("icp identity link web");
    expect(command).toContain(`--app ${window.location.host}`);
    expect(el("admin-link-note").textContent).toMatch(/must be this page's own domain/);
  });
});

describe("operator summary: wait versus work (#68)", () => {
  const figures = (id: string): Record<string, string> => {
    const out: Record<string, string> = {};
    const dl = el(id);
    const dts = [...dl.querySelectorAll("dt")];
    const dds = [...dl.querySelectorAll("dd")];
    dts.forEach((dt, i) => (out[dt.textContent ?? ""] = dds[i]?.textContent ?? ""));
    return out;
  };

  test("⚠️ the two groups are split by whether a human is required, not by severity", async () => {
    state.operatorSummary = {
      ...state.operatorSummary,
      ordersNeedingReview: 2n,
      orphansUnresolved: 1n,
      problemsUnresolved: 3n,
      ordersWithProblems: 2n,
      deliveriesOutstanding: 7n,
      deliveriesDelayed: 4n,
    };
    await mount("landing", "#/admin");

    const act = figures("summary-act-figures");
    const wait = figures("summary-wait-figures");
    // A self-clearing retry ranked beside an unattributed payment is the mistake the
    // grouping exists to prevent: one is waiting, the other is owed an answer.
    expect(act["Orders under review"]).toBe("2");
    expect(act["Payments not attributed"]).toBe("1");
    expect(act["Open problems"]).toBe("3");
    expect(wait["Deliveries outstanding"]).toBe("7");
    expect(wait["Deliveries past the alert threshold"]).toBe("4");
    // And neither group carries the other's figures.
    expect(act["Deliveries outstanding"]).toBeUndefined();
    expect(wait["Orders under review"]).toBeUndefined();
  });

  test("the headline answers the question in words", async () => {
    state.operatorSummary = {
      ...state.operatorSummary,
      ordersNeedingReview: 0n,
      orphansUnresolved: 0n,
      problemsUnresolved: 0n,
      deliveriesOutstanding: 9n,
    };
    await mount("landing", "#/admin");
    // ⚠️ Nine deliveries in flight and nothing owed: the headline must not read as work.
    expect(el("summary-headline").textContent).toBe("Nothing needs a person right now.");

    state.operatorSummary = { ...state.operatorSummary, orphansUnresolved: 1n };
    await mount("landing", "#/admin");
    expect(el("summary-headline").textContent).toBe("One thing needs a person.");

    state.operatorSummary = { ...state.operatorSummary, problemsUnresolved: 2n };
    await mount("landing", "#/admin");
    expect(el("summary-headline").textContent).toBe("3 things need a person.");
  });

  test("zero and non-zero carry a data hook, which is what the browser suite reads", async () => {
    state.operatorSummary = {
      ...state.operatorSummary,
      ordersNeedingReview: 0n,
      orphansUnresolved: 5n,
      problemsUnresolved: 0n,
    };
    await mount("landing", "#/admin");
    const dds = [...el("summary-act-figures").querySelectorAll("dd")];
    expect(dds.map((d) => (d as HTMLElement).dataset.zero)).toEqual([
      "true", "false", "true", "true",
    ]);
    // ⚠️ This is a DATA attribute, not evidence an operator can see a difference. That
    // claim needs cascade and layout, so it is asserted in the Chromium suite.
  });

  test("an unobserved reserve says so rather than printing a time", async () => {
    state.operatorSummary = { ...state.operatorSummary, reserveObservedAtNs: undefined };
    await mount("landing", "#/admin");
    expect(el("summary-reserve").textContent).toMatch(/never observed/);
  });
});

describe("worklists (#68)", () => {
  const rows = (id: string) => [...el(id).querySelectorAll("li")];
  const granted = {
    caller: Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"),
    granted: true,
    isController: false,
  };

  test("⚠️ an ungranted identity is told WHY the lists are absent", async () => {
    // Four empty lists would read as "nothing to do", which is the opposite of the truth
    // for a caller the canister refuses.
    await mount("landing", "#/admin");
    expect(el("worklists").hidden).toBe(true);
    expect(el("worklists-locked").hidden).toBe(false);
    expect(el("worklists-locked").textContent).toMatch(/would read as nothing to do/);
  });

  test("a granted identity gets the lists, and each row carries what its state means", async () => {
    state.adminStatus = granted;
    state.orphans = {
      entries: [
        {
          id: 7n,
          kind: {
            __kind__: "unattributed",
            unattributed: { claimedRef: "bogus", paymentRef: "pi_x" },
          },
          rail: "card",
          createdAtNs: 1n,
          resolvedAtNs: undefined,
          detail: "no order for pi_x",
        },
      ],
      nextCursor: undefined,
    } as never;
    await mount("landing", "#/admin");

    expect(el("worklists").hidden).toBe(false);
    const orphanRows = rows("wl-orphans-rows");
    expect(orphanRows).toHaveLength(1);
    expect(orphanRows[0]!.textContent).toContain("Payment 7");
    // ⚠️ The hint is INLINE: the console must not send anyone to RUNBOOK mid-incident.
    expect(orphanRows[0]!.textContent).toMatch(/could not be attributed/);
    expect(orphanRows[0]!.textContent).toMatch(/Refund it/);
    // Needs a person, carried as data for the stylesheet to key off.
    expect((orphanRows[0] as HTMLElement).dataset.urgency).toBe("act");
  });

  test("⚠️ one row per unresolved PROBLEM, not per order", async () => {
    // `resolve_problem` takes a kind, so an order with two open problems is two
    // obligations. Collapsing them to one row would hide one.
    state.adminStatus = granted;
    state.problemOrders = {
      orders: [
        {
          id: "abc123",
          problems: [
            {
              filedAtNs: 1n,
              kind: { __kind__: "duplicate", duplicate: { paymentRef: "pi_a" } },
              detail: "second charge",
              resolvedAtNs: undefined,
            },
            {
              filedAtNs: 2n,
              kind: { __kind__: "deliveryStuck", deliveryStuck: { stage: "transfer" } },
              detail: "stuck mid transfer",
              resolvedAtNs: undefined,
            },
            {
              filedAtNs: 3n,
              kind: { __kind__: "duplicate", duplicate: { paymentRef: "pi_b" } },
              detail: "RESOLVED_ROW_MARKER",
              resolvedAtNs: 9n,
            },
          ],
        },
      ],
      nextCursor: undefined,
    } as never;
    await mount("landing", "#/admin");

    expect(rows("wl-problems-rows")).toHaveLength(2);
    const text = el("wl-problems-rows").textContent ?? "";
    expect(text).toContain("duplicate");
    expect(text).toContain("deliveryStuck");
    // The resolved one is absent, so a cleared obligation does not read as outstanding.
    // ⚠️ A deliberately unmistakable marker: my first version asserted the absence of
    // "already handled", which is also a phrase inside the `duplicate` HINT, so the test
    // failed on its own copy rather than on the behaviour.
    expect(text).not.toContain("RESOLVED_ROW_MARKER");
  });

  test("the self-clearing lists say so at the section level", async () => {
    state.adminStatus = granted;
    await mount("landing", "#/admin");
    // ⚠️ Section-level because every row in these two is the same state. A per-row hint
    // would repeat identically; a section hint on the MIXED lists would describe the first
    // row and mislead about the rest, which is why those are per-row.
    expect(el("wl-pending-note").textContent).toMatch(/Clears itself/);
    expect(el("wl-delayed-note").textContent).toMatch(/worth reading/);
  });

  test("refusal counts render only what has happened, each with its meaning", async () => {
    state.refusals = {
      counts: {
        amountAboveMax: 0n,
        stripeApiFailed: 0n,
        unboundedGiveaway: 0n,
        buyerNotAllowed: 0n,
        canisterCyclesLow: 0n,
        amountBelowMin: 4n,
        reserveShort: 2n,
        railClosed: 0n,
        tooManyOpenOrders: 0n,
      },
      refusingNow: {
        stripeApiFailing: false,
        unboundedGiveaway: false,
        canisterCyclesLow: false,
        reserveShort: false,
        railClosed: false,
      },
    };
    await mount("landing", "#/admin");
    const text = el("refusal-rows").textContent ?? "";
    expect(text).toContain("amountBelowMin: 4");
    expect(text).toContain("reserveShort: 2");
    // Zeroes are not news, so they are not rows.
    expect(text).not.toContain("railClosed");
    // ⚠️ reserveShort's hint names the step that actually gets forgotten.
    expect(text).toMatch(/refresh_reserve/);
  });
});

describe("order history (#68)", () => {
  const rows = () => [...el("admin-history-rows").querySelectorAll("li")];
  const granted = {
    caller: Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"),
    granted: true,
    isController: false,
  };

  const anOrder = (id: string, status: string) => ({
    id,
    status,
    lockedCycles: 3_500_000_000_000n,
    paidUsdCents: 1_000n,
    createdAtNs: 1_700_000_000_000_000_000n,
    problems: [],
  });

  test("rows carry the status and what it means", async () => {
    state.adminStatus = granted;
    state.problemOrders = {
      orders: [anOrder("aaa111", "needsReview")],
      nextCursor: undefined,
    } as never;
    await mount("landing", "#/admin");
    expect(rows()).toHaveLength(1);
    const text = rows()[0]!.textContent ?? "";
    expect(text).toContain("needsReview");
    // ⚠️ The status hint, inline: needsReview is the one where acting on the wrong
    // assumption costs money, so the row says establish the fate first.
    expect(text).toMatch(/money position is unknown/);
    expect(text).toMatch(/record_delivered with the block/);
    expect((rows()[0] as HTMLElement).dataset.urgency).toBe("act");
  });

  test("a self-clearing status is not dressed as work", async () => {
    state.adminStatus = granted;
    state.problemOrders = { orders: [anOrder("bbb222", "paid")], nextCursor: undefined } as never;
    await mount("landing", "#/admin");
    expect((rows()[0] as HTMLElement).dataset.urgency).toBe("wait");
  });

  test("⚠️ after a filter change, Load more pages the NEW filter, not the old one", async () => {
    // Paging the new filter from the old filter's position skips rows silently rather
    // than erroring, which is the worst shape for a history someone is auditing.
    //
    // ⚠️ My first version of this asserted that changing a filter passes a null cursor.
    // That passes unconditionally: a non-append load always passes null. Removing the
    // `historyCursor = null` it was "guarding" changed no test, which is how the dead
    // code and the vacuous assertion were both found. This asserts the step that can
    // actually be wrong.
    state.adminStatus = granted;
    state.problemOrders = {
      orders: [anOrder("aaa111", "delivered")],
      nextCursor: "CURSOR_FROM_FILTER_A",
    } as never;
    await mount("landing", "#/admin");
    expect(el("admin-history-more").hidden).toBe(false);

    // Switch filters; the new filter's first page carries its own cursor.
    state.problemOrders = {
      orders: [anOrder("bbb222", "paid")],
      nextCursor: "CURSOR_FROM_FILTER_B",
    } as never;
    (el("filter-status") as HTMLSelectElement).value = "paid";
    el("filter-status").dispatchEvent(new Event("change"));
    await new Promise((r) => setTimeout(r, 0));

    const seen: Array<string | null> = [];
    state.onAdminOrders = (_f, after) => seen.push(after);
    el("admin-history-more").click();
    await new Promise((r) => setTimeout(r, 0));
    expect(seen).toEqual(["CURSOR_FROM_FILTER_B"]);
  });

  test("an ungranted identity is told, rather than shown an empty history", async () => {
    await mount("landing", "#/admin");
    expect(el("admin-history-locked").hidden).toBe(false);
    expect(el("admin-history-locked").textContent).toMatch(/needs operator access/);
    expect(rows()).toHaveLength(0);
  });
});

describe("simulation mode says so, in words (#99 2h)", () => {
  test("production shows no simulation note at all", async () => {
    await mount();
    // ⚠️ `hidden`, not absence: jsdom neither renders nor respects `hidden`, so a
    // test that only checked for the element would pass in either mode. And the
    // text is asserted empty-of-claim too, in case a future render sets it
    // unconditionally and relies on `hidden` alone.
    const note = document.getElementById("simulation-note")!;
    expect(note.hidden).toBe(true);
    const cap = document.getElementById("trust-capacity-note")!;
    expect(cap.hidden).toBe(true);
  });

  test("⚠️ simulation mode states the scale on the buy view, as a sentence", async () => {
    state.divisor = 1_000n;
    await mount();
    const note = document.getElementById("simulation-note")!;
    expect(note.hidden).toBe(false);
    // The three things a buyer needs: that it is a test environment, the scale,
    // and that no real money moves.
    expect(note.textContent).toMatch(/test environment/i);
    expect(note.textContent).toContain("1/1000");
    expect(note.textContent).toMatch(/no money moves/i);
  });

  test("the available-to-sell figure gets its one sentence of explanation", async () => {
    // Without it the ratio between a real reserve and a scaled quote reads as a
    // bug: 775 T available while $10 buys 7 G.
    state.divisor = 1_000n;
    await mount();
    const cap = document.getElementById("trust-capacity-note")!;
    expect(cap.hidden).toBe(false);
    expect(cap.textContent).toMatch(/real reserve/i);
    expect(cap.textContent).toContain("1000");
  });
});

describe("the gate notice: refusals no amount can fix (#99 2b)", () => {
  test("an admitted caller sees no notice", async () => {
    await mount();
    expect(document.getElementById("gate-notice")!.hidden).toBe(true);
  });

  test("⚠️ an uninvited tester is told BEFORE picking an amount", async () => {
    // The criterion this exists for: an unlisted buyer used to pick an amount, sign
    // in and press Buy to find out.
    state.canPurchase = { __kind__: "buyerNotAllowed", buyerNotAllowed: null } as never;
    await mount();
    const notice = document.getElementById("gate-notice")!;
    expect(notice.hidden).toBe(false);
    expect(notice.textContent).toMatch(/testers/i);
    // ⚠️ **No "nothing was charged" before an attempt.** True after one and
    // misleading before: it implies a purchase was tried and reversed, at exactly the
    // moment the page is trying to be clear. `gateReasonMessage` keeps that clause for
    // the after-attempt path; this notice reads from a separate table.
    expect(notice.textContent).not.toMatch(/charged/i);
  });

  test("the faucet refusal is shown too, and does NOT mention an allow-list", async () => {
    // Every buyer is refused in that state, so naming a list would send this one
    // asking for access that would not help.
    state.canPurchase = {
      __kind__: "unboundedGiveaway",
      unboundedGiveaway: { reserveFloor: 1n },
    } as never;
    await mount();
    const notice = document.getElementById("gate-notice")!;
    expect(notice.hidden).toBe(false);
    expect(notice.textContent).not.toMatch(/allow|invited|tester/i);
    expect(notice.textContent).not.toMatch(/charged/i);
    // ⚠️ And no operator vocabulary: a buyer must not be told the gateway is an
    // "unbounded giveaway" or read a description of the faucet. brand-lint checks
    // characters, not audience, so nothing else catches this.
    expect(notice.textContent).not.toMatch(/giveaway|faucet|reserve|allow-list/i);
  });

  test("⚠️ a VOLATILE refusal is NOT pre-announced — the existing rule still holds", async () => {
    // `#reserveShort` names how much is available, so a smaller amount may work, and
    // the figure would be stale by construction in a banner. It belongs at the moment
    // of the attempt. This is the assertion that stops the notice growing into the
    // pre-emptive banner this codebase deliberately does not have.
    state.canPurchase = {
      __kind__: "reserveShort",
      reserveShort: { requested: 2n, available: 1n },
    } as never;
    await mount();
    expect(document.getElementById("gate-notice")!.hidden).toBe(true);

    state.canPurchase = {
      __kind__: "canisterCyclesLow",
      canisterCyclesLow: { balance: 1n, min: 2n },
    } as never;
    await mount();
    expect(document.getElementById("gate-notice")!.hidden).toBe(true);
  });
});

describe("the signed-in principal is copyable", () => {
  /// Captures what `navigator.clipboard.writeText` was handed.
  function captureClipboard(): { last: () => string | undefined } {
    let last: string | undefined;
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText: async (text: string) => { last = text; } },
    });
    return { last: () => last };
  }

  test("⚠️ the header copies the FULL principal, not the truncated display text", async () => {
    // The whole point. The header shows `eoyfw…4qe` for width; copying that hands over
    // something useless in `add_allowed_buyer` or `add_admin`.
    const clip = captureClipboard();
    await mount();
    const shown = document.querySelector("#auth-area .principal")!;
    expect(shown.textContent).not.toBe(FULL_PRINCIPAL);
    expect(shown.textContent).toContain("…");

    const btn = document.querySelector<HTMLButtonElement>("#auth-area button.copy")!;
    btn.click();
    await Promise.resolve();
    expect(clip.last()).toBe(FULL_PRINCIPAL);
  });

  test("the copy button reports back, so a click is not silent", async () => {
    const clip = captureClipboard();
    await mount();
    const btn = document.querySelector<HTMLButtonElement>("#auth-area button.copy")!;
    expect(btn.textContent).toBe("Copy");
    btn.click();
    await Promise.resolve();
    await Promise.resolve();
    expect(btn.textContent).toBe("Copied");
    expect(clip.last()).toBe(FULL_PRINCIPAL);
  });

  test("it carries an aria-label, since \"Copy\" alone is ambiguous with several on a page", async () => {
    await mount();
    const btn = document.querySelector<HTMLButtonElement>("#auth-area button.copy")!;
    expect(btn.getAttribute("aria-label")).toMatch(/principal/i);
  });

  test("signed out, there is no principal and no copy button", async () => {
    await mount("landing");
    // ⚠️ `mount` arrives SIGNED IN, so this has to sign out first — asserting on the
    // default state would have passed while testing nothing about signing out.
    el<HTMLButtonElement>("sign-out").click();
    await Promise.resolve();
    // Nothing to copy, and a Copy button beside a Sign in prompt would be nonsense.
    expect(document.querySelector("#auth-area .principal")).toBeNull();
    expect(document.querySelector("#auth-area button.copy")).toBeNull();
    expect(document.getElementById("sign-in")).not.toBeNull();
  });
});
