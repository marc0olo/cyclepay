import { describe, expect, test } from "vitest";
import {
  checkReceipt,
  createOrderErrorMessage,
  cyclesCredited,
  cyclesForCents,
  estimateLine,
  feeBreakdown,
  formatCycles,
  formatUsdCents,
  type GateReason,
  gateReasonMessage,
  lockedVsEstimate,
  minAcceptableCycles,
  nsToMillis,
  parseUsdAmount,
  paymentLinkWithRef,
  rateSourceNote,
  shortPrincipal,
  statusInfo,
  type StatusKey,
  STEPS,
} from "./format";

describe("statusInfo", () => {
  const ALL: StatusKey[] = [
    "created",
    "expired",
    "paid",
    "minting",
    "icpAtCmc",
    "awaitingTreasury",
    "delivered",
    "errorQueue",
  ];

  test("exactly the two §4 terminal states stop polling", () => {
    const terminal = ALL.filter((k) => statusInfo(k).terminal);
    expect(terminal.sort()).toEqual(["delivered", "errorQueue"]);
  });

  test("expired stays pollable (advisory, §4) and reads as a warning", () => {
    const info = statusInfo("expired");
    expect(info.terminal).toBe(false);
    expect(info.tone).toBe("warn");
  });

  test("steps are within the timeline and monotone along the happy path", () => {
    for (const k of ALL) {
      const s = statusInfo(k).step;
      expect(s).toBeGreaterThanOrEqual(-1);
      expect(s).toBeLessThan(STEPS.length);
    }
    const happy: StatusKey[] = ["created", "paid", "minting", "delivered"];
    const steps = happy.map((k) => statusInfo(k).step);
    expect(steps).toEqual([0, 1, 2, 3]);
    // The two mid-flight composites sit on the same steps as their phase.
    expect(statusInfo("icpAtCmc").step).toBe(2);
    expect(statusInfo("awaitingTreasury").step).toBe(1);
  });
});

describe("paymentLinkWithRef", () => {
  test("appends with ? on a bare link", () => {
    expect(paymentLinkWithRef("https://buy.stripe.com/abc", "w7x7r-cok77-xa_deadbeef")).toBe(
      "https://buy.stripe.com/abc?client_reference_id=w7x7r-cok77-xa_deadbeef",
    );
  });
  test("appends with & when the link already has a query", () => {
    expect(paymentLinkWithRef("https://buy.stripe.com/abc?locale=en", "p_o")).toBe(
      "https://buy.stripe.com/abc?locale=en&client_reference_id=p_o",
    );
  });
});

describe("formatCycles", () => {
  test("the §3 pricing vector reads as trillions", () => {
    expect(formatCycles(3_353_350_000_000n)).toBe("3.353 T");
  });
  test("exact trillion drops the fraction", () => {
    expect(formatCycles(1_000_000_000_000n)).toBe("1 T");
  });
  test("rounds half up at the third decimal", () => {
    expect(formatCycles(1_234_500_000_000n)).toBe("1.235 T");
    expect(formatCycles(1_234_499_999_999n)).toBe("1.234 T");
  });
  test("giga and mega bands", () => {
    expect(formatCycles(2_500_000_000n)).toBe("2.5 G");
    expect(formatCycles(7_000_000n)).toBe("7 M");
  });
  test("below 1M is exact", () => {
    expect(formatCycles(999_999n)).toBe("999999");
    expect(formatCycles(0n)).toBe("0");
  });
});

describe("formatUsdCents", () => {
  test("pads cents", () => {
    expect(formatUsdCents(500n)).toBe("$5.00");
    expect(formatUsdCents(1_05n)).toBe("$1.05");
    expect(formatUsdCents(30n)).toBe("$0.30");
  });
});

describe("shortPrincipal", () => {
  test("leaves short principals alone", () => {
    expect(shortPrincipal("aaaaa-aa")).toBe("aaaaa-aa");
  });
  test("ellipsizes long principals", () => {
    const p = "k2t6j-2nvnp-4zjm3-25dtz-6xhaa-c7boj-5gayf-oj3xs-i43lp-teztq-6ae";
    expect(shortPrincipal(p)).toBe("k2t6j…q-6ae");
  });
});

describe("nsToMillis", () => {
  test("truncates to milliseconds", () => {
    expect(nsToMillis(1_700_000_000_123_456_789n)).toBe(1_700_000_000_123);
  });
});

describe("createOrderErrorMessage", () => {
  test("every backend variant maps to a specific message", () => {
    const keys = ["rateUnavailable", "tierBelowFees", "unknownTier", "anonymous", "idGeneration"];
    const msgs = keys.map(createOrderErrorMessage);
    expect(new Set(msgs).size).toBe(keys.length);
    for (const m of msgs) expect(m).not.toMatch(/failed: /);
  });
  test("unknown variants still produce something", () => {
    expect(createOrderErrorMessage("somethingNew")).toContain("somethingNew");
  });
});

