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
  ck_usdc_config: async () => ({
    minUsdCents: 100n,
    maxUsdCents: state.ckMaxUsdCents,
    feeBps: 0n,
    feeFixedCents: 0n,
    ledgerFeeUnits: 10_000n,
  }),
  quote_previews: async (_rail: unknown, amounts: bigint[]) => ({
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
  create_ck_usdc_order: async () => ({ __kind__: "err", err: { __kind__: "railDisabled" } }),
  get_order: async () => state.order ?? null,
  list_orders: async () => (state.order ? [state.order] : []),
  cancel_order: async () => {
    state.order = anOrder("expired");
    return { __kind__: "ok", ok: state.order };
  },
  receipt: async () => state.receipt ?? null,
  claim_ck_usdc_order: async () => ({ __kind__: "err", err: { __kind__: "notFound" } }),
};

const identity = { getPrincipal: () => ({ toText: () => "aaaaa-aa" }) };

vi.mock("./actor", () => ({
  backendCanisterId: "aaaaa-aa",
  makeBackend: () => backend,
  agentOptions: () => ({}),
  Rail: { card: "card", ckUsdc: "ckUsdc" },
}));
vi.mock("./auth", () => ({
  currentIdentity: async () => identity,
  signIn: async () => identity,
  signOut: async () => undefined,
}));
vi.mock("./ledger", () => ({ makeCkUsdcLedger: () => ({ icrc2_approve: async () => ({ Ok: 1n }) }) }));

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
async function mount(arm: "live" | "newcomer" | "none" = "live"): Promise<void> {
  // jsdom has no layout, so these are absent. main.ts calls them.
  Element.prototype.scrollIntoView ??= () => undefined;
  window.localStorage.clear();
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
    expect(label).toContain("credited");
    expect(label).toContain("deposit fee");
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
    // deliver. Asserted on the rule by opening a paid order, rather than on the
    // 3 s poll that reaches it in production — vitest fake timers cannot control
    // an interval created before they were installed, so the poll transition
    // itself stays uncovered here.
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

describe("ck-USDC panel", () => {
  test("there is no rail to reach while maxUsdCents is 0", async () => {
    // This replaces an assertion that the panel showed a "not enabled yet, check
    // back soon" notice. That notice promised a rail that may never ship, so the
    // panel and its tab are now removed outright and there is nothing to click.
    state.ckMaxUsdCents = 0n;
    await mount();
    expect(document.getElementById("rail-ckusdc")).toBeNull();
    expect(document.getElementById("ck-amount")).toBeNull();
    // And the card CTA is unaffected by a rail that is not there.
    expect(el<HTMLButtonElement>("create-order").textContent).not.toContain("not enabled");
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

describe("disabled rail is invisible, not promised", () => {
  test("the rail nav and panel are removed from the document while ck-USDC is off", async () => {
    // Hiding was not enough: `.rails { display: flex }` outranked the UA
    // stylesheet's `[hidden] { display: none }`, so a tab for a rail that may
    // never ship was on screen while `el.hidden` read true. Absent cannot be
    // undone by a stylesheet.
    state.ckMaxUsdCents = 0n;
    await mount("live");
    expect(document.getElementById("rail-nav")).toBeNull();
    expect(document.getElementById("ck-panel")).toBeNull();
  });

  test("the rail nav survives while the config is still unknown", async () => {
    // At first paint ckConfig is null, which reads as "disabled". Removing on
    // that guess deleted the markup before the real answer arrived.
    state.ckMaxUsdCents = 10_000n;
    await mount("live");
    expect(document.getElementById("rail-nav")).not.toBeNull();
    expect(el("rail-nav").hidden).toBe(false);
  });
});

function accountOrder(status: string) {
  // `anOrder` infers a canister destination, so this widens rather than
  // reassigns — the stub mirrors the bindgen wrapper's variant shape, which the
  // test fixtures type only structurally.
  const order = anOrder(status) as Record<string, unknown>;
  order.destination = {
    __kind__: "cyclesLedgerAccount",
    cyclesLedgerAccount: { owner: { toText: () => "bbbbb-bb" }, subaccount: undefined },
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

describe("CLI handoff", () => {
  test("a delivered account order prints --app and the credited principal", async () => {
    // The failure this prevents: the bare `icp identity link web dev` form
    // derives a principal from a different origin, so the buyer lands on an
    // empty balance and reads it as theft.
    state.order = accountOrder("delivered");
    await mount("newcomer");
    await openFromHistory();

    expect(el("cli-handoff").hidden).toBe(false);
    const cmd = el("cmd-link").textContent ?? "";
    expect(cmd).toContain("icp identity link web");
    expect(cmd).toContain(`--app ${window.location.origin}`);
    // Never the bare form: that is the whole point of the assertion above.
    expect(cmd.includes("--app")).toBe(true);
    // The principal is shown beside it so a mismatch is self-diagnosable.
    expect(el("credited-principal").textContent).toBe("bbbbb-bb");
  });

  test("a canister top-up gets no CLI commands, because it needs none", async () => {
    // The cycles are already where they will be spent.
    state.order = anOrder("delivered");
    await mount("live");
    await openFromHistory();
    expect(el("cli-handoff").hidden).toBe(true);
  });

  test("an undelivered order shows no commands yet", async () => {
    state.order = accountOrder("paid");
    await mount("newcomer");
    await openFromHistory();
    expect(el("cli-handoff").hidden).toBe(true);
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
