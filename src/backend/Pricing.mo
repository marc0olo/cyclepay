/// How USD becomes cycles (§3) — the pure half.
///
/// ```
/// cycles = netCents × xdrPermyriadPerIcp × 10¹² / usdPerIcpMicros
/// ```
///
/// Two inputs, both from on-chain canisters and cached together: `usdPerIcpMicros` (USD
/// per ICP × 10⁶, from the Exchange Rate Canister) and `xdrPermyriadPerIcp` (XDR per ICP
/// × 10⁴, from the Cycles Minting Canister — the protocol's own published rate, which is
/// why it is read there and nowhere else).
///
/// In units: `netCents` is worth `netCents × 10⁴ / usdPerIcpMicros` ICP, and one ICP is
/// `xdrPermyriadPerIcp × 10⁸` cycles at the protocol rate.
///
/// **ICP is an intermediate unit here, not a position** — it cancels, and the gateway
/// never holds it. Why this is derived rather than priced off a market USD/XDR rate, and
/// where the operator's exposure actually sits: `docs/DESIGN.md` §3.1.
///
/// ⚠️ **Fail-closed: every implausible, stale or missing input collapses to "no price",
/// and no price blocks order creation.** Nothing is ever priced on a guess. `Main.mo` owns
/// the impure half — the XRC/CMC calls, the timer and the backoff — so everything here
/// unit-tests with no IC environment.
import Int "mo:core/Int";
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
  /// the sound one; if the CMC is wrong instead we reject a good XRC price. That is
  /// the right direction, because the CMC's rate is the protocol's own valuation of
  /// a cycle, so a wrong one misprices cycles network-wide — a larger problem than
  /// one refused quote, and not ours to correct at the till.
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
    /// ≈2.9% + $0.30, recovering Stripe's cut at cost.
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
    /// Simulation scale: deliver `1/divisor` of the cycles a purchase buys.
    /// **`1` is production and means the arithmetic below is bit-identical to
    /// having no divisor at all** (#99).
    ///
    /// ⚠️ **`divisor > 1` IS the simulation-mode signal — there is no second
    /// flag.** A separate boolean could disagree with this number, and then two
    /// places would answer "are we simulating?" differently. One value has no
    /// inconsistent state.
    ///
    /// ⚠️ Applied HERE, in `quote`, because this is the single derivation of a
    /// cycle quantity and it has exactly one caller. That is what keeps the
    /// quote the buyer sees, the `lockedCycles` on the order, the promise tally,
    /// the reserve-floor decrement and the transfer all the *same* scaled
    /// number. **Scaling at delivery instead would make every reconcile report
    /// an unexplained shortfall** — the one signal that means an outflow we did
    /// not cause.
    divisor : Nat;
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
      divisor = 1;
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
    /// A zero divisor would divide the whole quote away; `1` is "off".
    #zeroDivisor;
    /// This divisor scales the smallest purchase we sell down below what the
    /// cycles-ledger deposit fee would eat (#99 2d). Carries both figures so an
    /// operator can see how far past the band they went.
    #divisorUndeliverable : { scaledCycles : Nat; ledgerFee : Nat };
    /// ⚠️ **`divisor > 1` requires `expectLivemode == ?false` EXACTLY** — not
    /// merely "not live", because `null` means "either mode" and would accept live
    /// payments while under-delivering. The mutual half lives in
    /// `set_expected_livemode` (#99 2a).
    #divisorNeedsSandbox : { expectLivemode : ?Bool };
    /// ⚠️ **The divisor is global rather than recorded per order**, which is only
    /// safe because it cannot change under stored orders: every earlier receipt
    /// would otherwise recompute against the new divisor and report a mismatch —
    /// exactly the claim the landing page makes. Reinstall to change it (#99 2e).
    #divisorChangeWithOrders : { stored : Nat };
  };

  // ⚠️ **`validateConfig` does NOT decide every `ConfigError`.** The three divisor
  // cases above need context this module cannot see — the Stripe mode, the order
  // store, and the live ledger fee — so `Main.set_pricing_config` decides those and
  // returns them through this same type. One error type, two deciding sites; the
  // alternative is a second error type that callers have to union by hand.

  public func validateConfig(config : Config) : Result.Result<(), ConfigError> {
    if (config.feeBps >= 10_000) return #err(#feeBpsTooHigh);
    if (config.maxAgeNs <= 0) return #err(#nonPositiveMaxAge);
    if (config.maxAgeNs > maxAllowedMaxAgeNs) {
      return #err(#maxAgeTooLong({ maxAgeNs = config.maxAgeNs; allowedNs = maxAllowedMaxAgeNs }));
    };
    if (config.maxRateDeltaBps == 0) return #err(#zeroRateDelta);
    if (config.minRateSources == 0) return #err(#zeroRateSources);
    if (config.divisor == 0) return #err(#zeroDivisor);
    #ok;
  };

  // ── The cycles-ledger deposit fee, and why the divisor has a ceiling ──────
  //
  // ⚠️ **The ledger's fee is FLAT and it is not ours.** It charges a fixed
  // amount to accept a deposit whatever the deposit is, so it does not scale
  // with the divisor and it is the same in simulation mode as in production.
  //
  // ⚠️ **An over-scaled gateway makes an "unreachable" state reachable.** The
  // delivery path documents the one state the stored fee cannot correct itself
  // out of: a fee above a whole order's locked quantity means nothing ever
  // reaches the ledger, so no `#BadFee` ever arrives to fix the stored copy, and
  // there is deliberately no admin lever to reset it. In production that needs a
  // ~70,000x fee rise. A divisor attacks exactly that ratio, so the guard below
  // is what keeps the unrecoverable state unreachable.

  /// How many times the ledger fee a scaled quote must clear.
  ///
  /// **Headroom rather than a bare `>`, because rates move.** A quote that
  /// clears the fee by one cycle today walks into the stall on the next ICP
  /// move; ten times over does not. At the $10 floor this puts the practical
  /// divisor ceiling around 7,200 — comfortably above the recommended 1,000 and
  /// below the scale at which a tester is mostly verifying the ledger's fee.
  public let ledgerFeeHeadroom : Nat = 10;

  public func clearsLedgerFee(scaledCycles : Nat, ledgerFee : Nat) : Bool {
    scaledCycles >= ledgerFee * ledgerFeeHeadroom;
  };

  /// Would the **smallest purchase this gateway sells** still clear the ledger
  /// fee at this divisor? Used by the config setter so an operator learns at set
  /// time rather than through a buyer's refusal.
  ///
  /// ⚠️ **A config-time check alone is NOT enough, and rates are why**: this
  /// passes against today's rate and goes stale as ICP moves. `quote` re-checks
  /// on every order and is the authoritative guard.
  ///
  /// ⚠️ **Absent rates return `#ok`, deliberately.** "Cannot tell" must not
  /// refuse a config change — on a cold canister the refresh timer may simply
  /// not have run yet, and refusing would make the setting unreachable exactly
  /// when it is being set up.
  public func divisorDeliverable(
    cache : Cache,
    fee : { feeBps : Nat; feeFixedCents : Nat },
    minGrossCents : Nat,
    divisor : Nat,
    ledgerFee : Nat,
  ) : Result.Result<(), ConfigError> {
    if (divisor == 0) return #err(#zeroDivisor);
    let ?net = netCents(fee, minGrossCents) else return #ok;
    let ?rates = cache.rates else return #ok;
    let ?gross = cyclesForCents(net, rates.xdrPermyriadPerIcp, rates.usdPerIcpMicros) else return #ok;
    let scaled = gross / divisor;
    if (clearsLedgerFee(scaled, ledgerFee)) return #ok;
    #err(#divisorUndeliverable({ scaledCycles = scaled; ledgerFee }));
  };

  /// The cached pair iff younger than `maxAgeNs` (age ≥ window = stale, the
  /// convention shared with Idempotency pruning and the CMC guard). Null = the
  /// caller fails closed.
  public func freshRates(cache : Cache, maxAgeNs : Int, nowNs : Int) : ?Rates {
    let ?rates = cache.rates else return null;
    if (nowNs - rates.fetchedAtNs >= maxAgeNs) return null;
    ?rates;
  };

  /// The cached pair regardless of age — for status reporting, so an operator can
  /// see *what* is cached and how old it is even when it is too stale to price.
  ///
  /// Not the delta-guard baseline: that uses `freshRates`, because a stale rate is
  /// not evidence about the current market and comparing against one deadlocks
  /// pricing after an outage spanning a large move.
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
    // Via Int so no subtraction can trap. The `if` below guarantees both branches
    // are non-negative, but that is a fact about the guard rather than the types,
    // and moc is right not to take it on trust (M0155).
    let diff = Int.abs(next.toInt() - prev.toInt());
    // diff/prev ≤ maxDeltaBps/10_000, without floating point.
    diff * 10_000 <= prev * maxDeltaBps;
  };

  /// §3 net-of-fees: gross minus (⌈gross·bps/10⁴⌉ + fixed). Rounds the fee
  /// **up**, so rounding never favours the buyer on the fee and the operator's
  /// at-cost posture absorbs the ≤1¢ variance. Null when the fee swallows the
  /// whole amount (an amount priced below the fee floor).
  ///
  /// The fee argument is the narrowed shape so both a live `Config` and an
  /// order's creation-time snapshot fit. The snapshot caller is `receipt`, which
  /// recomputes what a delivered order was charged from the rates it was priced
  /// at. The webhook does not reprice: it requires the paid amount to equal the
  /// quoted one, so a mismatch delivers nothing.
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

  /// Why a quote could not be produced at all, as distinct from being stale.
  ///
  /// ⚠️ **Two causes, not one, and conflating them tells a buyer the wrong
  /// thing.** Before #99 both arrived as a bare `#unpriceable`, which the
  /// frontend renders as *"Payment processing would exceed X. Pick a larger
  /// amount."* That is right for the first cause and wrong for the second: a
  /// buyer refused because the **simulation scale** is too small has not been
  /// charged too much for processing, and picking a larger amount may not help.
  public type Unpriceable = {
    /// The gross does not clear the Stripe fee — or, defensively, the cached
    /// rates cannot produce a cycle figure. The buyer's fix is a larger amount.
    #stripeFee;
    /// The SCALED cycles would not clear the flat cycles-ledger deposit fee, so
    /// this gateway's simulation scale is too small for this purchase. Not the
    /// buyer's fault and not fixable by them.
    #simulationScale : { scaledCycles : Nat; ledgerFee : Nat };
  };

  /// One-shot quote from a snapshot of fee config and rates. `#stale` = the
  /// caller fails closed (§3.1); `#unpriceable` carries which of the two causes
  /// fired.
  ///
  /// ⚠️ **The Stripe fee is taken BEFORE the divisor and the ledger fee is
  /// checked AFTER it**, and that asymmetry is not for symmetry's sake: the buyer
  /// really is charged the gross and Stripe really keeps its cut, so those are
  /// real dollars and scaling them would misreport what Stripe took. The ledger
  /// really charges a flat fee to accept whatever deposit arrives, so it comes
  /// off the scaled amount.
  ///
  /// **Where the division sits in the formula does not matter for correctness**:
  /// `floor(floor(a/b)/d) == floor(a/(b*d))` for positive integers. It is
  /// written as one division after the rate conversion for clarity, and
  /// `checkReceipt` divides at the same point so the recomputation a buyer can
  /// follow still reconciles.
  public func quote(
    cache : Cache,
    fee : { feeBps : Nat; feeFixedCents : Nat },
    maxAgeNs : Int,
    grossCents : Nat,
    nowNs : Int,
    divisor : Nat,
    ledgerFee : Nat,
  ) : { #ok : { cycles : Nat; rates : Rates }; #stale; #unpriceable : Unpriceable } {
    let ?net = netCents(fee, grossCents) else return #unpriceable(#stripeFee);
    let ?rates = freshRates(cache, maxAgeNs, nowNs) else return #stale;
    let ?gross = cyclesForCents(net, rates.xdrPermyriadPerIcp, rates.usdPerIcpMicros) else {
      return #unpriceable(#stripeFee);
    };
    // ⚠️ `divisor == 1` leaves this exactly `gross`, so production arithmetic is
    // bit-identical to having no divisor at all. `validateConfig` rejects 0, so
    // this cannot divide by zero.
    let cycles = gross / divisor;
    if (not clearsLedgerFee(cycles, ledgerFee)) {
      return #unpriceable(#simulationScale({ scaledCycles = cycles; ledgerFee }));
    };
    #ok({ cycles; rates });
  };

};
