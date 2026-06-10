import { describe, expect, test } from "vitest";
import {
  STEPS,
  createOrderErrorMessage,
  formatCycles,
  formatUsdCents,
  nsToMillis,
  parseSubaccountHex,
  paymentLinkWithRef,
  shortPrincipal,
  statusInfo,
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