describe("parseUsdAmount", () => {
  test("whole dollars, one and two decimals", () => {
    expect(parseUsdAmount("5")).toEqual({ ok: true, cents: 500n });
    expect(parseUsdAmount("5.5")).toEqual({ ok: true, cents: 550n });
    expect(parseUsdAmount("5.50")).toEqual({ ok: true, cents: 550n });
    expect(parseUsdAmount("0.01")).toEqual({ ok: true, cents: 1n });
  });
  test("leading $ and whitespace tolerated", () => {
    expect(parseUsdAmount(" $12.34 ")).toEqual({ ok: true, cents: 1234n });
  });
  test("zero is rejected (the backend would answer zeroAmount anyway)", () => {
    expect(parseUsdAmount("0").ok).toBe(false);
    expect(parseUsdAmount("0.00").ok).toBe(false);
  });
  test("garbage, sub-cent precision, and signs are rejected", () => {
    for (const bad of ["", "abc", "5.123", "-5", "+5", "5,50", "5.", ".5", "1e3"]) {
      expect(parseUsdAmount(bad).ok, bad).toBe(false);
    }
  });
});

describe("gateReasonMessage", () => {
  test("amountAboveMax tells the user what the limit is", () => {
    const msg = gateReasonMessage({
      __kind__: "amountAboveMax",
      amountAboveMax: { usdCents: 200_000n, maxUsdCents: 100_000n },
    });
    // formatUsdCents does not group thousands — assert what it actually emits.
    expect(msg).toContain("$1000.00");
  });

  test("tooManyOpenOrders tells the user what to do about it", () => {
    const msg = gateReasonMessage({
      __kind__: "tooManyOpenOrders",
      tooManyOpenOrders: { open: 20n, max: 20n },
    });
    expect(msg).toContain("20");
    expect(msg.toLowerCase()).toMatch(/pay or abandon/);
  });

  test("operational refusals promise nothing was charged", () => {
    // These are all pre-payment refusals, so the copy must say so — otherwise a
    // user seeing "unavailable" mid-purchase assumes money may have moved.
    const operational: GateReason[] = [
      { __kind__: "burnCapExhausted", burnCapExhausted: { burnedE8s: 1n, capE8s: 1n } },
      { __kind__: "floatLow", floatLow: { thresholdE8s: 1n } },
      { __kind__: "canisterCyclesLow", canisterCyclesLow: { balance: 0n, min: 1n } },
    ];
    for (const reason of operational) {
      expect(gateReasonMessage(reason)).toContain("Nothing was charged");
    }
  });

  test("floatLow renders with no observation present", () => {
    // observedE8s is absent when the float has never been read.
    expect(gateReasonMessage({
      __kind__: "floatLow",
      floatLow: { thresholdE8s: 1_000n },
    })).not.toBe("");
  });
});

describe("createOrderErrorMessage: notAdmitted", () => {
  test("the key-only path still says nothing was charged", () => {
    expect(createOrderErrorMessage("notAdmitted")).toMatch(/nothing was charged/i);
  });
});

// --- pricing display + slippage ----------------------------------------------

describe("cyclesForCents", () => {
  test("reproduces the shared §3 vector", () => {
    // The $5.00 tier: 500¢ less ⌈500·290/10⁴⌉ = 15¢ and 30¢ fixed leaves 455¢
    // net, which at $4.55/ICP and 3.5 XDR/ICP is exactly 3.5 T — the same vector
    // the Motoko suite and the PocketIC suite pin.
    expect(cyclesForCents(455n, 35_000n, 4_550_000n)).toBe(3_500_000_000_000n);
  });

  test("refuses a zero ICP price rather than dividing by zero", () => {
    expect(cyclesForCents(155n, 35_000n, 0n)).toBeNull();
  });

  test("floors, so a quote never exceeds what the money buys", () => {
    // 1 × 1 × 1e12 / 3 is not an integer; the remainder must not round up.
    expect(cyclesForCents(1n, 1n, 3n)).toBe(333_333_333_333n);
  });
});

describe("minAcceptableCycles", () => {
  test("allows exactly 5% below the shown figure", () => {
    expect(minAcceptableCycles(1_000_000n)).toBe(950_000n);
  });

  test("never exceeds the shown figure — the guard only protects the buyer", () => {
    for (const shown of [1n, 7n, 999n, 1_000_000_000_000n]) {
      expect(minAcceptableCycles(shown) <= shown).toBe(true);
    }
  });

  test("floors rather than rounding up, so the pin is never stricter than 5%", () => {
    // 19 × 9500 / 10000 = 18.05 → 18, not 19 (which would reject an exact match).
    expect(minAcceptableCycles(19n)).toBe(18n);
  });
});

