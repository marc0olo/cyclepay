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

const TIER_CENTS = 500n;
const TIER_CYCLES = 3_500_000_000_000n;

const state = {
  tiers: [{ id: "tier5", usdCents: TIER_CENTS, paymentLinkUrl: "https://buy.stripe.com/x" }],
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
  order: undefined as Record<string, unknown> | undefined,
  receipt: undefined as Record<string, unknown> | undefined,
  /// When set, the next `signIn()` rejects with it.
  signInError: undefined as unknown,
};

function anOrder(status: string, lockedCycles = TIER_CYCLES) {
  return {
    id: "abcdef0123456789abcdef0123456789",
    owner: { __kind__: "ii", ii: { toText: () => "aaaaa-aa" } },
    rail: "card",
    destination: { __kind__: "canister", canister: { toText: () => "aaaaa-aa" } },
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
    createdAtNs: 1_700_000_000_000_000_000n,
    updatedAtNs: 1_700_000_000_000_000_000n,
  };
}

const backend = {
  card_tiers: async () => state.tiers,
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
  create_order: async (_tier: string, _dest: unknown, minCycles: bigint | null) => {
    state.lastMinCycles = minCycles;
    if (state.quoteChangedTo !== undefined) {
      const quoted = state.quoteChangedTo;
      state.quoteChangedTo = undefined;
      return { __kind__: "err", err: { __kind__: "quoteChanged", quoteChanged: { quoted, minimum: minCycles ?? 0n } } };
    }
    state.order = anOrder("created");
    return { __kind__: "ok", ok: { order: state.order, clientReferenceId: "aaaaa-aa_abcdef0123456789abcdef0123456789" } };
  },
  get_order: async () => state.order ?? null,
  list_orders: async () => (state.order ? [state.order] : []),
  cancel_order: async () => {
    state.order = anOrder("expired");
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
/// `arm` picks the audience the way a visitor does — by clicking the chooser.
///
/// Not optional, and not a convenience: the purchase flow is hidden until an arm
/// is chosen, and jsdom neither renders nor respects `hidden`. A test that skips
/// the click still finds every element and still passes, while asserting a path
/// no real visitor can reach. Defaulting to "live" keeps the pre-existing tests
/// on the arm whose markup they were written against (canister destination).
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

async function mount(
  arm: "live" | "newcomer" | "none" = "live",
  hash = "",
): Promise<void> {
  // jsdom has no layout, so these are absent. main.ts calls them.
  Element.prototype.scrollIntoView ??= () => undefined;
  window.localStorage.clear();
  for (const [type, fn] of installedListeners) window.removeEventListener(type, fn);
  installedListeners = [];
  // jsdom keeps `location` across tests in a file, so a previous test's #/buy
  // would be parsed as the starting route and skip the chooser under test.
  // A real first-time visitor arrives with no hash; `hash` is for the deep-link
  // tests, which need the route to exist BEFORE `init` reads it.
  window.location.hash = hash;
  const html = readFileSync(resolve(__dirname, "..", "index.html"), "utf-8");
  const body = /<body>([\s\S]*)<\/body>/.exec(html);
  if (!body) throw new Error("could not extract <body> from index.html");
  document.body.innerHTML = body[1]!.replace(/<script[\s\S]*?<\/script>/g, "");
  vi.resetModules();
  await import("./main");
  // let init()'s awaits settle
  await new Promise((r) => setTimeout(r, 0));
  if (arm !== "none") {
    el(arm === "live" ? "choose-live" : "choose-new").click();
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
    expect(label.textContent).not.toContain("tier5");
    expect(tierButton().querySelector(".amount")!.textContent).toBe("$5.00");
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

describe("destination affects what lands", () => {
  test("switching to a cycles-ledger account subtracts the deposit fee and says so", async () => {
    await mount();
    expect(tierButton().querySelector(".cycles")!.textContent).toBe("≈ 3.5 T cycles");
    expect(el("dest-fee-note").hidden).toBe(true);

    const ledgerRadio = document.querySelector<HTMLInputElement>(
      'input[name="dest-kind"][value="cyclesLedgerAccount"]',
    )!;
    ledgerRadio.checked = true;
    ledgerRadio.dispatchEvent(new Event("change"));
    await settle();

    // At 3.5 T the 100 M fee is 0.003%, so it rounds away at display precision —
    // the copy must not then claim two different figures. It still says the fee
    // was applied.
    const label = tierButton().querySelector(".cycles")!.textContent!;
    expect(label).toMatch(/deposit/i);
    // The fee must be DISCLOSED; the exact wording is copy. Asserting the phrase
    // "deposit fee" pinned the operator-facing version of this sentence.
    expect(label).toMatch(/deposit/i);
    expect(label).toContain("100 M");
    expect(label).not.toMatch(/3\.5 T minted/);
    const note = el("dest-fee-note");
    expect(note.hidden).toBe(false);
    expect(note.textContent).toContain("not added to your price");
  });
});

describe("quote pinning", () => {
  test("the shown figure is pinned as a 5%-tolerance minimum", async () => {
    await mount();
    tierButton().click();
    await settle();
    el<HTMLInputElement>("canister-principal").value = "aaaaa-aa";
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
    el<HTMLInputElement>("canister-principal").value = "aaaaa-aa";

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
    el<HTMLInputElement>("canister-principal").value = "aaaaa-aa";
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
    el<HTMLInputElement>("canister-principal").value = "aaaaa-aa";
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

  test("cancelling an unpaid order keeps it payable, so cancel stays offered", async () => {
    // #expired is still payable (§4), which is what makes cancelling safe — the
    // UI must not imply the order is dead.
    await mount();
    tierButton().click();
    await settle();
    el<HTMLInputElement>("canister-principal").value = "aaaaa-aa";
    el<HTMLFormElement>("order-form").dispatchEvent(new Event("submit"));
    await settle();
    el("cancel-order").click();
    await settle();
    await settle();
    expect(el("order-status-line").textContent).toContain("still goes through");
  });

  test("the locked figure is stated without a '≈', and the locked rate is shown", async () => {
    await mount();
    tierButton().click();
    await settle();
    el<HTMLInputElement>("canister-principal").value = "aaaaa-aa";
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

// ── the two-audience flow (issue #21) ─────────────────────────────────────────

describe("audience chooser", () => {
  test("nothing is purchasable until an arm is chosen", async () => {
    // The gate this whole section rests on. It is asserted first because jsdom
    // ignores `hidden`: every other test in this file would still pass if the
    // chooser stopped gating anything at all.
    await mount("none");
    expect(el("chooser").hidden).toBe(false);
    expect(el("buy-flow").hidden).toBe(true);
  });

  test("the newcomer arm never renders a canister-id field", async () => {
    // A newcomer's first canister does not exist yet, so the question is
    // unanswerable. Showing it is what makes the page read as "not for me".
    await mount("newcomer");
    expect(el("buy-flow").hidden).toBe(false);
    expect(el("dest-newcomer").hidden).toBe(false);
    expect(el("dest-choice").hidden).toBe(true);
    expect(el("dest-canister").hidden).toBe(true);
  });

  test("the already-live arm defaults to a canister, which is why they came", async () => {
    await mount("live");
    expect(el("dest-choice").hidden).toBe(false);
    expect(el("dest-newcomer").hidden).toBe(true);
    expect(el("dest-canister").hidden).toBe(false);
    const checked = document.querySelector<HTMLInputElement>('input[name="dest-kind"]:checked');
    expect(checked!.value).toBe("canister");
  });

  test("persistence is asymmetric: live is remembered, newcomer is not", async () => {
    // Wrongly resuming the expert arm shows a canister field to someone with no
    // canister. Wrongly re-asking an expert costs one click. The asymmetry is
    // the point, so it is pinned in both directions.
    await mount("live");
    expect(window.localStorage.getItem("icp.audience")).toBe("live");

    await mount("newcomer");
    expect(window.localStorage.getItem("icp.audience")).toBeNull();
  });

  test("a remembered arm still offers a visible way back, and forgets on use", async () => {
    await mount("live");
    expect(el("chooser-back").hidden).toBe(false);
    el("back-to-chooser").click();
    await settle();
    expect(el("chooser").hidden).toBe(false);
    expect(el("buy-flow").hidden).toBe(true);
    expect(window.localStorage.getItem("icp.audience")).toBeNull();
  });

  test("the newcomer escape hatch reveals a canister field without promoting it", async () => {
    // "Sending to someone else's canister?" stays reachable, but as a link and
    // not a co-equal radio.
    await mount("newcomer");
    expect(el("dest-canister").hidden).toBe(true);
    el("show-advanced-dest").click();
    await settle();
    expect(el("dest-canister").hidden).toBe(false);
    expect(el("dest-choice").hidden).toBe(true);
  });
});

/// An account-funded order. `owner` defaults to the SIGNED-IN principal, which is
/// what makes it the buyer's own balance and so the case that earns the tour.
///
/// It used to default to a stranger's principal while the tests asserted the
/// buyer's tour was shown, which is the third-party bug those tests were meant to
/// be evidence against.
function accountOrder(status: string, owner = "aaaaa-aa") {
  // `anOrder` infers a canister destination, so this widens rather than
  // reassigns — the stub mirrors the bindgen wrapper's variant shape, which the
  // test fixtures type only structurally.
  const order = anOrder(status) as Record<string, unknown>;
  order.destination = {
    __kind__: "cyclesLedgerAccount",
    cyclesLedgerAccount: { owner: { toText: () => owner }, subaccount: undefined },
  };
  return order;
}

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
    state.order = accountOrder("delivered");
    await mount("newcomer");
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

  test("a canister top-up gets no CLI commands, because it needs none", async () => {
    // The cycles are already where they will be spent.
    state.order = anOrder("delivered");
    await mount("live");
    await openFromHistory();
    expect(el("tour").hidden).toBe(true);
  });

  test("an undelivered order shows no commands yet", async () => {
    state.order = accountOrder("paid");
    await mount("newcomer");
    await openFromHistory();
    expect(el("tour").hidden).toBe(true);
  });

  test("cycles sent to someone else's account get the fact and no commands", async () => {
    // `icp identity link web` links the BUYER's identity. For an account they do
    // not own that command reaches the wrong balance, so following it lands them
    // on an empty account and reads as the cycles having gone missing.
    state.order = accountOrder("delivered", "bbbbb-bb");
    await mount("live");
    await openFromHistory();
    expect(el("tour").hidden).toBe(false);
    expect(el("tour-third-party").hidden).toBe(false);
    expect(el("tour-steps").hidden).toBe(true);
    // And no progress strip either: steps 3 and 4 are not this buyer's to take.
    expect(el("stepper").hidden).toBe(true);
  });

  test("the POLL finding an order delivered brings up the tour", async () => {
    // The defect this pins. A buyer creating an order and paying never navigates
    // again: the poll is what discovers `delivered`. It updated the order facts
    // and left the view machine unrun, so the tour, the stepper state and the
    // collapsed facts — the whole delivered view — appeared only if you reopened
    // the order from history. Every earlier test did exactly that, which is why
    // none of them saw it.
    state.order = accountOrder("paid");
    await mount("newcomer");
    // Fake timers must be installed BEFORE `openOrder` creates the interval;
    // vitest cannot control one created under real timers.
    vi.useFakeTimers();
    try {
      el("orders").querySelector("tr")!.click();
      await vi.advanceTimersByTimeAsync(0);
      expect(el("active-order").hidden).toBe(false);
      expect(el("tour").hidden).toBe(true);

      // The gateway delivers. The visitor does nothing.
      state.order = accountOrder("delivered");
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
    await mount("live");
    vi.useFakeTimers();
    try {
      tierButton().click();
      await vi.advanceTimersByTimeAsync(0);
      el<HTMLInputElement>("canister-principal").value = "aaaaa-aa";
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
    await mount("none");
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
    await mount("none");
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
    await mount("none");
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
  test("#/buy with no arm chosen asks the question instead", async () => {
    // Deep-linked or reloaded, `#/buy` rendered a form with no destination
    // question on it at all: the newcomer block hidden, the already-live radios
    // hidden, and an amount grid wired to a destination nobody was asked about.
    await mount("none");
    window.location.hash = "#/buy";
    await settle();
    expect(el("buy-flow").hidden).toBe(true);
    expect(el("chooser").hidden).toBe(false);
  });

  test("a reload on an order deep link resolves it as the SIGNED-IN buyer", async () => {
    // `get_order` answers per caller. Resolving the route before the session was
    // restored looked the order up anonymously, got nothing, and landed the owner
    // on "we could not find that order" — on a plain reload of their own order.
    // It also decided whose tour to show, so a self-funded account order rendered
    // as somebody else's.
    state.order = accountOrder("delivered");
    // No chooser click: that would navigate to the buy view and throw the deep
    // link away, which is the whole thing under test.
    await mount("none", "#/order/abcdef0123456789abcdef0123456789");
    await settle();
    expect(el("order-missing").hidden).toBe(true);
    expect(el("active-order").hidden).toBe(false);
    expect(el("tour").hidden).toBe(false);
    expect(el("tour-steps").hidden).toBe(false);
    expect(el("tour-third-party").hidden).toBe(true);
  });

  test("an unknown order id says so rather than showing the last one", async () => {
    state.order = anOrder("delivered");
    await mount("live");
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
  test("prefills the amount and canister from a past order without submitting", async () => {
    // One click plus payment is the shortest flow the design allows for an
    // operator refilling the same canister monthly. It must NOT submit: the
    // price is re-quoted at today's rate and the buyer has to see the number.
    state.order = anOrder("delivered");
    await mount("live");
    const again = el("orders").querySelector<HTMLButtonElement>("button.buy-again");
    expect(again).not.toBeNull();
    again!.click();
    await settle();

    expect(el<HTMLInputElement>("canister-principal").value).toBe("aaaaa-aa");
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
    await mount("live");
    window.location.hash = "#/history";
    await settle();
    expect(el("history").hidden).toBe(false);

    el("orders").querySelector<HTMLButtonElement>("button.buy-again")!.click();
    await settle();

    expect(el("buy-flow").hidden).toBe(false);
    expect(el("history").hidden).toBe(true);
    expect(window.location.hash).toBe("#/buy");
    expect(el<HTMLInputElement>("canister-principal").value).toBe("aaaaa-aa");
  });

  test("clicking buy again does not also open the order row", async () => {
    // Both handlers live on the same row; without stopPropagation the prefill is
    // immediately replaced by the order view.
    state.order = anOrder("delivered");
    await mount("live");
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
    await mount("live");

    const strip = el("rate-line").textContent ?? "";
    expect(strip).toMatch(/no exchange rate/i);
    expect(strip).not.toContain("XDR/ICP");
    // And the tiers agree, which is the whole point.
    expect(tierButton().querySelector(".cycles")!.textContent).toMatch(/no exchange rate/i);
  });

  test("a usable rate is printed in full", async () => {
    await mount("live");
    const strip = el("rate-line").textContent ?? "";
    expect(strip).toContain("XDR/ICP");
    expect(strip).not.toMatch(/no exchange rate/i);
  });
});
