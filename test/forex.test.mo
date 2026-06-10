import { test; suite } "mo:test";
import Text "mo:core/Text";
import Forex "../src/backend/Forex";

// Unit suite for the §3.1 forex subsystem's pure half: rate extraction +
// coarse rounding (the outcall transform), plausibility band, fee formula
// (§3 net-of-fees), staleness, and the cycles quote. The outcall itself is
// mocked as crafted Blob bodies; the live wiring is PocketIC coverage
// (task 12).

// Realistic open.er-api.com USD-base body shape (truncated): the parser must
// find "XDR" inside a large rates object, not at the top level.
let realisticBody = "{\"result\":\"success\",\"provider\":\"https://www.exchangerate-api.com\",\"time_last_update_unix\":1718000000,\"base_code\":\"USD\",\"rates\":{\"USD\":1,\"AED\":3.6725,\"EUR\":0.9234,\"XDR\":0.737421,\"ZAR\":18.4011}}";

func cfg(feeBps : Nat, feeFixedCents : Nat, maxAgeNs : Int) : Forex.Config {
  { url = "https://open.er-api.com/v6/latest/USD"; feeBps; feeFixedCents; maxAgeNs };
};

suite("extractXdrPerUsdMicros", func() {
  test("realistic USD-base body", func() {
    assert Forex.extractXdrPerUsdMicros(realisticBody) == ?737_421;
  });

  test("whitespace around the colon", func() {
    assert Forex.extractXdrPerUsdMicros("{\"XDR\" : 0.74}") == ?740_000;
    assert Forex.extractXdrPerUsdMicros("{\"XDR\":\n\t 0.74}") == ?740_000;
  });

  test("integer rate (no fraction)", func() {
    assert Forex.extractXdrPerUsdMicros("{\"XDR\":1}") == ?1_000_000;
  });

  test("fractional digits beyond 6 are truncated", func() {
    assert Forex.extractXdrPerUsdMicros("{\"XDR\":0.1234567}") == ?123_456;
    assert Forex.extractXdrPerUsdMicros("{\"XDR\":0.12345678901}") == ?123_456;
  });

  test("first XDR key wins", func() {
    assert Forex.extractXdrPerUsdMicros("{\"XDR\":0.7,\"XDR\":0.9}") == ?700_000;
  });

  test("missing key is null", func() {
    assert Forex.extractXdrPerUsdMicros("{\"USD\":1,\"EUR\":0.92}") == null;
    assert Forex.extractXdrPerUsdMicros("") == null;
  });

  test("XDR as a substring of a longer string is not the key", func() {
    // "XDR basket" lacks the closing quote right after R.
    assert Forex.extractXdrPerUsdMicros("{\"name\":\"XDR basket\"}") == null;
  });

  test("non-numeric value is null", func() {
    assert Forex.extractXdrPerUsdMicros("{\"XDR\":\"0.74\"}") == null;
    assert Forex.extractXdrPerUsdMicros("{\"XDR\":}") == null;
  });

  test("negative rate is null (no sign accepted)", func() {
    assert Forex.extractXdrPerUsdMicros("{\"XDR\":-0.74}") == null;
  });

  test("dot with no fractional digits is null", func() {
    assert Forex.extractXdrPerUsdMicros("{\"XDR\":0.}") == null;
  });

  test("key present but nothing after colon is null", func() {
    assert Forex.extractXdrPerUsdMicros("{\"XDR\":") == null;
  });
});

suite("coarseRound", func() {
  test("rounds half up to the 1_000-micro step", func() {
    assert Forex.coarseRound(737_421) == 737_000;
    assert Forex.coarseRound(737_499) == 737_000;
    assert Forex.coarseRound(737_500) == 738_000;
    assert Forex.coarseRound(737_999) == 738_000;
  });

  test("exact multiples are fixed points", func() {
    assert Forex.coarseRound(737_000) == 737_000;
    assert Forex.coarseRound(0) == 0;
  });
});

suite("plausible", func() {
  test("band edges are inclusive", func() {
    assert Forex.plausible(100_000);
    assert Forex.plausible(10_000_000);
    assert not Forex.plausible(99_999);
    assert not Forex.plausible(10_000_001);
  });

  test("zero (free cycles) is implausible", func() {
    assert not Forex.plausible(0);
  });
});

suite("transformBody", func() {
  test("realistic body becomes the canonical rounded micros", func() {
    assert Forex.transformBody(realisticBody.encodeUtf8()) == "737000".encodeUtf8();
  });

  test("parse failure becomes the empty body", func() {
    assert Forex.transformBody("not json at all".encodeUtf8()) == "".encodeUtf8();
    assert Forex.transformBody("".encodeUtf8()) == "".encodeUtf8();
  });

  test("zero rate is rejected (would price orders free)", func() {
    assert Forex.transformBody("{\"XDR\":0}".encodeUtf8()) == "".encodeUtf8();
  });

  test("decimal-point bug at the source is rejected", func() {
    // 737.4 XDR/USD = 1000x off; the band catches it before consensus.
    assert Forex.transformBody("{\"XDR\":737.4}".encodeUtf8()) == "".encodeUtf8();
    assert Forex.transformBody("{\"XDR\":0.000737}".encodeUtf8()) == "".encodeUtf8();
  });

  test("rounding into the band boundary is accepted", func() {
    assert Forex.transformBody("{\"XDR\":0.0995}".encodeUtf8()) == "100000".encodeUtf8();
  });
});