describe("cyclesCredited", () => {
  test("the delivery loses the ledger's deposit fee", () => {
    expect(cyclesCredited(5_000_000_000n, 100_000_000n)).toBe(4_900_000_000n);
  });

  test("never goes negative when the fee exceeds the quantity", () => {
    expect(cyclesCredited(50n, 100_000_000n)).toBe(0n);
  });

  test("passes an unavailable quote straight through", () => {
    expect(cyclesCredited(null, 100_000_000n)).toBeNull();
  });
});

describe("estimateLine", () => {
  test("names the deposit fee when it moves the figure, so the gap is never a surprise", () => {
    const line = estimateLine(5_000_000_000n, 100_000_000n);
    expect(line).toContain("4.9 G");
    expect(line).toContain("deposit fee");
  });

  test("states the credited figure alone when the fee rounds away", () => {
    // 3.5 T less 100 M is still "3.5 T" at three decimals, so a split would read
    // as a contradiction. Repeating the fee here instead put the same
    // parenthetical on every amount tile and in the note below them — the fee is
    // disclosed once, in `#dest-fee-note`.
    expect(estimateLine(3_500_000_000_000n, 100_000_000n)).toBe("≈ 3.5 T cycles");
  });

  test("says nothing about a fee it has not been told", () => {
    // `depositFee` is 0n until the first quote answers, and after a failed one.
    expect(estimateLine(5_000_000_000n, 0n)).toBe("≈ 5 G cycles");
  });

  test("says orders are paused rather than showing a zero when unpriceable", () => {
    expect(estimateLine(null, 100_000_000n)).toContain("paused");
  });
});

describe("feeBreakdown", () => {
  test("accounts for every cent and states the operator takes nothing", () => {
    const text = feeBreakdown(500n, 345n, 155n, { feeBps: 290n, feeFixedCents: 30n });
    expect(text).toContain("$5.00 charged");
    expect(text).toContain("$3.45 payment processing");
    expect(text).toContain("$1.55 buys cycles");
    expect(text).toContain("operator margin: none");
  });

  test("names a zero-fee rail as such instead of printing 0% + $0.00", () => {
    expect(feeBreakdown(500n, 0n, 500n, { feeBps: 0n, feeFixedCents: 0n })).toContain(
      "no processor fee",
    );
  });

  test("tells the user to pick a larger amount when the fee swallows it", () => {
    expect(feeBreakdown(30n, 39n, undefined, { feeBps: 290n, feeFixedCents: 30n })).toContain(
      "larger amount",
    );
  });
});

describe("lockedVsEstimate", () => {
  test("stays silent when the locked quantity is exactly what was shown", () => {
    expect(lockedVsEstimate(1_000n, 1_000n)).toBeNull();
  });

  test("stays silent when nothing was shown to compare against", () => {
    expect(lockedVsEstimate(1_000n, null)).toBeNull();
  });

  test("declares the real locked figure when the rate drifted within tolerance", () => {
    const text = lockedVsEstimate(990_000_000_000n, 1_000_000_000_000n);
    expect(text).toContain("fewer");
    expect(text).toContain("will not change again");
  });

  test("also speaks up when the drift favoured the buyer", () => {
    expect(lockedVsEstimate(1_010_000_000_000n, 1_000_000_000_000n)).toContain("more");
  });
});

describe("checkReceipt", () => {
  const verification = {
    netCents: 455n,
    usdPerIcpMicros: 4_550_000n,
    xdrPermyriadPerIcp: 35_000n,
    rateReceivedRates: 5n,
    rateQueriedSources: 6n,
  };

  test("confirms a price that reproduces from the receipt's own inputs", () => {
    const check = checkReceipt(verification, 3_500_000_000_000n);
    expect(check.matches).toBe(true);
    expect(check.recomputed).toBe(3_500_000_000_000n);
  });

  test("flags a locked quantity the inputs do not produce", () => {
    expect(checkReceipt(verification, 3_500_000_000_001n).matches).toBe(false);
  });

  test("shows both rate inputs in the formula, since both are needed to re-derive it", () => {
    const { formula } = checkReceipt(verification, 3_500_000_000_000n);
    expect(formula).toContain("$4.55");
    expect(formula).toContain("3.5000 XDR/ICP");
    expect(formula).toContain("$4.55 net");
  });

  test("does not claim a match when there is no net amount to verify", () => {
    const check = checkReceipt({ ...verification, netCents: undefined }, 1n);
    expect(check.matches).toBe(false);
    expect(check.recomputed).toBeNull();
  });
});

describe("rateSourceNote", () => {
  test("names how many sources answered, so a thin price is visible", () => {
    expect(rateSourceNote(2n, 12n)).toBe("priced from 2 of 12 exchange sources");
  });

  test("says nothing when no sources were recorded", () => {
    expect(rateSourceNote(0n, 0n)).toBe("");
  });
});
