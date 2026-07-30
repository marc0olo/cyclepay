/// How USD becomes cycles (§3) — the pure half.
///
/// Two inputs, both from on-chain canisters, cached together:
///
/// - **`usdPerIcpMicros`** — USD per ICP × 10⁶, from the Exchange Rate Canister.
/// - **`xdrPermyriadPerIcp`** — XDR per ICP × 10⁴, from the Cycles Minting
///   Canister. This is the rate the CMC will *actually* honour when converting
///   ICP to cycles, which is why it is read from the CMC and nowhere else.
///
/// ```
/// cycles = netCents × xdrPermyriadPerIcp × 10¹² / usdPerIcpMicros
/// ```
///
/// Derivation: `netCents` buys `netCents × 10⁴ / usdPerIcpMicros` ICP, and one
/// ICP mints `xdrPermyriadPerIcp × 10⁸` cycles (one e8s mints
/// `xdrPermyriadPerIcp` cycles; 1 XDR = 10¹² cycles).
///
/// **Why derive rather than price off a USD/XDR rate directly.** At mint time
/// the ICP needed is `cycles / P′` where `P′` is the CMC rate then. Substituting
/// the quote above, the ICP needed is `netCents/100/usdPerIcp × (P / P′)` — so
/// when the CMC rate is unchanged between order and mint, the operator spends
/// exactly the dollars they received. `P` cancels. Pricing off a market USD/XDR
/// rate instead breaks even only when that rate happens to equal
/// `(CMC's XDR/ICP) / (market USD/ICP)`; any gap between the CMC's published
/// rate and the market-implied one becomes a systematic bias on every order.
///
/// Both rates are read on the same tick, so they are time-aligned by
/// construction and no timestamp reconciliation is needed.
///
/// Fail-closed posture: every implausible, stale, or missing input collapses to
/// "no price", and no price blocks order creation. Nothing is ever priced on a
/// guess. Main.mo owns the impure half — the XRC/CMC calls, the refresh timer,
/// and the backoff — so everything here unit-tests without an IC environment.
import Nat "mo:core/Nat";
import Result "mo:core/Result";

