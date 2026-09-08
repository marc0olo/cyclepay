import { describe, expect, test } from "vitest";
import {
  checkReceipt,
  decodeBurnMemo,
  CREATE_ORDER_ERROR_KEYS,
  createOrderErrorMessage,
  cyclesCredited,
  cyclesForCents,
  creditedSplit,
  depositFeeLine,
  estimateLine,
  formatCycles,
  formatUsdCents,
  type GateReason,
  gateReasonMessage,
  lockedVsEstimate,
  minAcceptableCycles,
  nsToMillis,
  parseUsdAmount,
  rateSourceNote,
  shortPrincipal,
  statusInfo,
  type StatusKey,
  formatAgo,
  timeUntil,
  formatDuration,
} from "./format";

describe("statusInfo", () => {
  const ALL: StatusKey[] = [
    "created",
    "cancelled",
    "expired",
    "paid",
    "delivered",
    "needsReview",
    "abandoned",
  ];

  test("polling stops exactly on the statuses the backend will never move again", () => {
    // Grew in #34: `#expired` became terminal when `#expired → #paid` was
    // deleted, and `#cancelled`/`#abandoned` are terminal by construction.
    const terminal = ALL.filter((k) => statusInfo(k).terminal);
    expect(terminal.sort()).toEqual(["abandoned", "cancelled", "delivered", "expired"]);
  });

  test("needsReview keeps polling, because the operator can still end it", () => {
    // The other half of splitting `#errorQueue`: this one is not terminal, and a
    // buyer watching the page should see `#abandoned` arrive rather than sit on a
    // stale screen.
    expect(statusInfo("needsReview").terminal).toBe(false);
    expect(statusInfo("needsReview").tone).toBe("err");
  });

  test("a cancelled order never reads as expired, and neither invites a payment", () => {
    // The defect #34 fixes: cancelling transitioned to `#expired`, so a reload
    // told a buyer who had cancelled that their order had expired — and the copy
    // then promised a late payment would still go through, which is now false for
    // both.
    expect(statusInfo("cancelled").label).toBe("Cancelled");
    expect(statusInfo("expired").label).not.toMatch(/still goes through/i);
    expect(statusInfo("expired").terminal).toBe(true);
  });

  test("every status the backend can report has an entry", () => {
    // ⚠️ **The three legacy statuses are gone from the type (#36)**, so a status the
    // page cannot describe is a compile error in the switch rather than a test failure
    // here. This pins the count so a status ADDED to the union is noticed.
    expect(ALL).toHaveLength(7);
    for (const k of ALL) {
      expect(statusInfo(k).pill.length).toBeGreaterThan(0);
      expect(statusInfo(k).headline()).not.toBe("");
    }
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
  test("⚠️ EVERY backend variant maps to a written message, not the fallback", () => {
    // ⚠️ The keys come from `CREATE_ORDER_ERROR_KEYS`, which is typed
    // `Record<CreateOrderError["__kind__"], true>` — so a new backend variant is a
    // compile error there and lands here automatically. An earlier version of
    // this test listed five keys by hand and passed while THREE variants
    // (`reserveUnavailable`, `sessionUnavailable`, `cancelledDuringCreation`)
    // rendered as "Order creation failed: <rawName>".
    const keys = Object.keys(CREATE_ORDER_ERROR_KEYS);
    expect(keys.length).toBeGreaterThan(5);
    for (const k of keys) {
      expect(createOrderErrorMessage(k), `no message for ${k}`).not.toMatch(/^Order creation failed: /);
    }
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

  test("amountBelowMin tells the user the floor, not just that it failed", () => {
    // Reachable by typing since #33 gave the rail custom amounts, and it was
    // rendering `undefined` until #30 PR-B aliased this union to the bindings.
    const msg = gateReasonMessage({
      __kind__: "amountBelowMin",
      amountBelowMin: { usdCents: 500n, minUsdCents: 1_000n },
    });
    expect(msg).toContain("$10.00");
  });

  test("reserveShort names both figures, because a smaller amount can succeed", () => {
    // ⚠️ The one refusal where "try again later" is the WRONG advice: the gateway can
    // still sell, just less. Sending the buyer away from a purchase it can make is a
    // lost sale for a reason the copy could have explained.
    const msg = gateReasonMessage({
      __kind__: "reserveShort",
      reserveShort: { requested: 7_000_000_000_000n, available: 3_500_000_000_000n },
    });
    expect(msg).toContain("3.5 T");
    expect(msg).toContain("7 T");
    expect(msg).toMatch(/smaller amount/i);
    expect(msg).toContain("Nothing was charged");
  });

  test("operational refusals promise nothing was charged", () => {
    // These are all pre-payment refusals, so the copy must say so — otherwise a
    // user seeing "unavailable" mid-purchase assumes money may have moved.
    //
    // ⚠️ This list used to hold `burnCapExhausted` and `floatLow`, which #30 PR-B
    // deleted from `Gate.Reason` — and it kept passing, because the union was a
    // hand-written mirror rather than the generated type. That is the whole reason
    // `GateReason` is now an alias: a deleted variant fails to compile here.
    const operational: GateReason[] = [
      { __kind__: "canisterCyclesLow", canisterCyclesLow: { balance: 0n, min: 1n } },
      { __kind__: "reserveShort", reserveShort: { requested: 2n, available: 1n } },
    ];
    for (const reason of operational) {
      expect(gateReasonMessage(reason)).toContain("Nothing was charged");
    }
  });

  test("EVERY variant renders a non-empty message", () => {
    // The gap this closes: `gateReasonMessage`'s switch has no default, so a variant
    // it does not name returns `undefined` and the buyer sees "undefined" in the UI.
    // Two variants were in exactly that state. Listing them all here means adding a
    // refusal to Gate.mo without copy fails a test rather than shipping.
    const all: GateReason[] = [
      { __kind__: "amountAboveMax", amountAboveMax: { usdCents: 2n, maxUsdCents: 1n } },
      { __kind__: "amountBelowMin", amountBelowMin: { usdCents: 1n, minUsdCents: 2n } },
      { __kind__: "tooManyOpenOrders", tooManyOpenOrders: { open: 3n, max: 3n } },
      { __kind__: "reserveShort", reserveShort: { requested: 2n, available: 1n } },
      { __kind__: "canisterCyclesLow", canisterCyclesLow: { balance: 0n, min: 1n } },
    ];
    const kinds = new Set(all.map((r) => r.__kind__));
    expect(kinds.size).toBe(5);
    for (const reason of all) {
      const msg = gateReasonMessage(reason);
      expect(msg, reason.__kind__).toBeTypeOf("string");
      expect(msg.length, reason.__kind__).toBeGreaterThan(0);
    }
  });
});

describe("the two-cause #unpriceable split (#99 review finding 2)", () => {
  test("⚠️ the simulation cause does NOT blame payment processing", () => {
    // The defect this split exists to fix: rendered as `tierBelowFees`, a buyer
    // refused by the operator's divisor is told the processing fee is too large.
    const msg = createOrderErrorMessage("simulationScaleTooSmall");
    expect(msg).toMatch(/simulation/i);
    expect(msg).not.toMatch(/processing|misconfigured/i);
    expect(msg).toMatch(/nothing was charged/i);
  });

  test("the Stripe-fee cause still says what it always said", () => {
    expect(createOrderErrorMessage("tierBelowFees")).toMatch(/fees would exceed/i);
  });

  test("the two causes do not share a message", () => {
    expect(createOrderErrorMessage("simulationScaleTooSmall"))
      .not.toBe(createOrderErrorMessage("tierBelowFees"));
  });
});

describe("the faucet and allow-list refusals (#99 2b)", () => {
  const faucet = { __kind__: "unboundedGiveaway", unboundedGiveaway: { reserveFloor: 1n } };
  const unlisted = { __kind__: "buyerNotAllowed", buyerNotAllowed: null };

  test("⚠️ BOTH tell the buyer they must be invited, and how to ask", () => {
    // An earlier version withheld the allow-list from the faucet case, reasoning that
    // the empty list is the operator's misconfiguration so asking for access "would
    // not help". That was FALSE, and a test pinned it: the condition is
    // `testPayments && listEmpty && reserveFunded`, so adding the asking buyer makes
    // the list non-empty, clears the condition AND admits them. Asking is the fix.
    for (const reason of [faucet, unlisted]) {
      const msg = gateReasonMessage(reason as never);
      expect(msg).toMatch(/invited/i);
      expect(msg).toMatch(/principal/i);
      expect(msg).toMatch(/nothing was charged/i);
    }
  });

  test("⚠️ neither uses operator vocabulary", () => {
    // A buyer must not be told the gateway is an "unbounded giveaway", or read a
    // description of the faucet. brand-lint checks characters, not audience, so
    // nothing else catches this.
    for (const reason of [faucet, unlisted]) {
      expect(gateReasonMessage(reason as never))
        .not.toMatch(/giveaway|faucet|reserve|unbounded/i);
    }
  });

  test("the buyer's instruction converges even though the reasons do not", () => {
    // Separate reasons, separate counters, separate operator diagnoses — one says the
    // list is missing and the other says it is working. What converges is the action
    // the BUYER takes, which is identical.
    expect(gateReasonMessage(faucet as never)).toBe(gateReasonMessage(unlisted as never));
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

describe("depositFeeLine", () => {
  test("⚠️ states the fee at a size where the figures read the SAME", () => {
    // The case that made the disclosure disappear: 3.5 T less 100 M is "3.5 T" at
    // three decimals, so `creditedSplit.note` is silent and the buy view had nothing
    // left to say about a charge the buyer pays on every order. Reachable by an
    // operator raising `maxPurchaseUsdCents`, which the console invites.
    const line = depositFeeLine(3_500_000_000_000n, 100_000_000n)!;
    expect(line).toContain("100 M");
    expect(line).toContain("transfer fee");
  });

  test("uses the sent-versus-credited wording when the two DO differ", () => {
    // One owner for the fee's wording: built on `creditedSplit`, so the note and this
    // line cannot state different fees for one order.
    expect(depositFeeLine(5_000_000_000n, 100_000_000n))
      .toBe(creditedSplit(5_000_000_000n, 100_000_000n).note);
  });

  test("says nothing about a fee it has not been told", () => {
    // A failed `icrc1_fee` leaves it at zero, and "no fee" would be a promise.
    expect(depositFeeLine(5_000_000_000n, 0n)).toBeNull();
  });
});

describe("estimateLine", () => {
  test("names the transfer fee when it moves the figure, so the gap is never a surprise", () => {
    // ⚠️ It asserted "deposit fee" — the operation the ledger charged for before #30
    // PR-A. Delivery is an `icrc1_transfer` out of the reserve now, so the fee the
    // buyer is shown is a transfer fee, and "deposit" pointed them at a mechanism
    // that no longer runs.
    const line = estimateLine(5_000_000_000n, 100_000_000n);
    expect(line).toContain("4.9 G");
    expect(line).toContain("transfer fee");
    expect(line).not.toContain("minted");
  });

  test("states the credited figure alone when the fee rounds away", () => {
    // 3.5 T less 100 M is still "3.5 T" at three decimals, so a split would read
    // as a contradiction. Repeating the fee here instead put the same
    // parenthetical on every amount tile and in the note below them — the fee is
    // stated for the chosen amount by `depositFeeLine`, which is unconditional.
    expect(estimateLine(3_500_000_000_000n, 100_000_000n)).toBe("≈ 3.5 T cycles");
  });

  test("says nothing about a fee it has not been told", () => {
    // `transferFee` is 0n until the first quote answers, and after a failed one.
    expect(estimateLine(5_000_000_000n, 0n)).toBe("≈ 5 G cycles");
  });

  test("says orders are paused rather than showing a zero when unpriceable", () => {
    expect(estimateLine(null, 100_000_000n)).toContain("paused");
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

describe("checkReceipt: the simulation divisor (#99)", () => {
  const verification = {
    netCents: 455n,
    usdPerIcpMicros: 4_550_000n,
    xdrPermyriadPerIcp: 35_000n,
    rateReceivedRates: 5n,
    rateQueriedSources: 6n,
  };
  const PRODUCTION = 3_500_000_000_000n;

  test("⚠️ divisor 1 is byte-identical to the pre-#99 receipt", () => {
    // Including the formula string: a production receipt must not gain a term.
    const before = checkReceipt(verification, PRODUCTION);
    const explicit = checkReceipt(verification, PRODUCTION, 1n);
    expect(explicit).toEqual(before);
    expect(explicit.formula).not.toContain("divisor");
  });

  test("a scaled order verifies against the scaled quantity", () => {
    const check = checkReceipt(verification, PRODUCTION / 1_000n, 1_000n);
    expect(check.matches).toBe(true);
  });

  test("⚠️ recomputed stays the PRODUCTION quantity — the receipt shows both legs", () => {
    // The whole value of a global divisor: what production would have locked is
    // recomputed here from the order's own rate inputs, not stored and trusted.
    const check = checkReceipt(verification, PRODUCTION / 1_000n, 1_000n);
    expect(check.recomputed).toBe(PRODUCTION);
    expect(check.formula).toContain("÷ 1000 simulation divisor");
  });

  test("the unscaled quantity does NOT verify under a divisor", () => {
    // If it did, the check would be blind to the divisor and could not catch a
    // gateway delivering production quantities while claiming to simulate.
    expect(checkReceipt(verification, PRODUCTION, 1_000n).matches).toBe(false);
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

describe("formatDuration", () => {
  test("a duration, with no suffix", () => {
    // ⚠️ Split out because "ago" is not always right: a delayed delivery has WAITED three
    // hours. The worklist row rendered "waiting 213 days ago" before this existed, and a
    // screenshot is what caught it.
    expect(formatDuration(30_000)).toBe("under a minute");
    expect(formatDuration(60_000)).toBe("1 minute");
    expect(formatDuration(3 * 3_600_000)).toBe("3 hours");
    expect(formatDuration(2 * 86_400_000)).toBe("2 days");
  });
});

describe("formatAgo", () => {
  const now = 1_700_000_000_000;
  test("coarse buckets, because the question is whether it is stale", () => {
    expect(formatAgo(now - 30_000, now)).toBe("under a minute ago");
    expect(formatAgo(now - 60_000, now)).toBe("1 minute ago");
    expect(formatAgo(now - 42 * 60_000, now)).toBe("42 minutes ago");
    expect(formatAgo(now - 60 * 60_000, now)).toBe("1 hour ago");
    expect(formatAgo(now - 5 * 3_600_000, now)).toBe("5 hours ago");
    expect(formatAgo(now - 24 * 3_600_000, now)).toBe("1 day ago");
    expect(formatAgo(now - 9 * 86_400_000, now)).toBe("9 days ago");
  });

  test("a clock that is behind reads as the future, and says so", () => {
    // Rather than printing a negative interval, which reads as a bug in the figure
    // rather than in the clock.
    expect(formatAgo(now + 60_000, now)).toBe("in the future (check the clock)");
  });

  test("⚠️ NOT timeUntil: that returns null for anything past", () => {
    // Reusing it here would render every observation as absent, i.e. "never observed"
    // for a reserve observed a minute ago, which is the one number the line reports.
    expect(timeUntil(now - 60_000, now)).toBeNull();
    expect(formatAgo(now - 60_000, now)).toBe("1 minute ago");
  });
});

describe("StatusKey is derived from the generated enum (#68)", () => {
  test("statusInfo answers for every status the canister has", () => {
    // ⚠️ The point is not this list: it is that `StatusKey` is `${OrderStatus}`, so a
    // status added to the canister makes `statusInfo`'s switch non-exhaustive and fails
    // the typecheck. It used to be a hand-written union reached through
    // `order.status as unknown as StatusKey` — a double cast, so a new status compiled
    // fine, fell off the end of the switch, and threw on `.label`.
    const keys: StatusKey[] = [
      "created", "cancelled", "expired", "paid", "delivered", "needsReview", "abandoned",
    ];
    for (const key of keys) {
      expect(typeof statusInfo(key).label).toBe("string");
      expect(statusInfo(key).label.length).toBeGreaterThan(0);
    }
  });
});

describe("decodeBurnMemo: which action a burn was", () => {
  // The bytes a real cycles ledger wrote. Captured from a local create and a local
  // withdraw issued against the SAME target canister, so nothing but the operation
  // differs between them. Both blocks reported op "burn" and block type 1burn.
  const CREATE_MEMO = new Uint8Array(32).fill(0xfe);
  const TOPUP_MEMO = new Uint8Array([
    0x81, 0x4a, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xa0, 0x00, 0x05, 0x01, 0x01,
  ]);

  test("a top-up names its target canister", () => {
    // The principal this decodes to is the canister the withdraw was actually issued
    // to, so this pins the CBOR offsets rather than just the shape.
    expect(decodeBurnMemo([TOPUP_MEMO])).toEqual({
      kind: "topUp",
      canister: "4xhad-gd777-77775-aaacq-cai",
    });
  });

  test("a creation is detected, and carries NO canister", () => {
    // ⚠️ The absence is the finding, not an omission here: the created id is returned by
    // the method and never written into the block, so no later read can recover it.
    const decoded = decodeBurnMemo([CREATE_MEMO]);
    expect(decoded).toEqual({ kind: "creation" });
    expect(decoded).not.toHaveProperty("canister");
  });

  test("an absent memo is unknown, not a creation", () => {
    expect(decodeBurnMemo([])).toEqual({ kind: "unknown" });
  });

  test("near-misses on the sentinel do not read as a creation", () => {
    // Matched on exact length and every byte, so neither a short run nor a long one
    // nor one wrong byte can be mistaken for the ledger's sentinel.
    expect(decodeBurnMemo([new Uint8Array(31).fill(0xfe)])).toEqual({ kind: "unknown" });
    expect(decodeBurnMemo([new Uint8Array(33).fill(0xfe)])).toEqual({ kind: "unknown" });
    const oneOff = new Uint8Array(32).fill(0xfe);
    oneOff[17] = 0xfd;
    expect(decodeBurnMemo([oneOff])).toEqual({ kind: "unknown" });
  });

  test("a CBOR-shaped memo of the wrong length does not decode a truncated id", () => {
    // Prefix matching would take the first bytes of a longer payload and render a
    // principal that names a canister nobody touched. Length is part of the match.
    expect(decodeBurnMemo([new Uint8Array([0x81, 0x4a, 0x00, 0x00, 0x01, 0x01])]))
      .toEqual({ kind: "unknown" });
    const tooLong = new Uint8Array([
      0x81, 0x4a, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xa0, 0x00, 0x05, 0x01, 0x01, 0x99,
    ]);
    expect(decodeBurnMemo([tooLong])).toEqual({ kind: "unknown" });
  });

  test("an unrecognised memo is unknown rather than thrown away", () => {
    expect(decodeBurnMemo([new Uint8Array([1, 2, 3])])).toEqual({ kind: "unknown" });
  });
});

describe("⚠️ a burn is the CHARGE, never the outcome", () => {
  // Measured, not reasoned: a create pinned to a nonexistent subnet and a withdraw to a
  // nonexistent canister both FAILED, and both still wrote a burn whose memo is
  // indistinguishable from the succeeding case. The refund arrived as a separate later
  // block. So nothing here may report success.
  test("a FAILED creation writes the same memo as a successful one", () => {
    const fromFailedCreate = new Uint8Array(32).fill(0xfe);
    expect(decodeBurnMemo([fromFailedCreate])).toEqual({ kind: "creation" });
  });

  test("a FAILED withdraw writes the same CBOR target as a successful one", () => {
    // rrkah-fqaaa-aaaaa-aaaaq-cai, which does not exist on the network this was measured
    // on. The withdraw was rejected DestinationInvalid and this burn was still written.
    const fromFailedWithdraw = new Uint8Array([
      0x81, 0x4a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01,
    ]);
    expect(decodeBurnMemo([fromFailedWithdraw])).toEqual({
      kind: "topUp",
      canister: "rrkah-fqaaa-aaaaa-aaaaq-cai",
    });
  });

  test("a withdraw to the management canister does not decode a bogus target", () => {
    // `aaaaa-aa` has ZERO principal bytes, so the ledger wrote CBOR array(1) of an empty
    // byte string: 0x81 0x40, two bytes. Prefix matching on 0x81 would have produced a
    // principal from nothing.
    expect(decodeBurnMemo([new Uint8Array([0x81, 0x40])])).toEqual({ kind: "unknown" });
  });

  test("⚠️ the refund sentinels are NOT decoded here, because they are forgeable", () => {
    // `FD * 32` is a failed creation's refund and `FF * 32` a failed withdraw's, but both
    // arrive as MINTS, and `deposit` takes a caller-supplied memo. Decoding them would let
    // anyone deposit memoed `FF * 32` and fake a refund. They are only ever seen on mints,
    // so this function must not claim them even if handed one.
    expect(decodeBurnMemo([new Uint8Array(32).fill(0xfd)])).toEqual({ kind: "unknown" });
    expect(decodeBurnMemo([new Uint8Array(32).fill(0xff)])).toEqual({ kind: "unknown" });
  });
});
