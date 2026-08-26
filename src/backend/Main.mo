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
// `Call.httpRequest` attaches the exact `ic0.cost_http_request` price; `IC` is
// imported for the request/response types the transform signature needs.
import Call "mo:ic/Call";
import IC "mo:ic/Types";
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
import Reserve "Reserve";
import Card "rails/Card";
import Session "rails/Session";
import Secret "Secret";
import Tiers "Tiers";
import Treasury "Treasury";
import Types "Types";

persistent actor CyclesGateway {

  /// §7 secret one of TWO: the Stripe webhook signing key. Plaintext by design,
  /// SEV-SNP posture documented in Secret.mo. Persists across upgrades; rotation
  /// never requires a redeploy.
  let webhookSecret : Secret.Store = Secret.emptyStore();

  /// §7 secret two: the Stripe **API key** that creates Checkout Sessions (#33).
  ///
  /// Same store, same posture, same never-readable-back guarantee. Use a
  /// **restricted key** (`rk_...`) scoped to *write Checkout Sessions* and
  /// nothing else: a leaked write-sessions key can create sessions that pay us,
  /// which is materially different from one that can also issue refunds. Stripe's
  /// IP/ASN access policies are not usable here — a subnet's replicas have many
  /// changing addresses.
  let stripeApiKey : Secret.Store = Secret.emptyStore();

  /// The asset origin Stripe returns the buyer to, e.g.
  /// `https://<canister>.icp0.io`. Null until an admin sets it, and
  /// `create_order` fails closed rather than creating a sessionless order.
  ///
  /// ⚠️ **Admin config, never a `create_order` parameter.** A caller-supplied
  /// `success_url` is an open redirect that Stripe renders *after a real
  /// payment* — a phishing primitive wearing a genuine receipt page.
  ///
  /// ⚠️ Changing it later invalidates nothing already paid, but Internet Identity
  /// derives a principal **per origin**, so an origin change is a user-visible
  /// migration rather than a config tweak: existing buyers get new principals and
  /// cannot see their old orders. Choose it once (#40/#23).
  var stripeOrigin : ?Text = null;

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

  /// Provision or rotate the Stripe API key (#33) — admin, mirroring
  /// `set_webhook_secret` in every respect including the provisioning caveat:
  /// the argument transits the TLS-terminating boundary node as plain ingress.
  /// #11 covers vetKeys for encrypted delivery, and now applies to two secrets.
  public shared ({ caller }) func set_stripe_api_key(key : Text) : async Result.Result<(), Secret.SetError> {
    requireAdmin(caller);
    let result = Secret.set(stripeApiKey, key.encodeUtf8(), Time.now());
    switch (result) {
      case (#ok) auditAdmin(caller, "stripe.apiKeySet", "generation " # Secret.status(stripeApiKey).generation.toText());
      case (#err(_)) auditAdmin(caller, "stripe.apiKeyRejected", "rejected as too short; the working key is untouched");
    };
    result;
  };

  public shared query ({ caller }) func stripe_api_key_status() : async Secret.Status {
    requireAdmin(caller);
    Secret.status(stripeApiKey);
  };

  public type OriginError = {
    /// Anything but `https://`. A plain-HTTP return URL after a card payment is
    /// not a thing to offer, and Stripe would render it.
    #notHttps;
    /// A query string or fragment would collide with the `#/order/<id>` route
    /// appended to it, producing a URL that does not resolve to the order.
    #hasQueryOrFragment;
    #empty;
  };

  /// Set the origin Stripe returns buyers to (#33) — admin.
  ///
  /// Validated at set time rather than at session-create time, so a bad value
  /// fails in front of the operator who typed it instead of breaking every
  /// purchase later. Until a domain is chosen (#40/#23) this is the canister's
  /// own asset origin.
  public shared ({ caller }) func set_stripe_origin(origin : Text) : async Result.Result<(), OriginError> {
    requireAdmin(caller);
    if (origin.size() == 0) return #err(#empty);
    if (not origin.startsWith(#text "https://")) return #err(#notHttps);
    if (origin.contains(#char '?') or origin.contains(#char '#')) return #err(#hasQueryOrFragment);
    // Trailing slash trimmed here rather than at every use site, so
    // `origin # "/#/order/" # id` cannot produce a double slash.
    let trimmed = origin.trimEnd(#char '/');
    stripeOrigin := ?trimmed;
    auditAdmin(caller, "stripe.originSet", trimmed);
    #ok;
  };

  /// The origin, readable back because it is not a secret — it is the URL
  /// buyers are sent to, and an operator needs to confirm it.
  public shared query func stripe_origin() : async ?Text {
    stripeOrigin;
  };

  // ── Order + tier state (task 6) ─────────────────────────────────────────

  /// §4.2 order store: `orders` + `principalsToOrders` history.
  let orderStore : Orders.Store = Orders.emptyStore();

  /// §3 fixed card tiers. Operator config (§7): controllers create the
  /// amounts the UI offers as tiles. Presentational since #33: a buyer can order
  /// any amount between the gate's floor and ceiling, so an empty list means "no
  /// tiles", not "rail off". Empty
  /// until first `set_card_tiers` — no made-up default prices.
  var cardTiers : [Tiers.Tier] = [];

  /// Pre-creation admission policy (Gate.mo) — open-order cap, own-cycles
  /// floor, per-purchase ceiling. Unlike the burn cap these default to real
  /// values: they are safety limits, and a zero default would brick the
  /// canister rather than protect it.
  var gateConfig : Gate.Config = Gate.defaultConfig();

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
  /// Is the card rail capable of completing a purchase?
  ///
  /// **Both Stripe secrets, and nothing else** (#33). Derived from actual
  /// capability rather than declared separately:
  ///
  /// - no **API key** → `create_order` cannot produce a payable session at all;
  /// - no **webhook secret** → `handleWebhook` answers 503, so a buyer can pay
  ///   and we cannot credit them.
  ///
  /// Neither state can complete a purchase, so neither should accept one. This
  /// used to read `cardTiers.size() > 0`, which was a proxy inherited from the
  /// Payment Link design — and with custom amounts it would stop nothing.
  ///
  /// It gates the rate-refresh timer, so this also fixes a real waste: a gateway
  /// with presets but no API key used to pay for XRC calls it could never use.
  func railsLive() : Bool {
    Secret.status(stripeApiKey).isSet and Secret.status(webhookSecret).isSet;
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
    /// No configured preset with this id. Only reachable for `#tier`.
    #unknownTier : Text;
    /// §3 fee formula swallows the tier's gross amount — a tier/fee config
    /// problem for the operator, not something a retry fixes.
    #tierBelowFees : Text;
    /// #30 PR-B: the reserve balance could not be read, so solvency is unknown.
    /// Fails closed on purpose — selling against an unknown balance is exactly
    /// what the check exists to prevent. (A short reserve is reported through
    /// `#notAdmitted(#reserveShort)`, which carries both figures.)
    #reserveUnavailable;
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
    /// The destination is not the caller's own default-subaccount cycles-ledger
    /// account. Cycles go to the buyer and nowhere else, and that is a property
    /// of the canister rather than of whichever frontend called it (#29).
    #destinationNotOwned;
    /// No payable Checkout Session could be created (#33): the API key or the
    /// origin is unset, Stripe refused, or the outcall failed. Carries a reason
    /// so the operator can tell "not provisioned yet" from "Stripe is down"
    /// without reading the audit log. The order was created and then failed, so
    /// the buyer's open-order slot is already free — they retry, they do not wait.
    ///
    /// Deliberately distinct from `#notAdmitted`: this is the operator's problem,
    /// that one is the buyer's.
    #sessionUnavailable : Text;
    /// The order was cancelled from another tab while its session was being
    /// created. The session exists at Stripe but its URL never left the canister,
    /// so it is unreachable and dies at its own `expires_at`.
    #cancelledDuringCreation;
  };

  /// What the buyer is paying for: a preset, or an amount they typed (#33).
  ///
  /// A variant rather than a second method, so the quote, the gate and the
  /// session path stay single. Everything downstream keys off gross USD cents,
  /// which is what both cases resolve to — the floor and the ceiling then apply
  /// uniformly instead of one bound per entry point.
  public type Amount = {
    #tier : Text;
    /// Gross USD cents, straight from the buyer. Bounded by
    /// `Gate.Config`'s floor and ceiling like any other amount — and bounded
    /// **here**, not only in the frontend, because a frontend-only bound is not a
    /// bound.
    #custom : Nat;
  };

  public type CreatedOrder = {
    /// The order, carrying `stripeSessionUrl` — which is the only thing the
    /// caller needs to send the buyer to Stripe.
    ///
    /// ⚠️ `clientReferenceId` used to be here. It existed so the frontend could
    /// append `?client_reference_id=` to a **Payment Link URL**; the canister now
    /// sets it through the API, so it was a Payment-Link relic sitting in a public
    /// response type (#33). It is derivable — `<principal>_<orderId>` — and the
    /// frontend computes it for the receipt field rather than being handed it.
    order : Types.Order;
  };

  /// The outcall transform (#33). Referenced by name in the request, so it has to
  /// be a public `shared query` on the actor even though nothing should ever call
  /// it directly.
  ///
  /// Its whole job is `Session.strip`: **remove every response header.** Stripe
  /// returns a unique `request-id` per HTTP request, and each replica issues its
  /// own request — so passing headers through fails consensus on *every* call, not
  /// occasionally. Replication-count independent: any `n > 1` breaks.
  public shared query func transform_stripe_response(args : { context : Blob; response : IC.HttpRequestResult }) : async IC.HttpRequestResult {
    Session.strip(args.response);
  };

  /// Create the Checkout Session for a freshly committed order (#33).
  ///
  /// Returns the session, or a reason the caller turns into a distinguishable
  /// `create_order` error. Cycles are attached by `Call.httpRequest`, which
  /// computes the exact `ic0.cost_http_request` price — **never hand-attach and
  /// never add a buffer**: over-attaching is refunded, but the cycles are reserved
  /// for the call's duration, so a buffer reduces how many outcalls can be in
  /// flight, which is precisely why the library attaches the minimum.
  /// The two things a session needs, or a reason there is none.
  ///
  /// ⚠️ **Read this BEFORE committing an order.** Both checks short-circuit
  /// without an outcall, so an unprovisioned gateway that committed the order
  /// first would mint a permanent `#expired` record for **free**: no cycles are
  /// spent, so `minCanisterCycles` never bounds the loop, and the record is not
  /// `#created`, so the open-order cap does not either. Unbounded storage growth
  /// at zero attacker cost — and precisely in the state RUNBOOK §1 prescribes
  /// during go-live, since provisioning the secrets last is what opens the rail.
  ///
  /// #33's own finding 1 says it: *fail closed rather than creating a sessionless
  /// order.*
  func sessionConfig() : { #ok : { apiKey : Text; origin : Text }; #err : SessionError } {
    let ?apiKey = Secret.get(stripeApiKey) else return #err(#railClosed);
    let ?keyText = apiKey.decodeUtf8() else return #err(#railClosed);
    let ?origin = stripeOrigin else return #err(#originUnset);
    #ok({ apiKey = keyText; origin });
  };

  func createStripeSession(
    config : { apiKey : Text; origin : Text },
    orderId : Types.OrderId,
    clientReferenceId : Text,
    usdCents : Nat,
  ) : async* { #ok : Session.Created; #err : SessionError } {
    let keyText = config.apiKey;
    let origin = config.origin;
    // Stripe evaluates the 30-minute floor against ITS clock on receipt, so the
    // request asks for 35 to survive skew and consensus latency. `expiresAtNs`
    // comes from the response, not from this.
    let expiresAtSeconds = Int.abs(Time.now() / 1_000_000_000) + Session.requestedLifetimeSeconds;
    let body = Session.createBody({
      orderId;
      clientReferenceId;
      usdCents;
      origin;
      expiresAtSeconds;
    });
    let response = try {
      await Call.httpRequest({
        url = Session.createUrl;
        method = #post;
        max_response_bytes = ?Session.maxResponseBytes;
        body = ?body.encodeUtf8();
        headers = Session.createHeaders(keyText, orderId);
        transform = ?{ function = transform_stripe_response; context = "" };
        is_replicated = null;
      });
    } catch (e) {
      // Classified rather than passed through raw: "outcall failed" cannot tell an
      // operator whether to wait, look at Stripe, or look at our own transform —
      // and the transform case is the one no test suite can catch.
      let kind = Session.classifyFailure(e.message());
      return #err(#outcallFailed(Session.failureAdvice(kind) # " [" # e.message() # "]"));
    };
    if (response.status != 200) {
      return #err(#stripeRejected({ status = response.status }));
    };
    switch (Session.parseCreated(response.body)) {
      case (#err(#unparseable)) #err(#unparseableResponse);
      case (#err(#missingField(f))) #err(#missingField(f));
      case (#ok(created)) {
        // Checked HERE rather than at webhook time: with two mode-bearing
        // secrets — this key and the webhook secret — they can disagree, and
        // catching it at session creation is before any money moves.
        switch (expectLivemode) {
          case (?expected) {
            if (created.livemode != expected) {
              return #err(#livemodeMismatch({ sessionLivemode = created.livemode; expected }));
            };
          };
          // Unset means "either mode", which is only sensible while nothing of
          // value is at stake. The go-live checklist declares it.
          case null {};
        };
        #ok(created);
      };
    };
  };

  /// Expire a session at Stripe so the order is provably unpayable (#33).
  ///
  /// Three outcomes, and the distinction between the last two is load-bearing:
  /// "not open" means the session already completed or expired, so the caller
  /// must change nothing and let the webhook resolve it; "failed" means we do not
  /// know, so the order must stay payable and uncancelled.
  func expireStripeSession(sessionId : Text) : async* { #ok; #notOpen; #failed : Text } {
    let ?apiKey = Secret.get(stripeApiKey) else return #failed("the Stripe API key is not provisioned");
    let ?keyText = apiKey.decodeUtf8() else return #failed("the stored API key is not valid UTF-8");
    let response = try {
      await Call.httpRequest({
        url = Session.expireUrl(sessionId);
        method = #post;
        max_response_bytes = ?Session.maxResponseBytes;
        // Stripe's expire endpoint takes no parameters; the session is in the
        // path. An empty body still needs to be `?` rather than null so the POST
        // is well formed.
        body = ?("" : Blob);
        headers = Session.expireHeaders(keyText);
        transform = ?{ function = transform_stripe_response; context = "" };
        is_replicated = null;
      });
    } catch (e) {
      let kind = Session.classifyFailure(e.message());
      return #failed(Session.failureAdvice(kind) # " [" # e.message() # "]");
    };
    if (response.status == 200) return #ok;
    if (Session.isNotOpen(response.status, response.body)) return #notOpen;
    #failed("Stripe answered " # response.status.toText());
  };

  public type SessionError = {
    /// The API key is not provisioned. The rail cannot produce a payable session.
    #railClosed;
    /// No origin set, so there is no URL to return the buyer to.
    #originUnset;
    #outcallFailed : Text;
    #stripeRejected : { status : Nat };
    #unparseableResponse;
    #missingField : Text;
    #livemodeMismatch : { sessionLivemode : Bool; expected : Bool };
  };

  func sessionErrorToText(e : SessionError) : Text {
    switch (e) {
      case (#railClosed) "the Stripe API key is not provisioned";
      case (#originUnset) "no return origin is configured";
      case (#outcallFailed(detail)) "outcall failed: " # detail;
      case (#stripeRejected({ status })) "Stripe answered " # status.toText();
      case (#unparseableResponse) "Stripe's response was not usable JSON";
      case (#missingField(f)) "Stripe's response had no " # f;
      case (#livemodeMismatch({ sessionLivemode; expected })) {
        "livemode mismatch: the API key is "
        # (if (sessionLivemode) "LIVE" else "test")
        # " but this gateway expects "
        # (if (expected) "LIVE" else "test");
      };
    };
  };

  /// One quote = one consistent epoch: the caller snapshots the rail's fee
  /// formula *before* any await, and both rates are read once from the cache
  /// here. The §6.1 pricing snapshot persisted on the order carries both rate
  /// inputs from that same epoch — which is what a buyer recomputes their own
  /// price from, and what a delivered order is auditable against. (It was also
  /// what the webhook repriced a mismatched paid amount from, until #33 made a
  /// mismatch mint nothing.)
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
            // The one field of `Pricing.Rates` this copy used to drop. Without
            // it `createdAtNs` is the only timestamp on the record, and it is
            // not when these rates were read (#34).
            ratesFetchedAtNs = rates.fetchedAtNs;
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

  /// **The** admission decision: everything `Gate.admit` asks, plus solvency.
  ///
  /// ⚠️ **One callable answer, deliberately.** #30 PR-B split solvency out of
  /// `Gate.admit` because reading the reserve needs an `await` and `admit` is
  /// synchronous by design — but that leaves the decision with two owners, and
  /// `-Werror` cannot see that calling `admit` alone is *half* a decision. A future
  /// entry point that called `admit` and forgot `solvent` would silently skip
  /// solvency. So this is the only thing `create_order` consults, and the split
  /// lives inside it as an implementation detail.
  ///
  /// ⚠️ **Must be called in the same synchronous block as `Orders.create`.** See
  /// the interleaving trace at the call site.
  func admitOrder(
    caller : Principal,
    usdCents : Nat,
    lockedCycles : Nat,
  ) : Result.Result<(), Gate.Reason> {
    switch (admit(caller, usdCents)) {
      case (#err(reason)) return #err(reason);
      case (#ok) {};
    };
    // ⚠️ **Synchronous, and that is the whole design.** `reserveFloor` is a
    // maintained lower bound on the ledger balance, moved only by our own
    // outflows — so there is no awaited value to go stale and nothing to pair
    // across an await. `Reserve.mo`'s floor section carries the asymmetry this
    // rests on (only we can debit; top-ups only ever add).
    //
    // An earlier version awaited `icrc1_balance_of` here. It was correct when it
    // arrived and historical when used, and pairing it with a live tally made
    // `available` optimistic by a full order at the ceiling. The fix was not a
    // fresher read — any awaited value is historical by the time it is used — it
    // was removing the read from the decision.
    switch (Gate.solvent(reserveFloor, Orders.promised(orderStore), lockedCycles)) {
      case (#err(reason)) {
        audit("order.notAdmitted", Gate.reasonToText(reason));
        #err(reason);
      };
      case (#ok) #ok;
    };
  };

  /// raw_rand → Orders.create, re-drawing fresh entropy on an ID collision
  /// (§2). Null = the entropy source misbehaved (short blob or repeated
  /// collisions), never bad luck.
  func createOrderWithFreshId(
    caller : Principal,
    usdCents : Nat,
    owner : Types.Owner,
    rail : Types.Rail,
    destination : Types.Destination,
    lockedCycles : Nat,
    pricing : Types.Pricing,
  ) : async* Result.Result<Types.Order, { #idGeneration; #notAdmitted : Gate.Reason }> {
    var attempts = 0;
    while (attempts < maxIdAttempts) {
      let entropy = await management.raw_rand();
      let ?id = Orders.idFromEntropy(entropy) else return #err(#idGeneration);
      // ── ONE SYNCHRONOUS BLOCK: decide, then hold. No `await` between them. ──
      //
      // ⚠️ **This is #30 PR-B's actual identified correctness bug.** The check and
      // the hold used to be separated by the `raw_rand` await above, so two
      // concurrent `create_order` calls could both pass the gate against the same
      // `promised` and only then both hold — together promising more than the
      // balance either of them checked. **Two honest buyers, no attacker.** #30's
      // own earlier draft called interleaved creates safe because "each resumes
      // after the other has recorded its promise", which is true only when the
      // check and the hold cannot be split.
      //
      // The redraw loop is why the decision is *inside* the loop rather than
      // before it: a duplicate id sends us back through `raw_rand`, and re-deciding
      // after that await is what stops the redraw reopening the same window.
      // `admitOrder` re-reads `Orders.promised` each time, so the tally half is
      // always fresh; the balance is deliberately not re-read (see the trace at
      // the call site — a stale balance cannot make this optimistic).
      switch (admitOrder(caller, usdCents, lockedCycles)) {
        case (#err(reason)) return #err(#notAdmitted(reason));
        case (#ok) {};
      };
      switch (Orders.create(orderStore, id, owner, rail, destination, lockedCycles, pricing, Time.now())) {
        case (#ok(order)) return #ok(order); // the hold is taken inside `create`
        case (#err(#duplicateId(_))) {}; // re-draw fresh entropy, then re-decide
      };
      attempts += 1;
    };
    #err(#idGeneration);
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
    amount : Amount,
    destination : Types.Destination,
    minCycles : ?Nat,
  ) : async Result.Result<CreatedOrder, CreateOrderError> {
    switch (Auth.checkUser(caller)) {
      case (#err(#anonymous)) return #err(#anonymous);
      case (#ok) {};
    };
    // Argument validation before any work, and before the gate: cycles go to the
    // caller's own account or the order is not created (#29). Checked HERE
    // rather than in the frontend, because a hand-crafted call reaches this
    // method too — "the cycles come to you" is only true if the gateway enforces
    // it.
    if (not Types.isOwnDestination(destination, caller)) {
      return #err(#destinationNotOwned);
    };
    // The rail's own state, before anything about this particular request. If no
    // session can be created then no tier matters, and "card payments are not
    // available yet" is a more useful answer than "unknown tier" — as well as a
    // cheaper one. Ordering: caller, then arguments that depend only on the
    // caller, then the RAIL, then this request's tier and admission.
    let config = switch (sessionConfig()) {
      case (#ok(c)) c;
      case (#err(e)) {
        audit("stripe.railClosed", "create_order refused: " # sessionErrorToText(e));
        return #err(#sessionUnavailable(sessionErrorToText(e)));
      };
    };
    // Both cases collapse to gross USD cents here, and everything after this is
    // identical for a preset and a typed amount — which is the point of the
    // variant: one quote path, one gate, one session.
    let (usdCents, quoteLabel) = switch (amount) {
      case (#tier(tierId)) {
        let ?tier = Tiers.find(cardTiers, tierId) else return #err(#unknownTier(tierId));
        (tier.usdCents, tierId);
      };
      // NOT validated against the presets: a custom amount is any amount the
      // gate admits, and the gate is the only bound. Checking it against the
      // tier list would make presets a constraint again.
      case (#custom(cents)) (cents, cents.toText() # " cents");
    };
    // A cheap PRE-REFUSAL before any await, so a spamming principal is turned
    // away before it can make the canister do work (`canister-security`: anyone
    // can burn your cycles with update calls). The floor and ceiling are enforced
    // here, for both cases alike.
    //
    // ⚠️ **This can only refuse, never admit.** The authoritative decision is
    // `admitOrder` inside the create block below, which additionally checks
    // solvency. Two calls, one decision — do not read this as the gate.
    switch (admit(caller, usdCents)) {
      case (#err(reason)) return #err(#notAdmitted(reason));
      case (#ok) {};
    };
    let fee = { feeBps = pricingConfig.feeBps; feeFixedCents = pricingConfig.feeFixedCents };
    let (lockedCycles, pricing) = switch (quoteCents(fee, usdCents)) {
      case (#ok(quoted)) quoted;
      case (#unpriceable) return #err(#tierBelowFees(quoteLabel));
      case (#stale) return #err(#rateUnavailable);
    };
    switch (minCycles) {
      case (?minimum) if (lockedCycles < minimum) {
        return #err(#quoteChanged({ quoted = lockedCycles; minimum }));
      };
      case null {};
    };
    let owner : Types.Owner = #ii(caller);

    // ── The reserve, read from the ledger ────────────────────────────────────
    //
    // ⚠️ **Why awaiting this is safe, when `Gate.admit` is synchronous precisely
    // so nothing can change between observing and deciding.**
    //
    // Because `available = balance − promised` is **invariant under delivery**, and
    // the three interleavings this codebase actually permits all land on
    // conservative or exact. Written out, because "conservative, never optimistic"
    // is a universal a reader can falsify in thirty seconds, and this comment is
    // the only thing between a future maintainer and *"this await looks like a bug,
    // let me cache the balance"*:
    //
    // **(A) racing a concurrent DELIVERY.** ⚠️ **This is the case an earlier version
    // of this trace got WRONG, and the error was optimistic — the dangerous
    // direction.** It reasoned about where the balance read falls relative to the
    // ledger debit and concluded "read-before-debit cancels exactly, because the
    // balance still includes those cycles and the tally still counts them". The
    // second half does not follow: the tally is read at DECISION time, not at
    // balance-read time. A delivery whose continuation runs in that gap debits the
    // ledger *and* releases the promise, so the stale balance includes the cycles
    // while the live tally no longer counts them — `available` overstated by a full
    // order at the ceiling.
    //
    // The fix is in `admitOrder`: the tally is snapshotted beside this call and the
    // decision uses `max(snapshot, live)`, which makes the staleness one-sided. The
    // ordering fact the old trace relied on is still true and still worth knowing —
    // the release runs strictly after the transfer response, which follows strictly
    // after the debit, so *released-but-not-debited* cannot occur — it just was not
    // sufficient on its own.
    //
    // **(B) racing a concurrent EXPIRY's release.** An expired order never moved
    // cycles, so a release here changes the tally and not the balance. Read before
    // → we understate `available` (conservative). Read after → exact. There is no
    // optimistic case, because this path can only ever *reduce* what we consider
    // owed; it can never raise the balance.
    //
    // **(C) racing a second `create_order`'s hold.** Both calls may read a balance
    // and then decide, but each decides and holds in ONE synchronous block that
    // re-reads `Orders.promised` — and Motoko messages do not interleave except at
    // an await, of which that block has none. So whichever block runs second sees
    // the first one's hold and answers against it. This is the case the reordering
    // exists for: with the check and the hold split by the `raw_rand` await, both
    // could pass against the same tally.
    //
    // A stale balance is therefore never optimistic **given the `max` in
    // `admitOrder`** — and that qualifier is the whole content of the fix. Without
    // it, (A) pairs a not-yet-lowered balance with an already-released promise, and
    // that is precisely capacity that is free-looking and unaccounted.
    // ── The order, held against the reserve floor ────────────────────────────
    //
    // ⚠️ **No ledger call here, deliberately.** `reserveFloor` is a maintained
    // lower bound moved only by our own outflows, so the admission decision is
    // synchronous — the check and the hold are in one block inside
    // `createOrderWithFreshId` with no await between them, which is what stops two
    // concurrent creates promising the same cycles.
    //
    // An earlier version awaited `icrc1_balance_of` at this point and paired it
    // with a live tally. That was optimistic by a full order whenever a delivery
    // released in the gap, and no fresher read could have fixed it: an awaited
    // value is historical the moment the continuation resumes. Removing the read
    // removed the class.
    let order = switch (
      await* createOrderWithFreshId(caller, usdCents, owner, #card, destination, lockedCycles, pricing)
    ) {
      case (#ok(o)) o;
      case (#err(#idGeneration)) return #err(#idGeneration);
      case (#err(#notAdmitted(reason))) return #err(#notAdmitted(reason));
    };
    let clientReferenceId = Orders.clientReferenceId(owner, order.id);

    // ── The session, after the order exists ─────────────────────────────────
    // The ordering is forced: the order id IS the `client_reference_id`, so the
    // order must be committed before the session can name it. Which means an
    // await sits between them, and everything below is about that gap.
    switch (await* createStripeSession(config, order.id, clientReferenceId, order.pricing.usdCents)) {
      case (#err(e)) {
        // Fail the order in the same call and let the buyer start over. There is
        // no retry method by design: a `payment_session(orderId)` retry was the
        // only thing that created orders in a sessionless state, and every
        // downstream complication chained off that — a promise no
        // `checkout.session.expired` can release, a sweep promoted into a release
        // path, a per-attempt idempotency key Stripe rejects on a changed body.
        //
        // ⚠️ Through `expireWithCause`, never a direct status write: a second tab
        // may have cancelled this order while the outcall was in flight, and the
        // matrix no-ops `#cancelled → #expired` for free.
        switch (Orders.expireWithCause(orderStore, order.id, #sessionFailed, Time.now())) {
          case (#ok(_)) {};
          case (#err(_)) {}; // already cancelled or gone; nothing to undo
        };
        audit("stripe.sessionFailed", order.id # ": " # sessionErrorToText(e));
        return #err(#sessionUnavailable(sessionErrorToText(e)));
      };
      case (#ok(created)) {
        // ⚠️ Re-check the status before storing. `create_order` committed the
        // order as `#created` and then awaited, so `cancel_order` from a second
        // tab can have run in between — its sessionless branch fires, because no
        // session id existed yet. Storing the URL anyway would hand the buyer a
        // payable link for an order they were told was cancelled. Money-safe (the
        // matrix rejects `#cancelled → #paid`) but it recreates exactly the
        // "told cancelled, tab still charges" wart atomic cancellation exists to
        // eliminate. `attachSession` enforces this; the branch below reports it.
        switch (
          Orders.attachSession(
            orderStore,
            order.id,
            created.id,
            created.url,
            Session.secondsToNs(created.expiresAtSeconds),
            Time.now(),
          )
        ) {
          case (#ok(withSession)) #ok({ order = withSession });
          case (#err(_)) {
            // The session is unreachable either way: its URL never left the
            // canister, so nobody can pay it, and it dies at its own expires_at.
            audit("stripe.sessionOrphaned", order.id # ": cancelled during creation; session " # created.id # " left to expire");
            #err(#cancelledDuringCreation);
          };
        };
      };
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

  /// Replace the card presets (§3/§7 — admin, validated atomically: a bad config
  /// never partially applies).
  ///
  /// ⚠️ **This is no longer the rail's on/off switch.** An empty list used to
  /// pause the rail, and the audit line said "CARD RAIL PAUSED". With custom
  /// amounts (#33) a buyer can order without any preset, so an empty list stops
  /// nothing — it just shows no tiles. The switch is both Stripe secrets being
  /// provisioned; `railsLive` is where that lives.
  public shared ({ caller }) func set_card_tiers(tiers : [Tiers.Tier]) : async Result.Result<(), Tiers.ValidateError> {
    requireAdmin(caller);
    switch (Tiers.validate(tiers, gateConfig.minPurchaseUsdCents, gateConfig.maxPurchaseUsdCents)) {
      case (#ok) {
        cardTiers := tiers;
        auditAdmin(caller, "tiers.set", tiers.size().toText() # " preset(s)" # (if (tiers.size() == 0) " — no presets shown; the rail is unaffected" else ""));
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

  /// Public: the frontend needs the bounds to size its amount input and to say
  /// what it will accept before the buyer types. Same transparency stance as
  /// `forex_status` and `treasury_status` — these are the rules users are held
  /// to, not secrets.
  ///
  /// It carried a `retention` half until #33. There is no lifecycle *policy* of
  /// ours any more: the deadline is the Stripe session's `expires_at`, which
  /// lives on each order rather than in config, so there is nothing global to
  /// report.
  public query func lifecycle_config() : async { gate : Gate.Config } {
    { gate = gateConfig };
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

  /// Public — the frontend renders the amount tiles from this. There is no link
  /// to render: the canister creates a session per order (#33).
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
  ///
  /// ⚠️ **It no longer discloses the cycles-ledger fee** (#30 PR-A). The frontend
  /// already queries the cycles ledger directly for the reserve balance, so it reads
  /// `icrc1_fee` in the same breath. Same split as `available = balance -
  /// promisedTotal`: **the canister owns what only it knows; the ledger owns what it
  /// owns.**
  ///
  /// ⚠️ This said disclosing it would mean "storing a copy and correcting it on
  /// `#BadFee`", as the argument against. #30 PR-B then stored exactly such a copy
  /// for the delivery path, so read the objection precisely: a stored fee is fine
  /// where a wrong value is **self-correcting and cheap** (one rejected transfer),
  /// and wrong here, where nothing checks the number a buyer was shown. Delivery
  /// gets a mechanism; a quote would get only the staleness.
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

  /// #30 PR-B — a maintained **lower bound** on the reserve's ledger balance.
  ///
  /// Sound because the balance can only fall when we transfer out (no allowance
  /// exists for anyone to pull from the account, and `withdraw` is owner-only and
  /// never called) and can only rise on a top-up we cannot see until we look. So
  /// every unobserved change is in our favour. `Reserve.mo`'s floor section has the
  /// full argument and the three maintenance rules.
  ///
  /// ⚠️ It is a bound, not the balance. The **actual** reserve is a public account
  /// on a public ledger that anyone — the operator, the frontend, monitoring — can
  /// read for free without asking this canister. `reserve_status` reports all three
  /// figures so "the ledger says 100 T and the gateway will sell 0" is diagnosable
  /// at a glance rather than a mystery.
  var reserveFloor : Nat = 0;

  /// Monotone count of transfers ISSUED out of the reserve. Only purpose: letting a
  /// reconcile prove no outflow happened across its balance read (see
  /// `refresh_reserve`). Transient is wrong here — an upgrade mid-reconcile would
  /// make the counter look unchanged — so it is stable.
  var outflowsIssued : Nat = 0;

  /// When `reserveFloor` was last reconciled against the ledger, so staleness is
  /// legible rather than invisible. Null until the first observation — which is
  /// also why a fresh canister sells nothing until the operator refreshes.
  var reserveObservedAtNs : ?Int = null;

  /// The cycles ledger's transfer fee, as last learned from the ledger (#30 PR-B).
  ///
  /// ⚠️ **Stored rather than awaited, and `#BadFee` is why that is safe.** Delivery
  /// used to `await icrc1_fee()` before building the intent, on the stated grounds
  /// that a stale copy "either shorts the buyer or makes every transfer answer
  /// `#BadFee`". The second half is the mechanism, not the objection: an ICRC-1
  /// ledger rejects a wrong fee **definitively and reports the expected one**, so a
  /// stale value costs one rejected call, self-corrects in the same message, and is
  /// persisted here for every later order. In exchange the delivery path loses an
  /// await — and with it the `delivery.feeFetchFailed` failure mode, where a ledger
  /// hiccup on a *read* stalled a delivery that was fully funded and ready.
  ///
  /// ⚠️ **No admin lever writes this** — `#BadFee` is the only writer, which is what
  /// keeps it honest. See `delivery.feeExceedsOrder` for the one state that cannot
  /// self-correct, and why a lever for it was deleted rather than kept.
  ///
  /// ⚠️ **A fee DECREASE shorts that one buyer by the delta.** `amount = locked −
  /// fee_stored`, so if the ledger has become cheaper than our copy, the first order
  /// after the change delivers a little less than it could have, and the reserve
  /// keeps the difference. The correction cannot recover it, because raising a
  /// committed intent's *amount* would be rebuilding the intent — which is the
  /// double-pay this whole path is built to avoid. Bounded by one fee-delta on one
  /// order, and it self-corrects for every order after it.
  ///
  /// An increase is the harmless direction: the reserve absorbs `delta` and the
  /// buyer gets exactly what was quoted (see the `#badFee` arm).
  var cyclesLedgerFee : Nat = Cmc.cyclesLedgerDefaultFee;

  /// §4.2 `journal : Map<OrderId, JournalEntry>` — the money-out record:
  /// transfer intent (written *before* the ledger call, §5.1), block_index,
  /// minted cycles, retries. Financial record — kept for years, never pruned.
  let deliveryJournal : Cmc.Journal = Cmc.emptyJournal();

  transient let icpLedger = actor (Cmc.icpLedgerId) : Cmc.LedgerService;
  transient let cmc = actor (Cmc.cmcId) : Cmc.CmcService;
  transient let cyclesLedger = actor (Cmc.cyclesLedgerId) : Cmc.CyclesLedgerService;

  /// Per-order single-flight guard: two concurrent drivers for one order
  /// would both pass the status gates between awaits. Transient — an
  /// upgrade mid-mint clears it and the journal-driven resume (Cmc.stageOf)
  /// picks up where the state actually is.
  transient let deliveriesInFlight = Set.empty<Types.OrderId>();

  /// Bounds the retriable-error loop on stages the ledger's 24 h dedup window
  /// doesn't already bound. Defined alongside the sweep cadence in Recovery.mo,
  /// because the two are only correct in combination.
  transient let maxMintRetries : Nat = Recovery.maxMintRetries;

  /// Orders already audited for a blocked `#begin` this session, so a stuck
  /// order contributes one audit line rather than one per sweep. Transient: the
  /// durable record of a stuck order is its error-queue entry once the max-wait
  /// bound trips, not this.
  transient let deliveryBlockedAudited = Set.empty<Types.OrderId>();

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
  /// ⚠️ **The stage half of this pair is gone (#30 PR-C).** It existed so a stall
  /// that MOVED between stages could close the stale alert and raise one describing
  /// where the order actually is. With one in-flight status there is nowhere to move
  /// to: `#minting` and `#icpAtCmc` have had no entrance since PR-A, so a `#paid`
  /// order's stage is always the same string. Keeping the comparison would have kept
  /// a whole branch, and an audit tag, describing a transition that cannot occur.
  /// #36 deletes the two legacy stages that made it conceivable.
  let delayedAlerts = Map.empty<Types.OrderId, Nat>();

  /// Raise the §5 delivery-delayed alert for an order, at most once.
  ///
  /// Deliberately does NOT transition the order: the cause is operator-fixable
  /// and the order must stay sweepable so that fixing it delivers with no
  /// further intervention. Only `abandon_order` ends an order without delivery.
  func alertDelayed(order : Types.Order, stage : Text, detail : Text) {
    // Already alerted for this order, so stay silent: re-raising on every sweep
    // would flood the worklist and the audit ring.
    if (delayedAlerts.get(order.id) != null) return;
    let entryId = queueDeliveryError(
      order.rail,
      #deliveryDelayed({ orderId = order.id; stage; sinceNs = order.updatedAtNs }),
      detail,
    );
    delayedAlerts.add(order.id, entryId);
    audit("delivery.delayed", order.id # " [" # stage # "]: " # detail);
  };

  /// The delay ended, so close the alert it raised.
  ///
  /// Resolving the entry matters as much as forgetting the mapping: an open
  /// obligation describing a delay that is over is an orphan on the operator's
  /// worklist, and the worklist is only useful if everything on it is live.
  func clearDelayed(orderId : Types.OrderId) {
    switch (delayedAlerts.get(orderId)) {
      case (?entryId) {
        ignore ErrorQueue.resolve(errorQueue, entryId, Time.now());
        delayedAlerts.remove(orderId);
      };
      case null {};
    };
  };

  /// Audit a blocked mint at most once per order per session.
  func auditDeliveryBlockedOnce(orderId : Types.OrderId, tag : Text, detail : Text) {
    if (deliveryBlockedAudited.contains(orderId)) return;
    deliveryBlockedAudited.add(orderId);
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
  func queueDeliveryError(rail : Types.Rail, kind : ErrorQueue.Kind, detail : Text) : Nat {
    let result = ErrorQueue.add(errorQueue, errorQueueCapacity, rail, kind, detail, Time.now());
    for (victim in result.evicted.values()) {
      if (victim.resolvedAtNs == null) {
        audit("errorQueue.evictedUnresolved", "entry " # victim.id.toText() # ": " # victim.detail);
      };
    };
    result.entry.id;
  };

  /// §5.1 escalation: the mint stopped where the money position is
  /// uncertain. The order goes `#needsReview` — **not** `#abandoned`: the money
  /// position is unknown, so its promise stays held (#30) and a human resolves it
  /// off-chain (inspect ledger/CMC/destination, refund/re-deliver). Only
  /// `abandon_order` ends an order.
  /// #30 PR-A escalation: a reserve delivery whose fate cannot be established.
  ///
  /// Same shape as `escalateStuckMint` and deliberately NOT folded into it — the
  /// queue kinds differ (`#transferUnresolved` survives #36, `#stuckMint` does
  /// not) and so does the operator's question. Here it is "did this transfer
  /// land?", answerable from the cycles ledger by the order id in the memo.
  ///
  /// ── EVERY route to `#needsReview` on the delivery path, because the count is
  /// ── claimed elsewhere and a census beats a claim ─────────────────────────────
  ///
  /// **Unknown money position** — "we can no longer ask safely", the only kind that
  /// needs a human to establish anything:
  ///
  ///  1. `#staleIntent` from `Cmc.stageOf`: the intent is past the ledger's ~24 h
  ///     dedup window, so a replay is no longer protected. Reaching it means a
  ///     ~day-long ledger outage with an hourly sweep and buyer kicks hammering it
  ///     throughout — **expected never**, and documented as such rather than as a
  ///     routine branch. (Via `escalateStuckMint`, the `#escalate` stage route.)
  ///  2. The ledger's `#escalate` responses — `#TooOld`, `#BadBurn` — arriving here.
  ///     ⚠️ Not a second cause: `#TooOld` **is** case 1 told to us by the ledger
  ///     instead of derived from our own clock, and `#BadBurn` is meaningless for a
  ///     transfer. Same position, different messenger.
  ///
  /// **Known money position** — no establishing needed, and this is the correction
  /// to a claim of "one trigger" that was too tidy:
  ///
  ///  3. §5.3's 72 h max-wait terminate. It fires on an order that has been `#paid`
  ///     too long *whatever* the reason, including one where **nothing was ever
  ///     sent** — position certain, instruction "refund in the Stripe Dashboard".
  ///     So `#needsReview` is genuinely reachable with the position known, and
  ///     `Cmc.terminationFor` is what distinguishes the cases. Read the reduction's
  ///     claim as scoped to the *unknown-position* triggers, which is what "we can
  ///     no longer ask safely" means; the RUNBOOK's triage is organised by position
  ///     for exactly this reason.
  ///
  /// **Unreachable guard**:
  ///
  ///  4. `journalInconsistent` — the intent's amount exceeds the order's locked
  ///     quantity, which cannot happen because the amount was derived by
  ///     subtracting a fee from that very quantity. ⚠️ If it ever fires, it is NOT
  ///     a counter-example to the reduction: it means `lockedCycles` acquired a
  ///     second writer, which is a much larger problem than one escalated order.
  ///     Escalating rather than guessing a fee on a money path is the point.
  func escalateDelivery(order : Types.Order, stage : Text, detail : Text) {
    ignore tryTransition(order.id, #needsReview);
    let blockIndex = switch (deliveryJournal.get(order.id)) {
      case (?e) e.blockIndex;
      case null null;
    };
    Cmc.patch(deliveryJournal, order.id, { status = ?#needsReview; blockIndex = null; cyclesMinted = null; bumpRetries = false }, Time.now());
    clearDelayed(order.id);
    deliveryBlockedAudited.remove(order.id);
    ignore queueDeliveryError(order.rail, #transferUnresolved({ orderId = order.id; blockIndex }), detail);
    audit("delivery.unresolved", order.id # " [" # stage # "]: " # detail);
  };

  func escalateStuckMint(order : Types.Order, stage : Text, detail : Text) {
    ignore tryTransition(order.id, #needsReview);
    Cmc.patch(deliveryJournal, order.id, { status = ?#needsReview; blockIndex = null; cyclesMinted = null; bumpRetries = false }, Time.now());
    // Before queueing the escalation: any open delay alert for this order says
    // "it delivers on the next sweep", which just stopped being true. Leaving it
    // open would put a false promise on the worklist next to the real problem,
    // and leak its `delayedAlerts` entry forever.
    clearDelayed(order.id);
    // Same reasoning for the once-per-order audit guard: the order is terminal,
    // so nothing will re-audit a mint block for it and keeping the id would only
    // suppress a legitimate line if it were ever re-driven.
    deliveryBlockedAudited.remove(order.id);
    ignore queueDeliveryError(order.rail, #stuckMint({ orderId = order.id; stage }), detail);
    audit("delivery.stuck", order.id # " [" # stage # "]: " # detail);
  };

  /// §5 forward half of mint-to-self-then-forward. The cycles ride the call
  /// from the app balance; a rejected/failed call refunds them to the app
  /// balance — exactly the Type 2 posture (§4.1).
  func forwardCycles(order : Types.Order) : async* { #ok; #failed : Text } {
    try {
      switch (order.destination) {
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
  func driveDelivery(orderId : Types.OrderId) : async* () {
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
                  case (#minting) "transferDelayed"; // LEGACY, dies with #36
                  case (#icpAtCmc) "notifyDelayed"; // LEGACY, dies with #36
                  // ⚠️ The reachable one, and it was called `mintDelayed` while
                  // reporting a DELIVERY delay (#30 PR-C). `#paid` is the only status
                  // that reaches this today.
                  case (_) "deliveryDelayed";
                },
                switch (order.status) {
                  case (#minting) "paid, ICP transfer not yet confirmed past the alert threshold — check the ICP ledger; it resumes on the next sweep";
                  case (#icpAtCmc) "paid, ICP is at the CMC but notify_top_up keeps failing past the alert threshold — check CMC health; the block index is in delivery_journal and notify is idempotent";
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
              let termination = Cmc.terminationFor(order.status, deliveryJournal.get(orderId));
              escalateStuckMint(order, termination.stage, termination.detail);
              clearDelayed(orderId);
              deliveryBlockedAudited.remove(orderId);
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
              let termination = Cmc.terminationFor(order.status, deliveryJournal.get(orderId));
              escalateStuckMint(order, termination.stage, termination.detail);
              clearDelayed(orderId);
              deliveryBlockedAudited.remove(orderId);
              return;
            };
          };
        };
        case (_) Cmc.stageOf(order.status, deliveryJournal.get(orderId), Time.now(), Cmc.ledgerDedupWindowNs, maxMintRetries);
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
          let position = Cmc.terminationFor(order.status, deliveryJournal.get(orderId));
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
            auditDeliveryBlockedOnce(orderId, "mint.rateFetchFailed", orderId # ": " # e.message());
            return; // stays #paid; the next sweep retries
          };
          let ?permyriad = Cmc.freshCmcRate(rate.data, Time.now(), Cmc.cmcRateMaxAgeNs) else {
            auditDeliveryBlockedOnce(orderId, "mint.rateStale", orderId);
            return;
          };
          // §5.3 pre-gate input: the live float balance (also feeds the
          // balance-alert observation).
          let floatE8s = try {
            await icpLedger.icrc1_balance_of({ owner = selfPrincipal(); subaccount = null });
          } catch (e) {
            auditDeliveryBlockedOnce(orderId, "mint.balanceFetchFailed", orderId # ": " # e.message());
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
            auditDeliveryBlockedOnce(orderId, "mint.unpriceable", orderId # ": cannot derive e8s for " # fresh.lockedCycles.toText() # " cycles at " # permyriad.toText() # " permyriad");
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
          ignore Cmc.openEntry(deliveryJournal, minting, intent, Time.now());
          // fall through the loop → #replayTransfer issues the transfer
        };
        case (#replayTransfer(intent)) {
          let result = try { await icpLedger.icrc1_transfer(Cmc.transferArgs(intent)) } catch (e) {
            Cmc.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
            audit("mint.transferFailed", orderId # ": " # e.message());
            return;
          };
          switch (Cmc.interpretTransfer(result)) {
            // LEGACY (ICP mint path): both outcomes are identical here — there is
            // no floor to maintain on the ICP side, so "we debited" and "an earlier
            // attempt debited" call for the same move.
            case (#delivered(block) or #deduplicated(block)) {
              // Progress: allow a future block on this order to be audited again.
              deliveryBlockedAudited.remove(orderId);
              // §5.1 step 2 — block_index + #icpAtCmc in one sync block.
              ignore tryTransition(orderId, #icpAtCmc);
              Cmc.patch(deliveryJournal, orderId, { status = ?#icpAtCmc; blockIndex = ?block; cyclesMinted = null; bumpRetries = false }, Time.now());
              // fall through → #notifyCmc
            };
            case (#retriable(detail)) {
              Cmc.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
              audit("mint.transferRetriable", orderId # ": " # detail);
              return;
            };
            case (#badFee(expected)) {
              // The ICP fee is protocol-wide and fixed; a change is a protocol
              // event, not something to absorb. Same verdict this had before #30
              // split the case out — only now the ICP path says so itself
              // instead of the shared table deciding for both ledgers.
              escalateStuckMint(order, "transferRejected", "ledger fee changed: expected " # expected.toText() # " e8s");
              return;
            };
            case (#escalate(detail)) {
              escalateStuckMint(order, "transferRejected", detail);
              return;
            };
          };
        };
        case (#beginDelivery) {
          // #30 PR-A — delivery is ONE transfer out of the reserve.
          //
          // ⚠️ **The fee is READ FROM STATE, and this whole case is now
          // synchronous (#30 PR-B).** It used to `await icrc1_fee()` here; that
          // await is gone because `#BadFee` is the ledger telling us the fee, which
          // makes a stored copy self-correcting. See `cyclesLedgerFee`.
          //
          // ⚠️ **Do not put an await back between here and the transfer issue.** Two
          // things depend on there being none: the post-await re-read this case used
          // to need is gone (nothing can move the order in a synchronous stretch),
          // and `unsettledDeliveries` — the reconcile's quiet-window predicate —
          // relies on an intent never being visible without its transfer having been
          // issued in the same message. Its doc spells that out.
          let fee = cyclesLedgerFee;
          let ?amount = Cmc.deliverableCycles(order.lockedCycles, fee) else {
            // Unreachable under the $10 floor (~7 T cycles against a 100 M fee),
            // and audited rather than silent so that a future move in either
            // number surfaces as a stuck order with a reason instead of a trap.
            //
            // ⚠️ This is the ONE state the stored fee cannot correct itself out of:
            // nothing reaches the ledger, so no `#BadFee` ever arrives to fix the copy,
            // and every order stalls here — audited, loudly, once per order.
            //
            // ⚠️ **There is deliberately no admin lever to reset the fee, and the
            // reason is worth keeping.** One existed briefly (#30 PR-B) and was
            // deleted as self-justifying: reaching this state needs the ledger to
            // report a fee above a whole order's locked quantity — a ~70,000× rise,
            // at which point the rail cannot sell at all and the answer is a code
            // change — or an operator typing a wrong number into the lever itself. A
            // lever whose main reachable failure mode is itself, and whose typo
            // silently shorts buyers, is worse than the stall it fixes. A stalled
            // rail is loud and costs nothing; a shorted buyer is quiet and costs
            // them.
            auditDeliveryBlockedOnce(orderId, "delivery.feeExceedsOrder", orderId # ": fee " # fee.toText() # " >= locked " # order.lockedCycles.toText());
            return;
          };
          let destination = switch (order.destination) {
            case (#cyclesLedgerAccount(account)) account;
          };
          // §5.1 step 1 — the intent commits BEFORE the transfer await, in a
          // sync block. From here the args are frozen and every retry replays
          // them byte-identically; that is what makes two concurrent drivers
          // (the webhook kick and the recovery sweep) safe.
          let intent = Cmc.buildDeliveryIntent(orderId, destination, amount, Time.now());
          ignore Cmc.openEntry(deliveryJournal, order, intent, Time.now());
          // fall through the loop → #replayDelivery issues the transfer
        };
        case (#replayDelivery(intent)) {
          // ⚠️ **The fee is DERIVED from the intent, never re-read here.**
          //
          // An earlier version read `icrc1_fee()` on every replay and a comment
          // claimed the fee is outside the ledger's dedup key, so a replay with a
          // corrected fee was "still byte-identical as far as the ledger is
          // concerned". **Nobody verified that**, and the whole at-most-once
          // guarantee rested on it: if the fee IS in the key, then a transfer that
          // executed, lost its response, and is replayed after a fee change is a
          // DISTINCT transaction — and the buyer is paid twice.
          //
          // So the claim is removed rather than checked. `deliverableCycles` set
          // `amount = lockedCycles - fee`, which means the fee it used is
          // recoverable exactly: `lockedCycles - amount`. A replay therefore
          // reproduces the original args **bit for bit**, and it does not matter
          // what the ledger's dedup key contains.
          //
          // ⚠️ **NO TEST CAN CATCH A REGRESSION HERE — verified by mutation.**
          // Re-reading the fee on this line passed every Motoko assertion and the
          // whole PocketIC suite, because the unit tests pin the *arithmetic*
          // (`test/cmc.test.mo`) and the integration suite runs against a real ledger
          // whose fee never moves. (#30 PR-B then deleted `icrc1_fee` from the ledger's
          // service type entirely, so the mutation no longer even compiles — the
          // strongest form of this guard, and the reason to keep it that way.) The failure
          // needs a fee change inside the 24 h dedup window, which nothing here
          // can arrange. Same class as #33's transform/consensus gap: the comment
          // is the guard, so do not re-read the fee on this path.
          let fee : Nat = if (order.lockedCycles >= intent.amountE8s) {
            order.lockedCycles - intent.amountE8s : Nat;
          } else {
            // Unreachable: the amount was derived by subtracting a fee from this
            // very quantity. Escalating beats guessing a fee on a money path.
            escalateDelivery(order, "journalInconsistent", "delivery intent amount " # intent.amountE8s.toText() # " exceeds the order's locked " # order.lockedCycles.toText() # " — the fee cannot be recovered; establish the transfer's fate on the cycles ledger before re-sending");
            return;
          };
          // ── Rule 2 (#30 PR-B): the floor drops when the transfer is ISSUED ──
          //
          // ⚠️ Not when it settles, and by `amount + fee` — the figure actually
          // being debited — rather than `lockedCycles` unconditionally, because the
          // `#BadFee` re-issue below debits `locked + delta`.
          //
          // The only way the balance can surprise us downward is one of OUR
          // transfers landing without us learning it did: our reply callback traps,
          // so the ledger's debit stands while the journal patch rolls back. (A
          // controlled upgrade cannot do this — `stop_canister` drains outstanding
          // callbacks before the canister reaches `Stopped`, which is why
          // `#ambiguousForward` was unreachable via the documented procedure.)
          // Assuming the debit now makes that case exact instead of optimistic.
          let debited = intent.amountE8s + fee;
          reserveFloor := Reserve.floorAfterOutflow(reserveFloor, debited);
          outflowsIssued += 1;
          let result = try { await cyclesLedger.icrc1_transfer(Cmc.deliveryArgs(intent, fee)) } catch (e) {
            // ⚠️ The floor is NOT credited back. A call that failed without a reply
            // tells us nothing about whether the ledger acted, and rule 2 exists to
            // be pessimistic about exactly that. A reconcile heals it if the
            // transfer never happened.
            Cmc.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
            audit("delivery.transferFailed", orderId # ": " # e.message());
            return;
          };
          switch (Cmc.interpretTransfer(result)) {
            // ⚠️ **`#deduplicated` credits the floor back; `#delivered` does not.**
            // Rule 2 decremented the floor when this call was issued. A fresh block
            // means this call really debited, so the decrement stands. A duplicate
            // means an EARLIER attempt debited — and that attempt's own decrement is
            // still standing, because a reply-callback trap rolls back the journal
            // patch but not the issuing message's decrement. So the replay sequence
            // nets to exactly one decrement per real execution. Crediting on both
            // arms would refund a real debit (optimistic); crediting on neither
            // would under-count every healed replay by a whole order.
            case (#deduplicated(block)) {
              reserveFloor += debited;
              deliveryBlockedAudited.remove(orderId);
              ignore tryTransition(orderId, #delivered);
              Cmc.patch(deliveryJournal, orderId, { status = ?#delivered; blockIndex = ?block; cyclesMinted = ?intent.amountE8s; bumpRetries = false }, Time.now());
              clearDelayed(orderId);
              audit("delivery.deduplicated", orderId # ": ledger block " # block.toText() # " was already ours; floor credited back " # debited.toText());
              return;
            };
            case (#delivered(block)) {
              deliveryBlockedAudited.remove(orderId);
              // Block + `#delivered` in ONE sync block, so the pair cannot disagree.
              ignore tryTransition(orderId, #delivered);
              Cmc.patch(deliveryJournal, orderId, { status = ?#delivered; blockIndex = ?block; cyclesMinted = ?intent.amountE8s; bumpRetries = false }, Time.now());
              clearDelayed(orderId);
              audit("delivery.sent", orderId # ": " # intent.amountE8s.toText() # " cycles, ledger block " # block.toText());
              return;
            };
            case (#badFee(expected)) {
              // The reserve absorbs a risen fee; the buyer is never shorted, so
              // the intent's AMOUNT is untouched — only the fee we pass.
              //
              // ⚠️ **Re-issued HERE, in the same message, rather than left to the
              // next sweep.** The fee is derived from the intent, so a later replay
              // derives the same rejected fee and bounces again — and since #30 PR-B
              // deleted the retry cap on this path, "again" means every sweep until
              // the 72 h max-wait, not until a counter runs out. Correcting in-message
              // is what makes the loop terminate. Changing the fee is safe precisely
              // because `#BadFee` is *definitive*: the ledger did not execute, so this
              // is a first attempt with corrected args, not a replay of something that
              // might already have happened.
              //
              // ⚠️ The reserve then drops by `lockedCycles + delta` while #30's
              // tally drops by `lockedCycles`, so `available` drifts down by the
              // delta. Fractions of a fee, erring conservative — but the "exactly
              // invariant under delivery" claim holds only while the fee is
              // unchanged, so do not read that small drift as a bug.
              // ⚠️ **Learn the fee, for every LATER order (#30 PR-B).** This arm is
              // the only place the ledger tells us its fee, now that delivery does not
              // read it. Persisting here is what bounds the cost of a stale copy to a
              // single rejected call: without it, every order after a fee change would
              // pay the same round trip.
              //
              // It does NOT change this order's intent — the amount is committed and
              // rebuilding it is the double-pay this path exists to avoid.
              cyclesLedgerFee := expected;
              audit("delivery.feeChanged", orderId # ": ledger expects " # expected.toText() # " (intent implies " # fee.toText() # "); reserve absorbs the difference, and " # expected.toText() # " is now the stored fee");
              // ── Rule 3 (#30 PR-B): a DEFINITIVE rejection credits the floor back ──
              // `#BadFee` means the ledger processed the call and refused it, so
              // nothing moved and rule 2's decrement was not a real debit. Credit it
              // and re-decrement for what the corrected attempt will actually take.
              // ⚠️ If the re-issue then fails without a reply, the LARGER decrement
              // stands — correctly pessimistic.
              reserveFloor += debited;
              let reDebited = intent.amountE8s + expected;
              reserveFloor := Reserve.floorAfterOutflow(reserveFloor, reDebited);
              outflowsIssued += 1;
              let retried = try {
                await cyclesLedger.icrc1_transfer(Cmc.deliveryArgs(intent, expected));
              } catch (e) {
                Cmc.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
                audit("delivery.transferFailed", orderId # " (after fee correction): " # e.message());
                return;
              };
              switch (Cmc.interpretTransfer(retried)) {
                case (#deduplicated(block)) {
                  // An earlier attempt had already landed: this one moved nothing.
                  reserveFloor += reDebited;
                  deliveryBlockedAudited.remove(orderId);
                  ignore tryTransition(orderId, #delivered);
                  Cmc.patch(deliveryJournal, orderId, { status = ?#delivered; blockIndex = ?block; cyclesMinted = ?intent.amountE8s; bumpRetries = false }, Time.now());
                  clearDelayed(orderId);
                  audit("delivery.deduplicated", orderId # ": block " # block.toText() # " after fee correction; floor credited back");
                  return;
                };
                case (#delivered(block)) {
                  deliveryBlockedAudited.remove(orderId);
                  ignore tryTransition(orderId, #delivered);
                  Cmc.patch(deliveryJournal, orderId, { status = ?#delivered; blockIndex = ?block; cyclesMinted = ?intent.amountE8s; bumpRetries = false }, Time.now());
                  clearDelayed(orderId);
                  audit("delivery.sent", orderId # ": " # intent.amountE8s.toText() # " cycles at the corrected fee, ledger block " # block.toText());
                  return;
                };
                case (_) {
                  // One correction attempt per pass, no loop. If the fee moved
                  // again mid-flight the next sweep starts over from the derived
                  // fee — which is still the byte-identical replay, so the
                  // at-most-once guarantee is never traded for convergence.
                  Cmc.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
                  audit("delivery.retriable", orderId # ": fee correction to " # expected.toText() # " did not settle; retrying next sweep");
                  return;
                };
              };
            };
            case (#retriable(detail)) {
              // ── Rule 3: definitive rejection, so credit the floor back ──
              // Every `#retriable` case is a ledger *response* — `#InsufficientFunds`,
              // `#TemporarilyUnavailable`, `#CreatedInFuture`, `#GenericError`. The
              // ledger processed the call and declined it, so nothing moved and rule
              // 2's decrement was not a debit. (Contrast the `catch` arm above: no
              // reply means no knowledge, so that decrement stands.)
              reserveFloor += debited;
              // `#InsufficientFunds` should be unreachable — the gate reserved this
              // quantity — and if it does fire, the floor and the ledger disagree.
              // Check `reserve_status.tallySaturations` and the last reconcile before
              // hunting a fee delta.
              Cmc.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
              audit("delivery.retriable", orderId # ": " # detail);
              return;
            };
            case (#escalate(detail)) {
              // ── Rule 3, and the framing that stops a future "fix" ──
              //
              // The accounting is **strictly per attempt**. `#TooOld` and `#BadBurn`
              // are ledger responses refusing *this* call, so crediting *this*
              // attempt's decrement is exact — and it says nothing about an earlier
              // attempt, whose decrement correctly stands.
              //
              // ⚠️ That standing decrement is **not a leak**. It is the floor-side
              // expression of the same unknown that parks the order at
              // `#needsReview`: the money position is unknown, so the floor assumes
              // the debit until a human establishes otherwise, and a quiet adopt
              // eventually absorbs whichever way it went. Do not "fix" the apparent
              // asymmetry by also crediting the original attempt — that is the
              // optimistic direction.
              reserveFloor += debited;
              escalateDelivery(order, "transferRejected", detail);
              return;
            };
          };
        };
        case (#finishDelivery(block)) {
          // The transfer landed and the transition did not — unreachable today
          // (both commit in one sync block), handled so a future regression
          // degrades to something resumable rather than to a stuck paid order
          // whose buyer already has their cycles.
          ignore tryTransition(orderId, #delivered);
          Cmc.patch(deliveryJournal, orderId, { status = ?#delivered; blockIndex = ?block; cyclesMinted = null; bumpRetries = false }, Time.now());
          clearDelayed(orderId);
          audit("delivery.healed", orderId # ": block " # block.toText() # " was recorded but the order had not moved");
          return;
        };
        case (#notifyCmc(block)) {
          // Heal the (today unreachable) #minting-with-block combination.
          if (order.status == #minting) { ignore tryTransition(orderId, #icpAtCmc) };
          let result = try {
            await cmc.notify_top_up({ block_index = Nat64.fromNat(block); canister_id = selfPrincipal() });
          } catch (e) {
            Cmc.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
            audit("mint.notifyFailed", orderId # ": " # e.message());
            return;
          };
          switch (Cmc.interpretNotify(result)) {
            case (#minted(cycles)) {
              // Pre-forward marker: commits before the forward await. If we
              // die mid-forward, stageOf answers #ambiguousForward and the
              // operator checks the destination — at-most-once delivery,
              // never an auto-double-forward.
              Cmc.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesMinted = ?cycles; bumpRetries = false }, Time.now());
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
              Cmc.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, Time.now());
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
              Cmc.patch(deliveryJournal, orderId, { status = ?#delivered; blockIndex = null; cyclesMinted = null; bumpRetries = false }, Time.now());
              clearDelayed(orderId);
              audit("mint.delivered", orderId # ": " # order.lockedCycles.toText() # " cycles");
            };
            case (#failed(detail)) {
              // §4.1 Type 2: the failed deposit refunded the cycles to the
              // app balance — minted money exists, delivery didn't happen.
              ignore tryTransition(orderId, #needsReview);
              Cmc.patch(deliveryJournal, orderId, { status = ?#needsReview; blockIndex = null; cyclesMinted = null; bumpRetries = false }, Time.now());
              // Same reason as escalateStuckMint: the delay is over, badly.
              clearDelayed(orderId);
              ignore queueDeliveryError(order.rail, #undeliverable({ orderId; cycles = order.lockedCycles }), detail);
              audit("mint.undeliverable", orderId # ": " # detail);
            };
          };
          return;
        };
      };
    };
  };

  /// Single-flight wrapper around the driver.
  func processDelivery(orderId : Types.OrderId) : async* () {
    if (deliveriesInFlight.contains(orderId)) return;
    deliveriesInFlight.add(orderId);
    try { await* driveDelivery(orderId) } finally { deliveriesInFlight.remove(orderId) };
  };

  /// Sweep every order with money-out work pending (Recovery.isSweepable:
  /// #paid/#minting/#icpAtCmc/#awaitingTreasury — the §5.3 hold retries
  /// until refill or max-wait) through the driver. Kicked after webhook
  /// ingestion; the §5.2 recovery timer sweeps it on a cadence.
  func sweepDeliverable() : async* Nat {
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
      await* processDelivery(id);
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

  /// Manual delivery kick — **admin, or the order's own owner** (#30 PR-B).
  ///
  /// Safe to spam by construction: every step is journalled, deduplicated,
  /// idempotent and single-flighted, which is what makes it safe to widen. It does
  /// exactly the right thing for a buyer whose delivery is stuck — replay the stored
  /// intent, `#Duplicate` recovers the block — so a page refresh heals their order in
  /// seconds instead of waiting up to a sweep interval.
  ///
  /// ⚠️ **Owner-scoped, not public.** `getOwned` is the guard, so a caller can only
  /// kick their OWN order. The DoS question is real but bounded: one order per kick,
  /// serialised by `deliveriesInFlight`, on an order they had to pay real money to
  /// create — a self-funding attack at the purchase floor. Contrast scenario 20's
  /// property, which is about *unauthenticated* traffic triggering a sweep over
  /// **every** order; that is a different shape and stays refused.
  ///
  /// ⚠️ **This does not replace the recovery sweep, and must not be read as making
  /// it optional.** Two different jobs: the sweep is the *guarantee* — we took the
  /// money, so we deliver whether or not the buyer ever comes back — and this is the
  /// *latency fix*. A UI-only retry would make fulfilling an obligation depend on the
  /// buyer returning, and whoever closed the tab is exactly who most needs us to
  /// finish.
  ///
  /// An admin kick is audited (it is an ops action on someone else's order); an owner
  /// kicking their own is not, or a refresh loop would fill the ring buffer with
  /// lines that say nothing.
  public shared ({ caller }) func process_order(id : Types.OrderId) : async Result.Result<Types.Order, ProcessOrderError> {
    let isAdmin = Auth.checkAdmin(caller, Principal.isController).isOk();
    if (isAdmin) {
      auditAdmin(caller, "mint.manualKick", id);
    } else {
      // Not an admin, so this must be the owner's own order. `getOwned` answers
      // "not found" for someone else's, which is also the right answer to give:
      // whether an id exists is not a stranger's business. No separate anonymous
      // check is needed — `create_order` refuses the anonymous principal, so it
      // owns no order and every id answers `#notFound` for it.
      if (Orders.getOwned(orderStore, id, caller) == null) return #err(#notFound);
    };
    if (Orders.get(orderStore, id) == null) return #err(#notFound);
    if (deliveriesInFlight.contains(id)) return #err(#inFlight);
    await* processDelivery(id);
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

  /// Reconcile the floor against the ledger (#30 PR-B) — **rule 1 of three**.
  ///
  /// This is where a top-up becomes sellable: the floor only ever learns about
  /// incoming cycles by looking. Called by the recovery sweep so drift is bounded
  /// in time, and exposed to the operator so funding does not wait for a tick.
  ///
  /// ⚠️ **A shortfall here is an invariant breach, not a surprise to absorb.** The
  /// ledger holding LESS than the floor says would mean an outflow this canister
  /// did not cause — and per `Reserve.mo`'s asymmetry that cannot happen (no
  /// allowance exists, `withdraw` is owner-only and unused). It is audited loudly
  /// and the truth is adopted anyway: continuing to sell against a bound the ledger
  /// contradicts is the one thing worse than under-selling.
  /// Deliveries that may still respond: a journalled intent, no recorded block, on
  /// an order that is still `#paid`.
  ///
  /// ⚠️ **The `#paid` clause is load-bearing, and leaving it out froze the reserve.**
  /// An escalated order keeps exactly the intent-without-block shape *forever* —
  /// `escalateDelivery` patches the status and leaves `blockIndex` null, and
  /// resolution happens off-chain on the queue entry, touching nothing in the
  /// journal. Without the clause, **one escalation makes the quiet window
  /// unsatisfiable for the life of the canister**: every reconcile skips, every
  /// `refresh_reserve` skips, and top-ups silently stop registering. Pessimistic,
  /// but operationally it reads as the rail slowly closing with no lever.
  ///
  /// Excluding escalated orders is sound because **they have no outstanding
  /// callback.** Escalation is decided either from `stageOf` at the top of the drive
  /// loop (no call in the air) or after a response has already arrived — never with
  /// one in flight. And their pessimism is not lost: `Orders.promised` still holds
  /// their promise, which is exactly what `#needsReview` is for, and the standing
  /// decrement from their issue is absorbed when a quiet adopt takes the ledger's
  /// truth.
  ///
  /// ⚠️ Still a conservative SUPERSET of in-flight for live orders, which is what
  /// makes it usable: what it counts is "an intent exists and no block is recorded",
  /// which includes the sweep-to-sweep gap after a retriable failure, when nothing
  /// is in the air at all. Counting those costs a skipped reconcile, which is free.
  ///
  /// The direction that would break the reconcile is the reverse — an outflow in
  /// flight with no intent to see — and it cannot happen, because `openEntry` commits
  /// the intent in a synchronous block before any issue and the `#BadFee` re-issue
  /// runs under an existing one.
  ///
  /// ⚠️ **That soundness is a property of there being no await between the intent
  /// write and the transfer issue, and nothing in the type system enforces it.**
  /// #30 PR-B removed the one await that used to sit in that stretch (`icrc1_fee`,
  /// now a stored value), which is why the two are adjacent today. Reintroduce an
  /// await there and a reconcile can adopt a balance while a transfer it cannot see
  /// is in flight. This comment is the guard.
  /// ⚠️ **It counts a delivery PARKED BETWEEN RETRIES, not only one in flight**, and
  /// that is deliberate: a transfer issued before a balance read can land after it,
  /// and nothing in the journal distinguishes "issued and awaiting a reply" from
  /// "failed and waiting for the next sweep". Tracking true in-flight state would
  /// need a counter incremented before the await, which leaks upward for good if a
  /// reply callback ever traps — trading a bounded pessimism for an unbounded one.
  ///
  /// The cost is therefore: while any delivery is retrying, a top-up is not adopted,
  /// so **new sales** are refused against cycles the ledger already holds. Bounded
  /// by the same ~24 h fuse (the intent goes stale, the order escalates, the entry
  /// leaves this set), and it does **not** block delivery itself — deliveries never
  /// consult the floor. So the one case that looks like a deadlock is not one: a dry
  /// reserve makes deliveries fail with `#InsufficientFunds`, the operator tops up,
  /// the retry succeeds *because the ledger has the cycles regardless of our floor*,
  /// the entry settles, and the next reconcile adopts. The remaining pessimistic
  /// case is a ledger outage — where refusing to sell is the correct posture anyway.
  ///
  /// ⚠️ There is deliberately **no force flag** on `refresh_reserve`. Adopting
  /// across an unsettled delivery is the exact bug this predicate exists to prevent,
  /// so a lever for it would be a lever for the bug.
  ///
  /// ⚠️ **`entry.status` is the JOURNAL's copy of the order's status, and this
  /// predicate is the only thing that reads it.** `Cmc.openEntry` used to hardcode
  /// `#minting`, which made this match nothing at all and quietly disabled the quiet
  /// window — see the comment there. If it ever stops recording the order's real
  /// status, this silently returns 0 again and the reserve floor becomes adoptable
  /// across an in-flight transfer. `test/cmc.test.mo` pins the coupling.
  func unsettledDelivery(entry : Types.JournalEntry) : Bool {
    entry.status == #paid and entry.transferIntent != null and entry.blockIndex == null;
  };

  func unsettledDeliveries() : Nat {
    var n = 0;
    for ((_, entry) in deliveryJournal.entries()) {
      if (unsettledDelivery(entry)) n += 1;
    };
    n;
  };

  /// Every delivery with money-out work outstanding, right now (admin).
  ///
  /// **The immediate answer to "is a delivery failing?", which nothing else gave.**
  /// The error queue is the worklist and it self-clears correctly — a
  /// `#deliveryDelayed` alert resolves on delivery *or* escalation — but it does not
  /// open until the 2 h alert threshold, and a delivery taking a sweep or two is
  /// normal, so lowering that threshold would file worklist entries for orders that
  /// deliver themselves. This closes the two-hour blind window without touching the
  /// queue's meaning.
  ///
  /// **It self-clears by construction**, which is the property that makes it usable
  /// as a dashboard: an entry leaves this set the moment delivery lands, because
  /// landing records the block and moves the status. There is no "resolve" step to
  /// forget, and a successful `process_order` empties it for that order immediately.
  ///
  /// Read `retries` as "how many times this has already failed" — `0` is an order in
  /// its first attempt, which is not a problem yet.
  ///
  /// ⚠️ **Admin, and O(journal) — those two facts belong together.** It scans every
  /// order ever created, so a public version would let an unauthenticated caller make
  /// this canister scan its whole history for free. That is also why none of it went
  /// into `reserve_status`, which is public and O(1) on purpose.
  ///
  /// ⚠️ The subset with `status = #paid` is **exactly** the reconcile's in-flight
  /// predicate (`unsettledDelivery`), so this is also how "the reserve reconcile keeps
  /// skipping" gets diagnosed. `#needsReview` entries are included because an
  /// operator asking "what is wrong right now" wants them, but they are deliberately
  /// NOT in the reconcile's predicate — see `unsettledDeliveries`.
  public shared query ({ caller }) func pending_deliveries() : async [Types.JournalEntry] {
    requireAdmin(caller);
    let out = List.empty<Types.JournalEntry>();
    for ((_, entry) in deliveryJournal.entries()) {
      if (entry.blockIndex == null and (unsettledDelivery(entry) or entry.status == #needsReview)) {
        out.add(entry);
      };
    };
    out.toArray();
  };

  /// ⚠️ `quiet` must mean "no outflow could have moved the balance between the read
  /// and this call" — see `Reserve.adoptObservation`, and `refresh_reserve` for how
  /// it is established. Passing `true` loosely reintroduces the bug this design
  /// exists to remove.
  func reconcileReserve(observed : Nat, quiet : Bool) {
    let adopted = Reserve.adoptObservation(reserveFloor, observed, quiet);
    if (not adopted.adopted) {
      audit("reserve.reconcileSkipped", "deliveries were in flight across the balance read; keeping the maintained floor of " # reserveFloor.toText());
      return;
    };
    if (adopted.unexplainedShortfall > 0) {
      audit(
        "reserve.unexplainedShortfall",
        "ledger holds " # observed.toText() # " but the floor said at least "
        # reserveFloor.toText() # " — short by " # adopted.unexplainedShortfall.toText()
        # ". No outflow but ours is possible, so treat this as a bookkeeping breach and reconcile before selling more.",
      );
    };
    reserveFloor := adopted.floor;
    reserveObservedAtNs := ?Time.now();
  };

  /// Read the ledger balance and reconcile the floor against it — the ONE place
  /// that establishes the quiet window, so the operator lever and the sweep cannot
  /// drift apart on the property the whole design rests on.
  ///
  /// ⚠️ **The quiet window is established across the await, not assumed.** Nothing
  /// unsettled before, nothing unsettled after, and no transfer issued in between —
  /// then and only then does the observed balance bound the current one. Any of the
  /// three failing means an outflow may have moved the balance in the gap, and
  /// adopting would erase rule 2's decrement.
  func observeReserve() : async* Nat {
    let unsettledBefore = unsettledDeliveries();
    let issuedBefore = outflowsIssued;
    let observed = await cyclesLedger.icrc1_balance_of(Cmc.reserveAccount(selfPrincipal()));
    let quiet = unsettledBefore == 0 and unsettledDeliveries() == 0 and outflowsIssued == issuedBefore;
    reconcileReserve(observed, quiet);
    observed;
  };

  /// On-demand reserve refresh (admin — a public one would let anyone spend our
  /// cycles on ledger calls). The sweep does this hourly; this is the lever for
  /// right after `icp cycles transfer`, so a top-up is sellable immediately.
  ///
  /// ⚠️ **`scripts/local-dev-seed.sh` and RUNBOOK's top-up step call this**, and
  /// forgetting it is invisible to every typecheck: the floor stays at zero, so the
  /// gateway refuses every sale against a fully funded reserve and nothing anywhere
  /// says why.
  public shared ({ caller }) func refresh_reserve() : async Nat {
    requireAdmin(caller);
    await* observeReserve();
  };

  /// Reserve solvency and order counters, public (#30 PR-B).
  ///
  /// **The three figures that decide whether a sale is admitted, in one answer**,
  /// because "the ledger says 100 T and the gateway will sell 0" has to be
  /// diagnosable at a glance rather than by inference:
  ///
  ///   `reserveFloor` − `promisedTotal` = `availableToSell`
  ///
  /// ⚠️ **`reserveFloor` is a maintained lower BOUND, not the balance.** The actual
  /// reserve lives on the cycles ledger, where `icrc1_balance_of` is a free query
  /// anyone can call — so this canister does not mirror it. What it reports is the
  /// bound it will actually sell against, which is the number that explains a
  /// refusal. A floor far below the ledger's balance means nothing has reconciled
  /// since the last top-up: `reserveObservedAtNs` says when it last did, and
  /// `refresh_reserve` is the lever. Two earlier drafts of #30 cached the balance
  /// here instead and were superseded — caching it invents a staleness class over a
  /// number the caller can read from the source.
  ///
  /// ⚠️ These are **uncertified query answers, and `create_order` does not consult
  /// them.** The gate decides solvency from the same state synchronously, inside the
  /// order-creating message. This surface is for operators, monitoring and the
  /// frontend; nothing reads it to decide anything, so it cannot be raced into an
  /// over-sale.
  ///
  /// The four order counters were `order_stats` (and `retention_status` before that,
  /// until #33 deleted retention). Folded in here as #30 planned: `openOrders`
  /// climbing while deliveries do not is the signature of order-creation abuse, and
  /// its lever is `Gate.maxOpenOrdersPerPrincipal`; `totalOrders` and
  /// `paidIntentsIndexed` should grow together, since a divergence means an index and
  /// its records disagree.
  public query func reserve_status() : async {
    reserveFloor : Nat;
    promisedTotal : Nat;
    availableToSell : Nat;
    reserveObservedAtNs : ?Int;
    cyclesLedgerFee : Nat;
    tallySaturations : Nat;
    reserveAccount : Types.Account;
    canisterCycles : Nat;
    minCanisterCycles : Nat;
    openOrders : Nat;
    expiredOrders : Nat;
    totalOrders : Nat;
    paidIntentsIndexed : Nat;
  } {
    {
      reserveFloor;
      /// Null means **no reconcile has ever run**, which is also why a freshly
      /// installed canister sells nothing until the operator refreshes: the floor
      /// starts at zero and only a look at the ledger can raise it.
      reserveObservedAtNs;
      /// Exactly what the gate computes, from the same two numbers, so a refused
      /// sale and this figure can never tell different stories.
      availableToSell = Reserve.available(reserveFloor, Orders.promised(orderStore));
      /// The fee the NEXT delivery will use, and the only way to see that `#BadFee`
      /// self-correction actually happened (#30 PR-B). ⚠️ Nothing but the ledger
      /// writes it — there is deliberately no admin lever — so a value at or above an
      /// order's locked quantity stalls delivery loudly and the answer is a redeploy;
      /// at that fee the rail cannot sell anyway.
      cyclesLedgerFee;
      // O(1), same reasoning as treasury_status.
      openOrders = Orders.countOf(orderStore, #created);
      expiredOrders = Orders.countOf(orderStore, #expired);
      totalOrders = orderStore.orders.size();
      paidIntentsIndexed = paidIntents.size();
      promisedTotal = Orders.promised(orderStore);
      /// ⚠️ **Any non-zero value means the tally has diverged.** A saturation is a
      /// release asking to remove more than was held, so it says the tally was
      /// already wrong *before* that order got there — strictly worse than a fault
      /// in the order being released. The daily recount reports drift's SIZE; this
      /// reports its EXISTENCE, same day. RUNBOOK §9 alerts on any increment.
      tallySaturations = orderStore.tallySaturations;
      // Named so an operator (or the frontend) can point a ledger query at the
      // right account without reconstructing it.
      reserveAccount = Cmc.reserveAccount(selfPrincipal());
      // The gas half, which is a different pot from the reserve: what the canister
      // spends to run, gated by `minCanisterCycles`.
      canisterCycles = Cycles.balance();
      minCanisterCycles = gateConfig.minCanisterCycles;
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

  /// Let a buyer give up on their own unpaid order (owner-scoped).
  ///
  /// `Gate.maxOpenOrdersPerPrincipal` counts `#created` orders, and its refusal
  /// tells the user to pay or abandon one — advice they could not follow without
  /// this: `abandon_order` is admin-only and only accepts *paid* orders. A buyer
  /// who opened the cap's worth of checkouts and completed none would be locked
  /// out until their sessions expired.
  ///
  /// ⚠️ This paragraph said the order is marked `#expired` and that a payment
  /// arriving afterwards is **still honoured**, because `#expired` was payable.
  /// Both halves stopped being true and the text did not follow: #34 gave the
  /// buyer's own decision the distinct `#cancelled` state, and deleted
  /// `#expired → #paid` along with it. Nothing is stranded, but the reason is
  /// now the opposite one — the session is expired on Stripe BEFORE the order
  /// moves, so an in-flight payment either wins that race and the order is not
  /// cancelled at all, or it cannot start. See the ordering note in the body.
  ///
  /// No error-queue entry: nothing is owed. The record and the audit line are the
  /// trail, and queueing an obligation for an order where no money moved is
  /// exactly the orphan state the queue must not accumulate.
  public shared ({ caller }) func cancel_order(id : Types.OrderId) : async Result.Result<Types.Order, Text> {
    let ?order = Orders.getOwned(orderStore, id, caller) else return #err("no order " # id);
    switch (order.status) {
      case (#created) {};
      case (#cancelled) return #ok(order); // idempotent: already given up on
      case (status) {
        return #err(
          "order " # id # " is " # Types.statusToText(status)
          # "; a paid order cannot be cancelled — it will deliver, or contact support"
        );
      };
    };
    // `#cancelled`, not `#expired`: the buyer's own decision is a distinct state,
    // so a reload shows them "Cancelled" rather than telling them their order
    // expired (#34). And `#cancelled → #paid` is absent from the matrix, which is
    // what makes a cancelled order unpayable by construction rather than by a
    // runtime check somebody has to remember.
    //
    // ── Atomic with Stripe (#33, option B) ──────────────────────────────────
    // Expire the session FIRST, then mark the order. Nothing is ever *half*
    // cancelled: if the session is still live on Stripe, the order is not
    // cancelled. That ordering is the whole reason `#cancelled → #paid` never
    // needs to be legal — Stripe guarantees a session ends in exactly one of
    // completed/expired, so a successful expire proves no payment completed.
    //
    // An earlier draft made this outcall non-fatal (audit and return success
    // anyway). Rejected: it recreates the half-cancelled state — order says
    // cancelled, session still charges the buyer — that `#cancelled` exists to
    // eliminate.
    switch (order.stripeSessionId) {
      case null {
        // No session ever existed, so no URL left the canister and the order is
        // provably unpayable. This is the residue case: a trap or upgrade landed
        // between the order commit and the outcall response, so the in-call
        // failure handler never ran. Cancel with no outcall.
        audit("order.cancelledSessionless", id # " had no session; cancelled without an outcall");
      };
      case (?sessionId) {
        switch (await* expireStripeSession(sessionId)) {
          case (#ok) {};
          case (#notOpen) {
            // Two causes and we must not guess between them from our clock: the
            // session completed (the payment won the race) or it expired already.
            // Change nothing and let the incoming `checkout.session.completed` or
            // `checkout.session.expired` resolve it.
            audit("order.cancelRaced", id # ": session " # sessionId # " is no longer open");
            return #err(
              "order " # id # " is already settled or has expired — refresh the page"
            );
          };
          case (#failed(detail)) {
            // The order stays payable and uncancelled, which is the safe side:
            // the buyer can retry, or it expires on its own.
            audit("order.cancelFailed", id # ": " # detail);
            return #err(
              "could not reach Stripe to cancel order " # id # " — try again, or it expires on its own"
            );
          };
        };
      };
    };
    let ?cancelled = tryTransition(id, #cancelled) else {
      return #err("order " # id # " refused the transition to cancelled");
    };
    audit("order.cancelled", id # " cancelled by owner");
    #ok(cancelled);
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
  public shared ({ caller }) func abandon_order(
    id : Types.OrderId,
    reason : Text,
  ) : async Result.Result<Types.Order, Text> {
    requireAdmin(caller);
    let ?order = Orders.get(orderStore, id) else return #err("no order " # id);
    switch (order.status) {
      // `#needsReview` is newly accepted here, and it is the point of splitting
      // `#errorQueue`: an escalated order could not previously be abandoned,
      // because one status meant both "promise held" and "promise released" and
      // the transition was to itself (#34).
      case (#paid or #awaitingTreasury or #needsReview) {};
      case (status) {
        return #err("order " # id # " is " # Types.statusToText(status) # "; only a paid, held or under-review order can be abandoned");
      };
    };
    // ── ⚠️ A PAID order with an unsettled delivery cannot be abandoned ────────
    //
    // **Otherwise this lever pays the buyer twice.** The order is `#paid` with a
    // transfer issued and no block recorded, so the money position is UNKNOWN.
    // Abandoning releases the promise and files a refund-by-hand obligation, while
    // the transfer either lands afterwards or has already landed with its reply
    // lost — and after `#abandoned` nothing sweeps the order, so nothing ever
    // discovers which. The buyer keeps the cycles and gets the refund.
    //
    // ⚠️ It is not only a race with a call in flight. The wider case is the one that
    // needs no timing at all: an intent whose transfer executed and whose reply was
    // lost looks exactly like one that never executed, and this lever would decide
    // between them by guessing. **Deciding an unknown money position is precisely
    // what `#needsReview` exists to prevent**, and without this guard
    // `abandon_order` reached the same outcome directly from `#paid`, skipping it.
    //
    // Second symptom, worth knowing for the post-mortem: the late reply patches the
    // journal to `#delivered` while `tryTransition` no-ops against `#abandoned`, so
    // the journal and the order end up contradicting each other.
    //
    // **Bounded, so this is a wait and not a refusal:** the ~24 h dedup fuse moves
    // such an order to `#needsReview` on its own, where abandonment is allowed and
    // the documented procedure is establish-the-fate-first. `#needsReview` is
    // therefore untouched by this guard — escalation implies no outstanding call.
    if (order.status == #paid) {
      switch (deliveryJournal.get(id)) {
        case (?entry) {
          if (unsettledDelivery(entry)) {
            return #err(
              "order " # id # " has a delivery outstanding, so whether its cycles moved is not yet known — abandoning it now would refund a buyer who may already hold them. "
              # "Check `pending_deliveries` for its state. Either it settles (and needs no refund), or the ~24 h dedup window escalates it to needsReview, where the ledger is the source of truth and the order id is in the transfer's memo."
            );
          };
        };
        case null {};
      };
    };
    if (reason.size() == 0) return #err("a reason is required — the audit trail must record why");
    let ?abandoned = tryTransition(id, #abandoned) else {
      return #err("order " # id # " refused the transition to abandoned");
    };
    Cmc.patch(deliveryJournal, id, { status = ?#abandoned; blockIndex = null; cyclesMinted = null; bumpRetries = false }, Time.now());
    clearDelayed(id);
    ignore queueDeliveryError(order.rail, #abandoned({ orderId = id; reason }), "abandoned by operator: " # reason);
    auditAdmin(caller, "order.abandoned", id # ": " # reason);
    #ok(abandoned);
  };

  /// Record that an escalated order's cycles **did** reach the buyer (admin, §7).
  ///
  /// The counterpart to `abandon_order`, and the reason #30 PR-B added the
  /// `#needsReview → #delivered` edge. `#needsReview` means "we could not establish
  /// whether the transfer landed"; when the operator establishes on the cycles
  /// ledger that it did, this is how they say so. Without it their only lever was
  /// `abandon_order`, which files a delivered order as abandoned and audits a refund
  /// that never happened.
  ///
  /// ⚠️ **The block index is required, and it is not decoration.** It is the evidence
  /// that this call is a *finding* rather than a guess, it goes into the journal so
  /// the receipt shows the same proof any other delivered order shows, and demanding
  /// it means the operator has actually looked. The order id is in the transfer's
  /// memo, so the lookup is a search on the ledger, not a reconstruction.
  ///
  /// ⚠️ It moves no money and must not: the cycles are already gone. It also does not
  /// credit the reserve floor back — the floor already assumed the debit when the
  /// transfer was issued (rule 2), and this call is the confirmation that the
  /// assumption was right.
  public shared ({ caller }) func record_delivered(
    id : Types.OrderId,
    blockIndex : Nat,
  ) : async Result.Result<Types.Order, Text> {
    requireAdmin(caller);
    let ?order = Orders.get(orderStore, id) else return #err("no order " # id);
    switch (order.status) {
      case (#needsReview) {};
      case (#delivered) return #ok(order); // idempotent: already recorded
      case (status) {
        return #err(
          "order " # id # " is " # Types.statusToText(status)
          # "; only an under-review order can be recorded as delivered — a live order delivers on its own"
        );
      };
    };
    let ?delivered = tryTransition(id, #delivered) else {
      return #err("order " # id # " refused the transition to delivered");
    };
    Cmc.patch(deliveryJournal, id, { status = ?#delivered; blockIndex = ?blockIndex; cyclesMinted = null; bumpRetries = false }, Time.now());
    clearDelayed(id);
    auditAdmin(caller, "order.recordedDelivered", id # ": operator confirmed cycles-ledger block " # blockIndex.toText());
    #ok(delivered);
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
  /// `delivery_journal` stays admin-only — it carries retries and raw transfer
  /// intents, which are operational rather than the buyer's business.
  public shared query ({ caller }) func receipt(id : Types.OrderId) : async ?Receipt {
    let ?order = Orders.getOwned(orderStore, id, caller) else return null;
    let journal = deliveryJournal.get(id);
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
  public shared query ({ caller }) func delivery_journal(id : Types.OrderId) : async ?Types.JournalEntry {
    requireAdmin(caller);
    deliveryJournal.get(id);
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

  /// How often the sweep reconciles the reserve floor against the cycles ledger.
  ///
  /// Hourly rather than per-sweep because it costs a ledger round trip plus two
  /// journal scans, and because what it detects — an unobserved top-up — is an
  /// operator action that has `refresh_reserve` for immediacy. The cost of the delay
  /// is bounded and one-directional: a floor below the truth under-sells, never over-
  /// sells.
  let reserveReconcileIntervalNs : Nat = 3_600 * 1_000_000_000;

  /// When the reserve reconcile was last *attempted*. Same attempt-vs-success split
  /// as the count reconcile below, for the same reason: `reserveObservedAtNs` records
  /// success, and gating the cadence on that alone would retry a failing (or
  /// perpetually non-quiet) read on every single tick.
  var lastReserveReconcileAttemptNs : Int = 0;

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
  /// is why it is not paged. (The retention sweep WAS paged, for the opposite
  /// reason — it mutated as it went and only had to visit everything eventually.
  /// #33 deleted it; this one stays unpaged deliberately.)
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

  /// The timer job. Correctness against concurrent drivers is processDelivery's
  /// per-order single-flight; this flag only stops sweep pile-up. The
  /// webhook kick deliberately bypasses it — a just-paid order must not
  /// wait a full interval because a background sweep (which enumerated
  /// `pending` before that order turned #paid) was still in flight.
  ///
  /// ⚠️ This is the **§5.2 recovery** timer and it stays. A retention sweep ran
  /// ahead of it until #33; only that went. The two were never the same job —
  /// this one backstops a money-out message that died, which no webhook reports.
  func recoverySweep() : async () {
    if (recoverySweepInFlight) return;
    recoverySweepInFlight := true;
    try {
      // Detached into its own message rather than run inline. It reads the whole
      // order store, so at enough orders it could hit the instruction limit — and
      // inline that trap would take the entire sweep down with it, leaving
      // money-out dead while the reconcile stayed due and trapped again on every
      // tick. A bookkeeping *check* must not be able to stop
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
      let pending = await* sweepDeliverable();
      lastRecoverySweep := ?{ atNs = Time.now(); pending };
      // ── Rule 1 (#30 PR-B): the floor learns about top-ups only by looking ──
      //
      // ⚠️ **After the sweep, and INLINE — both deliberate, and for opposite
      // reasons from the count reconcile above.**
      //
      // *After*, because a quiet window is what makes an observation adoptable, and
      // the sweep is the one thing in this canister that issues transfers. Reading
      // the balance first would race our own deliveries and skip almost every time
      // a sweep had work — the floor would then only ever rise on idle ticks, which
      // is precisely when nobody needs it to.
      //
      // *Inline*, because the detached-message trick the count reconcile uses would
      // put this message's writes and the sweep's deliveries in flight together,
      // recreating the same race. The trap risk it exists to avoid is handled by
      // catching instead: a ledger that will not answer is a skipped reconcile, and
      // the floor it leaves standing is a lower bound, so nothing unsafe follows.
      let now2 = Time.now();
      if (Recovery.reconcileDue(lastReserveReconcileAttemptNs, now2, reserveReconcileIntervalNs)) {
        lastReserveReconcileAttemptNs := now2;
        try { ignore await* observeReserve() } catch (e) {
          audit("reserve.observeFailed", "could not read the reserve balance: " # e.message() # " — the floor stands, so the gateway under-sells until the next attempt");
        };
      };
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
    /// When the RESERVE reconcile was last attempted (#30 PR-B). Its success clock
    /// is `reserve_status.reserveObservedAtNs`, and the two diverging is the one
    /// signal that says "the floor is stale on purpose": either the ledger read is
    /// failing, or every attempt has landed on a non-quiet window. Both under-sell
    /// rather than over-sell, so this is a P3 that explains refusals — not an
    /// incident.
    lastReserveReconcileAttemptNs : Int;
  } {
    {
      intervalNs = recoverySweepIntervalNs;
      lastSweep = lastRecoverySweep;
      sweepInFlight = recoverySweepInFlight;
      lastCountReconcile;
      lastCountReconcileAttemptNs;
      lastReserveReconcileAttemptNs;
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
        ignore async { await* processDelivery(orderId) };
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
