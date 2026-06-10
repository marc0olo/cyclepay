import { describe, expect, test } from "vitest";
import {
  STEPS,
  approveErrorMessage,
  ckUnitsForCents,
  claimErrorInfo,
  createCkOrderErrorMessage,
  createOrderErrorMessage,
  formatCkUsdcUnits,
  formatCycles,
  formatUsdCents,
  nsToMillis,
  parseSubaccountHex,
  parseUsdAmount,
  paymentLinkWithRef,
  shortPrincipal,
  statusInfo,
  type CkCreateError,
  type ClaimError,
  type StatusKey,
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

describe("parseSubaccountHex", () => {
  test("empty means no subaccount", () => {
    expect(parseSubaccountHex("")).toEqual({ ok: true, value: null });
    expect(parseSubaccountHex("   ")).toEqual({ ok: true, value: null });
  });
  test("short hex left-pads to 32 bytes", () => {
    const r = parseSubaccountHex("1f");
    if (!r.ok) throw new Error(r.error);
    expect(r.value).toHaveLength(32);
    expect(r.value![31]).toBe(0x1f);
    expect(r.value![0]).toBe(0);
  });
  test("0x prefix and uppercase accepted", () => {
    const r = parseSubaccountHex("0xFF");
    if (!r.ok) throw new Error(r.error);
    expect(r.value![31]).toBe(0xff);
  });
  test("full 64 digits round-trips", () => {
    const r = parseSubaccountHex("ab".repeat(32));
    if (!r.ok) throw new Error(r.error);
    expect([...r.value!].every((b) => b === 0xab)).toBe(true);
  });
  test("rejects non-hex and over-length", () => {
    expect(parseSubaccountHex("zz").ok).toBe(false);
    expect(parseSubaccountHex("0".repeat(65)).ok).toBe(false);
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

describe("ckUnitsForCents", () => {
  test("1¢ = 10⁴ units (6 decimals, 1:1 peg — the CkUsdc.mo constant)", () => {
    expect(ckUnitsForCents(1n)).toBe(10_000n);
    expect(ckUnitsForCents(500n)).toBe(5_000_000n);
  });
});

describe("formatCkUsdcUnits", () => {
  test("always shows at least two decimals", () => {
    expect(formatCkUsdcUnits(5_000_000n)).toBe("5.00 ckUSDC");
    expect(formatCkUsdcUnits(0n)).toBe("0.00 ckUSDC");
    expect(formatCkUsdcUnits(500_000n)).toBe("0.50 ckUSDC");
  });
  test("the ledger fee reads exactly", () => {
    expect(formatCkUsdcUnits(10_000n)).toBe("0.01 ckUSDC");
  });
  test("full 6-decimal precision survives, trailing zeros trimmed", () => {
    expect(formatCkUsdcUnits(5_010_000n)).toBe("5.01 ckUSDC");
    expect(formatCkUsdcUnits(1_234_567n)).toBe("1.234567 ckUSDC");
    // price + fee: $5.00 + 0.01 — the standard approveUnits shape
    expect(formatCkUsdcUnits(5_000_000n + 10_000n)).toBe("5.01 ckUSDC");
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

describe("createCkOrderErrorMessage", () => {
  test("bound violations carry the actual bound in dollars", () => {
    expect(createCkOrderErrorMessage({ __kind__: "belowMinimum", belowMinimum: 100n })).toContain("$1.00");
    expect(createCkOrderErrorMessage({ __kind__: "aboveMaximum", aboveMaximum: 10_000n })).toContain("$100.00");
  });
  test("every variant maps to a distinct message", () => {
    const errs: CkCreateError[] = [
      { __kind__: "anonymous" },
      { __kind__: "idGeneration" },
      { __kind__: "railDisabled" },
      { __kind__: "rateUnavailable" },
      { __kind__: "zeroAmount" },
      { __kind__: "amountBelowFees" },
      { __kind__: "belowMinimum", belowMinimum: 100n },
      { __kind__: "aboveMaximum", aboveMaximum: 10_000n },
    ];
    const msgs = errs.map(createCkOrderErrorMessage);
    expect(new Set(msgs).size).toBe(errs.length);
  });
  test("the fail-closed rate answer says nothing was charged", () => {
    expect(createCkOrderErrorMessage({ __kind__: "rateUnavailable" })).toContain("nothing was charged");
  });
});

describe("claimErrorInfo", () => {
  test("amount-short arms are user-actionable, not stuck (§6.2)", () => {
    const allowance = claimErrorInfo({
      __kind__: "insufficientAllowance",
      insufficientAllowance: { allowance: 5_000_000n, required: 5_010_000n },
    });
    expect(allowance.action).toBe("approve");
    expect(allowance.requiredUnits).toBe(5_010_000n);
    expect(allowance.message).toContain("5.01 ckUSDC");
    expect(allowance.message).toContain("nothing was charged");

    const funds = claimErrorInfo({
      __kind__: "insufficientFunds",
      insufficientFunds: { balance: 1_000_000n, required: 5_010_000n },
    });
    expect(funds.action).toBe("fund");
    expect(funds.message).toContain("1.00 ckUSDC");
  });
  test("transient arms read as retry", () => {
    expect(claimErrorInfo({ __kind__: "retryable", retryable: "ledger busy" }).action).toBe("retry");
    expect(claimErrorInfo({ __kind__: "inFlight" }).action).toBe("retry");
  });
  test("operator territory is never presented as user-retriable", () => {
    const operatorArms: ClaimError[] = [
      { __kind__: "staleIntent" },
      { __kind__: "badFee", badFee: { expectedFee: 20_000n } },
      { __kind__: "ledgerRejected", ledgerRejected: "boom" },
      { __kind__: "wrongRail" },
      { __kind__: "notFound" },
      { __kind__: "notClaimable", notClaimable: "delivered" },
      { __kind__: "anonymous" },
    ];
    for (const err of operatorArms) {
      expect(claimErrorInfo(err).action, err.__kind__).toBe("none");
    }
  });
  test("staleIntent reassures about double-charging (§5.1 money-in posture)", () => {
    expect(claimErrorInfo({ __kind__: "staleIntent" }).message).toContain("charged twice");
  });
});

describe("approveErrorMessage", () => {
  test("known raw ledger variants get specific messages", () => {
    expect(approveErrorMessage({ InsufficientFunds: { balance: 5_000n } })).toContain("0.005 ckUSDC");
    expect(approveErrorMessage({ BadFee: { expected_fee: 10_000n } })).toContain("0.01 ckUSDC");
    expect(approveErrorMessage({ TemporarilyUnavailable: null })).toContain("temporarily");
    expect(approveErrorMessage({ GenericError: { error_code: 1n, message: "boom" } })).toContain("boom");
  });
  test("unknown variants surface their tag", () => {
    expect(approveErrorMessage({ Expired: { ledger_time: 1n } })).toContain("Expired");
  });
});
