import { test; suite } "mo:test";
import Xrc "../src/backend/Xrc";

// Unit suite for the XRC binding. `toMicros` is the highest-risk pure function
// in the pricing path: it rescales the XRC's `rate` by its `metadata.decimals`,
// so getting the direction or magnitude wrong mis-prices every order by a power
// of ten. The mock the integration suite installs reports 9 decimals, so the
// other branches would otherwise never be exercised.

func rateWith(rate : Nat64, decimals : Nat32) : Xrc.ExchangeRate {
  {
    base_asset = { symbol = "ICP"; class_ = #Cryptocurrency };
    quote_asset = { symbol = "USD"; class_ = #FiatCurrency };
    timestamp = 1_749_600_000;
    rate;
    metadata = {
      decimals;
      base_asset_num_received_rates = 5;
      base_asset_num_queried_sources = 6;
      quote_asset_num_received_rates = 4;
      quote_asset_num_queried_sources = 7;
      standard_deviation = 123;
      forex_timestamp = null;
    };
  };
};

suite("toMicros — decimals rescaling", func() {
  test("9 decimals (what the XRC actually reports): $4.55 → 4_550_000 micros", func() {
    // The shared §3 vector. 4_550_000_000 at 9 decimals is 4.55.
    assert Xrc.toMicros(rateWith(4_550_000_000, 9)) == ?4_550_000;
  });

  test("exactly 6 decimals passes through unscaled", func() {
    assert Xrc.toMicros(rateWith(4_550_000, 6)) == ?4_550_000;
  });

  test("fewer than 6 decimals multiplies up", func() {
    assert Xrc.toMicros(rateWith(455, 2)) == ?4_550_000;
    assert Xrc.toMicros(rateWith(4, 0)) == ?4_000_000;
  });

  test("more than 6 decimals divides down", func() {
    assert Xrc.toMicros(rateWith(4_550_000_000_000, 12)) == ?4_550_000;
  });

  test("sub-micro precision truncates rather than rounding", func() {
    // 4.5500009 at 7 decimals → 4.550000 micros; the dropped digit is far below
    // any pricing significance.
    assert Xrc.toMicros(rateWith(45_500_009, 7)) == ?4_550_000;
  });

  test("a zero rate is unusable, not zero-priced", func() {
    assert Xrc.toMicros(rateWith(0, 9)) == null;
  });

  test("a rate that rounds away entirely is unusable", func() {
    // 1 unit at 12 decimals is 10⁻¹², which is 0 micros — pricing off that
    // would divide by zero downstream, so it must be refused here.
    assert Xrc.toMicros(rateWith(1, 12)) == null;
  });

  test("the smallest representable micro survives", func() {
    assert Xrc.toMicros(rateWith(1, 6)) == ?1;
    assert Xrc.toMicros(rateWith(1_000, 9)) == ?1;
  });

  test("a plausible ICP price at 9 decimals stays inside the band", func() {
    // Cross-check against the band the refresh path enforces, so the two
    // cannot drift apart silently.
    let ?micros = Xrc.toMicros(rateWith(4_550_000_000, 9)) else return assert false;
    assert micros >= 100_000 and micros <= 10_000_000_000;
  });
});

suite("qualityOf", func() {
  test("carries the BASE asset's source counts and the spread", func() {
    // The base asset is ICP, which is the price being quoted — the quote-asset
    // counts describe USD and are not what a buyer cares about.
    let quality = Xrc.qualityOf(rateWith(4_550_000_000, 9));
    assert quality.receivedRates == 5;
    assert quality.queriedSources == 6;
    assert quality.standardDeviation == 123;
  });
});

suite("errorToText", func() {
  test("every variant renders non-empty, so an audit entry is never blank", func() {
    let errors : [Xrc.ExchangeRateError] = [
      #AnonymousPrincipalNotAllowed,
      #Pending,
      #CryptoBaseAssetNotFound,
      #CryptoQuoteAssetNotFound,
      #StablecoinRateNotFound,
      #StablecoinRateTooFewRates,
      #StablecoinRateZeroRate,
      #ForexInvalidTimestamp,
      #ForexBaseAssetNotFound,
      #ForexQuoteAssetNotFound,
      #ForexAssetsNotFound,
      #RateLimited,
      #NotEnoughCycles,
      #FailedToAcceptCycles,
      #InconsistentRatesReceived,
      #Other({ code = 42; description = "boom" }),
    ];
    for (error in errors.values()) {
      assert Xrc.errorToText(error) != "";
    };
    // The two an operator most needs to tell apart.
    assert Xrc.errorToText(#RateLimited) == "RateLimited";
    assert Xrc.errorToText(#NotEnoughCycles) == "NotEnoughCycles";
    assert Xrc.errorToText(#Other({ code = 42; description = "boom" })) == "Other(42: boom)";
  });
});

suite("call contract", func() {
  test("exactly 1 B cycles is what the XRC requires per request", func() {
    assert Xrc.callCycles == 1_000_000_000;
  });

  test("the request asks for ICP priced in USD", func() {
    let request = Xrc.icpUsdRequest();
    assert request.base_asset.symbol == "ICP";
    assert request.base_asset.class_ == #Cryptocurrency;
    assert request.quote_asset.symbol == "USD";
    assert request.quote_asset.class_ == #FiatCurrency;
    // Current minute: both rates are read on the same tick, so there is nothing
    // to align a historical timestamp against.
    assert request.timestamp == null;
  });

  test("the pinned canister id is the mainnet XRC", func() {
    assert Xrc.canisterId == "uf6dk-hyaaa-aaaaq-qaaaq-cai";
  });
});