module {

  /// Plausibility band for USD per ICP, in micros: $0.10 … $10,000. Wide on
  /// purpose — its job is rejecting decimal-point disasters, not filtering
  /// market moves. `maxRateDeltaBps` is the tighter guard.
  public let minUsdPerIcpMicros : Nat = 100_000;
  public let maxUsdPerIcpMicros : Nat = 10_000_000_000;

  public func plausibleUsdPerIcp(micros : Nat) : Bool {
    minUsdPerIcpMicros <= micros and micros <= maxUsdPerIcpMicros;
  };

  /// Plausibility band for the **implied** XDR/USD, in micros: 0.5 … 1.2.
  ///
  /// This is the cross-check that stops us trusting one rate provider. The CMC's
  /// XDR/ICP and the XRC's USD/ICP are independently governed and independently
  /// sourced views of ICP's value, so dividing them yields an implied XDR/USD —
  /// and XDR/USD is the one quantity here that is genuinely stable, an IMF
  /// basket that has sat in ~0.6–0.9 for decades.
  ///
  /// An XRC price wrong by a factor therefore shows up as an absurd implied
  /// rate: $45.50/ICP against 3.5 XDR/ICP implies 0.077, and $0.455 implies 7.69.
  /// The band leaves >30% headroom each way against the historical range while
  /// catching anything off by roughly 1.5× or more — errors the wide ICP-price
  /// band sails straight past.
  ///
  /// Two honest limits: this is a cross-check, not independence — correlated
  /// drift in both sources would go unnoticed. And it assumes the CMC's rate is
  /// the sound one; if the CMC is wrong instead we reject a good XRC price. That
  /// is the right direction, because the CMC's rate is what we actually mint at,
  /// so a wrong CMC rate is a larger problem than a refused quote.
  public let minImpliedXdrPerUsdMicros : Nat = 500_000;
  public let maxImpliedXdrPerUsdMicros : Nat = 1_200_000;

  /// Implied XDR per USD × 10⁶ from the two rate inputs.
  ///
  /// `(P/10⁴ XDR per ICP) / (U/10⁶ USD per ICP) × 10⁶ = P · 10⁸ / U`.
  /// Null on a zero ICP price.
  public func impliedXdrPerUsdMicros(xdrPermyriadPerIcp : Nat, usdPerIcpMicros : Nat) : ?Nat {
    if (usdPerIcpMicros == 0) return null;
    ?(xdrPermyriadPerIcp * 100_000_000 / usdPerIcpMicros);
  };

  public func plausibleImpliedXdrPerUsd(micros : Nat) : Bool {
    minImpliedXdrPerUsdMicros <= micros and micros <= maxImpliedXdrPerUsdMicros;
  };

  /// Quality signal the XRC publishes alongside a rate. Recorded on the order
  /// so a buyer can see how well-sourced the price they were quoted was — a
  /// rate assembled from two exchanges is not the same product as one from
  /// twelve, and that distinction is otherwise invisible.
  public type Quality = {
    /// XRC `metadata.standard_deviation`, in the rate's own decimals.
    standardDeviation : Nat;
    /// How many sources answered, out of how many were asked.
    receivedRates : Nat;
    queriedSources : Nat;
  };

  /// Both rates plus when they were read. One record because they are only ever
  /// meaningful together: a quote built from an ICP price and a CMC rate taken
  /// at different moments is wrong by however much ICP moved in between.
  public type Rates = {
    usdPerIcpMicros : Nat;
    xdrPermyriadPerIcp : Nat;
    fetchedAtNs : Int;
    quality : Quality;
  };

  public type Cache = { var rates : ?Rates };

  public func emptyCache() : Cache {
    { var rates = null };
  };

  /// §3 fee formula plus the freshness and sanity bounds.
  public type Config = {
    /// Card rail: ≈2.9% + $0.30, recovering Stripe's cut at cost. The ck-USDC
    /// rail carries its own formula (`CkUsdc.Config`).
    feeBps : Nat;
    feeFixedCents : Nat;
    /// How long a cached pair may price orders.
    ///
    /// This is a **security control, not a tuning knob**. The refresh runs on a
    /// timer, and a dead timer is only safe because a stale cache refuses to
    /// price: an unbounded window would let orders be priced indefinitely off a
    /// frozen rate, which is exactly the gap that timer-reinstantiation
    /// guidance warns about. Bounded by `maxAllowedMaxAgeNs`.
    maxAgeNs : Int;
    /// Largest relative move accepted against the last good ICP price, in basis
    /// points. A refreshed rate outside this is rejected and the previous one
    /// keeps serving until it goes stale — a coarse guard against a source
    /// glitch, deliberately loose enough never to reject a real market move
    /// inside one refresh interval.
    maxRateDeltaBps : Nat;
    /// Minimum number of exchange sources that must have answered for the ICP
    /// price to be usable.
    ///
    /// The XRC's own `InconsistentRatesReceived` fires when the rates it
    /// collected disagree too much — but **a single rate cannot disagree with
    /// itself**, so the degenerate one-exchange case (a thin or manipulated
    /// market) arrives as a clean `Ok`. This is the only guard that sees it.
    ///
    /// Kept low on purpose: every increment buys a little more confidence and
    /// costs availability, because falling short means refusing to quote.
    minRateSources : Nat;
  };

  /// ICP/USD is volatile, so the window is short. The cost of a tighter window
  /// is one extra XRC call per interval, which is negligible next to the
  /// mispricing a long window allows.
  public let defaultMaxAgeNs : Int = 300_000_000_000; // 5 min

  /// Ceiling on any operator-set window (1 h). See `Config.maxAgeNs`.
  public let maxAllowedMaxAgeNs : Int = 3_600_000_000_000;

  public func defaultConfig() : Config {
    {
      feeBps = 290;
      feeFixedCents = 30;
      maxAgeNs = defaultMaxAgeNs;
      maxRateDeltaBps = 5_000; // 50%
      minRateSources = 2;
    };
  };

  public type ConfigError = {
    /// Fee ≥ 100% can never net out.
    #feeBpsTooHigh;
    /// A zero window would refresh on every order.
    #nonPositiveMaxAge;
    /// Above `maxAllowedMaxAgeNs` — see `Config.maxAgeNs`.
    #maxAgeTooLong : { maxAgeNs : Int; allowedNs : Int };
    /// A zero delta bound would reject every refresh after the first.
    #zeroRateDelta;
    /// Requiring zero sources would defeat the guard entirely.
    #zeroRateSources;
  };

  public func validateConfig(config : Config) : Result.Result<(), ConfigError> {
    if (config.feeBps >= 10_000) return #err(#feeBpsTooHigh);
    if (config.maxAgeNs <= 0) return #err(#nonPositiveMaxAge);
    if (config.maxAgeNs > maxAllowedMaxAgeNs) {
      return #err(#maxAgeTooLong({ maxAgeNs = config.maxAgeNs; allowedNs = maxAllowedMaxAgeNs }));
    };
    if (config.maxRateDeltaBps == 0) return #err(#zeroRateDelta);
    if (config.minRateSources == 0) return #err(#zeroRateSources);
    #ok;
  };

  /// The cached pair iff younger than `maxAgeNs` (age ≥ window = stale, the
  /// convention shared with Idempotency pruning and the CMC guard). Null = the
  /// caller fails closed.
  public func freshRates(cache : Cache, maxAgeNs : Int, nowNs : Int) : ?Rates {
    let ?rates = cache.rates else return null;
    if (nowNs - rates.fetchedAtNs >= maxAgeNs) return null;
    ?rates;
  };

  /// The cached pair regardless of age — for status reporting and as the
  /// baseline the delta guard compares against.
  public func lastRates(cache : Cache) : ?Rates {
    cache.rates;
  };

  public func record(cache : Cache, rates : Rates) {
    cache.rates := ?rates;
  };

  /// Is `next` within `maxDeltaBps` of `previous`? True when there is no
  /// previous rate — the first observation has nothing to be compared against,
  /// and the plausibility band is what guards it.
  public func withinDelta(previous : ?Nat, next : Nat, maxDeltaBps : Nat) : Bool {
    let ?prev = previous else return true;
    if (prev == 0) return true;
    let diff = if (next > prev) next - prev else prev - next;
    // diff/prev ≤ maxDeltaBps/10_000, without floating point.
    diff * 10_000 <= prev * maxDeltaBps;
  };

  /// §3 net-of-fees: gross minus (⌈gross·bps/10⁴⌉ + fixed). Rounds the fee
  /// **up**, so rounding never favours the buyer on the fee and the operator's
  /// at-cost posture absorbs the ≤1¢ variance. Null when the fee swallows the
  /// whole amount (an amount priced below the fee floor).
  ///
  /// The fee argument is the narrowed shape so both a live `Config` and an
  /// order's creation-time snapshot fit (§6.1 amount honouring).
  public func netCents(fee : { feeBps : Nat; feeFixedCents : Nat }, grossCents : Nat) : ?Nat {
    let total = feeCents(fee, grossCents);
    if (total >= grossCents) return null;
    ?(grossCents - total);
  };

  /// The fee itself, split out so it can be shown to a buyer without
  /// recomputing it: `netCents` is defined as `grossCents - feeCents` whenever
  /// that is positive, and the two must never disagree.
  public func feeCents(fee : { feeBps : Nat; feeFixedCents : Nat }, grossCents : Nat) : Nat {
    (grossCents * fee.feeBps + 9_999) / 10_000 + fee.feeFixedCents;
  };

  /// The §3 locked cycle quantity for an already-netted amount. Integer
  /// division **floors**, so a quote is never larger than the money actually
  /// buys; the sub-cycle remainder stays operator-side. Null on a zero ICP
  /// price (a broken rate must fail the quote, not divide by zero).
  public func cyclesForCents(
    netCents : Nat,
    xdrPermyriadPerIcp : Nat,
    usdPerIcpMicros : Nat,
  ) : ?Nat {
    if (usdPerIcpMicros == 0) return null;
    ?(netCents * xdrPermyriadPerIcp * 1_000_000_000_000 / usdPerIcpMicros);
  };

  /// One-shot quote from a snapshot of fee config and rates. `#stale` = the
  /// caller fails closed (§3.1); `#unpriceable` = the gross doesn't clear the
  /// fee, or the rates are unusable — a config/source problem, not a
  /// freshness one.
  public func quote(
    cache : Cache,
    fee : { feeBps : Nat; feeFixedCents : Nat },
    maxAgeNs : Int,
    grossCents : Nat,
    nowNs : Int,
  ) : { #ok : { cycles : Nat; rates : Rates }; #stale; #unpriceable } {
    let ?net = netCents(fee, grossCents) else return #unpriceable;
    let ?rates = freshRates(cache, maxAgeNs, nowNs) else return #stale;
    let ?cycles = cyclesForCents(net, rates.xdrPermyriadPerIcp, rates.usdPerIcpMicros) else {
      return #unpriceable;
    };
    #ok({ cycles; rates });
  };

};