suite("parseCanonicalMicros", func() {
  test("round-trips the transform output", func() {
    assert Forex.parseCanonicalMicros("737000".encodeUtf8()) == ?737_000;
  });

  test("empty (transform failure) is null", func() {
    assert Forex.parseCanonicalMicros("".encodeUtf8()) == null;
  });

  test("non-digits are null", func() {
    assert Forex.parseCanonicalMicros("73a000".encodeUtf8()) == null;
    assert Forex.parseCanonicalMicros("0.737".encodeUtf8()) == null;
  });

  test("re-applies the plausibility band", func() {
    assert Forex.parseCanonicalMicros("5".encodeUtf8()) == null;
    assert Forex.parseCanonicalMicros("10000000".encodeUtf8()) == ?10_000_000;
    assert Forex.parseCanonicalMicros("10000001".encodeUtf8()) == null;
  });
});

suite("hostOf", func() {
  test("standard URL with path", func() {
    assert Forex.hostOf("https://open.er-api.com/v6/latest/USD") == "open.er-api.com";
  });

  test("host with port is preserved", func() {
    assert Forex.hostOf("https://api.example.com:8443/rates") == "api.example.com:8443";
  });

  test("no path, and query-without-path", func() {
    assert Forex.hostOf("https://api.example.com") == "api.example.com";
    assert Forex.hostOf("https://api.example.com?base=USD") == "api.example.com";
  });
});

suite("netCents (§3 fee formula)", func() {
  test("$5 tier at 2.9% + 30¢: percentage rounds up", func() {
    // ceil(500 * 290 / 10000) = ceil(14.5) = 15; + 30 = 45 → net 455.
    assert Forex.netCents(cfg(290, 30, 1), 500) == ?455;
  });

  test("$100 tier, exact percentage (no rounding needed)", func() {
    // 10000 * 290 / 10000 = 290 exactly; + 30 = 320 → net 9680.
    assert Forex.netCents(cfg(290, 30, 1), 10_000) == ?9_680;
  });

  test("fee swallowing the gross is null, net of exactly 1 cent is fine", func() {
    // gross 31: fee = ceil(0.899) + 30 = 31 → net 0 → null.
    assert Forex.netCents(cfg(290, 30, 1), 31) == null;
    // gross 32: fee = 1 + 30 = 31 → net 1.
    assert Forex.netCents(cfg(290, 30, 1), 32) == ?1;
    assert Forex.netCents(cfg(290, 30, 1), 0) == null;
  });

  test("zero-fee config nets the full gross", func() {
    assert Forex.netCents(cfg(0, 0, 1), 500) == ?500;
  });
});

suite("cyclesForCents", func() {
  test("pinned conversion: $4.55 net at 0.737 XDR/USD ≈ 3.35T cycles", func() {
    // 455 * 737_000 * 10_000 = 3_353_350_000_000.
    assert Forex.cyclesForCents(455, 737_000) == 3_353_350_000_000;
  });

  test("one net cent at parity rate is 10B cycles (0.01 XDR)", func() {
    assert Forex.cyclesForCents(1, 1_000_000) == 10_000_000_000;
  });
});

suite("cache freshness", func() {
  test("empty cache has no fresh rate", func() {
    assert Forex.freshMicros(Forex.emptyCache(), 100, 50) == null;
  });

  test("age below the window is fresh; at the window is stale", func() {
    let cache = Forex.emptyCache();
    Forex.record(cache, 737_000, 0);
    assert Forex.freshMicros(cache, 100, 99) == ?737_000;
    assert Forex.freshMicros(cache, 100, 100) == null;
    assert Forex.freshMicros(cache, 100, 101) == null;
  });

  test("record overwrites: freshness follows the newest fetch", func() {
    let cache = Forex.emptyCache();
    Forex.record(cache, 700_000, 0);
    Forex.record(cache, 750_000, 200);
    assert Forex.freshMicros(cache, 100, 250) == ?750_000;
    assert cache.rate == ?{ xdrPerUsdMicros = 750_000; fetchedAtNs = 200 };
  });
});

suite("quote", func() {
  test("fresh cache prices the order", func() {
    let cache = Forex.emptyCache();
    Forex.record(cache, 737_000, 0);
    assert Forex.quote(cache, cfg(290, 30, 100), 500, 50) == #ok({ cycles = 3_353_350_000_000; xdrPerUsdMicros = 737_000 });
  });

  test("stale or empty cache asks for a refresh", func() {
    let cache = Forex.emptyCache();
    assert Forex.quote(cache, cfg(290, 30, 100), 500, 50) == #stale;
    Forex.record(cache, 737_000, 0);
    assert Forex.quote(cache, cfg(290, 30, 100), 500, 100) == #stale;
  });

  test("tier below the fee floor is unpriceable even with a fresh rate", func() {
    let cache = Forex.emptyCache();
    Forex.record(cache, 737_000, 0);
    assert Forex.quote(cache, cfg(290, 30, 100), 31, 50) == #unpriceable;
  });
});

suite("validateConfig", func() {
  test("default config is valid", func() {
    assert Forex.validateConfig(Forex.defaultConfig()) == #ok;
  });

  test("fee at or above 100% is rejected", func() {
    assert Forex.validateConfig(cfg(10_000, 30, 1)) == #err(#feeBpsTooHigh);
    assert Forex.validateConfig(cfg(9_999, 30, 1)) == #ok;
  });

  test("non-positive staleness window is rejected", func() {
    assert Forex.validateConfig(cfg(290, 30, 0)) == #err(#nonPositiveMaxAge);
    assert Forex.validateConfig(cfg(290, 30, -1)) == #err(#nonPositiveMaxAge);
  });

  test("non-https source is rejected", func() {
    let bad = { url = "http://open.er-api.com/v6/latest/USD"; feeBps = 290; feeFixedCents = 30; maxAgeNs = 1 : Int };
    assert Forex.validateConfig(bad) == #err(#notHttps);
  });
});
