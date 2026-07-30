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
import CkUsdc "rails/CkUsdc";
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

  /// Order-lifecycle retention policy (Retention.mo) — the `#created` TTL and
  /// the delete-and-tombstone horizon.
  var retentionConfig : Retention.Config = Retention.defaultConfig();

  /// Retention band-3 tombstones: ids of orders deliberately deleted as
  /// abandoned. Permanent and tiny (an id, not a record) — a Payment Link is
  /// always live, so a payment can arrive for a swept order forever, and this
  /// is what turns "no such order" into "we swept this on purpose".
  let sweptOrders = Set.empty<Types.OrderId>();

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

  transient let xrc = actor (Xrc.canisterId) : Xrc.Service;

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
    cardTiers.size() > 0 or ckUsdcConfig.maxUsdCents > 0;
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
        await (with cycles = Xrc.callCycles) xrc.get_exchange_rate(Xrc.icpUsdRequest());
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
      let previous = switch (Pricing.lastRates(rateCache)) {
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
  } {
    {
      rates = Pricing.lastRates(rateCache);
      config = pricingConfig;
      lastAttempt = lastRateAttempt;
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
  /// = the Stripe formula in `pricingConfig`, ck-USDC = its rail config) over
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
  public shared ({ caller }) func create_order(
    tierId : Text,
    destination : Types.Destination,
  ) : async Result.Result<CreatedOrder, CreateOrderError> {
    switch (Auth.checkUser(caller)) {
      case (#err(#anonymous)) return #err(#anonymous);
      case (#ok) {};
    };
    let ?tier = Tiers.find(cardTiers, tierId) else return #err(#unknownTier(tierId));
    // Admission BEFORE the quote: the quote can fire an HTTPS outcall, so a
    // spamming principal must be turned away before it can make us spend
    // cycles (`canister-security`: anyone can burn your cycles with update
    // calls).
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
  public shared ({ caller }) func set_gate_config(config : Gate.Config) : async Result.Result<(), Gate.ConfigError> {
    requireAdmin(caller);
    switch (Gate.validateConfig(config)) {
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
        auditAdmin(caller, "retention.configSet", "ttlNs=" # config.orderTtlNs.toText()
          # " horizonNs=" # config.retentionHorizonNs.toText());
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

  // ── Webhook ingestion state (task 8, §4.1/§4.2) ─────────────────────────

  /// §4.2 per-rail dedup sets. Stripe keys prune opportunistically on the
  /// webhook path (~7 days, Idempotency.mo); ck-USDC block indexes never.
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
      auditLog;
      auditLogCapacity;
      sweptOrders;
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

  /// §4.1 operator worklist + retained history. Admin: entries carry
  /// payment references and claimed-but-bogus URL params.
  public shared query ({ caller }) func error_queue() : async [ErrorQueue.Entry] {
    requireAdmin(caller);
    ErrorQueue.all(errorQueue);
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

  /// Bounds the retriable-error loop on stages the ledger's 24 h dedup
  /// window doesn't already bound (notify_top_up could otherwise retry
  /// forever). Sweep cadence (task 11) makes 25 retries ≫ a day of outage.
  transient let maxMintRetries : Nat = 25;

  /// Orders already audited for a blocked `#begin` this session, so a stuck
  /// order contributes one audit line rather than one per sweep. Transient: the
  /// durable record of a stuck order is its error-queue entry once the max-wait
  /// bound trips, not this.
  transient let mintBlockedAudited = Set.empty<Types.OrderId>();

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
  func queueMintError(rail : Types.Rail, kind : ErrorQueue.Kind, detail : Text) {
    let result = ErrorQueue.add(errorQueue, errorQueueCapacity, rail, kind, detail, Time.now());
    for (victim in result.evicted.values()) {
      if (victim.resolvedAtNs == null) {
        audit("errorQueue.evictedUnresolved", "entry " # victim.id.toText() # ": " # victim.detail);
      };
    };
  };

  /// §5.1 escalation: the mint stopped where the money position is
  /// uncertain. Terminal — the order goes `#errorQueue` and the operator
  /// resolves off-chain (inspect ledger/CMC/destination, refund/re-deliver).
  func escalateStuckMint(order : Types.Order, stage : Text, detail : Text) {
    ignore tryTransition(order.id, #errorQueue);
    Cmc.patch(mintJournal, order.id, { status = ?#errorQueue; blockIndex = null; cyclesMinted = null; bumpRetries = false }, Time.now());
    queueMintError(order.rail, #stuckMint({ orderId = order.id; stage }), detail);
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
      if (order.status == #paid) {
        switch (Treasury.holdStage(order.updatedAtNs, Time.now(), treasuryConfig.maxHoldNs)) {
          case (#escalate) {
            escalateStuckMint(order, "mintWaitExceeded", "paid but unable to mint past max wait: fiat received, nothing minted — refund via Stripe Dashboard");
            return;
          };
          case (#retry) {};
        };
      };
      let stage : Cmc.Stage = switch (order.status) {
        case (#awaitingTreasury) {
          switch (Treasury.holdStage(order.updatedAtNs, Time.now(), treasuryConfig.maxHoldNs)) {
            case (#escalate) {
              // Money position is *certain* here (fiat in, nothing minted)
              // but the resolution is the same operator worklist: refund in
              // the Stripe Dashboard (§5.3 max-wait → error queue).
              escalateStuckMint(order, "treasuryWaitExceeded", "held past max wait: fiat received, nothing minted — refund via Stripe Dashboard");
              return;
            };
            case (#retry) #begin;
          };
        };
        case (_) Cmc.stageOf(order.status, mintJournal.get(orderId), Time.now(), Cmc.ledgerDedupWindowNs, maxMintRetries);
      };
      switch (stage) {
        case (#none) return;
        case (#escalate(reason)) {
          let stage = Cmc.escalateReasonToText(reason);
          escalateStuckMint(order, stage, "mint pipeline stopped: " # stage);
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
            // Previously returned silently, leaving no trace at all.
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
              audit("mint.delivered", orderId # ": " # order.lockedCycles.toText() # " cycles");
            };
            case (#failed(detail)) {
              // §4.1 Type 2: the failed deposit refunded the cycles to the
              // app balance — minted money exists, delivery didn't happen.
              ignore tryTransition(orderId, #errorQueue);
              Cmc.patch(mintJournal, orderId, { status = ?#errorQueue; blockIndex = null; cyclesMinted = null; bumpRetries = false }, Time.now());
              queueMintError(order.rail, #undeliverable({ orderId; cycles = order.lockedCycles }), detail);
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
    let pending = List.empty<Types.OrderId>();
    for ((id, order) in orderStore.orders.entries()) {
      if (Recovery.isSweepable(order.status)) pending.add(id);
    };
    for (id in pending.values()) {
      await* processMint(id);
    };
    pending.size();
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

  /// Manual retention kick (admin, §7) — ops lever to apply the current TTL and
  /// horizon immediately after retuning them, instead of waiting up to a full
  /// sweep interval. Returns what it did. Safe to spam: the bands are computed
  /// from absolute ages, so a second run is a no-op.
  public shared ({ caller }) func run_retention() : async { expired : Nat; swept : Nat } {
    requireAdmin(caller);
    auditAdmin(caller, "retention.manualSweep", "operator-triggered");
    retentionSweep();
  };

  /// Was this order deliberately deleted as abandoned? Public and unauthorized
  /// on purpose: it answers only "did we sweep this id", which a user needs to
  /// understand why their order vanished from history, and which leaks nothing
  /// (ids are random and carry no balance or ownership).
  public query func was_swept(id : Types.OrderId) : async Bool {
    sweptOrders.contains(id);
  };

  /// Retention counters for monitoring (public, same stance as
  /// `treasury_status`): how many orders are in each band right now, and how
  /// many ids have been tombstoned. `openOrders` growing without `delivered`
  /// growing is the signature of order-creation abuse.
  public query func retention_status() : async {
    config : Retention.Config;
    openOrders : Nat;
    expiredOrders : Nat;
    totalOrders : Nat;
    tombstones : Nat;
    paidIntentsIndexed : Nat;
  } {
    {
      config = retentionConfig;
      // O(1), same reasoning as treasury_status.
      openOrders = Orders.countOf(orderStore, #created);
      expiredOrders = Orders.countOf(orderStore, #expired);
      totalOrders = orderStore.orders.size();
      tombstones = sweptOrders.size();
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

  /// Retention pass (Retention.mo): flip lapsed `#created` orders to
  /// `#expired`, and delete-and-tombstone `#expired` orders past the horizon.
  /// Synchronous and awaitless, so it cannot interleave with the money path.
  ///
  /// The band-3 delete is guarded by more than status and age: an order with a
  /// mint journal entry or a ck-USDC pull entry has touched money, so it is
  /// never deleted no matter how old — `Retention.bandOf` only sees status and
  /// age, and this is the other half of that contract.
  func retentionSweep() : { expired : Nat; swept : Nat } {
    let now = Time.now();
    var expired = 0;
    var swept = 0;
    // Materialise ids first — the loop mutates the store.
    for (id in Orders.allIds(orderStore).values()) {
      let ?order = Orders.get(orderStore, id) else continue;
      switch (Retention.bandOf(order.status, order.createdAtNs, now, retentionConfig)) {
        case (#keep) {};
        case (#expire) {
          if (tryTransition(id, #expired) != null) expired += 1;
        };
        case (#sweep) {
          // Money-touched orders are financial records — never swept.
          if (mintJournal.get(id) != null or ckUsdcPulls.get(id) != null) continue;
          ignore Orders.remove(orderStore, id);
          sweptOrders.add(id);
          swept += 1;
        };
      };
    };
    if (expired > 0 or swept > 0) {
      audit("retention.sweep", expired.toText() # " expired, " # swept.toText() # " swept and tombstoned");
    };
    { expired; swept };
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
  } {
    {
      intervalNs = recoverySweepIntervalNs;
      lastSweep = lastRecoverySweep;
      sweepInFlight = recoverySweepInFlight;
    };
  };

  // ── ck-USDC rail (task 14, §6.2) ────────────────────────────────────────

  /// §6.2 rail config. Fails closed: maxUsdCents defaults to 0, so the rail
  /// is disabled until the operator consciously sizes its bounds (the
  /// empty-tier-list stance).
  var ckUsdcConfig : CkUsdc.Config = CkUsdc.defaultConfig();

  /// Money-IN journal for this rail: the §5.1-style pull intent persisted
  /// *before* the transfer_from await, plus the recovered block. Financial
  /// record — never pruned (it proves which ledger block paid which order).
  let ckUsdcPulls : CkUsdc.PullJournal = CkUsdc.emptyPullJournal();

  /// Per-order single-flight for the claim path: two concurrent claims for
  /// one order would both pass the status gate before the ledger await.
  /// Transient — an upgrade mid-pull clears it and the persisted intent
  /// drives the replay (CkUsdc.claimStage) instead.
  transient let pullsInFlight = Set.empty<Types.OrderId>();

  transient let ckUsdcLedger = actor (CkUsdc.ledgerId) : CkUsdc.LedgerService;

  public type CreateCkUsdcOrderError = {
    #anonymous;
    /// Operator has not enabled the rail (maxUsdCents = 0).
    #railDisabled;
    #zeroAmount;
    /// Carry the bound so the frontend can render what would be accepted.
    #belowMinimum : Nat;
    #aboveMaximum : Nat;
    /// §3 fee formula swallows the amount — config problem, not retryable.
    #amountBelowFees;
    /// §3.1 fail-closed: no fresh rate and the refresh failed.
    #rateUnavailable;
    #idGeneration;
    /// Gate.mo admission refusal — the same pre-creation gate the card rail
    /// uses. Both rails converge on one ICP float and one burn cap, so both
    /// must be refused when fulfilment is impossible; gating only one would
    /// leave the other as a way around the own-cycles floor.
    #notAdmitted : Gate.Reason;
  };

  public type CreatedCkUsdcOrder = {
    order : Types.Order;
    /// Ledger units the claim will pull (the exact quoted price).
    amountUnits : Nat;
    /// The user's `icrc2_approve` must cover at least this: amount + the
    /// ledger transfer fee (charged to the `from` account on the pull).
    approveUnits : Nat;
  };

  /// Create a ck-USDC order (§6.2): user-chosen amount within operator
  /// bounds — nothing structural pins the amount the way a card Payment Link
  /// does, and the canister pulls the exact price itself. Same §3 quote path
  /// as the card rail (locked cycle quantity, fail-closed on a stale rate),
  /// priced with this rail's own fee formula. The flow after this:
  /// `icrc2_approve` (user → ledger, ≥ approveUnits) then `claim_ck_usdc_order`.
  public shared ({ caller }) func create_ck_usdc_order(
    usdCents : Nat,
    destination : Types.Destination,
  ) : async Result.Result<CreatedCkUsdcOrder, CreateCkUsdcOrderError> {
    switch (Auth.checkUser(caller)) {
      case (#err(#anonymous)) return #err(#anonymous);
      case (#ok) {};
    };
    // One config snapshot: bounds, fee formula, and ledger fee from one epoch.
    let config = ckUsdcConfig;
    switch (CkUsdc.validateAmount(config, usdCents)) {
      case (#err(#railDisabled)) return #err(#railDisabled);
      case (#err(#zeroAmount)) return #err(#zeroAmount);
      case (#err(#belowMinimum(min))) return #err(#belowMinimum(min));
      case (#err(#aboveMaximum(max))) return #err(#aboveMaximum(max));
      case (#ok) {};
    };
    // Same pre-quote admission gate as the card rail (see create_order).
    switch (admit(caller, usdCents)) {
      case (#err(reason)) return #err(#notAdmitted(reason));
      case (#ok) {};
    };
    let fee = { feeBps = config.feeBps; feeFixedCents = config.feeFixedCents };
    let (lockedCycles, pricing) = switch (quoteCents(fee, usdCents)) {
      case (#ok(quoted)) quoted;
      case (#unpriceable) return #err(#amountBelowFees);
      case (#stale) return #err(#rateUnavailable);
    };
    switch (await* createOrderWithFreshId(#ii(caller), #ckUsdc, destination, lockedCycles, pricing)) {
      case (?order) {
        let amountUnits = CkUsdc.unitsForCents(usdCents);
        #ok({ order; amountUnits; approveUnits = amountUnits + config.ledgerFeeUnits });
      };
      case null #err(#idGeneration);
    };
  };

  public type ClaimCkUsdcError = {
    #anonymous;
    /// Not found or not owned — existence is not revealed to non-owners.
    #notFound;
    #wrongRail;
    /// Order status is past money-in (carries the status text).
    #notClaimable : Text;
    /// A claim for this order is already in flight.
    #inFlight;
    /// §6.2 amount-short mismatch: approve at least `required`, then retry.
    #insufficientAllowance : { allowance : Nat; required : Nat };
    #insufficientFunds : { balance : Nat; required : Nat };
    /// ledgerFeeUnits config drifted from the ledger's fee — operator fixes.
    #badFee : { expectedFee : Nat };
    #ledgerRejected : Text;
    /// Transient ledger trouble — safe to retry (the intent replays).
    #retryable : Text;
    /// The pull's fate is unknowable (intent aged past the dedup window) —
    /// escalated to the operator; do not approve again until resolved.
    #staleIntent;
  };

  /// Mark the order paid off a recovered ledger block: dedup + journal +
  /// transition in one sync block. `#Duplicate`-recovered blocks from our own
  /// replayed intent skip the dedup insert (it was recorded with the block).
  func creditPull(orderId : Types.OrderId, block : Nat) : Result.Result<Types.Order, ClaimCkUsdcError> {
    let ownBlock = switch (ckUsdcPulls.get(orderId)) {
      case (?entry) entry.blockIndex == ?block;
      case null false;
    };
    if (not ownBlock) {
      if (not Idempotency.recordCkUsdcBlock(dedup, block)) {
        // Structurally unreachable: every pull is its own ledger transaction.
        // §4.1 invariant anyway — dedup gates the mint, so refuse to credit.
        audit("ckusdc.blockAlreadyCredited", orderId # ": block " # block.toText());
        return #err(#retryable("ledger block already credited"));
      };
      CkUsdc.recordPullBlock(ckUsdcPulls, orderId, block, Time.now());
    };
    switch (Orders.applyTransition(orderStore, orderId, #paid, Time.now())) {
      case (#ok(paid)) {
        audit("ckusdc.paid", orderId # ": block " # block.toText());
        #ok(paid);
      };
      case (#err(_)) {
        // Block + journal are committed; the next claim heals via
        // #recoverBlock. Degrade, never trap mid-money-flow.
        audit("ckusdc.paidTransitionRefused", orderId # ": block " # block.toText());
        #err(#retryable("payment recorded; retry to finalize"));
      };
    };
  };

  /// §5.1 stale-intent escalation, money-IN edition: the pull's fate is
  /// unknowable. The order deliberately stays `#created` (no legal edge to
  /// `#errorQueue` pre-payment, and the position may well be "nothing
  /// happened") — the pull journal's escalation mark blocks further claims;
  /// the operator reads the ck-USDC ledger, then either refunds via
  /// `withdraw_ck_usdc` (pull executed) or `reset_ck_usdc_pull` (it didn't).
  func escalateStalePull(order : Types.Order, detail : Text) {
    CkUsdc.markEscalated(ckUsdcPulls, order.id, Time.now());
    queueMintError(#ckUsdc, #stuckMint({ orderId = order.id; stage = "stalePullIntent" }), detail);
    audit("ckusdc.stalePull", order.id # ": " # detail);
  };

  func driveClaim(order : Types.Order) : async* Result.Result<Types.Order, ClaimCkUsdcError> {
    let orderId = order.id;
    let intent : CkUsdc.PullIntent = switch (CkUsdc.claimStage(order.status, ckUsdcPulls.get(orderId), Time.now(), CkUsdc.ledgerDedupWindowNs)) {
      case (#notClaimable) return #err(#notClaimable(Types.statusToText(order.status)));
      case (#alreadyEscalated) return #err(#staleIntent);
      case (#escalate(_)) {
        escalateStalePull(order, "pull intent aged past the ledger dedup window without a recorded block — check the ck-USDC ledger for the pull before refunding (order stays Created)");
        return #err(#staleIntent);
      };
      case (#recoverBlock(block)) {
        switch (creditPull(orderId, block)) {
          case (#ok(paid)) {
            // Detached money-out kick (§5) — the claim ack never waits on
            // ledger/CMC latency; the §5.2 timer backstops a dead message.
            ignore async { await* processMint(orderId) };
            return #ok(paid);
          };
          case (#err(e)) return #err(e);
        };
      };
      case (#fresh) {
        // §5.1 step 1, money-IN edition: the pull args are frozen and
        // persisted in this sync block, before the ledger await. The amount
        // comes from the order's own pricing snapshot, never live config.
        let #ii(fromOwner) = order.owner;
        let intent = CkUsdc.buildPullIntent(
          fromOwner,
          orderId,
          CkUsdc.unitsForCents(order.pricing.usdCents),
          ckUsdcConfig.ledgerFeeUnits,
          Time.now(),
        );
        ignore CkUsdc.openPull(ckUsdcPulls, orderId, intent, Time.now());
        intent;
      };
      case (#replay(intent)) intent;
    };
    let result = try {
      await ckUsdcLedger.icrc2_transfer_from(CkUsdc.transferFromArgs(selfPrincipal(), intent));
    } catch (e) {
      // Call rejected — keep the intent; the next claim replays it.
      audit("ckusdc.pullFailed", orderId # ": " # e.message());
      return #err(#retryable(e.message()));
    };
    switch (CkUsdc.interpretPull(result)) {
      case (#pulled(block)) {
        switch (creditPull(orderId, block)) {
          case (#ok(paid)) {
            ignore async { await* processMint(orderId) };
            #ok(paid);
          };
          case (#err(e)) #err(e);
        };
      };
      case (#drop(reason)) {
        // Definite rejection — proven nothing ever moved under these args
        // (dedup-first ledger semantics, CkUsdc.mo doc), so the intent goes
        // and the next claim builds a fresh one.
        CkUsdc.dropPull(ckUsdcPulls, orderId);
        let required = intent.amountUnits + intent.feeUnits;
        switch (reason) {
          case (#insufficientAllowance({ allowance })) #err(#insufficientAllowance({ allowance; required }));
          case (#insufficientFunds({ balance })) #err(#insufficientFunds({ balance; required }));
          case (#badFee({ expectedFee })) {
            audit("ckusdc.badFee", orderId # ": ledger expects " # expectedFee.toText() # " units");
            #err(#badFee({ expectedFee }));
          };
          case (#rejected(detail)) {
            audit("ckusdc.pullRejected", orderId # ": " # detail);
            #err(#ledgerRejected(detail));
          };
        };
      };
      case (#retry(detail)) {
        audit("ckusdc.pullRetriable", orderId # ": " # detail);
        #err(#retryable(detail));
      };
      case (#uncertain(detail)) {
        escalateStalePull(order, detail);
        #err(#staleIntent);
      };
    };
  };

  /// §6.2 pull: after `icrc2_approve` (≥ the order's approveUnits, spender =
  /// this canister), the owner claims and the canister pulls the exact quoted
  /// price. Idempotent against double-clicks (single-flight) and safe against
  /// lost responses (the persisted intent replays bit-identically; the ledger
  /// dedups on created_at_time). On success the order is `#paid` and the
  /// mint pipeline is kicked — the same money-out path as the card rail.
  public shared ({ caller }) func claim_ck_usdc_order(id : Types.OrderId) : async Result.Result<Types.Order, ClaimCkUsdcError> {
    switch (Auth.checkUser(caller)) {
      case (#err(#anonymous)) return #err(#anonymous);
      case (#ok) {};
    };
    let ?order = Orders.getOwned(orderStore, id, caller) else return #err(#notFound);
    if (order.rail != #ckUsdc) return #err(#wrongRail);
    if (pullsInFlight.contains(id)) return #err(#inFlight);
    pullsInFlight.add(id);
    try { await* driveClaim(order) } finally { pullsInFlight.remove(id) };
  };

  /// Adjust the rail config (§7): amount bounds, fee formula, ledger fee.
  /// Validated atomically — a bad config never partially applies.
  public shared ({ caller }) func set_ck_usdc_config(config : CkUsdc.Config) : async Result.Result<(), CkUsdc.ConfigError> {
    requireAdmin(caller);
    switch (CkUsdc.validateConfig(config)) {
      case (#ok) {
        ckUsdcConfig := config;
        auditAdmin(caller, "ckusdc.configSet", "maxUsdCents=" # config.maxUsdCents.toText()
          # (if (config.maxUsdCents == 0) " — RAIL DISABLED" else ""));
        #ok;
      };
      case (#err(e)) #err(e);
    };
  };

  /// Public — bounds and fee formula are what users are charged (the same
  /// transparency stance as forex_status); the frontend renders the rail
  /// panel (or its disabled state) from this.
  public query func ck_usdc_config() : async CkUsdc.Config {
    ckUsdcConfig;
  };

  /// Money-IN journal for one order (admin, ops parity with mint_journal).
  public shared query ({ caller }) func ck_usdc_pull(id : Types.OrderId) : async ?CkUsdc.PullEntry {
    requireAdmin(caller);
    ckUsdcPulls.get(id);
  };

  /// Clear a stuck pull intent so the order becomes claimable again — ONLY
  /// after verifying on the ck-USDC ledger that no transaction matches the
  /// intent (a fresh intent after an executed-but-unrecorded pull would debit
  /// the user twice). Refuses when a block is recorded (money moved). False =
  /// nothing cleared.
  public shared ({ caller }) func reset_ck_usdc_pull(id : Types.OrderId) : async Bool {
    requireAdmin(caller);
    switch (ckUsdcPulls.get(id)) {
      case (?entry) {
        if (entry.blockIndex != null) return false;
        CkUsdc.dropPull(ckUsdcPulls, id);
        auditAdmin(caller, "ckusdc.pullReset", id # ": intent cleared after ledger verification");
        true;
      };
      case null false;
    };
  };

  /// §6.2 hold-ckUSDC treasury posture: pulled ck-USDC accrues in this
  /// canister's ledger account; the operator withdraws it here, converts to
  /// ICP off-chain, and refills the float. Attended admin lever — no
  /// created_at_time dedup; on an ambiguous failure check the ledger before
  /// retrying. (Balance is public on the ck-USDC ledger; no query needed.)
  public shared ({ caller }) func withdraw_ck_usdc(to : Types.Account, amountUnits : Nat) : async Result.Result<Nat, Text> {
    requireAdmin(caller);
    let result = try {
      await ckUsdcLedger.icrc1_transfer({
        from_subaccount = null;
        to;
        amount = amountUnits;
        fee = ?ckUsdcConfig.ledgerFeeUnits;
        memo = null;
        created_at_time = null;
      });
    } catch (e) {
      return #err(e.message());
    };
    switch (result) {
      case (#Ok(block)) {
        auditAdmin(caller, "ckusdc.withdraw", amountUnits.toText() # " units to " # to.owner.toText() # ", block " # block.toText());
        #ok(block);
      };
      case (#Err(error)) #err(CkUsdc.transferErrorToText(error));
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
  /// init and `recoverySweep` reaches the order store, the mint journal, and
  /// the ck-USDC pull journal, all of which must already be initialized
  /// (M0016 otherwise).
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
