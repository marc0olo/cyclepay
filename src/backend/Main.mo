/// Fully on-chain cycles gateway — composition root.
///
/// See design-docs/ONCHAIN_GATEWAY_SPEC.md (spec v2.1) and PRD.md for the
/// module layout this actor grows into: Orders.mo wiring, rails/, Cmc.mo,
/// Pricing.mo, Treasury.mo, ErrorQueue.mo, Auth.mo.
import Array "mo:core/Array";
import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Timer "mo:core/Timer";
import { ic } "mo:ic";
import AuditLog "AuditLog";
import Auth "Auth";
import Cmc "Cmc";
import ErrorQueue "ErrorQueue";
import Pricing "Pricing";
import Xrc "Xrc";
import Gate "Gate";
import Http "Http";
import Idempotency "Idempotency";
import Orders "Orders";
import Recovery "Recovery";
import Retention "Retention";
import Card "rails/Card";
import Secret "Secret";
import Tiers "Tiers";
import Treasury "Treasury";
import Types "Types";

persistent actor CyclesGateway {

  /// §7: the only stored secret — plaintext by design, SEV-SNP posture and
  /// burn-cap backstop documented in Secret.mo. Persists across upgrades;
  /// rotation never requires a redeploy.
  let webhookSecret : Secret.Store = Secret.emptyStore();

  /// §7 admin authz: caller ∈ controllers (flat allowlist, equal
  /// privileges — see Auth.mo). Traps rather than returning an error so an
  /// unauthorized call can never be mistaken for a handled outcome.
  func requireAdmin(caller : Principal) {
    switch (Auth.checkAdmin(caller, Principal.isController)) {
      case (#ok) {};
      case (#err(#anonymous)) Runtime.trap("admin API: anonymous caller rejected");
      case (#err(#notController)) Runtime.trap("admin API: caller is not a controller");
    };
  };

  /// Provision or rotate the Stripe webhook signing secret (§7). Pass the
  /// full `whsec_...` string from the Stripe dashboard — the whole string,
  /// prefix included, is the HMAC key. NOTE: the argument transits the
  /// TLS-terminating boundary node as plain ingress (§7 provisioning
  /// exposure); rotate after provisioning over an untrusted path.
  public shared ({ caller }) func set_webhook_secret(secret : Text) : async Result.Result<(), Secret.SetError> {
    requireAdmin(caller);
    let result = Secret.set(webhookSecret, secret.encodeUtf8(), Time.now());
    switch (result) {
      case (#ok) {
        // The secret itself is never logged — only that it changed, by whom,
        // and to which generation, which is what a rotation audit needs.
        auditAdmin(caller, "secret.set", "generation " # Secret.status(webhookSecret).generation.toText());
      };
      case (#err(_)) auditAdmin(caller, "secret.setRejected", "rejected as too short; the working secret is untouched");
    };
    result;
  };

  /// Provisioning state only — the secret itself is never readable back
  /// out, even by controllers. `generation` confirms a rotation landed.
  public shared query ({ caller }) func webhook_secret_status() : async Secret.Status {
    requireAdmin(caller);
    Secret.status(webhookSecret);
  };

  // ── Order + tier state (task 6) ─────────────────────────────────────────

  /// §4.2 order store: `orders` + `principalsToOrders` history.
  let orderStore : Orders.Store = Orders.emptyStore();

  /// §3 fixed card tiers. Operator config (§7): controllers create the
  /// Payment Links in the Stripe Dashboard and register them here. Empty
  /// until first `set_card_tiers` — no made-up default prices.
  var cardTiers : [Tiers.Tier] = [];

  /// Pre-creation admission policy (Gate.mo) — open-order cap, own-cycles
  /// floor, per-purchase ceiling. Unlike the burn cap these default to real
  /// values: they are safety limits, and a zero default would brick the
  /// canister rather than protect it.
  var gateConfig : Gate.Config = Gate.defaultConfig();

  /// Order-lifecycle retention policy (Retention.mo) — the `#created` TTL, which
  /// is retention's only effect. Nothing deletes orders.
  var retentionConfig : Retention.Config = Retention.defaultConfig();

  /// `payment_intent` → the order it paid for. Financial record, never pruned;
  /// the only way `charge.refunded` can tell whether the refunded payment had
  /// already been delivered as cycles.
  let paidIntents = Map.empty<Text, Types.OrderId>();

  // ── Pricing rates (§3/§3.1) ─────────────────────────────────────────────

  /// Both §3 rate inputs, cached together. Persistent, so a redeploy does not
  /// blank the price — an upgrade only costs pricing if it outlasts the
  /// staleness window, which the one-shot refresh below covers.
  let rateCache : Pricing.Cache = Pricing.emptyCache();

  /// §3 fee formula + staleness window + the delta guard. Admin-adjustable
  /// without a redeploy. There is deliberately no rate-source setting: the XRC
  /// and CMC ids are pinned in their modules, because a settable rate source is
  /// a money lever that does not look like one.
  var pricingConfig : Pricing.Config = Pricing.defaultConfig();

  /// Which Stripe world this gateway belongs to, or null for "not declared".
  ///
  /// A test-mode webhook secret provisioned against a canister holding a real
  /// ICP float would mint real cycles for payments that never happened — the
  /// secret is the only thing separating the two, and provisioning the wrong one
  /// is an ordinary operator slip. Declaring the expectation lets the canister
  /// refuse the mismatch instead of trusting that nobody pasted the wrong value.
  ///
  /// Null rather than `?true` by default so a fresh local install works against
  /// a Stripe sandbox without configuration. The go-live checklist sets it, and
  /// until it is set every honoured payment records `stripe.livemodeUnset` — a
  /// nudge that stops as soon as the expectation is declared.
  var expectLivemode : ?Bool = null;

  /// Which XRC this gateway prices from.
  ///
  /// Read **lazily on every use, never cached at init**, per the icp-cli guidance:
  /// on a first deploy a sibling canister may not exist yet when this one
  /// initialises, and `--mode reinstall` wipes anything held in state while the
  /// automatic variables are re-stamped on every deploy. A lazy read self-heals.
  ///
  /// Absent variable → the mainnet XRC, so a production deploy that injects
  /// nothing is correct by default.
  /// The id the last refresh actually used, for `pricing_status`.
  ///
  /// Mirrored into a var because reading an environment variable needs the
  /// `system` capability, which a query does not have — and "which XRC am I
  /// pricing from?" has to be answerable from a query, since a mainnet deploy
  /// wrongly pointed at a mock is otherwise completely silent.
  ///
  /// **Null until an XRC call has actually resolved the id**, and transient, so it
  /// is null again after every upgrade until the refresh timer warms (seconds).
  /// Defaulting it to the mainnet id instead would make the one signal that
  /// detects a mock read *all-clear* during exactly the window an operator checks
  /// a fresh deploy — an alert that is silent when unverified is worse than none.
  transient var lastXrcCanisterId : ?Text = null;

  func xrcActor<system>() : Xrc.Service {
    let id = switch (Runtime.envVar<system>(Xrc.canisterIdEnvVar)) {
      case (?injected) injected;
      case null Xrc.mainnetCanisterId;
    };
    lastXrcCanisterId := ?id;
    actor (id);
  };

  /// Single-flight guard for the refresh. Transient: a flag left true by an
  /// upgrade mid-call would deadlock refreshes forever.
  transient var rateRefreshInFlight = false;

  /// Consecutive refresh failures, for backoff. Transient — an upgrade is a
  /// fine moment to retry immediately.
  transient var rateRefreshFailures : Nat = 0;

  /// Ticks to skip after a failure, doubling to this cap. XRC answers
  /// `RateLimited` if we hammer it, so backing off is both cheaper and the
  /// behaviour that recovers fastest.
  transient let rateBackoffMaxTicks : Nat = 8;

  /// Remaining ticks to skip before the next attempt.
  transient var rateTicksToSkip : Nat = 0;

  /// Liveness for ops. A stale rate is ambiguous between "the timer is dead"
  /// and "XRC is erroring", and those want different responses — so both the
  /// last attempt and the last error are recorded.
  var lastRateAttempt : ?{ atNs : Int; ok : Bool; detail : Text } = null;

  /// Is the rail live enough to be worth spending cycles keeping a rate warm?
  /// A dark gateway refreshes nothing.
  func railsLive() : Bool {
    cardTiers.size() > 0;
  };

  func recordRateAttempt(ok : Bool, detail : Text) {
    lastRateAttempt := ?{ atNs = Time.now(); ok; detail };
    if (ok) {
      rateRefreshFailures := 0;
    } else {
      if (rateRefreshFailures < rateBackoffMaxTicks) rateRefreshFailures += 1;
      audit("rates.refreshFailed", detail);
    };
  };

  /// Read both §3 rate inputs and cache them together.
  ///
  /// Only ever called from the refresh timer — never from a user-facing method.
  /// The XRC charges per request, so a call reachable from `create_order` would
  /// be an operation that is free to invoke and expensive to serve; worse, a
  /// failing XRC would leave the cache stale and let every subsequent order
  /// retry, which is a self-reinforcing drain. Orders read the cache and fail
  /// closed instead.
  func refreshRates() : async* () {
    if (rateRefreshInFlight) return;
    rateRefreshInFlight := true;
    try {
      // ICP/USD from the XRC. Exactly 1 B cycles must be attached; the unused
      // remainder is refunded.
      let usdResult = try {
        await (with cycles = Xrc.callCycles) xrcActor<system>().get_exchange_rate(Xrc.icpUsdRequest());
      } catch (e) {
        recordRateAttempt(false, "xrc call rejected: " # e.message());
        return;
      };
      let rate = switch (usdResult) {
        case (#Ok(rate)) rate;
        case (#Err(error)) {
          recordRateAttempt(false, "xrc: " # Xrc.errorToText(error));
          return;
        };
      };
      let ?usdPerIcpMicros = Xrc.toMicros(rate) else {
        recordRateAttempt(false, "xrc returned an unusable rate scale");
        return;
      };
      if (not Pricing.plausibleUsdPerIcp(usdPerIcpMicros)) {
        recordRateAttempt(false, "implausible ICP price: " # usdPerIcpMicros.toText() # " micro-USD");
        return;
      };
      // The one-exchange case: XRC's own consistency check cannot catch it,
      // because a single rate cannot disagree with itself.
      let quality = Xrc.qualityOf(rate);
      if (quality.receivedRates < pricingConfig.minRateSources) {
        recordRateAttempt(
          false,
          "too few rate sources: " # quality.receivedRates.toText() # " of "
          # quality.queriedSources.toText() # " answered, need "
          # pricingConfig.minRateSources.toText(),
        );
        return;
      };
      // Reject an implausible *move* against the last good price, keeping the
      // previous rate serving until it goes stale rather than pricing on a
      // suspected glitch.
      //
      // Only a rate that is still *fresh* is a valid baseline. A stale one is not
      // evidence about the current market, and comparing against it deadlocks:
      // after an outage spanning a move larger than the delta bound, every
      // refresh would be rejected against an ancient price that itself can never
      // be replaced, so orders stay refused until an operator widens the config.
      // Guarding a move only makes sense between two observations close in time.
      let previous = switch (Pricing.freshRates(rateCache, pricingConfig.maxAgeNs, Time.now())) {
        case (?prior) ?prior.usdPerIcpMicros;
        case null null;
      };
      if (not Pricing.withinDelta(previous, usdPerIcpMicros, pricingConfig.maxRateDeltaBps)) {
        recordRateAttempt(false, "ICP price moved beyond the delta guard: " # usdPerIcpMicros.toText() # " micro-USD");
        return;
      };
      // XDR/ICP from the CMC — the rate the CMC will actually honour, so it is
      // read from the CMC and nowhere else. Same tick as the ICP price above,
      // which is what makes the pair time-aligned.
      let cmcRate = try { await cmc.get_icp_xdr_conversion_rate() } catch (e) {
        recordRateAttempt(false, "cmc call rejected: " # e.message());
        return;
      };
      let ?permyriad = Cmc.freshCmcRate(cmcRate.data, Time.now(), Cmc.cmcRateMaxAgeNs) else {
        recordRateAttempt(false, "cmc rate is stale or zero");
        return;
      };
      // Cross-check the two independent sources against each other. Dividing
      // them yields an implied XDR/USD, and XDR/USD is stable enough that an
      // implausible value means one of the two is wrong — which the wide band on
      // the ICP price alone would not catch.
      let ?implied = Pricing.impliedXdrPerUsdMicros(permyriad, usdPerIcpMicros) else {
        recordRateAttempt(false, "cannot derive an implied XDR/USD from the rate pair");
        return;
      };
      if (not Pricing.plausibleImpliedXdrPerUsd(implied)) {
        recordRateAttempt(
          false,
          "rate pair disagrees: implied " # implied.toText() # " micro-XDR/USD from "
          # usdPerIcpMicros.toText() # " micro-USD/ICP and " # permyriad.toText()
          # " permyriad XDR/ICP",
        );
        return;
      };
      Pricing.record(
        rateCache,
        {
          usdPerIcpMicros;
          xdrPermyriadPerIcp = permyriad;
          fetchedAtNs = Time.now();
          quality;
        },
      );
      recordRateAttempt(true, usdPerIcpMicros.toText() # " micro-USD/ICP, " # permyriad.toText() # " permyriad XDR/ICP");
    } finally {
      rateRefreshInFlight := false;
    };
  };

  /// The rate timer's job: refresh unless backing off, and only while a rail is
  /// actually selling.
  ///
  /// Refreshing on a timer rather than on demand is what makes the XRC's
  /// per-request fee independent of call volume — no user-facing method can
  /// trigger it, so no caller can drive our cycle spend. The cost is that a
  /// live gateway pays continuously whether or not anyone buys, which is why
  /// `railsLive` gates it: a dark gateway spends nothing.
  func rateTimerJob() : async () {
    if (not railsLive()) return;
    if (rateTicksToSkip > 0) {
      rateTicksToSkip -= 1;
      return;
    };
    await* refreshRates();
    // Exponential-ish backoff after a failure so an XRC outage neither burns
    // cycles nor earns us `RateLimited`.
    if (rateRefreshFailures > 0) {
      var skip = 1;
      var n = rateRefreshFailures;
      while (n > 1 and skip < rateBackoffMaxTicks) { skip *= 2; n -= 1 };
      rateTicksToSkip := if (skip > rateBackoffMaxTicks) rateBackoffMaxTicks else skip;
    };
  };

  /// Refresh cadence. Derived from the staleness window rather than configured
  /// separately, so the two can never be set inconsistently — a cadence longer
  /// than the window would let the cache lapse between ticks and refuse orders.
  func rateIntervalNs() : Nat {
    let half = Int.abs(pricingConfig.maxAgeNs) / 2;
    if (half < 30_000_000_000) 30_000_000_000 else half;
  };

  /// Adjust pricing params (§7): fee formula, staleness window, delta guard.
  /// Validated atomically — a bad config never partially applies.
  public shared ({ caller }) func set_pricing_config(config : Pricing.Config) : async Result.Result<(), Pricing.ConfigError> {
    requireAdmin(caller);
    switch (Pricing.validateConfig(config)) {
      case (#ok) {
        pricingConfig := config;
        // The cadence is derived from maxAgeNs, so re-arm rather than waiting
        // for the old interval to elapse under the new window.
        Timer.cancelTimer(rateTimerId);
        rateTimerId := Timer.recurringTimer<system>(#nanoseconds(rateIntervalNs()), rateTimerJob);
        auditAdmin(caller, "rates.configSet", "maxAgeNs=" # config.maxAgeNs.toText() # " deltaBps=" # config.maxRateDeltaBps.toText());
        #ok;
      };
      case (#err(e)) #err(e);
    };
  };

  /// Rates + params + refresh liveness, public: both rates are market data any
  /// third party can query for themselves, and the fee formula is what users
  /// are charged. Nothing here is secret, and reproducibility is the point.
  public query func pricing_status() : async {
    rates : ?Pricing.Rates;
    config : Pricing.Config;
    lastAttempt : ?{ atNs : Int; ok : Bool; detail : Text };
    /// Which Exchange Rate Canister the last refresh actually priced from. On
    /// mainnet this MUST read `uf6dk-hyaaa-aaaaq-qaaaq-cai`; anything else means
    /// the deploy injected `PUBLIC_CANISTER_ID:xrc` and prices are coming from
    /// somewhere else. Alert on it (RUNBOOK §9).
    ///
    /// **Null means no refresh has resolved it yet** — not that it is the mainnet
    /// canister. Null is the expected reading for the first seconds after an
    /// install or upgrade, and it is a "check again", never a pass.
    xrcCanisterId : ?Text;
  } {
    {
      rates = Pricing.lastRates(rateCache);
      config = pricingConfig;
      lastAttempt = lastRateAttempt;
      xrcCanisterId = lastXrcCanisterId;
    };
  };

  /// Force a rate refresh now (admin) — the ops lever after retuning config or
  /// while diagnosing a stale rate, without waiting for the next tick.
  public shared ({ caller }) func refresh_rates() : async ?Pricing.Rates {
    requireAdmin(caller);
    await* refreshRates();
    Pricing.lastRates(rateCache);
  };

  // ── Orders: create/query (task 6) ───────────────────────────────────────

  /// raw_rand source for order IDs (§2).
  transient let management = actor "aaaaa-aa" : actor {
    raw_rand : () -> async Blob;
  };

  /// raw_rand re-draws on an ID collision. With 128-bit IDs a single
  /// collision is already astronomically unlikely; exhausting this means
  /// the entropy source is broken, not that we're unlucky.
  transient let maxIdAttempts : Nat = 3;

  public type CreateOrderError = {
    /// Anonymous principal — a shared identity can't own orders (§7).
    #anonymous;
    /// No configured tier with this id.
    #unknownTier : Text;
    /// §3 fee formula swallows the tier's gross amount — a tier/fee config
    /// problem for the operator, not something a retry fixes.
    #tierBelowFees : Text;
    /// §3.1 fail-closed: no fresh rate and the refresh failed (or one is
    /// already in flight), so no price, so no order. Retry shortly.
    #rateUnavailable;
    /// The caller pinned a minimum cycle quantity and the current rate no
    /// longer clears it. Carries what the amount buys now, so the caller can
    /// show the buyer the real figure and let them decide.
    #quoteChanged : { quoted : Nat; minimum : Nat };
    /// Entropy source misbehaved (short blob or repeated collisions).
    #idGeneration;
    /// Gate.mo admission refusal — carries the observed value and the bound so
    /// the frontend can say *why* rather than failing generically.
    #notAdmitted : Gate.Reason;
  };

  public type CreatedOrder = {
    order : Types.Order;
    /// `<principal>_<orderId>` — the frontend appends this to the tier's
    /// Payment Link as `?client_reference_id=` (§6.1).
    clientReferenceId : Text;
  };

  /// One quote = one consistent epoch: the caller snapshots the rail's fee
  /// formula *before* any await, and both rates are read once from the cache
  /// here. The §6.1 pricing snapshot persisted on the order carries both rate
  /// inputs from that same epoch — the webhook reprices a mismatched paid
  /// amount from it, never from a fresh rate.
  ///
  /// Synchronous and awaitless by design: the rates come from the cache the
  /// refresh timer maintains, never from a call. That is what keeps a
  /// user-facing method from being able to trigger a paid XRC request.
  ///
  /// The fee is a parameter because each rail prices with its own formula (card
  /// = the Stripe formula in `pricingConfig`) over
  /// the one shared rate cache.
  func quoteCents(fee : { feeBps : Nat; feeFixedCents : Nat }, usdCents : Nat) : {
    #ok : (Nat, Types.Pricing);
    #stale;
    #unpriceable;
  } {
    switch (Pricing.quote(rateCache, fee, pricingConfig.maxAgeNs, usdCents, Time.now())) {
      case (#stale) #stale;
      case (#unpriceable) #unpriceable;
      case (#ok({ cycles; rates })) {
        #ok((
          cycles,
          {
            usdCents;
            usdPerIcpMicros = rates.usdPerIcpMicros;
            xdrPermyriadPerIcp = rates.xdrPermyriadPerIcp;
            rateStandardDeviation = rates.quality.standardDeviation;
            rateReceivedRates = rates.quality.receivedRates;
            rateQueriedSources = rates.quality.queriedSources;
            feeBps = fee.feeBps;
            feeFixedCents = fee.feeFixedCents;
          },
        ));
      };
    };
  };

  /// Read every admission input, synchronously, immediately before deciding —
  /// no awaits in between, so there is no TOCTOU window between observing and
  /// admitting. `Cycles.balance()` is this canister's own gas; the float comes
  /// from the last observation because a query cannot call the ledger (§5.3),
  /// and the authoritative float check remains the mint-time pre-gate.
  func gateObservation(caller : Principal) : Gate.Observation {
    {
      openOrders = Orders.openOrderCount(orderStore, caller);
      canisterCycles = Cycles.balance();
      burnedInWindowE8s = Treasury.burnedInWindow(burnLedger, treasuryConfig.burnWindowNs, Time.now());
      burnCapE8s = treasuryConfig.burnCapE8s;
      observedFloatE8s = switch (lastFloatObservation) {
        case (?observation) ?observation.e8s;
        case null null;
      };
      lowFloatThresholdE8s = treasuryConfig.lowFloatThresholdE8s;
    };
  };

  /// The §5.3-adjacent admission gate: refuse to *quote* when fulfilment is
  /// already known to be impossible, rather than taking the user's money and
  /// discovering it at mint time. Audited on refusal — a rail that has quietly
  /// stopped selling is something the operator must be able to see.
  func admit(caller : Principal, usdCents : Nat) : Result.Result<(), Gate.Reason> {
    switch (Gate.admit(gateConfig, gateObservation(caller), usdCents)) {
      case (#ok) #ok;
      case (#err(reason)) {
        audit("order.notAdmitted", Gate.reasonToText(reason));
        #err(reason);
      };
    };
  };

  /// raw_rand → Orders.create, re-drawing fresh entropy on an ID collision
  /// (§2). Null = the entropy source misbehaved (short blob or repeated
  /// collisions), never bad luck.
  func createOrderWithFreshId(
    owner : Types.Owner,
    rail : Types.Rail,
    destination : Types.Destination,
    lockedCycles : Nat,
    pricing : Types.Pricing,
  ) : async* ?Types.Order {
    var attempts = 0;
    while (attempts < maxIdAttempts) {
      let entropy = await management.raw_rand();
      let ?id = Orders.idFromEntropy(entropy) else return null;
      switch (Orders.create(orderStore, id, owner, rail, destination, lockedCycles, pricing, Time.now())) {
        case (#ok(order)) return ?order;
        case (#err(#duplicateId(_))) {}; // re-draw fresh entropy
      };
      attempts += 1;
    };
    null;
  };

  /// Create a card-rail order: II caller becomes the owner (ownership is
  /// captured here at the API edge, seam §11.1.3), the tier's USD amount is
  /// quoted into a locked cycle *quantity* (§3, net of fees at the cached
  /// rate — a stale cache refreshes lazily, a failed refresh fails closed
  /// §3.1), and the ID comes from raw_rand. The fee config is snapshotted
  /// before the refresh await, so one order is always priced from one
  /// consistent epoch even when a refresh interleaves with a config change;
  /// the store write after the awaits is atomic.
  /// `minCycles` pins the quantity the caller was shown (§3).
  ///
  /// The rate refresh runs on a timer, so a figure quoted to a buyer can move
  /// before they commit — and a client-side re-check cannot close that window,
  /// because a query and this update are separate messages. Pinning the
  /// expectation here makes the check atomic with the lock, so no order can ever
  /// be created at a quantity the buyer was not shown.
  ///
  /// A **minimum**, deliberately, not an equality: a rate move in the buyer's
  /// favour passes through and they keep the extra cycles. The guard can only
  /// ever protect the buyer. `null` opts out entirely.
  public shared ({ caller }) func create_order(
    tierId : Text,
    destination : Types.Destination,
    minCycles : ?Nat,
  ) : async Result.Result<CreatedOrder, CreateOrderError> {
    switch (Auth.checkUser(caller)) {
      case (#err(#anonymous)) return #err(#anonymous);
      case (#ok) {};
    };
    let ?tier = Tiers.find(cardTiers, tierId) else return #err(#unknownTier(tierId));
    // Admission BEFORE the quote, so a spamming principal is turned away before
    // it can make the canister do work (`canister-security`: anyone can burn
    // your cycles with update calls).
    switch (admit(caller, tier.usdCents)) {
      case (#err(reason)) return #err(#notAdmitted(reason));
      case (#ok) {};
    };
    let fee = { feeBps = pricingConfig.feeBps; feeFixedCents = pricingConfig.feeFixedCents };
    let (lockedCycles, pricing) = switch (quoteCents(fee, tier.usdCents)) {
      case (#ok(quoted)) quoted;
      case (#unpriceable) return #err(#tierBelowFees(tierId));
      case (#stale) return #err(#rateUnavailable);
    };
    switch (minCycles) {
      case (?minimum) if (lockedCycles < minimum) {
        return #err(#quoteChanged({ quoted = lockedCycles; minimum }));
      };
      case null {};
    };
    let owner : Types.Owner = #ii(caller);
    switch (await* createOrderWithFreshId(owner, #card, destination, lockedCycles, pricing)) {
      case (?order) #ok({ order; clientReferenceId = Orders.clientReferenceId(owner, order.id) });
      case null #err(#idGeneration);
    };
  };

  /// §2 query authz: `caller == order.owner`, null otherwise — existence is
  /// not revealed to non-owners. Anonymous callers own nothing by
  /// construction (create_order rejects them), so they always get null.
  public shared query ({ caller }) func get_order(id : Types.OrderId) : async ?Types.Order {
    Orders.getOwned(orderStore, id, caller);
  };

  /// Order history for the caller (§2, fixes the lost-receipt problem).
  public shared query ({ caller }) func list_orders() : async [Types.Order] {
    Orders.ordersFor(orderStore, caller);
  };

  /// Replace the card tier config (§3/§7 — admin, validated atomically: a
  /// bad config never partially applies).
  public shared ({ caller }) func set_card_tiers(tiers : [Tiers.Tier]) : async Result.Result<(), Tiers.ValidateError> {
    requireAdmin(caller);
    switch (Tiers.validate(tiers, gateConfig.maxPurchaseUsdCents)) {
      case (#ok) {
        cardTiers := tiers;
        auditAdmin(caller, "tiers.set", tiers.size().toText() # " tier(s)" # (if (tiers.size() == 0) " — CARD RAIL PAUSED" else ""));
        #ok;
      };
      case (#err(e)) #err(e);
    };
  };

  /// Adjust the admission gate (§7): open-order cap, own-cycles floor,
  /// per-purchase ceiling. Validated atomically — a bad config never partially
  /// applies. Lowering `maxPurchaseUsdCents` below an existing tier does NOT
  /// retroactively invalidate that tier's registration, but the next
  /// `set_card_tiers` will reject it and the webhook will refuse to mint a
  /// payment above the new ceiling.
  /// Declare which Stripe mode this gateway serves (admin).
  ///
  /// Set it to `?true` before taking real payments and `?false` on a sandbox
  /// deployment. `null` restores "accept either", which only makes sense while
  /// nothing of value is at stake.
  public shared ({ caller }) func set_expected_livemode(expected : ?Bool) : async () {
    requireAdmin(caller);
    expectLivemode := expected;
    auditAdmin(
      caller,
      "stripe.expectLivemodeSet",
      switch (expected) {
        case (?true) "true — only live-mode payments will mint";
        case (?false) "false — only test-mode payments will mint";
        case null "unset — either mode will mint";
      },
    );
  };

  public query func expected_livemode() : async ?Bool {
    expectLivemode;
  };

  public shared ({ caller }) func set_gate_config(config : Gate.Config) : async Result.Result<(), Gate.ConfigError> {
    requireAdmin(caller);
    // Cross-check against live tiers: lowering the ceiling under a registered tier
    // would leave it sellable but unpayable (see Gate.ConfigError.tierAboveCeiling).
    let tierPrices = cardTiers.map(func(t) = (t.id, t.usdCents));
    switch (Gate.validateConfig(config, tierPrices)) {
      case (#ok) {
        gateConfig := config;
        auditAdmin(caller, "gate.configSet", "openOrderCap=" # config.maxOpenOrdersPerPrincipal.toText()
          # " minCycles=" # config.minCanisterCycles.toText()
          # " maxPurchaseCents=" # config.maxPurchaseUsdCents.toText());
        #ok;
      };
      case (#err(e)) #err(e);
    };
  };

  /// Adjust retention (§4/§4.2): the `#created` TTL and the delete horizon.
  public shared ({ caller }) func set_retention_config(config : Retention.Config) : async Result.Result<(), Retention.ConfigError> {
    requireAdmin(caller);
    switch (Retention.validateConfig(config)) {
      case (#ok) {
        retentionConfig := config;
        auditAdmin(caller, "retention.configSet", "ttlNs=" # config.orderTtlNs.toText());
        #ok;
      };
      case (#err(e)) #err(e);
    };
  };

  /// Public: the frontend needs the ceiling to bound its amount input, and the
  /// TTL to tell the user how long an order stays live. Same transparency
  /// stance as `forex_status` and `treasury_status` — these are the rules users
  /// are held to, not secrets.
  public query func lifecycle_config() : async { gate : Gate.Config; retention : Retention.Config } {
    { gate = gateConfig; retention = retentionConfig };
  };

  /// Admission preflight, public: lets the frontend disable the buy button with
  /// a real reason (and lets an operator ask "would a purchase go through right
  /// now?") without creating an order. `usdCents` is the gross amount to test.
  ///
  /// The answer is advisory — it can go stale between this call and
  /// `create_order`, which re-checks. It is not an authorization decision, so
  /// anonymous callers may ask: it reveals only operational state that
  /// `treasury_status` already publishes. Answered for the *calling* principal,
  /// so the open-order cap it reports is the caller's own.
  public shared query ({ caller }) func can_purchase(usdCents : Nat) : async Result.Result<(), Gate.Reason> {
    Gate.admit(gateConfig, gateObservation(caller), usdCents);
  };

  /// Public — the frontend renders tiers and their Payment Links from this.
  public query func card_tiers() : async [Tiers.Tier] {
    cardTiers;
  };

  /// What a given amount buys right now (§3), before anyone commits to an order.
  public type QuotePreview = {
    usdCents : Nat;
    /// Payment-processing fee at the rail's current formula, rounded up.
    feeCents : Nat;
    /// What is left to buy cycles with. Null when the fee swallows the amount.
    netCents : ?Nat;
    /// The §3 quantity this amount would lock. Null exactly when `create_order`
    /// would refuse to price it — no rates, stale rates, or fee-swallowed — so a
    /// caller that shows `cycles` never promises a purchase that cannot happen.
    cycles : ?Nat;
  };

  public type QuotePreviews = {
    quotes : [QuotePreview];
    /// The rate pair the quotes came from, so a caller can reproduce the
    /// arithmetic without a second call. Null when nothing usable is cached.
    rates : ?Pricing.Rates;
    /// Deducted by the cycles ledger from a `#cyclesLedgerAccount` delivery; a
    /// `#canister` top-up receives the full quantity.
    cyclesLedgerDepositFee : Nat;
  };

  /// Batch pre-purchase quote, public.
  ///
  /// This exists so the price a buyer is shown is **computed by the same code
  /// that prices the order** — `quoteCents`, the identical function
  /// `create_order` calls. A client reimplementing the
  /// formula would be one refactor away from quoting a number the gateway does
  /// not honour, and the buyer would have no way to tell which was wrong.
  ///
  /// Batched because the tier grid needs every price in one round trip.
  ///
  /// **Unbounded input on purpose**, unlike the paged queries. Those cap `limit`
  /// because a tiny request makes them scan a large store — cheap to invoke,
  /// expensive to serve. Here the work is constant per element the caller already
  /// had to transmit, there is no state scan and no amplification, so the ingress
  /// size limit already bounds it. A cap would only buy silent truncation, which
  /// is a worse failure than the one it prevents: a caller passing more tiers
  /// than the cap would get a short array back with no signal that anything was
  /// dropped.
  ///
  /// There is one rail, so there is one fee formula and no `rail` parameter to
  /// select it with (#35): a query that branches on nothing should not ask the
  /// caller to pick. `Types.Rail` still exists on the order — the type names the
  /// dimension, this query does not need to switch on it.
  public query func quote_previews(amounts : [Nat]) : async QuotePreviews {
    let fee : { feeBps : Nat; feeFixedCents : Nat } = {
      feeBps = pricingConfig.feeBps;
      feeFixedCents = pricingConfig.feeFixedCents;
    };
    let quotes = amounts.map(
      func(usdCents) {
        {
          usdCents;
          feeCents = Pricing.feeCents(fee, usdCents);
          netCents = Pricing.netCents(fee, usdCents);
          cycles = switch (quoteCents(fee, usdCents)) {
            case (#ok((cycles, _))) ?cycles;
            case (#stale or #unpriceable) null;
          };
        };
      },
    );
    {
      quotes;
      rates = Pricing.lastRates(rateCache);
      cyclesLedgerDepositFee = Cmc.cyclesLedgerDepositFee;
    };
  };

  // ── Webhook ingestion state (task 8, §4.1/§4.2) ─────────────────────────

  /// §4.2 per-rail dedup sets. Stripe keys prune opportunistically on the
  /// webhook path (~7 days, Idempotency.mo).
  let dedup : Idempotency.Store = Idempotency.emptyStore();

  /// §4.1 bounded error queue: Type 1 (fiat-only, operator refunds in the
  /// Stripe Dashboard) + Type 2 (stranded cycles, task 9).
  let errorQueue : ErrorQueue.Store = ErrorQueue.emptyStore();

  /// §4.2 bounded audit-log ring buffer — operational trail, not a
  /// financial record (orders/error queue are the records of money).
  let auditLog : AuditLog.Log = AuditLog.emptyLog();

  /// Bounds are operator headroom knobs, not financial records — transient
  /// so a redeploy can retune them (same reasoning as maxRequestBodyBytes).
  transient let errorQueueCapacity : Nat = 1_000;
  transient let auditLogCapacity : Nat = 4_096;

  /// Built per request rather than held in a transient field: it carries
  /// `maxPurchaseUsdCents` from the live gate config, so a ceiling change takes
  /// effect on the very next webhook.
  func webhookDeps() : Card.Deps {
    {
      orders = orderStore;
      dedup;
      errorQueue;
      errorQueueCapacity;
      expectLivemode;
      auditLog;
      auditLogCapacity;
      paidIntents;
      maxPurchaseUsdCents = gateConfig.maxPurchaseUsdCents;
    };
  };

  /// Open-obligation depth, public.
  ///
  /// Unresolved entries are never evicted, so this number only ever comes down
  /// by the operator working it. A climbing value means dollars are arriving
  /// that nobody has dealt with — the single most important operational number
  /// on the money path, and it is public because §9's transparency stance says
  /// operational state is not secret.
  public query func error_queue_depth() : async { unresolved : Nat; retained : Nat } {
    {
      unresolved = ErrorQueue.unresolvedCount(errorQueue);
      retained = ErrorQueue.size(errorQueue);
    };
  };

  /// §4.1 retained history, oldest first, **paged**. Admin: entries carry
  /// payment references and claimed-but-bogus URL params.
  ///
  /// Paged because unresolved obligations are never evicted, so the queue can
  /// grow — and an unpaginated read would eventually exceed Candid's 2 MB
  /// message limit, i.e. the record would become unreadable exactly when it
  /// mattered most. Pass `null` to start; feed `nextCursor` back until it is
  /// null. `limit` is capped at `ErrorQueue.maxPageSize`.
  public shared query ({ caller }) func error_queue(
    afterId : ?Nat,
    limit : Nat,
  ) : async ErrorQueue.Page {
    requireAdmin(caller);
    ErrorQueue.page(errorQueue, afterId, limit);
  };

  /// The operator worklist: open obligations only, paged. Filtered server-side
  /// so a large body of resolved history never stands between the operator and
  /// the dollars that still need an answer.
  public shared query ({ caller }) func error_queue_unresolved(
    afterId : ?Nat,
    limit : Nat,
  ) : async ErrorQueue.Page {
    requireAdmin(caller);
    ErrorQueue.unresolvedPage(errorQueue, afterId, limit);
  };

  /// Manual resolution (§4.1/§7): refund issued off-chain, or Type 2 cycles
  /// re-delivered/refunded. (`charge.refunded` resolves Type 1 entries
  /// automatically; this is the fallback and the only path for Type 2.)
  public shared ({ caller }) func resolve_error(id : Nat) : async Result.Result<ErrorQueue.Entry, ErrorQueue.ResolveError> {
    requireAdmin(caller);
    let resolved = ErrorQueue.resolve(errorQueue, id, Time.now());
    switch (resolved) {
      case (#ok(entry)) auditAdmin(caller, "errorQueue.resolved", "entry " # id.toText() # ": " # entry.detail);
      case (#err(_)) {};
    };
    resolved;
  };

  /// §4.2 operational trail, newest-last. Admin: details reference payment
  /// intents. Readers detect ring-buffer drops via gaps in `seq`.
  public shared query ({ caller }) func audit_log() : async [AuditLog.Event] {
    requireAdmin(caller);
    AuditLog.events(auditLog);
  };

  // ── CMC mint pipeline (task 9, §5/§5.1) ─────────────────────────────────

  /// §4.2 `journal : Map<OrderId, JournalEntry>` — the money-out record:
  /// transfer intent (written *before* the ledger call, §5.1), block_index,
  /// minted cycles, retries. Financial record — kept for years, never pruned.
  let mintJournal : Cmc.Journal = Cmc.emptyJournal();

  transient let icpLedger = actor (Cmc.icpLedgerId) : Cmc.LedgerService;
  transient let cmc = actor (Cmc.cmcId) : Cmc.CmcService;
  transient let cyclesLedger = actor (Cmc.cyclesLedgerId) : Cmc.CyclesLedgerService;

  /// Per-order single-flight guard: two concurrent drivers for one order
  /// would both pass the status gates between awaits. Transient — an
  /// upgrade mid-mint clears it and the journal-driven resume (Cmc.stageOf)
  /// picks up where the state actually is.
  transient let mintsInFlight = Set.empty<Types.OrderId>();

  /// Bounds the retriable-error loop on stages the ledger's 24 h dedup window
  /// doesn't already bound. Defined alongside the sweep cadence in Recovery.mo,
  /// because the two are only correct in combination.
  transient let maxMintRetries : Nat = Recovery.maxMintRetries;

  /// Orders already audited for a blocked `#begin` this session, so a stuck
  /// order contributes one audit line rather than one per sweep. Transient: the
  /// durable record of a stuck order is its error-queue entry once the max-wait
  /// bound trips, not this.
  transient let mintBlockedAudited = Set.empty<Types.OrderId>();

  /// Orders already alerted as delayed → the error-queue entry id raised for it.
  ///
  /// Persistent, so an upgrade does not re-alert an order that is still waiting
  /// (which would put duplicate obligations on the operator's worklist).
  ///
  /// The *entry id* rather than a timestamp, because the alert has to be closed
  /// when the delay ends: an order that eventually delivers must not leave an
  /// open obligation on the worklist describing a problem that no longer exists.
  /// order id → (error-queue entry id, the stage that alert described).
  ///
  /// The stage is kept so a *changed* stall can refresh the entry. An order that
  /// alerts while `#paid` and later stalls in `#icpAtCmc` is a different problem with
  /// a different recovery, and leaving the first wording in place would have the
  /// operator chasing a cause that has moved on.
  let delayedAlerts = Map.empty<Types.OrderId, (Nat, Text)>();

  /// Raise the §5 delivery-delayed alert for an order, at most once.
  ///
  /// Deliberately does NOT transition the order: the cause is operator-fixable
  /// and the order must stay sweepable so that fixing it delivers with no
  /// further intervention. Only `abandon_order` ends an order without delivery.
  func alertDelayed(order : Types.Order, stage : Text, detail : Text) {
    // The guard lives inside the body rather than on a `case ... if`: a guarded
    // case is irrefutable to the coverage checker, so the second `?` case would
    // be reported as unmatched (M0146) even though it is reached.
    switch (delayedAlerts.get(order.id)) {
      case (?(staleId, reported)) {
        // Same stall, already reported. Staying silent is the point: re-raising
        // on every sweep would flood the worklist and the audit ring.
        if (reported == stage) return;
        // A *different* stall. Close the stale entry and raise one that describes
        // where the order actually is now, rather than leaving day-one wording on
        // the worklist.
        ignore ErrorQueue.resolve(errorQueue, staleId, Time.now());
        audit("mint.delayedStageChanged", order.id # ": " # reported # " → " # stage);
      };
      case null {};
    };
    let entryId = queueMintError(
      order.rail,
      #deliveryDelayed({ orderId = order.id; stage; sinceNs = order.updatedAtNs }),
      detail,
    );
    delayedAlerts.add(order.id, (entryId, stage));
    audit("mint.delayed", order.id # " [" # stage # "]: " # detail);
  };

  /// The delay ended, so close the alert it raised.
  ///
  /// Resolving the entry matters as much as forgetting the mapping: an open
  /// obligation describing a delay that is over is an orphan on the operator's
  /// worklist, and the worklist is only useful if everything on it is live.
  func clearDelayed(orderId : Types.OrderId) {
    switch (delayedAlerts.get(orderId)) {
      case (?(entryId, _)) {
        ignore ErrorQueue.resolve(errorQueue, entryId, Time.now());
        delayedAlerts.remove(orderId);
      };
      case null {};
    };
  };

  /// Audit a blocked mint at most once per order per session.
  func auditMintBlockedOnce(orderId : Types.OrderId, tag : Text, detail : Text) {
    if (mintBlockedAudited.contains(orderId)) return;
    mintBlockedAudited.add(orderId);
    audit(tag, detail);
  };

  func selfPrincipal() : Principal = Principal.fromActor(CyclesGateway);

  // ── Treasury + burn cap (task 10, §5.3) ─────────────────────────────────

  /// §5.3 treasury policy. burnCapE8s defaults to 0 — every mint holds in
  /// #awaitingTreasury until the operator consciously sizes the primary
  /// blast-radius bound (same no-invented-numbers stance as the empty tier
  /// list; a default cap in ICP would be a money decision invented here).
  var treasuryConfig : Treasury.Config = Treasury.defaultConfig();

  /// §5.3 rolling-window burn accounting. Persistent — an upgrade must not
  /// reset the blast-radius bound mid-window.
  let burnLedger : Treasury.Ledger = Treasury.emptyLedger();

  /// Last float balance the mint pre-gate (or an admin refresh) observed.
  /// The balance-alert query reads this; queries can't call the ledger.
  var lastFloatObservation : ?Treasury.FloatObservation = null;

  /// Record a float observation, audit-alerting on the *crossing* into low
  /// (not every low observation — a sweep over held orders would spam the
  /// ring buffer out of its useful history).
  func observeFloat(e8s : Nat) {
    let wasLow = switch (lastFloatObservation) {
      case (?previous) Treasury.isLowFloat(treasuryConfig, previous.e8s);
      case null false;
    };
    lastFloatObservation := ?{ e8s; atNs = Time.now() };
    if (Treasury.isLowFloat(treasuryConfig, e8s) and not wasLow) {
      audit("treasury.lowFloat", "float " # e8s.toText() # " e8s below threshold " # treasuryConfig.lowFloatThresholdE8s.toText());
    };
  };

  /// Adjust treasury policy (§5.3/§7): burn cap, window, max hold, alert
  /// threshold. Validated atomically — a bad config never partially applies.
  public shared ({ caller }) func set_treasury_config(config : Treasury.Config) : async Result.Result<(), Treasury.ConfigError> {
    requireAdmin(caller);
    switch (Treasury.validateConfig(config)) {
      case (#ok) {
        treasuryConfig := config;
        auditAdmin(caller, "treasury.configSet", "burnCap=" # config.burnCapE8s.toText()
          # " e8s/window, lowFloatThreshold=" # config.lowFloatThresholdE8s.toText()
          # ", maxHold=" # config.maxHoldNs.toText() # "ns");
        #ok;
      };
      case (#err(e)) #err(e);
    };
  };

  /// §5.3 manual override: clear the rolling window's consumption after
  /// confirming the traffic was legitimate (or rotating a leaked secret).
  /// Returns the e8s of consumption cleared. Held orders resume on the next
  /// sweep, not here — the pre-gate stays the single decision point.
  public shared ({ caller }) func reset_burn_window() : async Nat {
    requireAdmin(caller);
    let cleared = Treasury.burnedInWindow(burnLedger, treasuryConfig.burnWindowNs, Time.now());
    Treasury.reset(burnLedger);
    auditAdmin(caller, "treasury.burnWindowReset", cleared.toText() # " e8s of window consumption cleared");
    cleared;
  };

  /// On-demand float refresh (admin — public would let anyone spend our
  /// cycles on ledger calls). The mint pre-gate refreshes the observation as
  /// a side effect; this is the ops lever between mints.
  public shared ({ caller }) func refresh_float() : async Nat {
    requireAdmin(caller);
    let e8s = await icpLedger.icrc1_balance_of({ owner = selfPrincipal(); subaccount = null });
    observeFloat(e8s);
    e8s;
  };

  /// §5.3 balance alert + soft UI gate, public: the frontend disables tiers
  /// off `lowFloat`, and cap consumption is operational transparency (the
  /// thesis), not a secret. The float observation may be stale — `atNs` says
  /// how stale; `refresh_float` is the admin lever for a fresh read.
  public query func treasury_status() : async Treasury.Status {
    {
      config = treasuryConfig;
      burnedInWindowE8s = Treasury.burnedInWindow(burnLedger, treasuryConfig.burnWindowNs, Time.now());
      lastObservedFloat = lastFloatObservation;
      lowFloat = Treasury.lowFloatSignal(treasuryConfig, lastFloatObservation);
      // O(1) off the maintained tally — this query is public and
      // unauthenticated, so it must not scan the order store.
      heldOrders = Orders.countOf(orderStore, #awaitingTreasury);
      // Money in, not yet minted. A non-transient value here means the mint is
      // blocked upstream (a stale CMC rate, a CMC outage) and orders are on the
      // clock toward `mintWaitExceeded` — visible without reading the audit log,
      // which is a ring buffer that drops.
      paidOrders = Orders.countOf(orderStore, #paid);
    };
  };

  func audit(tag : Text, detail : Text) {
    ignore AuditLog.append(auditLog, auditLogCapacity, Time.now(), tag, detail);
  };

  /// Audit an admin action, recording **which principal took it**.
  ///
  /// §7's trust model is a flat controller allowlist with equal privileges —
  /// "any one can upgrade-then-drain". With several controllers and no caller
  /// recorded, the trail can say the burn cap was raised but not by whom, which
  /// is the one thing it most needs to say. Every admin mutation goes through
  /// this.
  func auditAdmin(caller : Principal, tag : Text, detail : Text) {
    audit(tag, "by " # caller.toText() # ": " # detail);
  };

  /// Driver-side transition helper: the pipeline only requests legal edges,
  /// so a refusal is a concurrent-update race — degrade to "stop this pass"
  /// (null), never trap mid-money-flow.
  func tryTransition(id : Types.OrderId, to : Types.OrderStatus) : ?Types.Order {
    switch (Orders.applyTransition(orderStore, id, to, Time.now())) {
      case (#ok(order)) ?order;
      case (#err(_)) null;
    };
  };

  /// Queue a mint-path error entry, audit-logging any unresolved eviction
  /// (each is a live money obligation dropped from on-chain state, §4.1).
  func queueMintError(rail : Types.Rail, kind : ErrorQueue.Kind, detail : Text) : Nat {
    let result = ErrorQueue.add(errorQueue, errorQueueCapacity, rail, kind, detail, Time.now());
    for (victim in result.evicted.values()) {
      if (victim.resolvedAtNs == null) {
        audit("errorQueue.evictedUnresolved", "entry " # victim.id.toText() # ": " # victim.detail);
      };
    };
    result.entry.id;
  };

  /// §5.1 escalation: the mint stopped where the money position is
  /// uncertain. Terminal — the order goes `#errorQueue` and the operator
  /// resolves off-chain (inspect ledger/CMC/destination, refund/re-deliver).
  func escalateStuckMint(order : Types.Order, stage : Text, detail : Text) {
    ignore tryTransition(order.id, #errorQueue);
    Cmc.patch(mintJournal, order.id, { status = ?#errorQueue; blockIndex = null; cyclesMinted = null; bumpRetries = false }, Time.now());
    // Before queueing the escalation: any open delay alert for this order says
    // "it delivers on the next sweep", which just stopped being true. Leaving it
    // open would put a false promise on the worklist next to the real problem,
    // and leak its `delayedAlerts` entry forever.
    clearDelayed(order.id);
    // Same reasoning for the once-per-order audit guard: the order is terminal,
    // so nothing will re-audit a mint block for it and keeping the id would only
    // suppress a legitimate line if it were ever re-driven.
    mintBlockedAudited.remove(order.id);
    ignore queueMintError(order.rail, #stuckMint({ orderId = order.id; stage }), detail);
    audit("mint.stuck", order.id # " [" # stage # "]: " # detail);
  };

  /// §5 forward half of mint-to-self-then-forward. The cycles ride the call
  /// from the app balance; a rejected/failed call refunds them to the app
  /// balance — exactly the Type 2 posture (§4.1).
  func forwardCycles(order : Types.Order) : async* { #ok; #failed : Text } {
    try {
      switch (order.destination) {
        case (#canister(canisterId)) {
          await (with cycles = order.lockedCycles) ic.deposit_cycles({ canister_id = canisterId });
        };
        case (#cyclesLedgerAccount(account)) {
          ignore await (with cycles = order.lockedCycles) cyclesLedger.deposit({ to = account; memo = null });
        };
      };
      #ok;
    } catch (e) {
      #failed(e.message());
    };
  };

  /// Drive one order as far toward `#delivered` as the world allows (§5).
  /// Each loop pass asks Cmc.stageOf for the next move off status + journal,
  /// so the first attempt and every recovery resume run the same code —
  /// "replay the identical transfer" (§5.1) isn't a special case, it IS the
  /// transfer path. Retriable failures return with state untouched (plus a
  /// retry bump) for the next sweep; uncertainty escalates.
  func driveMint(orderId : Types.OrderId) : async* () {
    label drive loop {
      let ?order = Orders.get(orderStore, orderId) else return;
      // §5.3: a treasury-held order resumes here — Treasury owns the hold
      // policy (max-wait), Cmc.stageOf owns the money-out resume logic. A
      // hold within the wait bound retries #begin: the pre-gate inside it is
      // the single decision point for cap/float, so a rolled window or a
      // refill clears the hold with no second code path. updatedAtNs is the
      // hold start (the hold transition is the last one the order took).
      // Bound the time an order may sit with money in and nothing minted,
      // whatever the reason.
      //
      // `#begin` has several paths that return without transitioning — the CMC
      // call failing, its rate being stale, the float read failing, an
      // underivable e8s amount. Each leaves the order `#paid` and relies on the
      // next sweep, so a persistent upstream problem parked an order forever:
      // no bound, no error-queue entry, and the only trace was one audit line
      // per sweep in a ring buffer that both floods and drops.
      //
      // The money position is identical to `treasuryWaitExceeded` — fiat in,
      // nothing minted, refund in the Stripe Dashboard — so it is bounded by the
      // same `maxHoldNs` and escalated the same way. Orders that are actually
      // progressing bump `updatedAtNs` on every transition, so only a genuinely
      // stuck one trips this.
      // The alert tier covers **every** in-flight status, not just `#paid`.
      // `#minting` and `#icpAtCmc` are equally capable of sitting still — a
      // ledger or CMC that keeps answering retriably leaves the order there —
      // and a buyer waiting on those is no less stuck than one waiting on the
      // burn cap. `updatedAtNs` is the right age anchor for all three: retries
      // do not transition, so it stays pinned at the moment the order entered
      // its current state.
      switch (order.status) {
        case (#paid or #minting or #icpAtCmc) {
          switch (Treasury.waitStage(order.updatedAtNs, Time.now(), treasuryConfig)) {
            case (#retry) {};
            case (#alert) {
              // Tell someone while the cause is still fixable, and keep retrying:
              // most incidents end here with the order delivering.
              alertDelayed(
                order,
                switch (order.status) {
                  case (#minting) "transferDelayed";
                  case (#icpAtCmc) "notifyDelayed";
                  case (_) "mintDelayed";
                },
                switch (order.status) {
                  case (#minting) "paid, ICP transfer not yet confirmed past the alert threshold — check the ICP ledger; it resumes on the next sweep";
                  case (#icpAtCmc) "paid, ICP is at the CMC but notify_top_up keeps failing past the alert threshold — check CMC health; the block index is in mint_journal and notify is idempotent";
                  case (_) "paid but not yet minted past the alert threshold — fix the cause (burn cap / float / CMC) and it delivers on the next sweep";
                },
              );
            };
            case (#terminate) {
              // §5.3 max-wait bound. By now the cause is not transient, and a
              // buyer left waiting files a chargeback — which costs more than a
              // refund. Terminating so the operator refunds is the protective act.
              //
              // The escalation comes from `Cmc.terminationFor`, which reads the
              // **journal** and not just the status: the status says where the
              // order stopped, the journal says where the money is, and the money
              // position is what the operator acts on. Deciding this inline off
              // status alone is what produced three rounds of defects — see that
              // function's doc for the specific dangerous cell it closes.
              let termination = Cmc.terminationFor(order.status, mintJournal.get(orderId));
              escalateStuckMint(order, termination.stage, termination.detail);
              clearDelayed(orderId);
              mintBlockedAudited.remove(orderId);
              return;
            };
          };
        };
        case (_) {};
      };
      let stage : Cmc.Stage = switch (order.status) {
        case (#awaitingTreasury) {
          switch (Treasury.waitStage(order.updatedAtNs, Time.now(), treasuryConfig)) {
            case (#retry) #begin;
            case (#alert) {
              // A hold clears the moment the window rolls or the float is
              // refilled, so keep retrying — but say something now.
              alertDelayed(order, "treasuryDelayed", "held past the alert threshold — refill the float or raise the burn cap and it delivers on the next sweep");
              #begin;
            };
            case (#terminate) {
              // §5.3: same decision function as every other terminate, so there
              // is exactly one place that maps a money position to an
              // instruction.
              let termination = Cmc.terminationFor(order.status, mintJournal.get(orderId));
              escalateStuckMint(order, termination.stage, termination.detail);
              clearDelayed(orderId);
              mintBlockedAudited.remove(orderId);
              return;
            };
          };
        };
        case (_) Cmc.stageOf(order.status, mintJournal.get(orderId), Time.now(), Cmc.ledgerDedupWindowNs, maxMintRetries);
      };
      switch (stage) {
        case (#none) return;
        case (#escalate(reason)) {
          // ⚠️ This is the route that actually fires. The recovery sweep runs
          // every 15 min, so `stageOf` reaches an escalation within minutes of a
          // failure, while the 72 h wait bound is the rare path. Emitting a bare
          // "mint pipeline stopped: <reason>" here left the operator's *first*
          // read of the entry with no instruction, on the high-probability route.
          //
          // Two different questions, so both are answered:
          //
          // - `stage` stays `stageOf`'s reason — that is the **cause**, and it is
          //   the key the runbook triage table is organised by.
          // - the detail comes from `terminationFor` — that is the **money
          //   position**, which is what determines the action.
          //
          // They can legitimately disagree: retries exhausted in `#minting` with
          // no block is caused by retry exhaustion but the money is in an
          // unknown-transfer position, and "establish its fate, never rebuild"
          // is the correct action regardless of why we stopped trying. Naming
          // both means neither reading can mislead.
          let stage = Cmc.escalateReasonToText(reason);
          let position = Cmc.terminationFor(order.status, mintJournal.get(orderId));
          let detail =
            if (position.stage == stage) {
              position.detail;
            } else {
              "stopped because: " # stage # ". Money position is " # position.stage
              # " — " # position.detail;
            };
          escalateStuckMint(order, stage, detail);
          return;
        };
        case (#begin) {
          // §5 rate derivation: fresh CMC ICP/XDR rate, staleness-guarded.
          let rate = try { await cmc.get_icp_xdr_conversion_rate() } catch (e) {
            auditMintBlockedOnce(orderId, "mint.rateFetchFailed", orderId # ": " # e.message());
            return; // stays #paid; the next sweep retries
          };
          let ?permyriad = Cmc.freshCmcRate(rate.data, Time.now(), Cmc.cmcRateMaxAgeNs) else {
            auditMintBlockedOnce(orderId, "mint.rateStale", orderId);
            return;
          };
          // §5.3 pre-gate input: the live float balance (also feeds the
          // balance-alert observation).
          let floatE8s = try {
            await icpLedger.icrc1_balance_of({ owner = selfPrincipal(); subaccount = null });
          } catch (e) {
            auditMintBlockedOnce(orderId, "mint.balanceFetchFailed", orderId # ": " # e.message());
            return; // status untouched; the next sweep retries
          };
          observeFloat(floatE8s);
          // Re-read after the awaits; only an untouched mintable order
          // proceeds (#awaitingTreasury arrives here via the hold retry).
          let ?fresh = Orders.get(orderStore, orderId) else return;
          switch (fresh.status) {
            case (#paid or #awaitingTreasury) {};
            case (_) continue drive;
          };
          let ?e8s = Cmc.icpE8sForCycles(fresh.lockedCycles, permyriad) else {
            // Audited, not silent: the order stays #paid and the next sweep
            // retries, so without a trace this looks like a mint that simply
            // never ran.
            auditMintBlockedOnce(orderId, "mint.unpriceable", orderId # ": cannot derive e8s for " # fresh.lockedCycles.toText() # " cycles at " # permyriad.toText() # " permyriad");
            return;
          };
          // §5.3 pre-gate: burn cap (blast-radius bound, checked first —
          // it must hold mints even when the float could fund them), then
          // float sufficiency. A held order stays put on re-hold (no
          // transition, no re-audit — the hold start must keep its max-wait
          // clock and the ring buffer its history).
          switch (Treasury.gate(burnLedger, treasuryConfig, floatE8s, e8s, Cmc.icpTransferFeeE8s, Time.now())) {
            case (#hold(reason)) {
              if (fresh.status == #paid) {
                ignore tryTransition(orderId, #awaitingTreasury);
                audit("mint.held", orderId # ": " # Treasury.holdReasonToText(reason));
              };
              return;
            };
            case (#proceed) {};
          };
          // §5.1 step 1 — intent + #minting + burn-cap consumption commit
          // in ONE sync block, before the transfer await. From here the
          // transfer args are frozen; replay is always bit-identical. The
          // cap entry is never refunded on failure — over-counting pauses
          // mints early, the fail-safe direction for a blast-radius bound.
          let intent = Cmc.buildIntent(selfPrincipal(), e8s, Time.now());
          let ?minting = tryTransition(orderId, #minting) else return;
          Treasury.recordBurn(burnLedger, treasuryConfig.burnWindowNs, e8s, Time.now());
          ignore Cmc.openEntry(mintJournal, minting, intent, Time.now());
          // fall through the loop → #replayTransfer issues the transfer
        };
        case (#replayTransfer(intent)) {
          let result = try { await icpLedger.icrc1_transfer(Cmc.transferArgs(intent)) } catch (e) {
            Cmc.patch(mintJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
            audit("mint.transferFailed", orderId # ": " # e.message());
            return;
          };
          switch (Cmc.interpretTransfer(result)) {
            case (#blockIndex(block)) {
              // Progress: allow a future block on this order to be audited again.
              mintBlockedAudited.remove(orderId);
              // §5.1 step 2 — block_index + #icpAtCmc in one sync block.
              ignore tryTransition(orderId, #icpAtCmc);
              Cmc.patch(mintJournal, orderId, { status = ?#icpAtCmc; blockIndex = ?block; cyclesMinted = null; bumpRetries = false }, Time.now());
              // fall through → #notifyCmc
            };
            case (#retriable(detail)) {
              Cmc.patch(mintJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
              audit("mint.transferRetriable", orderId # ": " # detail);
              return;
            };
            case (#escalate(detail)) {
              escalateStuckMint(order, "transferRejected", detail);
              return;
            };
          };
        };
        case (#notifyCmc(block)) {
          // Heal the (today unreachable) #minting-with-block combination.
          if (order.status == #minting) { ignore tryTransition(orderId, #icpAtCmc) };
          let result = try {
            await cmc.notify_top_up({ block_index = Nat64.fromNat(block); canister_id = selfPrincipal() });
          } catch (e) {
            Cmc.patch(mintJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
            audit("mint.notifyFailed", orderId # ": " # e.message());
            return;
          };
          switch (Cmc.interpretNotify(result)) {
            case (#minted(cycles)) {
              // Pre-forward marker: commits before the forward await. If we
              // die mid-forward, stageOf answers #ambiguousForward and the
              // operator checks the destination — at-most-once delivery,
              // never an auto-double-forward.
              Cmc.patch(mintJournal, orderId, { status = null; blockIndex = null; cyclesMinted = ?cycles; bumpRetries = false }, Time.now());
              // What the CMC actually minted can fall short of what was locked:
              // the e8s were sized from a CMC rate up to 15 min old, and after an
              // outage the recovery sweep may notify a transfer days later at a
              // materially worse rate. Forwarding lockedCycles regardless would
              // quietly cover the gap out of this canister's own gas — an
              // unbudgeted, invisible subsidy that grows with rate volatility,
              // and eventually a trap when gas cannot cover it.
              //
              // Deliver what was actually bought and escalate, rather than
              // silently over- or under-delivering. The operator decides whether
              // to top the buyer up; the position is fully recoverable and the
              // cycles are real.
              if (Cmc.isMaterialShortfall(cycles, order.lockedCycles)) {
                escalateStuckMint(
                  order,
                  "mintShortfall",
                  "CMC minted " # cycles.toText() # " cycles but the order locked "
                  # order.lockedCycles.toText()
                  # " — the conversion rate moved between quoting and notifying. The minted cycles are in this canister's balance; deliver them (or top up to the locked quantity from operator funds) and resolve.",
                );
                return;
              };
            };
            case (#retriable(detail)) {
              Cmc.patch(mintJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
              audit("mint.notifyRetriable", orderId # ": " # detail);
              return;
            };
            case (#escalate(detail)) {
              escalateStuckMint(order, "notifyRejected", detail);
              return;
            };
          };
          switch (await* forwardCycles(order)) {
            case (#ok) {
              ignore tryTransition(orderId, #delivered);
              Cmc.patch(mintJournal, orderId, { status = ?#delivered; blockIndex = null; cyclesMinted = null; bumpRetries = false }, Time.now());
              clearDelayed(orderId);
              audit("mint.delivered", orderId # ": " # order.lockedCycles.toText() # " cycles");
            };
            case (#failed(detail)) {
              // §4.1 Type 2: the failed deposit refunded the cycles to the
              // app balance — minted money exists, delivery didn't happen.
              ignore tryTransition(orderId, #errorQueue);
              Cmc.patch(mintJournal, orderId, { status = ?#errorQueue; blockIndex = null; cyclesMinted = null; bumpRetries = false }, Time.now());
              // Same reason as escalateStuckMint: the delay is over, badly.
              clearDelayed(orderId);
              ignore queueMintError(order.rail, #undeliverable({ orderId; cycles = order.lockedCycles }), detail);
              audit("mint.undeliverable", orderId # ": " # detail);
            };
          };
          return;
        };
      };
    };
  };

  /// Single-flight wrapper around the driver.
  func processMint(orderId : Types.OrderId) : async* () {
    if (mintsInFlight.contains(orderId)) return;
    mintsInFlight.add(orderId);
    try { await* driveMint(orderId) } finally { mintsInFlight.remove(orderId) };
  };

  /// Sweep every order with money-out work pending (Recovery.isSweepable:
  /// #paid/#minting/#icpAtCmc/#awaitingTreasury — the §5.3 hold retries
  /// until refill or max-wait) through the driver. Kicked after webhook
  /// ingestion; the §5.2 recovery timer sweeps it on a cadence.
  func sweepMintable() : async* Nat {
    // Answer "is there anything to do?" in O(1) before scanning.
    //
    // The scan below is O(total orders), and it ran every tick forever even with
    // nothing sweepable — a cost that grows with lifetime sales and never comes
    // back down. The maintained tallies cover exactly the sweepable statuses, so
    // an idle sweep is now free, which is what makes a shorter cadence
    // affordable.
    if (sweepableCount() == 0) return 0;
    let pending = List.empty<Types.OrderId>();
    for ((id, order) in orderStore.orders.entries()) {
      if (Recovery.isSweepable(order.status)) pending.add(id);
    };
    for (id in pending.values()) {
      await* processMint(id);
    };
    pending.size();
  };

  /// Orders with money-out work pending, from the maintained tallies. Must stay
  /// in step with `Recovery.isSweepable` — the unit tests pin that.
  func sweepableCount() : Nat {
    Orders.countOf(orderStore, #paid)
    + Orders.countOf(orderStore, #minting)
    + Orders.countOf(orderStore, #icpAtCmc)
    + Orders.countOf(orderStore, #awaitingTreasury);
  };

  public type ProcessOrderError = { #notFound; #inFlight };

  /// Manual mint kick (admin, §7) — ops lever for a stuck-looking order;
  /// safe to spam, every step is deduped/idempotent/single-flighted.
  public shared ({ caller }) func process_order(id : Types.OrderId) : async Result.Result<Types.Order, ProcessOrderError> {
    requireAdmin(caller);
    auditAdmin(caller, "mint.manualKick", id);
    if (Orders.get(orderStore, id) == null) return #err(#notFound);
    if (mintsInFlight.contains(id)) return #err(#inFlight);
    await* processMint(id);
    switch (Orders.get(orderStore, id)) {
      case (?order) #ok(order);
      case null #err(#notFound);
    };
  };

  /// Rebuild the per-status tallies from the order store (admin, §7).
  ///
  /// The tallies are maintained incrementally so the public status queries stay
  /// O(1); this is the O(n) reconciliation lever for the case where they are
  /// ever suspected of having drifted. Admin-only precisely because it is the
  /// expensive path. Returns the rebuilt counts.
  public shared ({ caller }) func recount_orders() : async [(Text, Nat)] {
    requireAdmin(caller);
    let rebuilt = Orders.recount(orderStore);
    let rendered = rebuilt.map(func((status, n)) = status # "=" # n.toText());
    auditAdmin(caller, "orders.recounted", rendered.values().join(", "));
    rebuilt;
  };

  /// Manual retention kick (admin, §7) — ops lever to apply a retuned TTL
  /// immediately instead of waiting up to a full sweep interval. Safe to spam:
  /// the band is an absolute age, so a second run is a no-op.
  ///
  /// Returns `scanned` alongside `expired` because the sweep is bounded per call
  /// (`maxRetentionScanPerSweep`) and resumes from a cursor: on a large store it
  /// takes several calls to cover everything, and `scanned` is how an operator
  /// tells "nothing left to expire" from "did not look at everything yet".
  public shared ({ caller }) func run_retention() : async { expired : Nat; scanned : Nat } {
    requireAdmin(caller);
    auditAdmin(caller, "retention.manualSweep", "operator-triggered");
    retentionSweep();
  };

  /// Retention counters for monitoring (public, same stance as
  /// `treasury_status`).
  ///
  /// `openOrders` climbing while `delivered` does not is the signature of
  /// order-creation abuse; the lever is `Gate.maxOpenOrdersPerPrincipal`.
  /// `totalOrders` and `paidIntentsIndexed` should grow together — a divergence
  /// means an index and its records disagree.
  public query func retention_status() : async {
    config : Retention.Config;
    openOrders : Nat;
    expiredOrders : Nat;
    totalOrders : Nat;
    paidIntentsIndexed : Nat;
  } {
    {
      config = retentionConfig;
      // O(1), same reasoning as treasury_status.
      openOrders = Orders.countOf(orderStore, #created);
      expiredOrders = Orders.countOf(orderStore, #expired);
      totalOrders = orderStore.orders.size();
      paidIntentsIndexed = paidIntents.size();
    };
  };

  /// Which order did this Stripe `payment_intent` pay for (admin, §4.2)? The
  /// reconciliation lookup: given a charge in the Stripe Dashboard, find the
  /// order it funded. Null means the payment was never attributed to an order
  /// here — check the error queue for a Type 1 entry carrying it.
  public shared query ({ caller }) func order_for_payment(paymentRef : Text) : async ?Types.OrderId {
    requireAdmin(caller);
    paidIntents.get(paymentRef);
  };

  public type AttachPaymentError = {
    #noOrder : Types.OrderId;
    #wrongRail;
    /// Past money-in already; attaching again would credit twice.
    #notClaimable : Text;
    /// This `payment_intent` was already credited — the dedup set is the same
    /// one the webhook path uses, so a charge can never be counted twice
    /// whichever route it arrives by.
    #alreadyCredited : Text;
    #belowFeeFloor : Nat;
    #aboveCeiling : { paidUsdCents : Nat; maxUsdCents : Nat };
    #unusableSnapshot;
    #transitionRefused : Text;
  };

  /// Credit a Stripe charge the canister never saw (admin, §6.1).
  ///
  /// The recovery path for the one card-rail failure that otherwise has none:
  /// **the webhook never arrived.** Stripe retries a failed delivery for about
  /// three days and then stops; we hold no API key, so we never poll. Past that
  /// horizon the charge exists in Stripe with no on-chain trace at all, the
  /// buyer's money is gone, and their order reads "Awaiting payment" forever.
  ///
  /// Also rescues an unattributed payment the operator *can* identify — turning
  /// "refund and ask them to re-order at today's price" into "deliver what they
  /// bought". Any open Type 1 entry for the charge is resolved, since attaching
  /// it discharges that obligation.
  ///
  /// The operator supplies the amount because Stripe is the authority on it, and
  /// it is honoured through exactly the same helper the webhook uses.
  ///
  /// This is a money-creating lever, so: controller-only, dedup-guarded against
  /// double credit, and audited with the calling principal.
  public shared ({ caller }) func attach_payment(
    paymentRef : Text,
    id : Types.OrderId,
    paidUsdCents : Nat,
  ) : async Result.Result<Types.Order, AttachPaymentError> {
    requireAdmin(caller);
    let ?order = Orders.get(orderStore, id) else return #err(#noOrder(id));
    if (order.rail != #card) return #err(#wrongRail);
    switch (order.status) {
      case (#created or #expired) {};
      case (status) return #err(#notClaimable(Types.statusToText(status)));
    };
    let honored = switch (Card.honoredCycles(order, paidUsdCents, gateConfig.maxPurchaseUsdCents)) {
      case (#asQuoted(cycles) or #repriced(cycles)) cycles;
      case (#belowFeeFloor) return #err(#belowFeeFloor(paidUsdCents));
      case (#aboveCeiling(bound)) return #err(#aboveCeiling(bound));
      case (#unusableSnapshot) return #err(#unusableSnapshot);
    };
    // Guard on `paidIntents`, NOT on the dedup set.
    //
    // The two answer different questions. The dedup set means "this webhook has
    // been processed" — and `handleCheckout` records the intent *before*
    // attribution, so an unattributed payment is already in it. Guarding on that
    // would make the primary rescue case unreachable: the operator could never
    // attach the very payments that need attaching.
    //
    // `paidIntents` is only written when an order is actually marked paid, so it
    // is the authority on "has this charge been credited", which is the thing
    // that must never happen twice.
    if (paidIntents.containsKey(paymentRef)) return #err(#alreadyCredited(paymentRef));
    switch (Orders.markPaid(orderStore, id, honored, paidUsdCents, Time.now())) {
      case (#err(e)) {
        auditAdmin(caller, "payment.attachFailed", id # ": transition refused for " # paymentRef);
        #err(#transitionRefused(debug_show (e)));
      };
      case (#ok(paid)) {
        paidIntents.add(paymentRef, id);
        // Claim the intent in the webhook's dedup set too. If the charge was
        // attached before its webhook ever landed, a late delivery is then
        // cleanly deduped rather than raising a spurious #duplicate obligation
        // against an order that is already paid.
        ignore Idempotency.recordStripeIntent(dedup, paymentRef, Time.now());
        // Attaching the charge discharges any Type 1 obligation it raised.
        for (entry in ErrorQueue.resolveByPaymentRef(errorQueue, paymentRef, Time.now()).values()) {
          audit("errorQueue.resolvedByAttach", "entry " # entry.id.toText() # " closed by attaching " # paymentRef);
        };
        auditAdmin(caller, "payment.attached", id # ": " # paymentRef # " at " # paidUsdCents.toText() # " cents = " # honored.toText() # " cycles");
        // Same detached money-out kick the webhook uses.
        ignore async { await* processMint(id) };
        #ok(paid);
      };
    };
  };

  /// Stop trying to deliver an order (admin, §7) — **the only path to a
  /// terminal non-delivered state.**
  ///
  /// Nothing in the system gives up on a purchase automatically: a delay raises
  /// `#deliveryDelayed` and keeps retrying, because its causes are all
  /// operator-fixable. This is the deliberate human decision that a purchase
  /// will not be completed, and it demands a reason so the trail records *why*
  /// alongside *who*.
  ///
  /// Only reachable from a pre-delivery money-bearing state. A `#created` order
  /// has taken no money and needs no decision; a `#delivered` one is done.
  /// Let a buyer give up on their own unpaid order (owner-scoped).
  ///
  /// `Gate.maxOpenOrdersPerPrincipal` counts `#created` orders, and its refusal
  /// tells the user to pay or abandon one — advice they could not follow without
  /// this: `abandon_order` is admin-only and only accepts *paid* orders. A buyer
  /// who opened the cap's worth of checkouts and completed none would be locked
  /// out until the TTL expired them.
  ///
  /// Marks the order `#expired`, which is the existing retention transition, not
  /// a new state. Two consequences, both wanted: the slot frees immediately, and
  /// a payment that arrives anyway is **still honoured** at the locked quantity,
  /// because `#expired` is payable (§4). So this can never strand a payment that
  /// was already in flight when the buyer clicked cancel.
  ///
  /// No error-queue entry: nothing is owed. The record and the audit line are the
  /// trail, and queueing an obligation for an order where no money moved is
  /// exactly the orphan state the queue must not accumulate.
  public shared ({ caller }) func cancel_order(id : Types.OrderId) : async Result.Result<Types.Order, Text> {
    let ?order = Orders.getOwned(orderStore, id, caller) else return #err("no order " # id);
    switch (order.status) {
      case (#created) {};
      case (#expired) return #ok(order); // idempotent: already given up on
      case (status) {
        return #err(
          "order " # id # " is " # Types.statusToText(status)
          # "; a paid order cannot be cancelled — it will deliver, or contact support"
        );
      };
    };
    let ?cancelled = tryTransition(id, #expired) else {
      return #err("order " # id # " refused the transition to expired");
    };
    audit("order.cancelled", id # " cancelled by owner");
    #ok(cancelled);
  };

  public shared ({ caller }) func abandon_order(
    id : Types.OrderId,
    reason : Text,
  ) : async Result.Result<Types.Order, Text> {
    requireAdmin(caller);
    let ?order = Orders.get(orderStore, id) else return #err("no order " # id);
    switch (order.status) {
      case (#paid or #awaitingTreasury) {};
      case (status) {
        return #err("order " # id # " is " # Types.statusToText(status) # "; only a paid or held order can be abandoned");
      };
    };
    if (reason.size() == 0) return #err("a reason is required — the audit trail must record why");
    let ?abandoned = tryTransition(id, #errorQueue) else {
      return #err("order " # id # " refused the transition to errorQueue");
    };
    Cmc.patch(mintJournal, id, { status = ?#errorQueue; blockIndex = null; cyclesMinted = null; bumpRetries = false }, Time.now());
    clearDelayed(id);
    ignore queueMintError(order.rail, #abandoned({ orderId = id; reason }), "abandoned by operator: " # reason);
    auditAdmin(caller, "order.abandoned", id # ": " # reason);
    #ok(abandoned);
  };

  public type Receipt = {
    order : Types.Order;
    /// What the buyer actually paid, if they have.
    paidUsdCents : ?Nat;
    /// The ICP ledger block that funded the mint — the on-chain proof that the
    /// cycles were bought, checkable by anyone against the ledger.
    mintBlockIndex : ?Nat;
    /// Cycles the CMC reported minting.
    cyclesMinted : ?Nat;
    /// Recompute the quote from these and it must equal `order.lockedCycles`:
    ///   netCents × xdrPermyriadPerIcp × 10¹² / usdPerIcpMicros
    /// where netCents = usdCents − (⌈usdCents·feeBps/10⁴⌉ + feeFixedCents).
    /// Both rate inputs are queryable from the XRC and the CMC, so the price is
    /// reproducible from first principles rather than merely asserted by us.
    verification : {
      netCents : ?Nat;
      usdPerIcpMicros : Nat;
      xdrPermyriadPerIcp : Nat;
      rateReceivedRates : Nat;
      rateQueriedSources : Nat;
    };
  };

  /// Everything the **buyer** needs to verify their own purchase (§2 authz:
  /// `caller == order.owner`).
  ///
  /// The order already carried enough to reproduce the price; nothing surfaced
  /// it, and the delivery proof was admin-only. A buyer could see *that* we
  /// claimed to deliver, never check it. Now they can: recompute the quote from
  /// the two recorded rate inputs, and look up the block index on the ICP ledger.
  ///
  /// `mint_journal` stays admin-only — it carries retries and raw transfer
  /// intents, which are operational rather than the buyer's business.
  public shared query ({ caller }) func receipt(id : Types.OrderId) : async ?Receipt {
    let ?order = Orders.getOwned(orderStore, id, caller) else return null;
    let journal = mintJournal.get(id);
    ?{
      order;
      paidUsdCents = order.paidUsdCents;
      mintBlockIndex = switch (journal) { case (?entry) entry.blockIndex; case null null };
      cyclesMinted = switch (journal) { case (?entry) entry.cyclesMinted; case null null };
      verification = {
        netCents = Pricing.netCents(order.pricing, switch (order.paidUsdCents) {
          case (?paid) paid;
          case null order.pricing.usdCents;
        });
        usdPerIcpMicros = order.pricing.usdPerIcpMicros;
        xdrPermyriadPerIcp = order.pricing.xdrPermyriadPerIcp;
        rateReceivedRates = order.pricing.rateReceivedRates;
        rateQueriedSources = order.pricing.rateQueriedSources;
      };
    };
  };

  /// Money-out journal for one order (admin, §4.2) — intent, block_index,
  /// minted cycles, retries.
  public shared query ({ caller }) func mint_journal(id : Types.OrderId) : async ?Types.JournalEntry {
    requireAdmin(caller);
    mintJournal.get(id);
  };

  // ── Recovery timer (task 11, §5.2) ──────────────────────────────────────

  /// §5.2 sweep cadence. Persistent — an operator-tuned cadence survives
  /// upgrades; the transient timer below re-arms at this value. Bounded by
  /// Recovery.validateInterval (≪ the §5.1 ledger dedup window).
  var recoverySweepIntervalNs : Nat = Recovery.defaultIntervalNs;

  /// §5.2 single-flight guard: a sweep slower than the interval must skip
  /// the next firing, never pile up. Transient on purpose — a persistent
  /// flag left true by an upgrade mid-sweep would deadlock recovery
  /// forever (the `pumping`-style deadlock §5.2 warns about); an upgrade
  /// resets it and the timer below re-arms.
  transient var recoverySweepInFlight = false;

  /// Last *completed* timer sweep — recovery liveness for ops (the §5.2
  /// timer is the backstop for every detached webhook kick that dies, so
  /// "is it actually firing" must be observable).
  var lastRecoverySweep : ?{ atNs : Int; pending : Nat } = null;

  /// Retention pass (Retention.mo): flip lapsed `#created` orders to `#expired`.
  /// That is the whole job — no order is ever deleted, so there is nothing here
  /// that has to be guarded against destroying a financial record.
  ///
  /// Synchronous and awaitless, so it cannot interleave with the money path.
  /// Retention pass: flip lapsed `#created` orders to `#expired` (§4).
  ///
  /// Synchronous and awaitless, so it cannot interleave with the money path.
  /// Nothing is ever deleted — see Retention.mo for why an earlier
  /// delete-past-a-horizon design was dropped.
  /// Cap on orders inspected per sweep.
  ///
  /// Only `#created` orders can expire, but the store is not indexed by status,
  /// so finding them means a scan. Left unbounded, every tick would cost O(all
  /// orders forever) — which grows without limit, since orders are never deleted,
  /// and makes each tick more expensive exactly when the canister is under the
  /// order-creation pressure that made the store large.
  ///
  /// Bounding the work is safe because **expiry is advisory** (§4): an order that
  /// expires a few ticks late is still payable and nothing downstream reads the
  /// flip. Correctness does not depend on promptness here, so throughput is the
  /// right thing to trade away.
  transient let maxRetentionScanPerSweep : Nat = 2_000;

  /// The last order id this sweep handled, so the next tick resumes after it.
  ///
  /// An **id**, not an index: an index into a snapshot is meaningless across
  /// ticks, because an insert shifts every later position and a positional cursor
  /// then silently skips some orders and re-scans others. Order ids are stable,
  /// so resuming from one visits every order exactly once per pass.
  var retentionCursor : ?Types.OrderId = null;

  /// How often the sweep reconciles the per-status tallies against the order
  /// store. Daily, not per-sweep: the reconcile is O(orders) while the tallies
  /// exist precisely so the hot queries are O(1), and drift can only come from a
  /// bookkeeping bug, which does not need a 15-minute detection window.
  let countReconcileIntervalNs : Nat = 24 * 3_600 * 1_000_000_000;

  /// When the tallies were last **successfully** rebuilt, and what had to move.
  /// Surfaced on `recovery_status` so "the counts are trustworthy" is an
  /// observable fact rather than an assumption. Written only on success, so it
  /// falling behind while `lastSweep` advances is the signal that the reconcile
  /// itself is failing (RUNBOOK §9).
  var lastCountReconcile : ?{ atNs : Int; drift : [Orders.Drift] } = null;

  /// When a reconcile was last *attempted*, which is what gates the cadence.
  ///
  /// Separate from the success timestamp on purpose. A trap rolls back every
  /// state change in its own message, so a reconcile that traps cannot record
  /// that it ran — gating on success alone would leave it due on the next tick
  /// and every tick after, trapping forever. This is written by the **sweep's**
  /// message, which commits regardless of what the detached reconcile does.
  var lastCountReconcileAttemptNs : Int = 0;

  /// Rebuild the tallies. Audits **only on drift**: a clean reconcile every day
  /// would bury the one line that matters, and drift is a bug in the incremental
  /// bookkeeping that an operator must see.
  ///
  /// Runs in its own message (see the call site) and takes no `await`, so it
  /// still sees a consistent snapshot of the order store — chunking it across
  /// messages would admit mutations mid-scan and manufacture false drift, which
  /// is why this is not paged the way retention is.
  func reconcileCounts() {
    let { drift; counts = _ } = Orders.reconcile(orderStore);
    // Stamped from inside, not handed the sweep's clock: this message runs after
    // the one that scheduled it, and the two timestamps are compared against each
    // other (attempt vs success) to tell a failing reconcile from a due one.
    lastCountReconcile := ?{ atNs = Time.now(); drift };
    if (drift.size() > 0) {
      let rendered = drift.map(
        func(d : Orders.Drift) : Text = d.status # " " # d.was.toText() # "→" # d.is.toText()
      );
      audit("orders.countDrift", rendered.values().join(", "));
    };
  };

  func retentionSweep() : { expired : Nat; scanned : Nat } {
    // O(1) short-circuit, mirroring the mint sweep: no `#created` order means
    // nothing can expire, so the scan is pure waste.
    if (Orders.countOf(orderStore, #created) == 0) {
      retentionCursor := null;
      return { expired = 0; scanned = 0 };
    };
    let now = Time.now();
    var expired = 0;
    // Bounded slice, so the per-tick cost is O(maxRetentionScanPerSweep) and not
    // O(total orders) — the store only ever grows, so anything proportional to it
    // gets more expensive every tick forever.
    let ids = Orders.idsFrom(orderStore, retentionCursor, maxRetentionScanPerSweep);
    if (ids.size() == 0) {
      // Reached the end; the next tick starts a fresh pass.
      retentionCursor := null;
      return { expired = 0; scanned = 0 };
    };
    for (id in ids.values()) {
      let ?order = Orders.get(orderStore, id) else continue;
      switch (Retention.bandOf(order.status, order.createdAtNs, now, retentionConfig)) {
        case (#keep) {};
        case (#expire) {
          if (tryTransition(id, #expired) != null) expired += 1;
        };
      };
    };
    retentionCursor := ?ids[ids.size() - 1];
    if (expired > 0) {
      audit("retention.sweep", expired.toText() # " order(s) marked expired (still payable, §4)");
    };
    { expired; scanned = ids.size() };
  };

  /// The timer job. Correctness against concurrent drivers is processMint's
  /// per-order single-flight; this flag only stops sweep pile-up. The
  /// webhook kick deliberately bypasses it — a just-paid order must not
  /// wait a full interval because a background sweep (which enumerated
  /// `pending` before that order turned #paid) was still in flight.
  ///
  /// Retention runs FIRST and synchronously: it must not race the money sweep's
  /// awaits, and expiring an order is a no-op for money-out (`#expired` is not
  /// sweepable, and a late payment on it is still honoured per §4).
  func recoverySweep() : async () {
    if (recoverySweepInFlight) return;
    recoverySweepInFlight := true;
    try {
      ignore retentionSweep();
      // Detached into its own message rather than run inline. It reads the whole
      // order store, so at enough orders it could hit the instruction limit — and
      // inline that trap would take the entire sweep down with it, leaving
      // retention and money-out dead while the reconcile stayed due and trapped
      // again on every tick. A bookkeeping *check* must not be able to stop
      // orders from minting.
      //
      // Claiming the cadence here, in the sweep's own message, is what bounds the
      // damage: this write commits whatever the detached message does, so a
      // trapping reconcile retries daily rather than every tick. Its cost is a
      // visibly stale `lastCountReconcile` (RUNBOOK §9), which is the right
      // signal — the tallies are unverified, not known-wrong.
      let now = Time.now();
      if (Recovery.reconcileDue(lastCountReconcileAttemptNs, now, countReconcileIntervalNs)) {
        lastCountReconcileAttemptNs := now;
        ignore async { reconcileCounts() };
      };
      let pending = await* sweepMintable();
      lastRecoverySweep := ?{ atNs = Time.now(); pending };
    } finally {
      recoverySweepInFlight := false;
    };
  };

  /// Tune the sweep cadence (admin, §7) — re-arms immediately, no redeploy.
  /// Validated against the §5.1 bound: the cadence must stay well inside
  /// the ledger dedup window or replay loses its safety margin.
  public shared ({ caller }) func set_recovery_interval(intervalNs : Nat) : async Result.Result<(), Recovery.IntervalError> {
    requireAdmin(caller);
    switch (Recovery.validateInterval(intervalNs, Cmc.ledgerDedupWindowNs)) {
      case (#err(e)) #err(e);
      case (#ok) {
        recoverySweepIntervalNs := intervalNs;
        Timer.cancelTimer(recoveryTimerId);
        recoveryTimerId := Timer.recurringTimer<system>(#nanoseconds(intervalNs), recoverySweep);
        auditAdmin(caller, "recovery.intervalSet", "sweep cadence set to " # intervalNs.toText() # " ns");
        #ok;
      };
    };
  };

  /// §5.2 liveness observability, public (operational transparency, same
  /// stance as treasury_status): cadence + last completed timer sweep. A
  /// null or stale `lastSweep` means recovery is not running.
  /// This canister's OWN cycle balance and the floor the admission gate holds
  /// it against (public — the same operational-transparency stance as
  /// `treasury_status`; it is visible via `canister_status` regardless).
  ///
  /// Distinct from the ICP float in every way: this is gas. Below the freezing
  /// threshold the canister stops accepting updates; at zero it is uninstalled
  /// and the order store, journals, and dedup sets go with it. Monitor it
  /// separately, and alert well above `minCanisterCycles` — that gate stops
  /// *sales*, it does not stop the burn. A sudden acceleration here is the
  /// signature of a cycle-drain attempt.
  public query func cycles_status() : async { balance : Nat; floor : Nat } {
    { balance = Cycles.balance(); floor = gateConfig.minCanisterCycles };
  };

  public query func recovery_status() : async {
    intervalNs : Nat;
    lastSweep : ?{ atNs : Int; pending : Nat };
    sweepInFlight : Bool;
    /// Last **successful** tally reconciliation. A non-empty `drift` means the
    /// incremental counts had diverged from the orders and were repaired — the
    /// tallies are correct again, but the bug that moved them is not fixed.
    /// `recount_orders` is the on-demand form of the same repair.
    lastCountReconcile : ?{ atNs : Int; drift : [Orders.Drift] };
    /// When one was last *attempted*. Reported alongside the success timestamp so
    /// "due tomorrow" and "attempted today and failed" are distinguishable without
    /// correlating against the sweep clock: an attempt materially newer than the
    /// success means the reconcile is trapping (RUNBOOK §9).
    lastCountReconcileAttemptNs : Int;
  } {
    {
      intervalNs = recoverySweepIntervalNs;
      lastSweep = lastRecoverySweep;
      sweepInFlight = recoverySweepInFlight;
      lastCountReconcile;
      lastCountReconcileAttemptNs;
    };
  };

  // ── HTTP ingress ────────────────────────────────────────────────────────

  /// Set by the webhook route handler when a delivery marks an order `#paid`,
  /// read by `http_request_update` immediately afterwards to decide whether to
  /// kick money-out. Transient: it only carries a value within one message
  /// execution, and the §5.2 recovery timer is the backstop if an upgrade lands
  /// between the write and the read.
  transient var webhookPaidOrder : ?Types.OrderId = null;

  /// §6.0 body-size guard. Stripe events are a few KiB; 64 KiB is generous
  /// headroom and far below the 2 MiB ingress cap. Transient so a redeploy
  /// can retune it — a persistent let would freeze the first-deploy value.
  transient let maxRequestBodyBytes : Nat = 65_536;

  /// HTTP route table (binding seam §11.1.2) — exactly one anonymous,
  /// payload-authed route (§6.0). The whole §6.1 path lives in Card.mo;
  /// an unprovisioned secret answers 503 inside handleWebhook, which makes
  /// Stripe keep retrying instead of treating the delivery as accepted.
  transient let routes : [Http.Route] = [
    {
      method = "POST";
      path = "/webhook/stripe";
      upgrade = true;
      handler = func req {
        let outcome = Card.handleWebhook(
          webhookDeps(),
          Secret.get(webhookSecret),
          req,
          Time.now(),
          Card.defaultToleranceSeconds,
        );
        // Handed to http_request_update, which runs in the same atomic block
        // (the dispatch is synchronous and nothing awaits in between), so this
        // cannot be read by a different message than the one that set it.
        webhookPaidOrder := outcome.paidOrder;
        outcome.response;
      };
    },
  ];

  /// §6.0 query half: the boundary node calls this first; a matched
  /// upgrade route answers `upgrade = ?true` and the gateway re-issues the
  /// request to `http_request_update` through consensus.
  public query func http_request(req : Http.Request) : async Http.Response {
    Http.handleQuery(routes, req, maxRequestBodyBytes);
  };

  /// §6.0 update half. Anyone can call this directly via Candid, so the
  /// dispatcher re-applies every guard; the route handlers themselves are
  /// payload-authenticated (HMAC), never caller-authenticated.
  public func http_request_update(req : Http.Request) : async Http.Response {
    let response = Http.handleUpdate(routes, req, maxRequestBodyBytes);
    // Kick money-out (§5) as a detached self-message ONLY when this delivery
    // actually marked an order #paid, and drive just that order rather than
    // sweeping every one. `webhookPaidOrder` is set inside the dispatch above
    // and consumed here.
    //
    // This route is unauthenticated by necessity (Stripe cannot sign in), so
    // anything it triggers is free for anyone on the internet to invoke. A
    // sweep over all orders — which makes paid inter-canister calls per
    // sweepable order — must therefore never be reachable from a 404, a bad
    // signature, or an unprovisioned-secret 503. The §5.2 recovery timer
    // remains the backstop if this detached message dies.
    switch (webhookPaidOrder) {
      case (?orderId) {
        webhookPaidOrder := null;
        ignore async { await* processMint(orderId) };
      };
      case null {};
    };
    response;
  };

  /// Liveness probe; also used by the scaffold smoke test path.
  public query func health() : async Bool {
    true;
  };

  /// §5.2 the timer itself. Transient initializer = runs on install AND on
  /// every upgrade (postupgrade re-initialization), so a deploy can never
  /// leave recovery dead; the IC drops timers across upgrades, so there is
  /// no stale duplicate to cancel.
  ///
  /// Declared last in the actor body: the initializer evaluates during actor
  /// init and `recoverySweep` reaches the order store and the mint journal,
  /// both of which must already be initialized (M0016 otherwise).
  transient var recoveryTimerId : Timer.TimerId =
    Timer.recurringTimer<system>(#nanoseconds(recoverySweepIntervalNs), recoverySweep);

  /// §3 rate refresh. Same transient-initializer pattern as the recovery timer:
  /// it runs on install AND on every upgrade, which is what the IC requires
  /// (global timers are deactivated when the Wasm module changes) without an
  /// explicit `postupgrade` hook — which enhanced orthogonal persistence
  /// forbids anyway. Do not "improve" this by adding one.
  ///
  /// A dead rate timer is an availability failure, not an exploitable one: the
  /// cache goes stale and orders are refused. `Pricing.Config.maxAgeNs` is the
  /// control that guarantees that, which is why it is bounded.
  transient var rateTimerId : Timer.TimerId =
    Timer.recurringTimer<system>(#nanoseconds(rateIntervalNs()), rateTimerJob);

  /// Refresh immediately rather than after a full interval. The rate cache is
  /// persistent so an upgrade does not blank the price, but a stop→upgrade→start
  /// can outlast a 5-minute window; this closes that gap on install and upgrade
  /// alike.
  transient let _rateWarmup : Timer.TimerId =
    Timer.setTimer<system>(#nanoseconds(0), rateTimerJob);
};
