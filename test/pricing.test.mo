import { test; suite } "mo:test";
import Pricing "../src/backend/Pricing";

// Unit suite for §3 pricing: the fee formula, the two-rate cycle derivation,
// staleness, the plausibility band, and the delta guard. Everything here is
// pure over a cache and a config, so the whole pricing policy is pinned without
// an IC environment.

// ── The shared vector ──────────────────────────────────────────────────────
//
// Chosen so the at-cost property is checkable by eye rather than buried in a
// magic constant:
//
//   500¢ gross − (⌈500·290/10⁴⌉ + 30)¢ fee = 455¢ net
//   at $4.55 per ICP, 455¢ buys exactly 1 ICP
//   1 ICP mints 35_000 · 10⁸ = 3.5 T cycles
//
// So the dollars received buy exactly the ICP needed to mint what was quoted.
// If those two ever disagree, the formula is wrong.
let USD_PER_ICP_MICROS : Nat = 4_550_000;
let XDR_PERMYRIAD : Nat = 35_000;
let NET_CENTS : Nat = 455;
let VECTOR_CYCLES : Nat = 3_500_000_000_000;

let fee = { feeBps = 290; feeFixedCents = 30 };
let config = Pricing.defaultConfig();

func ratesAt(nowNs : Int) : Pricing.Rates {
  {
    usdPerIcpMicros = USD_PER_ICP_MICROS;
    xdrPermyriadPerIcp = XDR_PERMYRIAD;
    fetchedAtNs = nowNs;
    quality = { standardDeviation = 0; receivedRates = 5; queriedSources = 5 };
  };
};

func cacheAt(nowNs : Int) : Pricing.Cache {
  let cache = Pricing.emptyCache();
  Pricing.record(cache, ratesAt(nowNs));
  cache;
};

suite("fee formula (§3 net-of-fees)", func() {
  test("the vector: 500¢ gross nets 455¢", func() {
    assert Pricing.netCents(fee, 500) == ?NET_CENTS;
  });

  test("the fee rounds UP, so rounding never favours the buyer", func() {
    // 500·290/10⁴ = 14.5 → 15, not 14.
    assert Pricing.netCents({ feeBps = 290; feeFixedCents = 0 }, 500) == ?485;
  });

  test("an amount the fee swallows is unpriceable, not negative", func() {
    assert Pricing.netCents(fee, 30) == null;
    assert Pricing.netCents(fee, 31) == null; // 1 + 30 = 31, not < 31
    assert Pricing.netCents(fee, 32) == ?1;
  });

  test("a zero-fee formula nets the gross unchanged (the ck-USDC rail)", func() {
    assert Pricing.netCents({ feeBps = 0; feeFixedCents = 0 }, 500) == ?500;
  });
});

