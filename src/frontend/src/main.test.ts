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
async function mount(): Promise<void> {
  // jsdom has no layout, so this is absent. main.ts calls it on openOrder.
  Element.prototype.scrollIntoView ??= () => undefined;
  const html = readFileSync(resolve(__dirname, "..", "index.html"), "utf-8");
  const body = /<body>([\s\S]*)<\/body>/.exec(html);
  if (!body) throw new Error("could not extract <body> from index.html");
  document.body.innerHTML = body[1]!.replace(/<script[\s\S]*?<\/script>/g, "");
  vi.resetModules();
  await import("./main");
  // let init()'s awaits settle
  await new Promise((r) => setTimeout(r, 0));
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
    expect(notice.textContent).toContain("nothing was charged");
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
    expect(el("receipt-verdict").textContent).toContain("✓");
    expect(el("receipt-formula").textContent).toContain("3.5 T");
  });
});

describe("ck-USDC panel", () => {
  test("the rail shows its disabled notice while maxUsdCents is 0", async () => {
    await mount();
    el("rail-ckusdc").click();
    await settle();
    expect(el("ck-disabled-notice").hidden).toBe(false);
    expect(el<HTMLInputElement>("ck-amount").disabled).toBe(true);
    expect(el<HTMLButtonElement>("create-order").textContent).toContain("not enabled");
  });
});
