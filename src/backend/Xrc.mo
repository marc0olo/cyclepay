/// Exchange Rate Canister (XRC) binding — the ICP/USD half of §3 pricing.
///
/// The XRC is an NNS-governed protocol canister that queries multiple exchanges
/// and forex sources, aggregates them, and publishes the result with quality
/// metadata (`standard_deviation`, sources queried vs. answered). It refuses
/// with `InconsistentRatesReceived` rather than returning a number it doesn't
/// trust.
///
/// **This does not remove the off-chain dependency, it delegates it.** The XRC
/// makes HTTPS outcalls on our behalf — that is exactly what its fee encodes
/// (20 M cycles served from its cache, more when it has to fetch). What we gain
/// is that *this* canister makes no outcall: no `transform`, no
/// replica-divergence problem, no coarse rounding, no retry-for-boundary-split,
/// no IPv6 requirement, and no operator-settable source URL. And the aggregation
/// is done by something better at it than a single free endpoint, with a result
/// any third party can independently query and reproduce.
///
/// Call contract: **update call**, and exactly 1 B cycles must be attached.
/// Unused cycles are refunded; a minimum is charged even on error. The 1 B is a
/// *liquidity* requirement rather than a cost — the canister must be able to
/// attach it, so `Gate.Config.minCanisterCycles` has to stay comfortably above
/// it or pricing stops working (fail-closed, but the symptom looks like an
/// unexplained rate outage).
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";

module {

  /// Mainnet XRC. Hardcoded rather than configurable, matching `Cmc.mo` and
  /// `CkUsdc.mo`: a settable rate-source principal would be a money lever that
  /// doesn't look like one, which is the property that made the old forex
  /// source URL a footgun.
  public let canisterId : Text = "uf6dk-hyaaa-aaaaq-qaaaq-cai";

  /// Exactly this must be attached per request; the remainder is refunded.
  public let callCycles : Nat = 1_000_000_000;

  public type AssetClass = { #Cryptocurrency; #FiatCurrency };

  /// Candid `class` is a Motoko keyword, so the field is `class_` — the Candid
  /// name is preserved by the field-name mangling Motoko applies.
  public type Asset = { symbol : Text; class_ : AssetClass };

  public type GetExchangeRateRequest = {
    base_asset : Asset;
    quote_asset : Asset;
    /// Omitted = the current minute. Timestamps have 1-minute granularity.
    timestamp : ?Nat64;
  };

  public type ExchangeRateMetadata = {
    decimals : Nat32;
    base_asset_num_received_rates : Nat64;
    base_asset_num_queried_sources : Nat64;
    quote_asset_num_received_rates : Nat64;
    quote_asset_num_queried_sources : Nat64;
    standard_deviation : Nat64;
    forex_timestamp : ?Nat64;
  };

  public type ExchangeRate = {
    base_asset : Asset;
    quote_asset : Asset;
    timestamp : Nat64;
    /// Scaled by `metadata.decimals`.
    rate : Nat64;
    metadata : ExchangeRateMetadata;
  };

  public type ExchangeRateError = {
    #AnonymousPrincipalNotAllowed;
    /// Still gathering — retriable on the next refresh.
    #Pending;
    #CryptoBaseAssetNotFound;
    #CryptoQuoteAssetNotFound;
    #StablecoinRateNotFound;
    #StablecoinRateTooFewRates;
    #StablecoinRateZeroRate;
    #ForexInvalidTimestamp;
    #ForexBaseAssetNotFound;
    #ForexQuoteAssetNotFound;
    #ForexAssetsNotFound;
    /// We are calling too often — backoff, do not hammer.
    #RateLimited;
    #NotEnoughCycles;
    #FailedToAcceptCycles;
    /// Sources disagreed beyond tolerance. The XRC declining to guess is the
    /// behaviour we want; treat as retriable.
    #InconsistentRatesReceived;
    #Other : { code : Nat32; description : Text };
  };

  public type GetExchangeRateResult = { #Ok : ExchangeRate; #Err : ExchangeRateError };

  public type Service = actor {
    get_exchange_rate : shared GetExchangeRateRequest -> async GetExchangeRateResult;
  };

  /// ICP priced in USD — crypto base, fiat quote.
  public func icpUsdRequest() : GetExchangeRateRequest {
    {
      base_asset = { symbol = "ICP"; class_ = #Cryptocurrency };
      quote_asset = { symbol = "USD"; class_ = #FiatCurrency };
      // Current minute. Asking for a specific past minute is only needed to
      // align against another source's timestamp, and here both rates are read
      // on the same tick instead.
      timestamp = null;
    };
  };

  /// Rescale the XRC's `rate` (which is scaled by `metadata.decimals`) to
  /// micro-USD per ICP. Both directions are handled: `decimals` above 6 divides
  /// (truncating sub-micro precision, far below any pricing significance) and
  /// below 6 multiplies. Null if the rate is zero — a zero price must fail the
  /// quote rather than propagate.
  public func toMicros(rate : ExchangeRate) : ?Nat {
    if (rate.rate == 0) return null;
    let value = rate.rate.toNat();
    let decimals = rate.metadata.decimals.toNat();
    if (decimals >= 6) {
      let divisor = 10 ** (decimals - 6);
      let micros = value / divisor;
      if (micros == 0) return null; // rounded away entirely
      ?micros;
    } else {
      ?(value * 10 ** (6 - decimals));
    };
  };

  /// The quality signal, normalised for storage on an order.
  public func qualityOf(rate : ExchangeRate) : {
    standardDeviation : Nat;
    receivedRates : Nat;
    queriedSources : Nat;
  } {
    {
      standardDeviation = rate.metadata.standard_deviation.toNat();
      receivedRates = rate.metadata.base_asset_num_received_rates.toNat();
      queriedSources = rate.metadata.base_asset_num_queried_sources.toNat();
    };
  };

  /// Whether a failed refresh is worth trying again on the next tick. All XRC
  /// errors are transient or configuration problems rather than permanent
  /// verdicts, but `RateLimited` specifically means *back further off*, which
  /// the caller's backoff handles.
  public func errorToText(error : ExchangeRateError) : Text {
    switch (error) {
      case (#AnonymousPrincipalNotAllowed) "AnonymousPrincipalNotAllowed";
      case (#Pending) "Pending";
      case (#CryptoBaseAssetNotFound) "CryptoBaseAssetNotFound";
      case (#CryptoQuoteAssetNotFound) "CryptoQuoteAssetNotFound";
      case (#StablecoinRateNotFound) "StablecoinRateNotFound";
      case (#StablecoinRateTooFewRates) "StablecoinRateTooFewRates";
      case (#StablecoinRateZeroRate) "StablecoinRateZeroRate";
      case (#ForexInvalidTimestamp) "ForexInvalidTimestamp";
      case (#ForexBaseAssetNotFound) "ForexBaseAssetNotFound";
      case (#ForexQuoteAssetNotFound) "ForexQuoteAssetNotFound";
      case (#ForexAssetsNotFound) "ForexAssetsNotFound";
      case (#RateLimited) "RateLimited";
      case (#NotEnoughCycles) "NotEnoughCycles";
      case (#FailedToAcceptCycles) "FailedToAcceptCycles";
      case (#InconsistentRatesReceived) "InconsistentRatesReceived";
      case (#Other({ code; description })) "Other(" # code.toText() # ": " # description # ")";
    };
  };

};