suite("cycle derivation (§3)", func() {
  test("THE VECTOR: 455¢ at $4.55/ICP and 3.5 XDR/ICP = 3.5 T cycles", func() {
    assert Pricing.cyclesForCents(NET_CENTS, XDR_PERMYRIAD, USD_PER_ICP_MICROS) == ?VECTOR_CYCLES;
  });

  test("the quoted cycles cost exactly the ICP the dollars bought", func() {
    // This is the at-cost invariant, stated as arithmetic. One e8s mints
    // `xdrPermyriadPerIcp` cycles, so the e8s needed for the quote is
    // cycles/P — and that must equal the e8s the net dollars buy at the ICP
    // price used to quote them.
    let ?cycles = Pricing.cyclesForCents(NET_CENTS, XDR_PERMYRIAD, USD_PER_ICP_MICROS) else return assert false;
    let e8sNeeded = cycles / XDR_PERMYRIAD;
    // netCents buys netCents·10⁴/U ICP, and 1 ICP = 10⁸ e8s.
    let e8sBought = NET_CENTS * 10_000 * 100_000_000 / USD_PER_ICP_MICROS;
    assert e8sNeeded == 100_000_000; // exactly 1 ICP
    assert e8sNeeded == e8sBought;
  });

  test("doubling the net amount doubles the cycles", func() {
    let ?one = Pricing.cyclesForCents(NET_CENTS, XDR_PERMYRIAD, USD_PER_ICP_MICROS) else return assert false;
    let ?two = Pricing.cyclesForCents(NET_CENTS * 2, XDR_PERMYRIAD, USD_PER_ICP_MICROS) else return assert false;
    assert two == one * 2;
  });

  test("a dearer ICP buys fewer cycles for the same dollars", func() {
    // The buyer is unaffected in XDR terms only if the CMC rate moves with it;
    // this pins the direction of the dependency.
    let ?base = Pricing.cyclesForCents(NET_CENTS, XDR_PERMYRIAD, USD_PER_ICP_MICROS) else return assert false;
    let ?dearer = Pricing.cyclesForCents(NET_CENTS, XDR_PERMYRIAD, USD_PER_ICP_MICROS * 2) else return assert false;
    assert dearer == base / 2;
  });

  test("a richer CMC rate mints more cycles per ICP", func() {
    let ?base = Pricing.cyclesForCents(NET_CENTS, XDR_PERMYRIAD, USD_PER_ICP_MICROS) else return assert false;
    let ?richer = Pricing.cyclesForCents(NET_CENTS, XDR_PERMYRIAD * 2, USD_PER_ICP_MICROS) else return assert false;
    assert richer == base * 2;
  });

  test("division FLOORS, so a quote never exceeds what the money buys", func() {
    // 1¢ at $4.55/ICP with 3.5 XDR/ICP is 7_692_307_692.3… cycles.
    assert Pricing.cyclesForCents(1, XDR_PERMYRIAD, USD_PER_ICP_MICROS) == ?7_692_307_692;
  });

  test("a zero ICP price is unpriceable rather than a division trap", func() {
    assert Pricing.cyclesForCents(NET_CENTS, XDR_PERMYRIAD, 0) == null;
  });

  test("a zero CMC rate quotes zero cycles, which the caller must reject", func() {
    // Mirrors Cmc.freshCmcRate treating a zero permyriad as unusable — this
    // function only guarantees it will not trap.
    assert Pricing.cyclesForCents(NET_CENTS, 0, USD_PER_ICP_MICROS) == ?0;
  });
});

suite("staleness (§3.1 fail-closed)", func() {
  test("an empty cache has no rates", func() {
    assert Pricing.freshRates(Pricing.emptyCache(), config.maxAgeNs, 0) == null;
    assert Pricing.lastRates(Pricing.emptyCache()) == null;
  });

  test("one ns short of the window is fresh; exactly at it is stale", func() {
    let cache = cacheAt(1_000);
    assert Pricing.freshRates(cache, config.maxAgeNs, 1_000 + config.maxAgeNs - 1) != null;
    assert Pricing.freshRates(cache, config.maxAgeNs, 1_000 + config.maxAgeNs) == null;
  });

  test("lastRates still reports a stale pair, for status and the delta guard", func() {
    let cache = cacheAt(1_000);
    let far = 1_000 + config.maxAgeNs * 100;
    assert Pricing.freshRates(cache, config.maxAgeNs, far) == null;
    assert Pricing.lastRates(cache) != null;
  });
});

suite("config bounds", func() {
  test("the default config validates and keeps the window short", func() {
    assert Pricing.validateConfig(config) == #ok;
    // ICP/USD is volatile, so the window must be minutes, not hours.
    assert config.maxAgeNs <= 300_000_000_000;
  });

  test("a fee of 100% or more is refused", func() {
    assert Pricing.validateConfig({ config with feeBps = 10_000 }) == #err(#feeBpsTooHigh);
  });

  test("a non-positive window is refused", func() {
    assert Pricing.validateConfig({ config with maxAgeNs = 0 }) == #err(#nonPositiveMaxAge);
  });

  test("a window beyond the allowed ceiling is refused — it is a security bound", func() {
    // The refresh is timer-driven, and a stale cache refusing to price is what
    // makes a dead timer safe. An unbounded window would let orders be priced
    // indefinitely off a frozen rate.
    let tooLong = Pricing.maxAllowedMaxAgeNs + 1;
    assert Pricing.validateConfig({ config with maxAgeNs = tooLong })
      == #err(#maxAgeTooLong({ maxAgeNs = tooLong; allowedNs = Pricing.maxAllowedMaxAgeNs }));
    assert Pricing.validateConfig({ config with maxAgeNs = Pricing.maxAllowedMaxAgeNs }) == #ok;
  });

  test("a zero delta bound is refused — it would reject every later refresh", func() {
    assert Pricing.validateConfig({ config with maxRateDeltaBps = 0 }) == #err(#zeroRateDelta);
  });
});

