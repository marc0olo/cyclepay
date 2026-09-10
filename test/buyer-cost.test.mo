import { test; suite } "mo:test";
import Runtime "mo:core/Runtime";
import Pricing "../src/backend/Pricing";

/// Pins the tier table in `docs/BUYER-COST-MODEL.md` to **this canister's own arithmetic**.
///
/// ⚠️ **Why this exists: that document reimplemented the fee formula, and a reimplementation
/// cannot check itself.** The doc carries a Python snippet for reproducing its figures, and
/// because the snippet is the same transcription the table came from, running it confirms
/// only that the transcription is self-consistent. It said `$5 → $4.56 net` while
/// `Pricing.feeCents` **ceilings** the basis-point part — `(gross × bps + 9_999) / 10_000` —
/// which nets $4.55. $5 was the only tier where floor and ceiling differ, so nothing else
/// in the table was wrong and nothing in the doc could have caught it.
///
/// So the numbers a reader acts on are asserted here against `Pricing.feeCents` and
/// `Pricing.cyclesForCents`, and any change to the fee config or the formula fails this
/// suite with the tier that moved.
///
/// ⚠️ **What this does NOT pin.** The cost side — creation fee, storage rate, ingress bytes
/// — has no oracle in this repo: those are the IC's published prices, and the doc cites the
/// source. This covers the half that *is* ours.

/// `Pricing.defaultConfig()`'s fee, restated so a change there fails here loudly rather
/// than silently re-basing every figure in the document.
let fee = { feeBps = 290; feeFixedCents = 30 };

/// A rate pair encoding the real XDR/USD rate the document quotes: 1 XDR = $1.373470, so
/// $1.00 = 0.728083 XDR (IMF, 2026-09-10).
///
/// ⚠️ **ICP is an intermediate unit and cancels** — `cyclesForCents` divides
/// `xdrPermyriadPerIcp` by `usdPerIcpMicros`, so only their ratio matters and the ICP price
/// chosen here is arbitrary. $4.55/ICP is used because it is the §3 vector's, which keeps
/// the pair recognisable; `33_128` is then the permyriad that lands on the IMF ratio to
/// within 0.0007%.
let usdPerIcpMicros = 4_550_000;
let xdrPermyriadPerIcp = 33_128;

func cycles(grossCents : Nat) : Nat {
  let ?net = Pricing.netCents(fee, grossCents) else Runtime.trap("no net for " # debug_show grossCents);
  let ?c = Pricing.cyclesForCents(net, xdrPermyriadPerIcp, usdPerIcpMicros) else Runtime.trap("no cycles");
  c;
};

/// What two canisters cost to create with `icp canister create`'s default `--cycles`.
/// The document's headline rests on this being the comparison, not the consumed figure.
let UPFRONT_2_CANISTERS = 4_000_000_000_000;

suite("docs/BUYER-COST-MODEL.md — the fee arithmetic is this canister's", func() {
  test("⚠️ $5 nets 455 cents, not 456 — feeCents CEILINGS the bps part", func() {
    // (500 × 290 + 9_999) / 10_000 = 15, not the 14 that flooring gives. $5 is the only
    // tier in the table where the two disagree, which is why a floored transcription of
    // the formula looked correct everywhere else.
    assert Pricing.feeCents(fee, 500) == 45;
    assert Pricing.netCents(fee, 500) == ?455;
  });

  test("the other tiers are unaffected by the rounding", func() {
    assert Pricing.netCents(fee, 1_000) == ?941;
    assert Pricing.netCents(fee, 2_000) == ?1_912;
    assert Pricing.netCents(fee, 5_000) == ?4_825;
  });

  test("the fee share the document quotes per tier", func() {
    // 9.0% of $5 and 5.9% of $10 — the regressive-fixed-fee argument, in basis points so
    // the assertion is exact rather than a rounded percentage.
    assert Pricing.feeCents(fee, 500) * 10_000 / 500 == 900;
    assert Pricing.feeCents(fee, 1_000) * 10_000 / 1_000 == 590;
  });
});

suite("docs/BUYER-COST-MODEL.md — the tier table", func() {
  test("⚠️ $5 does NOT cover two canisters at the CLI default", func() {
    let got = cycles(500);
    // 3.313 T, and the document says so. Asserted as a range because the last digits
    // depend on the rate pair's integer encoding, not on anything this test is about.
    assert got >= 3_312_000_000_000 and got <= 3_314_000_000_000;
    assert got < UPFRONT_2_CANISTERS;
    // Short by ~0.69 T. This is the number the whole document turns on.
    assert UPFRONT_2_CANISTERS - got >= 686_000_000_000;
  });

  test("$10 covers them, 1.7×", func() {
    let got = cycles(1_000);
    assert got >= 6_850_000_000_000 and got <= 6_852_000_000_000;
    assert got > UPFRONT_2_CANISTERS;
    assert got * 10 / UPFRONT_2_CANISTERS == 17; // 1.7×
  });

  test("$20 and $50, for the rest of the table", func() {
    let c20 = cycles(2_000);
    let c50 = cycles(5_000);
    assert c20 >= 13_920_000_000_000 and c20 <= 13_922_000_000_000;
    assert c50 >= 35_129_000_000_000 and c50 <= 35_131_000_000_000;
  });

  test("⚠️ one canister is affordable at $5, which is why the failure lands on the second", func() {
    // The failure mode the document describes: `icp deploy` creates the first canister and
    // then asks for another 2 T the buyer does not have. Reported by the CLI, with nothing
    // pointing back at the purchase being too small.
    let got = cycles(500);
    assert got >= 2_000_000_000_000;
    assert got - 2_000_000_000_000 < 2_000_000_000_000;
  });
});
