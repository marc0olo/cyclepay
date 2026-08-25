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
  quote: {
    usdCents: TIER_CENTS,
    feeCents: 45n,
    netCents: 455n,
    cycles: TIER_CYCLES,
  } as Quote,
  depositFee: 100_000_000n,
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

const backend = {
  card_tiers: async () => state.tiers,
  lifecycle_config: async () => ({
    gate: {
      maxOpenOrdersPerPrincipal: 1n,
      minCanisterCycles: 5_000_000_000_000n,
      // The #33 bounds: $10 floor, $100 ceiling.
      minPurchaseUsdCents: 1_000n,
      maxPurchaseUsdCents: 10_000n,
    },
    retention: { orderTtlNs: 172_800_000_000_000n },
  }),
  treasury_status: async () => ({ lowFloat: false }),
  pricing_status: async () => ({
    rates: {
      usdPerIcpMicros: 4_550_000n,
      xdrPermyriadPerIcp: 35_000n,
      fetchedAtNs: 1n,
      quality: { standardDeviation: 0n, receivedRates: 5n, queriedSources: 6n },
    },
    config: { feeBps: 290n, feeFixedCents: 30n },
    lastAttempt: undefined,
  }),
  quote_previews: async (amounts: bigint[]) => ({
    quotes: amounts.map(() => state.quote),
    rates: undefined,
    cyclesLedgerDepositFee: state.depositFee,
  }),
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
  list_orders: async () => (state.order ? [state.order] : []),
  cancel_order: async () => {
    state.order = anOrder("cancelled");
    return { __kind__: "ok", ok: state.order };
  },
  receipt: async () => state.receipt ?? null,
};

const identity = { getPrincipal: () => ({ toText: () => "aaaaa-aa" }) };

vi.mock("./actor", () => ({
  backendCanisterId: "aaaaa-aa",
  makeBackend: () => backend,
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
  state.quote = { usdCents: TIER_CENTS, feeCents: 45n, netCents: 455n, cycles: TIER_CYCLES };
  state.depositFee = 100_000_000n;
  state.ckMaxUsdCents = 0n;
  state.quoteChangedTo = undefined;
  state.lastMinCycles = undefined;
  state.lastDestination = undefined;
  state.lastAmount = undefined;
  state.order = undefined;
  state.receipt = undefined;
  state.signInError = undefined;
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

  test("a fee large enough to move the figure is shown as a split", async () => {
    state.depositFee = 500_000_000_000n;
    await mount();
    const label = tierButton().querySelector(".cycles")!.textContent!;
    expect(label).toContain("3 T cycles credited");
    expect(label).toContain("3.5 T minted");
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
      cyclesMinted: TIER_CYCLES,
      mintBlockIndex: 42n,
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
    el("auth-area").querySelector("button")!.click();
    await settle();
  }

  test("the header reports a blocked pop-up in the CTA's own words", async () => {
    await mount("landing");
    await signOutInHeader();
    state.signInError = new Error("popup was blocked by the browser");
    el("auth-area").querySelector("button")!.click();
    await settle();
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
    el("auth-area").querySelector("button")!.click();
    await settle();
    expect(el("auth-error").textContent).toMatch(/cancelled/i);

    state.signInError = new Error("connection reset");
    el("auth-area").querySelector("button")!.click();
    await settle();
    expect(el("auth-error").textContent).toMatch(/could not reach the sign-in service/i);
  });

  test("a successful sign-in clears the previous failure", async () => {
    await mount("landing");
    await signOutInHeader();
    state.signInError = new Error("UserInterrupt");
    el("auth-area").querySelector("button")!.click();
    await settle();
    expect(el("auth-error").hidden).toBe(false);

    state.signInError = undefined;
    el("auth-area").querySelector("button")!.click();
    await settle();
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
    expect(el("client-ref").textContent).toBe("aaaaa-aa_abcdef0123456789abcdef0123456789");
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