suite("plausibility band", func() {
  test("the vector price is plausible", func() {
    assert Pricing.plausibleUsdPerIcp(USD_PER_ICP_MICROS);
  });

  test("the band is inclusive at both ends", func() {
    assert Pricing.plausibleUsdPerIcp(Pricing.minUsdPerIcpMicros);
    assert Pricing.plausibleUsdPerIcp(Pricing.maxUsdPerIcpMicros);
    assert not Pricing.plausibleUsdPerIcp(Pricing.minUsdPerIcpMicros - 1);
    assert not Pricing.plausibleUsdPerIcp(Pricing.maxUsdPerIcpMicros + 1);
  });

  test("decimal-point disasters are rejected in both directions", func() {
    assert not Pricing.plausibleUsdPerIcp(USD_PER_ICP_MICROS / 1_000);
    assert not Pricing.plausibleUsdPerIcp(USD_PER_ICP_MICROS * 10_000);
  });

  test("zero is never plausible", func() {
    assert not Pricing.plausibleUsdPerIcp(0);
  });
});

suite("delta guard", func() {
  test("the first observation is always accepted — nothing to compare to", func() {
    assert Pricing.withinDelta(null, USD_PER_ICP_MICROS, config.maxRateDeltaBps);
  });

  test("an unchanged rate is accepted", func() {
    assert Pricing.withinDelta(?USD_PER_ICP_MICROS, USD_PER_ICP_MICROS, config.maxRateDeltaBps);
  });

  test("a move at exactly the bound is accepted, beyond it rejected", func() {
    // 10% bound against 1_000_000.
    assert Pricing.withinDelta(?1_000_000, 1_100_000, 1_000);
    assert not Pricing.withinDelta(?1_000_000, 1_100_001, 1_000);
  });

  test("the guard is symmetric — a crash is caught like a spike", func() {
    assert not Pricing.withinDelta(?1_000_000, 400_000, 1_000);
    assert not Pricing.withinDelta(?1_000_000, 2_000_000, 1_000);
  });

  test("the default bound tolerates a real market move within one interval", func() {
    // A 20% swing inside 5 minutes is extreme but possible; it must not take
    // pricing offline, because rejecting means failing closed.
    assert Pricing.withinDelta(?USD_PER_ICP_MICROS, USD_PER_ICP_MICROS * 12 / 10, config.maxRateDeltaBps);
    assert Pricing.withinDelta(?USD_PER_ICP_MICROS, USD_PER_ICP_MICROS * 8 / 10, config.maxRateDeltaBps);
  });

  test("an order-of-magnitude jump is rejected by the default bound", func() {
    assert not Pricing.withinDelta(?USD_PER_ICP_MICROS, USD_PER_ICP_MICROS * 10, config.maxRateDeltaBps);
  });
});

suite("quote (the composed path)", func() {
  test("the vector quotes end to end and carries the rates it used", func() {
    let cache = cacheAt(1_000);
    switch (Pricing.quote(cache, fee, config.maxAgeNs, 500, 1_100)) {
      case (#ok({ cycles; rates })) {
        assert cycles == VECTOR_CYCLES;
        // The snapshot carries both inputs, so the quote is reproducible.
        assert rates.usdPerIcpMicros == USD_PER_ICP_MICROS;
        assert rates.xdrPermyriadPerIcp == XDR_PERMYRIAD;
        assert rates.quality.queriedSources == 5;
      };
      case (_) assert false;
    };
  });

  test("a stale cache is #stale, distinct from unpriceable", func() {
    let cache = cacheAt(1_000);
    assert Pricing.quote(cache, fee, config.maxAgeNs, 500, 1_000 + config.maxAgeNs) == #stale;
  });

  test("an empty cache is #stale — never priced on a guess", func() {
    assert Pricing.quote(Pricing.emptyCache(), fee, config.maxAgeNs, 500, 1_000) == #stale;
  });

  test("an amount below the fee floor is #unpriceable, even with fresh rates", func() {
    let cache = cacheAt(1_000);
    assert Pricing.quote(cache, fee, config.maxAgeNs, 30, 1_100) == #unpriceable;
  });

  test("a zero ICP price in the cache is #unpriceable, not a trap", func() {
    let cache = Pricing.emptyCache();
    Pricing.record(cache, { ratesAt(1_000) with usdPerIcpMicros = 0 });
    assert Pricing.quote(cache, fee, config.maxAgeNs, 500, 1_100) == #unpriceable;
  });
});

suite("implied XDR/USD cross-check", func() {
  test("the vector implies a plausible XDR/USD", func() {
    // 3.5 XDR/ICP against $4.55/ICP implies 0.769 XDR/USD — right where an IMF
    // basket rate should sit.
    let ?implied = Pricing.impliedXdrPerUsdMicros(XDR_PERMYRIAD, USD_PER_ICP_MICROS) else return assert false;
    assert implied == 769_230;
    assert Pricing.plausibleImpliedXdrPerUsd(implied);
  });

  test("an XRC price 10x too high is caught by the cross-check", func() {
    // The wide ICP-price band accepts $45.50 — this is the guard that does not.
    let tenXHigh = USD_PER_ICP_MICROS * 10;
    assert Pricing.plausibleUsdPerIcp(tenXHigh); // the band alone lets it through
    let ?implied = Pricing.impliedXdrPerUsdMicros(XDR_PERMYRIAD, tenXHigh) else return assert false;
    assert not Pricing.plausibleImpliedXdrPerUsd(implied);
  });

  test("an XRC price 10x too low is caught symmetrically", func() {
    let tenXLow = USD_PER_ICP_MICROS / 10;
    assert Pricing.plausibleUsdPerIcp(tenXLow);
    let ?implied = Pricing.impliedXdrPerUsdMicros(XDR_PERMYRIAD, tenXLow) else return assert false;
    assert not Pricing.plausibleImpliedXdrPerUsd(implied);
  });

  test("the band is inclusive at both ends", func() {
    assert Pricing.plausibleImpliedXdrPerUsd(Pricing.minImpliedXdrPerUsdMicros);
    assert Pricing.plausibleImpliedXdrPerUsd(Pricing.maxImpliedXdrPerUsdMicros);
    assert not Pricing.plausibleImpliedXdrPerUsd(Pricing.minImpliedXdrPerUsdMicros - 1);
    assert not Pricing.plausibleImpliedXdrPerUsd(Pricing.maxImpliedXdrPerUsdMicros + 1);
  });

  test("the band spans the real historical XDR/USD range with headroom", func() {
    // XDR/USD has lived in ~0.6–0.9 for decades; the band must never reject that.
    for (micros in ([600_000, 700_000, 769_230, 800_000, 900_000] : [Nat]).values()) {
      assert Pricing.plausibleImpliedXdrPerUsd(micros);
    };
  });

  test("a real CMC rate move keeps the implied rate plausible", func() {
    // The cross-check must not fire when BOTH sources move consistently — an
    // ICP rally shows up in the CMC rate too.
    let ?implied = Pricing.impliedXdrPerUsdMicros(XDR_PERMYRIAD * 2, USD_PER_ICP_MICROS * 2) else return assert false;
    assert Pricing.plausibleImpliedXdrPerUsd(implied);
  });

  test("a zero ICP price cannot imply anything", func() {
    assert Pricing.impliedXdrPerUsdMicros(XDR_PERMYRIAD, 0) == null;
  });
});

suite("minimum rate sources", func() {
  test("the default requires more than one answering source", func() {
    // XRC's own InconsistentRatesReceived cannot fire for a single rate, so this
    // is the only guard that sees the degenerate one-exchange case.
    assert config.minRateSources >= 2;
  });

  test("requiring zero sources is refused as config", func() {
    assert Pricing.validateConfig({ config with minRateSources = 0 }) == #err(#zeroRateSources);
  });

  test("the default stays low, because strictness costs availability", func() {
    // Every increment means more rateUnavailable outages on a bad XRC day.
    assert config.minRateSources <= 3;
  });
});
