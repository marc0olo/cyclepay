/// Fully on-chain cycles gateway — composition root.
///
/// The module layout this actor composes: Orders.mo, Delivery.mo, Pricing.mo,
/// Reserve.mo, Gate.mo, Problems.mo, Orphans.mo, Auth.mo, Card.mo, Http.mo.
/// Decision record for the `§N` comments: `docs/DESIGN.md`.
import Array "mo:core/Array";
import Problems "Problems";
import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
import Int "mo:core/Int";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
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
import Delivery "Delivery";
import Orphans "Orphans";
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
import Types "Types";

persistent actor CyclesGateway {

  /// §7 secret one of TWO: the Stripe webhook signing key. Plaintext by design,
  /// SEV-SNP posture documented in Secret.mo. Persists across upgrades; rotation
  /// never requires a redeploy.
  let webhookSecret : Secret.Store = Secret.emptyStore();

  /// §7 secret two: the Stripe **API key** that creates Checkout Sessions (#33).
  ///
  /// Same store, same posture, same never-readable-back guarantee. Use a
  /// **restricted key** (`rk_...`) with *Checkout Sessions = Write* and everything else
  /// None: a leaked key at that scope can create sessions that pay us and read sessions
  /// back, which is materially different from one that can also issue refunds.
  /// ⚠️ **Write rather than Read, because both are needed** — the rail creates sessions
  /// and the recovery sweep retrieves one to settle a stranded order (#52). Stripe's
  /// permissions are escalating per resource, so Write is the single level that covers
  /// both. Stripe's
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
  /// floor, per-purchase ceiling. These default to real
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
  /// A test-mode webhook secret provisioned against a canister holding a funded
  /// reserve would deliver real cycles for payments that never happened — the secret
  /// is the only thing separating the two, and provisioning the wrong one is an
  /// ordinary operator slip. Declaring the expectation lets the canister
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
    /// somewhere else. Alert on it (RUNBOOK §8).
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
  /// first would create a permanent `#expired` record for **free**: no cycles are
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
        headers = Session.authHeaders(keyText);
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

  /// `GET /v1/checkout/sessions/{id}` — the read that settles a stranded `#created`
  /// order (#52).
  ///
  /// ⚠️ **`#unauthorized` is its own answer, not folded into `#failed`.** A restricted
  /// key without read on Checkout Sessions 401s on every retrieve, which makes this
  /// whole feature inert *quietly* — the arm audits, the sweep moves on, and the only
  /// symptom is capacity that stays stranded. "Stripe refused the read" and "Stripe is
  /// unreachable" are different operator actions, so they get different audit tags and
  /// different RUNBOOK rows.
  func retrieveStripeSession(sessionId : Text) : async* {
    #ok : Session.Status;
    #unauthorized;
    #failed : Text;
  } {
    let ?apiKey = Secret.get(stripeApiKey) else return #failed("the Stripe API key is not provisioned");
    let ?keyText = apiKey.decodeUtf8() else return #failed("the stored API key is not valid UTF-8");
    let response = try {
      await Call.httpRequest({
        url = Session.retrieveUrl(sessionId);
        method = #get;
        // Larger than the create cap on purpose — see `Session.retrieveMaxResponseBytes`.
        max_response_bytes = ?Session.retrieveMaxResponseBytes;
        body = null;
        headers = Session.authHeaders(keyText);
        transform = ?{ function = transform_stripe_response; context = "" };
        is_replicated = null;
      });
    } catch (e) {
      let kind = Session.classifyFailure(e.message());
      return #failed(Session.failureAdvice(kind) # " [" # e.message() # "]");
    };
    if (response.status == 401 or response.status == 403) return #unauthorized;
    if (response.status != 200) return #failed("Stripe answered " # response.status.toText());
    #ok(Session.classify(response.body));
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
  /// mismatch deliver nothing.)
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
  /// admitting. `Cycles.balance()` is this canister's own **gas**, which is a
  /// different pot from the reserve it sells — solvency is decided separately, and
  /// synchronously, against the maintained floor.
  func gateObservation(caller : Principal) : Gate.Observation {
    {
      openOrders = Orders.openOrderCount(orderStore, caller, Time.now());
      canisterCycles = Cycles.balance();
    };
  };

  /// The §5.3-adjacent admission gate: refuse to *quote* when fulfilment is
  /// already known to be impossible, rather than taking the user's money and
  /// discovering it at delivery time. Audited on refusal — a rail that has quietly
  /// stopped selling is something the operator must be able to see.
  func admit(caller : Principal, usdCents : Nat) : Result.Result<(), Gate.Reason> {
    switch (Gate.admit(gateConfig, gateObservation(caller), usdCents)) {
      case (#ok) #ok;
      case (#err(reason)) {
        noteRefusal(reason);
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
        noteRefusal(reason);
        #err(reason);
      };
      case (#ok) {
        // ⚠️ **The only thing that clears the latch, and the only place it can
        // be cleared correctly.** Reaching here means neither rail-state
        // condition fired. A refusal earlier in `admit` — below the minimum,
        // say — returns before the reserve is ever consulted, so it is not
        // evidence that the reserve recovered; clearing on it would drop the
        // latch and re-announce on the next genuine refusal.
        railStateLatch := Gate.latchAdmission(railStateLatch);
        #ok;
      };
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
        noteRailClosed(e);
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

    // ── The order, held against the reserve floor ────────────────────────────
    //
    // ⚠️ **No ledger call here, and the decision must stay synchronous.**
    // `reserveFloor` is a maintained lower bound moved only by our own outflows
    // (§5.4), so the check and the hold sit in ONE block inside
    // `createOrderWithFreshId` with no await between them. Motoko messages do not
    // interleave except at an await, so whichever block runs second sees the first
    // one's hold. **Splitting them across an await lets two concurrent creates
    // promise the same cycles** — which is what an earlier version did, and no
    // fresher balance read can fix it: an awaited value is historical the moment
    // the continuation resumes.
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
        noteStripeApiFailed("create: " # sessionErrorToText(e));
        return #err(#sessionUnavailable(sessionErrorToText(e)));
      };
      case (#ok(created)) {
        // Stripe answered, so the outcall is working again. This is the ONLY
        // evidence that bears on `#stripeApiFailing` — `latchAdmission` cannot
        // clear it, because admission runs *before* this call and says nothing
        // about it (#37 §2c).
        railStateLatch := Gate.latchStripeApiOk(railStateLatch);
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
  /// The caller's own orders, **paginated** (#38).
  ///
  /// ⚠️ **This was a latent trap on the BUYER path, not an ergonomic wart.** It returned
  /// every order the caller owns, unbounded, and a query response is capped at ~2 MB —
  /// so an oversized read does not degrade, it **traps**. The open-order cap of 1 means
  /// a buyer accumulates them slowly, but nothing bounded it, and nothing drops orders
  /// under #37.
  ///
  /// ⚠️ **Implemented through the same `Orders.page` the admin list uses**, with the
  /// owner filter pinned to the caller. One traversal, one cursor semantics, one place
  /// to get the "visits every match exactly once" property right — rather than a second
  /// pager on the path where a mistake is a buyer's missing receipt.
  public shared query ({ caller }) func list_orders(
    afterId : ?Types.OrderId,
    limit : Nat,
  ) : async Orders.Page {
    Orders.page(orderStore, { Orders.noFilter() with owner = ?caller }, afterId, limit);
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
  /// `set_card_tiers` will reject it and the webhook will refuse to deliver a
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
        case (?true) "true — only live-mode payments deliver";
        case (?false) "false — only test-mode payments deliver";
        case null "unset — either mode delivers";
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
  /// `pricing_status` and `reserve_status` — these are the rules users are held
  /// to, not secrets.
  ///
  /// ⚠️ **One field, and no lifecycle *policy* of ours to add to it.** An order's
  /// deadline is the Stripe session's `expires_at`, which lives on the order rather
  /// than in config, so there is nothing global to report.
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
  /// `reserve_status` already publishes. Answered for the *calling* principal,
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

  /// §4.1 — payments that could not be attributed to any order. Every dollar that
  /// arrives resolves to a delivery or to an obligation, and this list holds the ones
  /// with no order to hang off; the rest live on their order's `problems`.
  let orphanStore : Orphans.Store = Orphans.emptyStore();

  /// §4.2 audit log, unbounded since #37 — operational trail, not a
  /// financial record (orders, their problems and the orphan list are the records of money).
  let auditLog : AuditLog.Log = AuditLog.emptyLog();

  /// Refusal tallies and the rail-state latch (#61).
  ///
  /// ⚠️ **Stable, because they replace an audit line.** These carry the content
  /// of the per-attempt `order.notAdmitted` line that #61 removed, and losing
  /// them on upgrade would lose the volume signal the monitoring rows read.
  var refusalCounts : Gate.RefusalCounts = Gate.noRefusals();
  var railStateLatch : Gate.RailStateLatch = Gate.admitting();

  /// Tally a refusal, and write an audit line **only** on the transition into a
  /// rail-state condition (#61).
  ///
  /// ⚠️ **The one place a refusal is recorded.** It replaced two
  /// `audit("order.notAdmitted", …)` calls, both pre-commit, both reachable for
  /// free — `#amountBelowMin` needs no prior state at all, so one cent from any
  /// fresh principal drove one permanent line per attempt once #37 removes the
  /// ring. The audit log is the only structure here whose growth is not
  /// attacker-priced, which is why this is a counter and not a line.
  func noteRefusal(reason : Gate.Reason) {
    refusalCounts := Gate.countRefusal(refusalCounts, reason);
    let latched = Gate.latchRefusal(railStateLatch, reason);
    railStateLatch := latched.latch;
    if (latched.announce) {
      audit("gate.startedRefusing", Gate.reasonToText(reason));
    };
  };

  /// Which `sessionConfig` failures are rail **state** — a configuration fact
  /// about this gateway rather than anything about the request.
  ///
  /// ⚠️ **Exhaustive on purpose.** `sessionConfig` can only produce the first two
  /// today, but a new `SessionError` must decide whether it is a persistent
  /// configuration state (latch it, announce once) or a transient outcall failure
  /// (do not latch — a transient that latched would be cleared by the next
  /// success anyway, but announcing it as "the rail started refusing" would be a
  /// false report).
  func railClosureCondition(e : SessionError) : ?Gate.RailCondition {
    switch (e) {
      // Either the key and origin are provisioned or they are not.
      case (#railClosed or #originUnset) ?#railClosed;
      // These five come from the outcall in `createStripeSession` and cannot
      // reach `sessionConfig`. If one ever does, it is counted but not
      // announced — a `railClosed` counter climbing while
      // `refusingNow.railClosed` stays false is the tell that this happened.
      case (
        #outcallFailed(_) or #stripeRejected(_) or #unparseableResponse
        or #missingField(_) or #livemodeMismatch(_)
      ) null;
    };
  };

  /// Tally a pre-gate refusal caused by the rail being closed, announcing once
  /// on the way in (#61).
  ///
  /// ⚠️ **This path never reaches `admit`, which is what made it easy to miss.**
  /// `create_order` checks caller, destination, then the RAIL, then tier and
  /// admission — so while the rail is closed, **100% of attempts refuse here** and
  /// a counter set covering only `Gate.Reason` would record nothing. RUNBOOK §1
  /// prescribes provisioning the secrets last, so a freshly deployed gateway sits
  /// in exactly this state by design.
  func noteRailClosed(e : SessionError) {
    refusalCounts := Gate.countRailClosed(refusalCounts);
    switch (railClosureCondition(e)) {
      case (?condition) {
        let latched = Gate.latchCondition(railStateLatch, condition);
        railStateLatch := latched.latch;
        if (latched.announce) {
          audit("gate.startedRefusing", "railClosed: " # sessionErrorToText(e));
        };
      };
      case null {};
    };
  };

  /// Tally a failed session creation, announcing once on the way into the
  /// condition (#37 §2c).
  ///
  /// ⚠️ **Per-attempt before this.** `stripe.sessionFailed` wrote one line per try,
  /// and the reachable driver is not a transient outage — it is a key that is
  /// **present but invalid**, rotated or revoked at Stripe without updating the
  /// canister. `sessionConfig` cannot see that (the secret exists), so every attempt
  /// reaches the outcall, 401s, and files a line. A transient timeout is
  /// self-limiting; a revoked key repeats until `minCanisterCycles` closes the rail.
  ///
  /// ⚠️ **The order-record half of that loop is NOT fixed here.** Each attempt still
  /// commits an order and expires it, and because the record is not `#created` the
  /// open-order cap does not bound it. Committing first is forced — the order id *is*
  /// the `client_reference_id` — so no pre-commit check can cover this branch. A
  /// circuit breaker is deferred behind the evidence #37 §2c asks for; this fixes the
  /// audit half, which is the half that becomes permanent when the ring comes out.
  /// ⚠️ **Takes a DETAIL rather than a `SessionError`, because the callers know
  /// different things.** It used to render `sessionErrorToText(e)`, and the retrieve
  /// path's `#unauthorized` has no honest `SessionError` to pass: `#railClosed` renders
  /// as "the API key is not provisioned", which is exactly wrong — the key is present
  /// and Stripe is refusing it. The remedy differs too (rotate versus provision), so
  /// squeezing three call sites through one enum produced a confident wrong sentence.
  func noteStripeApiFailed(detail : Text) {
    refusalCounts := Gate.countStripeApiFailed(refusalCounts);
    let latched = Gate.latchCondition(railStateLatch, #stripeApiFailing);
    railStateLatch := latched.latch;
    if (latched.announce) {
      audit("gate.startedRefusing", "stripeApiFailing: " # detail);
    };
  };

  /// Built per request rather than held in a transient field: it carries
  /// `maxPurchaseUsdCents` from the live gate config, so a ceiling change takes
  /// effect on the very next webhook.
  func webhookDeps() : Card.Deps {
    {
      orders = orderStore;
      dedup;
      orphanStore;
      expectLivemode;
      auditLog;
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
  /// Refusal tallies, and whether the gate is refusing right now (#61).
  ///
  /// ⚠️ **Public, like every other monitoring surface here** — operational state
  /// is public by design; the webhook secret is the only secret in the system.
  ///
  /// ⚠️ **This query is the point of the counters.** A tally nobody reads is the
  /// `Orders.tallySaturations` failure over again, so RUNBOOK §8 carries a row
  /// per counter with the response — the counters mean different things:
  /// `amountBelowMin` climbing is a UI bug or an attacker probing, while
  /// `reserveShort` climbing is a refill. Same shape, opposite actions.
  /// Read **any** order by id (admin, #38).
  ///
  /// ⚠️ **A deliberate exception to §2's "existence is not revealed to non-owners", so
  /// it audits itself on every use.** `get_order` is owner-scoped with no admin bypass,
  /// which meant an operator handed a Stripe receipt could determine *which* order it
  /// was — `order_for_payment` is admin-gated — and then could not look at it. Support
  /// meant asking the buyer to read their own screen.
  ///
  /// ⚠️ **The audit line is the price of the exception, not decoration.** It is an
  /// `auditAdmin` write, so it names *who* looked, and it fires on the read whether or
  /// not the order exists — a probe for existence is exactly what §2 withholds from
  /// everyone else, so a miss has to be as visible as a hit.
  public shared ({ caller }) func admin_order(id : Types.OrderId) : async ?Types.Order {
    requireAdmin(caller);
    let found = Orders.get(orderStore, id);
    auditAdmin(
      caller,
      "order.adminRead",
      id # (switch (found) { case (?_) ""; case null " (no such order)" }),
    );
    found;
  };

  /// Filtered, cursor-paginated order list (admin, #38).
  ///
  /// ⚠️ **This is also #37's worklist.** `withUnresolvedProblems` is a *filter* here
  /// rather than a query of its own, which is the whole thesis: "everything outstanding"
  /// composes with status, owner and time range instead of being a parallel list that
  /// answers a slightly different question. It replaced `orders_with_problems`.
  ///
  /// ⚠️ **Ordered by order id, which is not time order.** See `Orders.page` — id order
  /// is arbitrary because ids are random, and sorting by `createdAtNs` would mean
  /// materialising the filtered set first, which is the unbounded scan #63 exists to
  /// remove. Narrow with `createdFromNs` for recency.
  ///
  /// ⚠️ **Deliberately NOT audited, unlike `admin_order` and `admin_receipt`. Written
  /// down because the difference otherwise reads as an oversight — which is exactly what
  /// the `receipt` path looked like before review caught it.**
  ///
  /// The line those two write is *"an operator looked at THIS person's order"*, and that
  /// targeted act is the accountable one. A filtered list is the operator doing their
  /// job: triaging a worklist, checking what is outstanding, finding an order by time
  /// range. Logging a line per page would record the work rather than the intrusion, and
  /// bury the targeted reads it exists to make findable — in a log #37 made permanent.
  ///
  /// Same reasoning keeps `orphans`, `orphan_depth` and `problem_depth` unaudited.
  ///
  /// ⚠️ **And auditing it would cost what the `receipt` split just avoided:** audits
  /// write state, so an audited list cannot be a `query`, and this is the call an
  /// operator makes repeatedly while working.
  ///
  /// ⚠️ **What would change the answer:** if this ever returns something an operator
  /// could not reach through `admin_order`, or if a filter narrows to a *single named
  /// principal* as the normal way to use it — at that point the list becomes the
  /// targeted act and inherits the audit. `owner : ?Principal` makes that possible
  /// today; it is not how the query is meant to be driven.
  public shared query ({ caller }) func admin_orders(
    filter : Orders.Filter,
    afterId : ?Types.OrderId,
    limit : Nat,
  ) : async Orders.Page {
    requireAdmin(caller);
    Orders.page(orderStore, filter, afterId, limit);
  };

  /// How much is outstanding, as two numbers rather than a collection (#38).
  ///
  /// ⚠️ **The shape to poll, and the reason it exists separately from the list.** A
  /// paginated detail query needs a cheap total beside it or a monitor pages through
  /// everything to learn one number — the same split `orphan_depth` already has, and
  /// the same reason RUNBOOK says to alert on the depth and fetch details only when it
  /// fires.
  ///
  /// ⚠️ **`unresolved` is NOT `orders`.** One order can carry several problems, so a
  /// caller reading the order count undercounts the work.
  public query func problem_depth() : async { unresolved : Nat; orders : Nat } {
    {
      unresolved = Orders.unresolvedProblemCount(orderStore);
      orders = Orders.withUnresolvedProblems(orderStore).size();
    };
  };

  public query func refusal_counts() : async {
    counts : Gate.RefusalCounts;
    /// True while that rail-state condition is refusing. Each flips to true with
    /// exactly one `gate.startedRefusing` audit line and clears on the next
    /// successful admission.
    refusingNow : Gate.RailStateLatch;
  } {
    { counts = refusalCounts; refusingNow = railStateLatch };
  };

  public query func orphan_depth() : async { unresolved : Nat; retained : Nat } {
    {
      unresolved = Orphans.unresolvedCount(orphanStore);
      retained = Orphans.size(orphanStore);
    };
  };

  /// §4.1 retained history, oldest first, **paged**. Admin: entries carry
  /// payment references and claimed-but-bogus URL params.
  ///
  /// Paged because unresolved obligations are never evicted, so the queue can
  /// grow — and an unpaginated read would eventually exceed Candid's 2 MB
  /// message limit, i.e. the record would become unreadable exactly when it
  /// mattered most. Pass `null` to start; feed `nextCursor` back until it is
  /// null. `limit` is capped at `Orphans.maxPageSize`.
  public shared query ({ caller }) func orphans(
    afterId : ?Nat,
    limit : Nat,
  ) : async Orphans.Page {
    requireAdmin(caller);
    Orphans.page(orphanStore, afterId, limit);
  };

  /// The operator worklist: open obligations only, paged. Filtered server-side
  /// so a large body of resolved history never stands between the operator and
  /// the dollars that still need an answer.
  public shared query ({ caller }) func orphans_unresolved(
    afterId : ?Nat,
    limit : Nat,
  ) : async Orphans.Page {
    requireAdmin(caller);
    Orphans.unresolvedPage(orphanStore, afterId, limit);
  };

  /// Manual resolution (§4.1/§7) — the operator marking an obligation settled after
  /// acting off-chain: a refund issued in the Stripe Dashboard, or a delivery whose
  /// fate they established on the cycles ledger.
  ///
  /// ⚠️ **This is the only path for everything a refund cannot resolve.** A
  /// `charge.refunded` auto-resolves the refund-resolvable kinds, so those usually
  /// close themselves; `#deliveryStuck`, `#refundAfterDelivery` and `#abandoned` carry
  /// no `paymentRef` and can only be closed here. Resolving an entry never transitions
  /// the order — see `Orphans`'s header.
  /// Close **one** order-bound problem an operator has dealt with (#37).
  ///
  /// The order-shaped counterpart to `resolve_orphan`, which addresses entries by a
  /// queue id that no longer exists for the kinds that moved.
  ///
  /// ⚠️ **`paymentRef` is the selector, and omitting it is only safe when there is one
  /// candidate.** An earlier version took the tag alone and closed *every* unresolved
  /// problem of that kind — which over-resolves, because `Problems.sameShape`
  /// deliberately allows two unresolved `#duplicate` problems on one order with
  /// different payment references (a buyer who pays three times). An operator who
  /// refunded one payment would have marked the other settled.
  ///
  /// ⚠️ **The root cause is structural, so the fix is a real selector rather than a
  /// warning.** Queue entries had monotonic ids; problems in an array have no stable
  /// handle, so **the dedup key is the handle** — `(kindTag, identifyingRef)`, the same
  /// pair `sameShape` uses to decide identity. One definition, both users.
  ///
  /// ⚠️ **And it refuses rather than guesses when the selector is ambiguous**, which is
  /// this codebase's posture wherever a lever might act on the wrong thing — the
  /// abandon guard and `cancel_order`'s `#notOpen` do the same. The refusal lists the
  /// references so the operator can disambiguate, because declining without a way
  /// through is a dead end rather than a safeguard.
  public shared ({ caller }) func resolve_problem(
    orderId : Types.OrderId,
    kindTag : Text,
    /// Which one, when the kind can have several. `#deliveryStuck` never can — it is
    /// matched on the discriminator alone — so null is always right for it.
    paymentRef : ?Text,
  ) : async Result.Result<Nat, Text> {
    requireAdmin(caller);
    let candidates = Orders.unresolvedOfKind(orderStore, orderId, kindTag);
    if (candidates.size() == 0) {
      return #err(
        "no unresolved " # kindTag # " problem on order " # orderId
        # " — check the tag against the order's own problems, and note a resolved one stays on the order rather than disappearing"
      );
    };
    switch (paymentRef) {
      case null {
        if (candidates.size() > 1) {
          let refs = candidates.map(
            func(c) = switch (c.ref) { case (?r) r; case null "(none)" }
          );
          return #err(
            candidates.size().toText() # " unresolved " # kindTag # " problems on order "
            # orderId # ", so this would close all of them — pass the payment reference for the one you dealt with. Candidates: "
            # refs.values().join(", ")
          );
        };
      };
      case (?_) {};
    };
    let closed = Orders.resolveProblems(
      orderStore,
      orderId,
      func(k) {
        Problems.kindToText(k) == kindTag
        and (
          switch (paymentRef) {
            case null true; // exactly one candidate, checked above
            case (?want) Problems.identifyingRef(k) == ?want;
          }
        );
      },
      Time.now(),
    );
    if (closed == 0) {
      return #err(
        "no unresolved " # kindTag # " problem on order " # orderId
        # " with that payment reference — the candidates are listed by resolve_problem with no reference given"
      );
    };
    auditAdmin(
      caller,
      "order.problemResolved",
      orderId # ": " # kindTag
      # (switch (paymentRef) { case (?r) " (" # r # ")"; case null "" })
      # " — " # closed.toText() # " closed",
    );
    #ok(closed);
  };

  public shared ({ caller }) func resolve_orphan(id : Nat) : async Result.Result<Orphans.Entry, Orphans.ResolveError> {
    requireAdmin(caller);
    let resolved = Orphans.resolve(orphanStore, id, Time.now());
    switch (resolved) {
      case (#ok(entry)) auditAdmin(caller, "orphanStore.resolved", "entry " # id.toText() # ": " # entry.detail);
      case (#err(_)) {};
    };
    resolved;
  };

  /// §4.2 operational trail, newest-last. Admin: details reference payment
  /// intents. Readers detect ring-buffer drops via gaps in `seq`.
  /// The operational trail, **paginated** (#38).
  ///
  /// ⚠️ **Pagination became necessary the moment #37 removed the ring.** The bound used
  /// to be the 4,096-entry ring, so the response size took care of itself; retention is
  /// now total. Removing the cap moved the problem from *"history is lossy"* to *"the
  /// query cannot answer"* — both real, and removing the ring only fixed the first.
  ///
  /// Cursor on `seq`, which now has **no gaps**: gaps used to be how a reader detected
  /// drops, and there are no drops.
  public shared query ({ caller }) func audit_log(
    afterSeq : ?Nat,
    limit : Nat,
  ) : async AuditLog.Page {
    requireAdmin(caller);
    AuditLog.page(auditLog, afterSeq, limit);
  };

  // ── Delivery from the reserve (§5/§5.1) ─────────────────────────────────

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
  var cyclesLedgerFee : Nat = Delivery.cyclesLedgerDefaultFee;

  /// §4.2 `journal : Map<OrderId, JournalEntry>` — the money-out record:
  /// transfer intent (written *before* the ledger call, §5.1), block_index,
  /// delivered cycles, retries. Financial record — kept for years, never pruned.
  let deliveryJournal : Delivery.Journal = Delivery.emptyJournal();

  transient let cmc = actor (Cmc.cmcId) : Cmc.CmcService;
  transient let cyclesLedger = actor (Delivery.cyclesLedgerId) : Delivery.CyclesLedgerService;

  /// Per-order single-flight guard: two concurrent drivers for one order
  /// would both pass the status gates between awaits. Transient — an
  /// upgrade mid-delivery clears it and the journal-driven resume (Delivery.stageOf)
  /// picks up where the state actually is.
  transient let deliveriesInFlight = Set.empty<Types.OrderId>();
  /// Single-flight for the stranded-`#created` retrieve (#52), and the scan's cadence.
  ///
  /// **Transient, both of them, deliberately.** A single-flight guard that survived an
  /// upgrade would block the order it was holding forever, and a cadence stamp is worth
  /// re-earning after a deploy. Neither is money state.
  transient let expiryChecksInFlight = Set.empty<Types.OrderId>();
  transient var lastExpiryScanAtNs : Int = 0;

  /// Orders already audited for a blocked delivery this session, so a stuck
  /// order contributes one audit line rather than one per sweep. Transient: the
  /// durable record of a stuck order is the problem filed on it once the max-wait
  /// bound trips, not this.
  transient let deliveryBlockedAudited = Set.empty<Types.OrderId>();




  /// Audit a blocked delivery at most once per order per session.
  func auditDeliveryBlockedOnce(orderId : Types.OrderId, tag : Text, detail : Text) {
    if (deliveryBlockedAudited.contains(orderId)) return;
    deliveryBlockedAudited.add(orderId);
    audit(tag, detail);
  };

  func selfPrincipal() : Principal = Principal.fromActor(CyclesGateway);

  // ── Delivery timeline config (§5.3) ─────────────────────────────────────

  /// The two thresholds the delivery timeline reads: alert at 2 h, terminate at 72 h.
  var deliveryConfig : Delivery.Config = Delivery.defaultConfig();

  /// Tune the delivery timeline (admin, §7).
  ///
  /// ⚠️ Validated rather than trusted: an alert at or after the terminal bound would
  /// tell the operator at the moment the decision was already taken, and a
  /// non-positive bound would escalate every order instantly.
  public shared ({ caller }) func set_delivery_config(config : Delivery.Config) : async Result.Result<(), Delivery.ConfigError> {
    requireAdmin(caller);
    switch (Delivery.validateConfig(config)) {
      case (#err(e)) return #err(e);
      case (#ok) {};
    };
    deliveryConfig := config;
    auditAdmin(caller, "delivery.configSet", "alert after " # config.alertAfterNs.toText() # " ns, terminate after " # config.maxHoldNs.toText() # " ns");
    #ok;
  };

  func audit(tag : Text, detail : Text) {
    ignore AuditLog.append(auditLog, Time.now(), tag, detail);
  };

  /// Audit an admin action, recording **which principal took it**.
  ///
  /// §7's trust model is a flat controller allowlist with equal privileges —
  /// "any one can upgrade-then-drain". With several controllers and no caller
  /// recorded, the trail can say a limit was raised but not by whom, which
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


  /// **The one escalation.** A delivery stopped where it cannot continue
  /// automatically, so the order goes `#needsReview` — **not** `#abandoned`: the
  /// money position may be unknown, its promise stays held (#30 PR-B), and a human
  /// resolves it off-chain. Only `abandon_order` and `record_delivered` end an order.
  ///
  /// **One escalation function, and resist splitting it again.** Two of them once
  /// filed two queue kinds for the same question; they differed only in which audit tag
  /// they emitted and whether they read `blockIndex`, and both left the order in the
  /// same state. A second escalation path is a second answer to "where is the money",
  /// which is the one question that must have exactly one.
  ///
  /// Every route to `#needsReview`, and why the cause and the money position are recorded
  /// separately: `docs/DESIGN.md` §4.1.
  ///
  /// ⚠️ **`journalInconsistent` is an unreachable guard, and if it ever fires it is not a
  /// delivery problem.** The intent's amount cannot exceed the order's locked quantity,
  /// because it was derived by subtracting a fee from that quantity — so firing means
  /// `lockedCycles` acquired a second writer. Escalating rather than guessing a fee on a
  /// money path is the point.
  func escalateDelivery(order : Types.Order, stage : Text, detail : Text) {
    ignore tryTransition(order.id, #needsReview);
    Delivery.patch(deliveryJournal, order.id, { status = ?#needsReview; blockIndex = null; cyclesDelivered = null; bumpRetries = false; lastError = null }, Time.now());
    // **No delay alert to close here, by construction (#37).** An entry saying "it
    // delivers on the next sweep" would have become a false promise on the
    // worklist next to the real problem. Escalation moves the status off `#paid`, so
    // Same for the once-per-order audit guard: nothing will re-audit a blocked
    // delivery for an escalated order, and keeping the id would only suppress a
    // legitimate line if it were ever re-driven.
    deliveryBlockedAudited.remove(order.id);
    // **`blockIndex` is no longer carried here.** It is on the `JournalEntry`
    // along with `status`, `retries` and `updatedAtNs`, and #37 §1b moved the last thing
    // this problem held alone — the ledger's error text — to `JournalEntry.lastError`.
    // What is left is the stage and the resolution state, which is what a problem on
    // an order is for.
    ignore Orders.fileProblem(orderStore, order.id, #deliveryStuck({ stage }), detail, Time.now());
    audit("delivery.stuck", order.id # " [" # stage # "]: " # detail);
  };

  /// Drive one order as far toward `#delivered` as the world allows (§5).
  /// Each loop pass asks Delivery.stageOf for the next move off status + journal,
  /// so the first attempt and every recovery resume run the same code —
  /// "replay the identical transfer" (§5.1) isn't a special case, it IS the
  /// transfer path. Retriable failures return with state untouched (plus a
  /// retry bump) for the next sweep; uncertainty escalates.
  func driveDelivery(orderId : Types.OrderId) : async* () {
    label drive loop {
      let ?order = Orders.get(orderStore, orderId) else return;
      // ⚠️ **The wait bound applies to `#paid` and only `#paid`** — the one status with
      // money in and nothing delivered. `updatedAtNs` is the right anchor because
      // **retries deliberately do not transition**, so the clock stays pinned to the
      // moment the order was paid. Several failure paths return without transitioning
      // and leave the order `#paid` for the next sweep, which is right for a transient
      // fault and would park an order forever on a persistent one.
      if (order.status == #paid) {
        switch (Delivery.waitStage(order.updatedAtNs, Time.now(), deliveryConfig)) {
          case (#retry) {};
          case (#alert) {
            // Tell someone while the cause is still fixable, and keep retrying: most
            // incidents end here with the order delivering.
            //
            // ⚠️ **One line per order, bounded by `markDelayed`** — it returns true only
            // on the first crossing, so the line needs no bookkeeping of its own and
            // passes `AuditLog.mo`'s admission rule.
            //
            // One in-flight status means one sentence, so no switch here. If a second
            // status can ever sit still, this becomes a switch and the wording has to
            // name which one.
            if (Orders.markDelayed(orderStore, orderId, Time.now())) {
              audit(
                "delivery.delayed",
                orderId # ": paid but not yet delivered past the alert threshold — fix the cause and it delivers on the next sweep",
              );
            };
          };
          case (#terminate) {
            // §5.3 max-wait bound. By now the cause is not transient, and a buyer left
            // waiting files a chargeback — which costs more than a refund. Terminating
            // so the operator refunds is the protective act.
            //
            // The escalation's stage comes from `Delivery.terminationFor`, which reads the
            // **journal** and not just the status: the status says where the order
            // stopped, the journal says where the money is, and the money position is
            // what the operator acts on.
            let termination = Delivery.terminationFor(order.status, deliveryJournal.get(orderId));
            escalateDelivery(order, termination.stage, termination.detail);
            deliveryBlockedAudited.remove(orderId);
            return;
          };
        };
      };
      // The whole next-move decision is one pure call: status + journal in, stage out.
      // Keep it that way — every arm of `stageOf` is unit-pinned, and a `switch` here
      // would be a second, untested copy of the same decision.
      let stage : Delivery.Stage = Delivery.stageOf(order.status, deliveryJournal.get(orderId), Time.now(), Delivery.ledgerDedupWindowNs);
      switch (stage) {
        case (#none) return;
        case (#escalate(reason)) {
          // **The high-probability escalation route, so it must carry an
          // instruction.** `stage` is the CAUSE (the runbook's triage key); the detail is
          // the MONEY POSITION from `terminationFor` (what determines the action). They
          // can legitimately disagree — see §4.1 — so both are recorded and neither
          // reading can mislead. A bare "delivery stopped: <reason>" left the operator's
          // first read with no instruction.
          let stage = Delivery.escalateReasonToText(reason);
          let position = Delivery.terminationFor(order.status, deliveryJournal.get(orderId));
          let detail =
            if (position.stage == stage) {
              position.detail;
            } else {
              "stopped because: " # stage # ". Money position is " # position.stage
              # " — " # position.detail;
            };
          escalateDelivery(order, stage, detail);
          return;
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
          let ?amount = Delivery.deliverableCycles(order.lockedCycles, fee) else {
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
          let intent = Delivery.buildDeliveryIntent(orderId, destination, amount, Time.now());
          ignore Delivery.openEntry(deliveryJournal, order, intent, Time.now());
          // fall through the loop → #replayDelivery issues the transfer
        };
        case (#replayDelivery(intent)) {
          // ⚠️ **The fee is DERIVED from the intent, never re-read here** — the fee the
          // original attempt used is recoverable exactly as `lockedCycles - amount`, so a
          // replay reproduces the original args **bit for bit**. Re-reading it would make
          // a replay after a fee change a DISTINCT transaction if the fee is inside the
          // ledger's dedup key, and the buyer is paid twice. Whether it is in that key is
          // not knowable from here, which is why the args are reproduced rather than
          // rebuilt.
          //
          // ⚠️ **No test can catch a regression here — verified by mutation.** Re-reading
          // the fee passed every unit assertion and the whole PocketIC suite: the unit
          // tests pin the arithmetic and the integration ledger's fee never moves. The
          // real guard is now the ledger's service type, which does not declare
          // `icrc1_fee` at all, so the mutation no longer compiles. **Keep it undeclared.**
          let fee : Nat = if (order.lockedCycles >= intent.amountCycles) {
            order.lockedCycles - intent.amountCycles : Nat;
          } else {
            // Unreachable: the amount was derived by subtracting a fee from this
            // very quantity. Escalating beats guessing a fee on a money path.
            escalateDelivery(order, "journalInconsistent", "delivery intent amount " # intent.amountCycles.toText() # " exceeds the order's locked " # order.lockedCycles.toText() # " — the fee cannot be recovered; establish the transfer's fate on the cycles ledger before re-sending");
            return;
          };
          // ── Rule 2 (§5.4): the floor drops when the transfer is ISSUED ──
          //
          // ⚠️ By `amount + fee` — the figure actually being debited — not
          // `lockedCycles`, because the `#BadFee` re-issue below debits `amount +
          // corrected fee`. The case this is pessimistic about: our reply callback
          // traps, so the ledger's debit stands while the journal patch rolls back.
          // (A controlled upgrade cannot do that — `stop_canister` drains outstanding
          // callbacks first.)
          let debited = intent.amountCycles + fee;
          reserveFloor := Reserve.floorAfterOutflow(reserveFloor, debited);
          outflowsIssued += 1;
          let result = try { await cyclesLedger.icrc1_transfer(Delivery.deliveryArgs(intent, fee)) } catch (e) {
            // ⚠️ The floor is NOT credited back. A call that failed without a reply
            // tells us nothing about whether the ledger acted, and rule 2 exists to
            // be pessimistic about exactly that. A reconcile heals it if the
            // transfer never happened.
            Delivery.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesDelivered = null; bumpRetries = true; lastError = ?e.message() }, Time.now());
            audit("delivery.transferFailed", orderId # ": " # e.message());
            return;
          };
          switch (Delivery.interpretTransfer(result)) {
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
              Delivery.patch(deliveryJournal, orderId, { status = ?#delivered; blockIndex = ?block; cyclesDelivered = ?intent.amountCycles; bumpRetries = false; lastError = null }, Time.now());
              audit("delivery.deduplicated", orderId # ": ledger block " # block.toText() # " was already ours; floor credited back " # debited.toText());
              return;
            };
            case (#delivered(block)) {
              deliveryBlockedAudited.remove(orderId);
              // Block + `#delivered` in ONE sync block, so the pair cannot disagree.
              ignore tryTransition(orderId, #delivered);
              Delivery.patch(deliveryJournal, orderId, { status = ?#delivered; blockIndex = ?block; cyclesDelivered = ?intent.amountCycles; bumpRetries = false; lastError = null }, Time.now());
              audit("delivery.sent", orderId # ": " # intent.amountCycles.toText() # " cycles, ledger block " # block.toText());
              return;
            };
            case (#badFee(expected)) {
              // The reserve absorbs a risen fee; the buyer is never shorted, so the
              // intent's AMOUNT is untouched — only the fee we pass.
              //
              // ⚠️ **Re-issued HERE, in the same message, or the loop never terminates.**
              // The fee is derived from the intent, so a later replay derives the same
              // rejected fee and bounces again — every sweep until the max-wait bound.
              // Changing the fee is safe only because `#BadFee` is *definitive*: the
              // ledger did not execute, so this is a first attempt with corrected args,
              // not a replay of something that might already have happened.
              //
              // The floor then drops by `amount + corrected fee` while the promise tally
              // drops by the amount alone, so `available` drifts down by the delta —
              // fractions of a fee, erring conservative. Not a bug (§5.4).
              // ⚠️ **Learn the fee for every LATER order.** This arm is the only place
              // the ledger tells us its fee, so persisting here bounds the cost of a
              // stale copy to one rejected call. It does **not** change this order's
              // intent — rebuilding that is the double-pay this path exists to avoid.
              cyclesLedgerFee := expected;
              audit("delivery.feeChanged", orderId # ": ledger expects " # expected.toText() # " (intent implies " # fee.toText() # "); reserve absorbs the difference, and " # expected.toText() # " is now the stored fee");
              // ── Rule 3 (§5.4): a DEFINITIVE rejection credits the floor back ──
              // `#BadFee` means the ledger processed the call and refused it, so nothing
              // moved and rule 2's decrement was not a real debit.
              // ⚠️ If the re-issue then fails with no reply, the LARGER decrement stands
              // — correctly pessimistic.
              reserveFloor += debited;
              let reDebited = intent.amountCycles + expected;
              reserveFloor := Reserve.floorAfterOutflow(reserveFloor, reDebited);
              outflowsIssued += 1;
              let retried = try {
                await cyclesLedger.icrc1_transfer(Delivery.deliveryArgs(intent, expected));
              } catch (e) {
                Delivery.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesDelivered = null; bumpRetries = true; lastError = ?("after fee correction: " # e.message()) }, Time.now());
                audit("delivery.transferFailed", orderId # " (after fee correction): " # e.message());
                return;
              };
              switch (Delivery.interpretTransfer(retried)) {
                case (#deduplicated(block)) {
                  // An earlier attempt had already landed: this one moved nothing.
                  reserveFloor += reDebited;
                  deliveryBlockedAudited.remove(orderId);
                  ignore tryTransition(orderId, #delivered);
                  Delivery.patch(deliveryJournal, orderId, { status = ?#delivered; blockIndex = ?block; cyclesDelivered = ?intent.amountCycles; bumpRetries = false; lastError = null }, Time.now());
                  audit("delivery.deduplicated", orderId # ": block " # block.toText() # " after fee correction; floor credited back");
                  return;
                };
                case (#delivered(block)) {
                  deliveryBlockedAudited.remove(orderId);
                  ignore tryTransition(orderId, #delivered);
                  Delivery.patch(deliveryJournal, orderId, { status = ?#delivered; blockIndex = ?block; cyclesDelivered = ?intent.amountCycles; bumpRetries = false; lastError = null }, Time.now());
                  audit("delivery.sent", orderId # ": " # intent.amountCycles.toText() # " cycles at the corrected fee, ledger block " # block.toText());
                  return;
                };
                case (_) {
                  // One correction attempt per pass, no loop. If the fee moved
                  // again mid-flight the next sweep starts over from the derived
                  // fee — which is still the byte-identical replay, so the
                  // at-most-once guarantee is never traded for convergence.
                  Delivery.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesDelivered = null; bumpRetries = true; lastError = null }, Time.now());
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
              Delivery.patch(deliveryJournal, orderId, { status = null; blockIndex = null; cyclesDelivered = null; bumpRetries = true; lastError = ?detail }, Time.now());
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
              // That standing decrement is **not a leak**. It is the floor-side
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
          Delivery.patch(deliveryJournal, orderId, { status = ?#delivered; blockIndex = ?block; cyclesDelivered = null; bumpRetries = false; lastError = null }, Time.now());
          audit("delivery.healed", orderId # ": block " # block.toText() # " was recorded but the order had not moved");
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
  /// `#paid` is the only status with money-out work) through the driver. Kicked after webhook
  /// ingestion; the §5.2 recovery timer sweeps it on a cadence.
  func sweepDeliverable() : async* Nat {
    // Answer "is there anything to do?" in O(1) before looking.
    //
    // The maintained tally covers exactly the sweepable status, so an idle sweep is
    // free — which is what makes a short cadence affordable.
    if (sweepableCount() == 0) return 0;
    // ⚠️ **Over the non-terminal index, not the order store (#63).** `#paid` — the one
    // sweepable status — holds its promise, so the index is a superset of the population
    // and the filter is exact. This used to walk every order ever created on every tick
    // that had work, a cost that grows with lifetime sales and never comes back down.
    //
    // ⚠️ **Collect first, then await.** `processDelivery` awaits, and iterating the
    // index while a transition removes members from it would be a mutation during
    // iteration. The list is bounded by the index, so materialising it is cheap.
    let pending = List.empty<Types.OrderId>();
    for (id in Orders.promiseHolderIds(orderStore)) {
      switch (Orders.get(orderStore, id)) {
        case (?order) if (Recovery.isSweepable(order.status)) pending.add(id);
        case null {};
      };
    };
    for (id in pending.values()) {
      await* processDelivery(id);
    };
    pending.size();
  };

  /// Orders with money-out work pending, from the maintained tally. Must stay in step
  /// with `Recovery.isSweepable` — the unit tests pin that, and after #36 both are one
  /// status.
  func sweepableCount() : Nat {
    Orders.countOf(orderStore, #paid);
  };

  public type ProcessOrderError = { #notFound; #inFlight };

  /// Manual delivery kick — **admin, or the order's own owner** (#30 PR-B).
  ///
  /// Safe to spam by construction: every step is journalled, deduplicated, idempotent
  /// and single-flighted. A page refresh heals a stuck order in seconds rather than
  /// waiting a sweep interval.
  ///
  /// ⚠️ **Owner-scoped, not public.** `getOwned` is the guard, so a caller can only kick
  /// their OWN order — one order per kick, serialised, on an order they paid real money
  /// to create. *Unauthenticated* traffic triggering a sweep over **every** order is a
  /// different shape and stays refused.
  ///
  /// ⚠️ **This does not replace the recovery sweep and must not be read as making it
  /// optional.** The sweep is the *guarantee* — we took the money, so we deliver whether
  /// or not the buyer comes back; this is the *latency fix*. A retry that only exists in
  /// the UI makes fulfilling an obligation depend on the buyer returning, and whoever
  /// closed the tab is exactly who most needs us to finish.
  ///
  /// ⚠️ **An owner kicking their own order is NOT audited**, because the log drops
  /// nothing (#37) and a refresh loop would be permanent state growth driven by a
  /// caller. An admin kick is audited — it is an ops action on someone else's order.
  public shared ({ caller }) func process_order(id : Types.OrderId) : async Result.Result<Types.Order, ProcessOrderError> {
    let isAdmin = Auth.checkAdmin(caller, Principal.isController).isOk();
    if (isAdmin) {
      auditAdmin(caller, "delivery.manualKick", id);
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

  /// Run the reconcile now rather than waiting for the daily one (admin, §7).
  ///
  /// The tallies are maintained incrementally so the public status queries stay O(1);
  /// this is the on-demand lever for the case where they are ever suspected of having
  /// drifted. Returns the counts as they stand after the pass.
  ///
  /// ⚠️ **It is the same bounded pass the timer runs, with the same one-directional
  /// rule — it is NOT a stronger repair, and an operator must not reach for it as one.**
  /// `Orders.adoptOnlyIncreases` refuses a recount lower than the maintained tally,
  /// here exactly as on the timer, because a lower recount is indistinguishable from an
  /// incomplete index and adopting it is the only way an index bug could oversell the
  /// reserve. There is deliberately **no** force flag and no full-scan rebuild: a lever
  /// for adopting the unsafe direction would be a lever for the bug.
  ///
  /// ⚠️ **No longer the expensive path**, and it stays admin-only anyway — it writes
  /// tallies the gate reads.
  public shared ({ caller }) func recount_orders() : async [(Text, Nat)] {
    requireAdmin(caller);
    let report = Orders.reconcileBounded(orderStore);
    reportReconciliation(report);
    let rendered = report.counts.map(func((status, n)) = status # "=" # n.toText());
    auditAdmin(caller, "orders.recounted", rendered.values().join(", "));
    report.counts;
  };

  /// Deliveries that may still respond: a journalled intent, no recorded block, on an
  /// order that is still `#paid`. The quiet-window predicate — why it is a superset of
  /// "in flight", and why the cost is not a deadlock: `docs/DESIGN.md` §5.4.
  ///
  /// ⚠️ **The `#paid` clause is load-bearing, and leaving it out froze the reserve.** An
  /// escalated order keeps the intent-without-block shape *forever*, so without it one
  /// escalation makes the quiet window unsatisfiable for the life of the canister: every
  /// reconcile skips, every `refresh_reserve` skips, and top-ups stop registering.
  ///
  /// ⚠️ **`entry.status` is the JOURNAL's copy of the order's status, and this predicate is
  /// the only thing that reads it.** `Delivery.openEntry` once wrote a hardcoded status,
  /// which made this match nothing and quietly disabled the quiet window. If it stops
  /// recording the order's real status this silently returns 0 and the floor becomes
  /// adoptable across an in-flight transfer. `test/cmc.test.mo` pins the coupling.
  ///
  /// ⚠️ **Soundness requires NO AWAIT between the intent write and the transfer issue, and
  /// nothing in the type system enforces it.** The one await that used to sit in that
  /// stretch (`icrc1_fee`) became a stored value, which is why the two are adjacent today.
  /// Reintroduce an await there and a reconcile can adopt a balance while a transfer it
  /// cannot see is in flight. This comment is the guard.
  ///
  /// ⚠️ **Do not add a force flag to `refresh_reserve`.** Adopting across an unsettled
  /// delivery is the exact bug this predicate prevents, so a lever for it is a lever for
  /// the bug.
  func unsettledDelivery(entry : Types.JournalEntry) : Bool {
    entry.status == #paid and entry.transferIntent != null and entry.blockIndex == null;
  };

  /// ⚠️ **A walk over every journal entry ever written, and #69 owns bounding it.**
  /// #63 bounded the order store's walks and this one is in the same class — the journal
  /// gains an entry per `#paid` order and nothing removes them. It fails safe (a trap
  /// means the floor is never adopted, so the gateway under-sells) which is why it is
  /// sequenced rather than folded into #63.
  ///
  /// ⚠️ **Do not "fix" it with `Orders.promiseHolders`.** This reads the JOURNAL's status
  /// copy, deliberately, and the two are allowed to disagree: `abandon_order` can take a
  /// `#paid` order terminal while its transfer is still in flight, so the order leaves
  /// the non-terminal index while its entry is still unsettled. Iterating that index
  /// would return 0 here and make the floor adoptable across an in-flight transfer —
  /// exactly the bug this predicate exists to prevent. See #69.
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
  /// The problem list is the worklist and it self-clears correctly — a
  /// `delayed_deliveries` self-clears on delivery *or* escalation — but it does not
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
  /// Deliveries outstanding past `alertAfterNs` — **the heir to the
  /// `#deliveryDelayed` worklist entry** (#37).
  ///
  /// ⚠️ **The alert it replaces stored nothing of its own.** It was raised as
  /// `#deliveryDelayed({ orderId = order.id; stage = "deliveryDelayed"; sinceNs =
  /// order.updatedAtNs })` with a fixed sentence for `detail` — every field copied
  /// off the order, a constant stage, and no operator decision of its own. It
  /// self-resolved on delivery or escalation, so its whole content was *"this order
  /// is past the threshold"*, which is a **reading**, not an obligation.
  ///
  /// ⚠️ **Self-clearing by construction**, which is the property that makes this
  /// usable where the entry was not: an order leaves this set the moment it
  /// delivers or escalates, because that moves its status. There is no resolve step
  /// to forget and no `delayedAlerts` mapping to leak.
  ///
  /// ⚠️ **`alertAfterNs` survives as this predicate's threshold, not as a trigger.**
  /// The admin still tunes when a slow delivery *shows up*; it no longer files
  /// anything. That is also why the old 2 h floor mattered less than it looked —
  /// lowering a *filter* costs nothing, whereas lowering a trigger filed worklist
  /// entries for orders that deliver themselves.
  /// One delayed delivery, as `delayed_deliveries` reports it (#37, paginated by #38).
  ///
  /// ⚠️ **`pastMaxHold` is a transient window, at most one sweep interval wide** — past
  /// `maxHoldNs` the next sweep escalates the order out of `#paid` and out of this set.
  /// Useful to read; **do not assert it in an integration scenario**, because pinning
  /// that window without ticking the clock is the shape that produces a flaky test. The
  /// boundary is unit-pinned on `Delivery.waitStage`, which is where it belongs.
  type DelayedDelivery = {
    orderId : Types.OrderId;
    status : Types.OrderStatus;
    /// `order.updatedAtNs` — retries deliberately do not move it, so the clock is
    /// pinned to the moment the order entered its current state.
    heldSinceNs : Int;
    waitedNs : Int;
    /// How many times delivery has already failed. `0` is an order simply waiting.
    retries : Nat;
    pastMaxHold : Bool;
    /// When it FIRST crossed the threshold, read off the order — the permanent record,
    /// where every other field here is a live reading.
    delayedAtNs : ?Int;
  };

  public shared query ({ caller }) func delayed_deliveries(
    afterId : ?Types.OrderId,
    limit : Nat,
  ) : async {
    entries : [DelayedDelivery];
    nextCursor : ?Types.OrderId;
  } {
    requireAdmin(caller);
    // ⚠️ **Bounded by the non-terminal index, not by lifetime sales (#63).** `#paid`
    // holds its promise, so the index is a superset of the population and the filter is
    // exact — and the index is capped by the reserve rather than growing with sales.
    //
    // ⚠️ **The page bounds the RESPONSE; the index bounds the WORK. Both are needed
    // and they are different limits** — ~2 MB for the response, instructions per
    // message for the walk — which is why paginating this in #38 did not make it
    // bounded and the comment here said so until now.
    let capped = if (limit == 0 or limit > Orders.maxPageSize) Orders.maxPageSize else limit;
    let now = Time.now();
    let collected = List.empty<DelayedDelivery>();
    var last : ?Types.OrderId = null;
    // Seek in O(log n); `valuesFrom` is inclusive, so the `id > cursor` test below is
    // what skips the cursor itself.
    let ids = switch (afterId) {
      case (?cursor) Orders.promiseHolderIdsFrom(orderStore, cursor);
      case null Orders.promiseHolderIds(orderStore);
    };
    label scan for (id in ids) {
      let ?order = Orders.get(orderStore, id) else continue scan;
      let past = switch (afterId) { case (?cursor) id > cursor; case null true };
      if (past and order.status == #paid) {
        let stage = Delivery.waitStage(order.updatedAtNs, now, deliveryConfig);
        let delayed = switch (stage) {
          case (#retry) false;
          case (#alert or #terminate) true;
        };
        if (delayed) {
          if (collected.size() == capped) {
            return { entries = collected.toArray(); nextCursor = last };
          };
          collected.add({
            orderId = order.id;
            status = order.status;
            heldSinceNs = order.updatedAtNs;
            waitedNs = now - order.updatedAtNs;
            retries = switch (deliveryJournal.get(order.id)) {
              case (?entry) entry.retries;
              case null 0;
            };
            pastMaxHold = stage == #terminate;
            delayedAtNs = order.delayedAtNs;
          });
          last := ?order.id;
        };
      };
    };
    { entries = collected.toArray(); nextCursor = null };
  };

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
    let observed = await cyclesLedger.icrc1_balance_of(Delivery.reserveAccount(selfPrincipal()));
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
  /// The four order counters live here rather than in a surface of their own:
  /// `openOrders` climbing while deliveries do not is the signature of order-creation
  /// abuse, and its lever is `Gate.maxOpenOrdersPerPrincipal`; `totalOrders` and
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
      // O(1): maintained counters, not a scan of the order store.
      openOrders = Orders.countOf(orderStore, #created);
      expiredOrders = Orders.countOf(orderStore, #expired);
      totalOrders = orderStore.orders.size();
      paidIntentsIndexed = paidIntents.size();
      promisedTotal = Orders.promised(orderStore);
      /// ⚠️ **Any non-zero value means the tally has diverged.** A saturation is a
      /// release asking to remove more than was held, so it says the tally was
      /// already wrong *before* that order got there — strictly worse than a fault
      /// in the order being released. The daily recount reports drift's SIZE; this
      /// reports its EXISTENCE, same day. RUNBOOK §8 alerts on any increment.
      tallySaturations = orderStore.tallySaturations;
      // Named so an operator (or the frontend) can point a ledger query at the
      // right account without reconstructing it.
      reserveAccount = Delivery.reserveAccount(selfPrincipal());
      // The gas half, which is a different pot from the reserve: what the canister
      // spends to run, gated by `minCanisterCycles`.
      canisterCycles = Cycles.balance();
      minCanisterCycles = gateConfig.minCanisterCycles;
    };
  };

  /// Which order did this Stripe `payment_intent` pay for (admin, §4.2)? The
  /// reconciliation lookup: given a charge in the Stripe Dashboard, find the
  /// order it funded. Null means the payment was never attributed to an order
  /// here — check the order's problems and the orphan list for an obligation carrying it.
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
  /// No problem filed: nothing is owed. The record and the audit line are the
  /// trail, and queueing an obligation for an order where no money moved is
  /// exactly the orphan state the queue must not accumulate.
  /// **Admin: expire one `#created` order, releasing its reserve capacity** (#52).
  ///
  /// The lever for the class the sweep **structurally cannot see**: an order whose
  /// session-create response was lost carries neither `expiresAtNs` (nothing to trigger
  /// on) nor `stripeSessionId` (nothing to query with), and Stripe's session list cannot
  /// be filtered by `client_reference_id`, so it cannot be looked up either. That state
  /// needs a human anyway — reaching it means a trap in the create continuation or a
  /// frozen canister, not an operating condition.
  ///
  /// ⚠️ **Expire-first, exactly as `cancel_order` does, and for exactly that reason.**
  /// Nothing is ever half-expired: if the session is still live on Stripe, the order does
  /// not move. A successful expire is what makes "expired" mean *provably unpayable*
  /// rather than assumed, because Stripe guarantees a session ends in exactly one of
  /// completed/expired.
  ///
  /// ⚠️ **`#notOpen` changes nothing, and that is not timidity.** It means the session
  /// completed or already expired, and those demand opposite actions — expiring an order
  /// whose buyer just paid would strand a real payment. Let the webhook (or the sweep)
  /// settle it on Stripe's answer.
  public shared ({ caller }) func expire_order(id : Types.OrderId) : async Result.Result<Types.Order, Text> {
    requireAdmin(caller);
    let ?order = Orders.get(orderStore, id) else return #err("no order " # id);
    switch (order.status) {
      case (#created) {};
      case (#expired) return #ok(order); // idempotent
      case (status) {
        return #err(
          "order " # id # " is " # Types.statusToText(status)
          # "; only a #created order can be expired. A paid order delivers or escalates; use abandon_order for a paid one you have refunded"
        );
      };
    };
    switch (order.stripeSessionId) {
      case (?sessionId) {
        switch (await* expireStripeSession(sessionId)) {
          case (#ok) {};
          case (#notOpen) {
            audit("order.expireRaced", id # ": session " # sessionId # " is no longer open");
            return #err(
              "order " # id # "'s session is already settled or expired — the webhook or the recovery sweep will resolve it on Stripe's answer, which is the only authority on which of the two happened"
            );
          };
          case (#failed(detail)) {
            audit("order.expireFailed", id # ": " # detail);
            return #err("could not expire the Stripe session for order " # id # ": " # detail);
          };
        };
      };
      case null {
        // The residue class this method exists for. No session id means no URL ever left
        // the canister, so the order is provably unpayable with no outcall needed.
        audit("order.expiredSessionless", id # " had no session; expired without an outcall");
      };
    };
    // Through the machinery, never a status write: a second tab may have cancelled this
    // order while the outcall was in flight, and the matrix no-ops `#cancelled → #expired`
    // for free — which is what keeps the buyer's own decision, and its `expiredBy`
    // provenance, from being overwritten.
    switch (Orders.expireWithCause(orderStore, id, #sessionExpired, Time.now())) {
      case (#ok(updated)) {
        auditAdmin(caller, "order.expiredByAdmin", id # ": reserve capacity released");
        #ok(updated);
      };
      case (#err(_)) {
        let ?fresh = Orders.get(orderStore, id) else return #err("no order " # id);
        #err("order " # id # " moved to " # Types.statusToText(fresh.status) # " while the Stripe call was in flight; nothing was changed");
      };
    };
  };

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
            //
            // ⚠️ **No audit line, deliberately (#37 §2c).** It failed the admission
            // rule on both halves: a buyer can retry the cancel and hit this again, so
            // it was caller-bounded — and its information exists nowhere else *only*
            // if you ignore that **the resolving event is itself logged**. The
            // `completed` or `expired` webhook that settles this race writes the record,
            // and it is the one an operator actually needs, because it says WHICH of
            // the two causes it was. This line said only "one of two things happened".
            //
            // The buyer still learns, from the error returned below.
            return #err(
              "order " # id # " is already settled or has expired — refresh the page"
            );
          };
          case (#failed(detail)) {
            // The order stays payable and uncancelled, which is the safe side:
            // the buyer can retry, or it expires on its own.
            //
            // ⚠️ **And because the buyer CAN retry, this line was caller-bounded** —
            // the comment above invites exactly the loop that made it fail
            // `AuditLog.mo`'s admission rule. It is the same Stripe-API-failing
            // condition `create_order` latches, with the same cause and the same lever,
            // so it routes through the same latch: one line when the API starts
            // refusing us, a counter for the volume.
            noteStripeApiFailed("expire: " # detail);
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
  /// `delayed_deliveries` and keeps retrying, because its causes are all
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
      // `#orphanStore`: an escalated order could not previously be abandoned,
      // because one status meant both "promise held" and "promise released" and
      // the transition was to itself (#34).
      case (#paid or #needsReview) {};
      case (status) {
        return #err("order " # id # " is " # Types.statusToText(status) # "; only a paid or under-review order can be abandoned");
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
    // Status and reason in one step, so they cannot diverge — an `#abandoned` order
    // with no explanation is the gap the dropped queue entry used to paper over.
    let abandoned = switch (Orders.abandonWithReason(orderStore, id, reason, Time.now())) {
      case (#ok(o)) o;
      case (#err(_)) return #err("order " # id # " refused the transition to abandoned");
    };
    Delivery.patch(deliveryJournal, id, { status = ?#abandoned; blockIndex = null; cyclesDelivered = null; bumpRetries = false; lastError = null }, Time.now());
    // ⚠️ **No queue entry.** It was the fourth copy of one decision — the status, the
    // journal patch and this audit line already carry it, and nothing about it was
    // outstanding. Review established the refund is tracked separately, via
    // `stripe.refundOfEscalated` on the `charge.refunded` for the intent.
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
    Delivery.patch(deliveryJournal, id, { status = ?#delivered; blockIndex = ?blockIndex; cyclesDelivered = null; bumpRetries = false; lastError = null }, Time.now());
    auditAdmin(caller, "order.recordedDelivered", id # ": operator confirmed cycles-ledger block " # blockIndex.toText());
    #ok(delivered);
  };

  public type Receipt = {
    order : Types.Order;
    /// What the buyer actually paid, if they have.
    paidUsdCents : ?Nat;
    /// The **cycles-ledger** block the delivery transfer landed in — the on-chain
    /// proof, checkable by anyone against that ledger by the order id in the
    /// transfer's memo.
    deliveryBlockIndex : ?Nat;
    /// Cycles delivered to the buyer's account.
    cyclesDelivered : ?Nat;
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
  /// ⚠️ **Owner-only, and a `query`, which is why the admin path is a separate method.**
  /// See `admin_receipt`. Auditing writes state, so an audited read cannot be a query —
  /// and folding the admin case in here would have made **every buyer's** receipt read
  /// an update, putting the common path through consensus to serve the rare one.
  /// The same receipt, for **any** order (admin, #38) — and **audited**, which is the
  /// whole reason it is a separate method.
  ///
  /// ⚠️ **An earlier version folded this into `receipt` and argued the admin branch need
  /// not be audited. That argument was wrong**, and the error is worth keeping: it
  /// reasoned about *existence disclosure* — a receipt read cannot reveal existence
  /// `admin_order` has not already revealed, which is true — but that is not what the
  /// audit is for. `admin_order` audits because **an operator reading a buyer's order
  /// should leave a record of having looked**, and `Receipt` embeds the whole `Order`. An
  /// unaudited admin branch returns exactly the same data with no trace, so the audit on
  /// `admin_order` becomes **bypassable by calling the other method** — a marker rather
  /// than an accountability control.
  ///
  /// ⚠️ **A separate method rather than a branch, because auditing writes state.** An
  /// audited read cannot be a `query`, and folding this into `receipt` would have made
  /// **every buyer's** receipt read an update — putting the common path through consensus
  /// to serve the rare one. Two methods, each with the call type its job needs.
  ///
  /// ⚠️ **This is also why the boundary could be lifted at all.** #38's stated gap is
  /// "an operator cannot read any order but their own"; lifting it is deliberate and
  /// **auditing is the mitigation**. A path that lifts it without the mitigation is not a
  /// smaller version of the change — it is the change without its safeguard.
  public shared ({ caller }) func admin_receipt(id : Types.OrderId) : async ?Receipt {
    requireAdmin(caller);
    let ?order = Orders.get(orderStore, id) else {
      // Audited on a miss too, like `admin_order`: an id probe by an operator is exactly
      // what §2 withholds from everyone else, so a miss must be as visible as a hit.
      auditAdmin(caller, "order.adminRead", id # " (receipt; no such order)");
      return null;
    };
    auditAdmin(caller, "order.adminRead", order.id # " (receipt)");
    let journal = deliveryJournal.get(id);
    ?{
      order;
      paidUsdCents = order.paidUsdCents;
      deliveryBlockIndex = switch (journal) { case (?entry) entry.blockIndex; case null null };
      cyclesDelivered = switch (journal) { case (?entry) entry.cyclesDelivered; case null null };
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

  public shared query ({ caller }) func receipt(id : Types.OrderId) : async ?Receipt {
    let ?order = Orders.getOwned(orderStore, id, caller) else return null;
    let journal = deliveryJournal.get(id);
    ?{
      order;
      paidUsdCents = order.paidUsdCents;
      deliveryBlockIndex = switch (journal) { case (?entry) entry.blockIndex; case null null };
      cyclesDelivered = switch (journal) { case (?entry) entry.cyclesDelivered; case null null };
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

  /// Money-out journal for one order (admin, §4.2) — intent, block_index, cycles
  /// delivered, retries.
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
  /// Re-entry guard for the detached stranded-`#created` pass (#52).
  ///
  /// ⚠️ **The per-pass cap bounds ONE pass, not overlapping ones.** The cadence gate is
  /// claimed before the pass is detached, so a pass that outlives its hour — a slow or
  /// unresponsive Stripe, with up to `maxRetrievesPerPass` sequential outcalls — would
  /// otherwise let the next tick start a second pass against the same orders and stack
  /// outcalls. That is a production concern, not only a test one.
  transient var expiryScanInFlight = false;
  /// Where the last stranded-`#created` pass stopped, so the next one resumes rather than
  /// restarting.
  ///
  /// ⚠️ **The cap alone STARVES.** Taking the first `maxRetrievesPerPass` due orders in
  /// store order means a due order that stays due — Stripe answering `open` because of
  /// clock skew, or a retrieve that keeps failing — is asked again every pass while
  /// orders behind it are never reached at all. The bound has to come with a resume or it
  /// is a bound on *which* orders get looked at, not on how many.
  ///
  /// Measured, not theorised: the integration suite carries dozens of lingering
  /// `#created` orders, and two scenarios failed with "the sweep never retrieved
  /// session …" because their order sat behind ten permanently-due neighbours.
  ///
  /// ⚠️ **An id, not an index — and this was known before and lost.** The deleted
  /// retention sweep paged the store with exactly this shape and said why, verbatim:
  /// *"An **id**, not an index: an index into a snapshot is meaningless across ticks,
  /// because an insert shifts every later position."* It had `maxRetentionScanPerSweep`
  /// **and** `Orders.idsFrom(store, cursor, limit)`; #33 PR-C deleted the module, the
  /// cursor and the primitive together, so this issue rebuilt a bounded scan and
  /// reintroduced the starvation the old one had already solved.
  ///
  /// The lesson belongs with the deletion discipline rather than here: **a disposal
  /// record has to carry the invariants the deleted code satisfied**, not only where its
  /// behaviour went, or the next thing of that shape pays for them again.
  ///
  /// This pages the **due set** rather than the store, because "due" is not a
  /// store-order property — collecting it costs one scan and no outcalls, and the cap
  /// applies to the expensive half.
  transient var expiryScanCursor : Text = "";

  /// Last *completed* timer sweep — recovery liveness for ops (the §5.2
  /// timer is the backstop for every detached webhook kick that dies, so
  /// "is it actually firing" must be observable).
  var lastRecoverySweep : ?{ atNs : Int; pending : Nat } = null;

  /// How often the sweep reconciles the per-status tallies against the order
  /// store. Daily, not per-sweep: the reconcile is O(orders) while the tallies
  /// exist precisely so the hot queries are O(1), and drift can only come from a
  /// bookkeeping bug, which does not need a 15-minute detection window.
  let countReconcileIntervalNs : Nat = 24 * 3_600 * 1_000_000_000;

  /// When the tallies were last **successfully** reconciled, and what the pass found.
  /// Surfaced on `recovery_status` so "the counts are trustworthy" is an observable
  /// fact rather than an assumption. Written only on success, so it falling behind
  /// while `lastSweep` advances is the signal that the reconcile itself is failing
  /// (RUNBOOK §8).
  ///
  /// ⚠️ **`drift` and `refused` are different verdicts and are reported separately**
  /// (#63): `drift` is a tally that was raised to the recount and is now correct, while
  /// `refused` is one the pass would not touch because the recount came out lower — see
  /// `Orders.adoptOnlyIncreases`. A monitor that alerts on the pair as if they were one
  /// number cannot tell "repaired" from "still suspect".
  ///
  /// `ordersRead` is how much work the pass did. It is bounded by the two index sizes,
  /// so watching it grow with lifetime sales would mean the bound had broken.
  var lastCountReconcile : ?{
    atNs : Int;
    drift : [Orders.Drift];
    refused : [Orders.Drift];
    ordersRead : Nat;
  } = null;

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

  /// Report what a bounded reconcile pass found (#63), shared by the timer and the
  /// admin lever so the two cannot report differently.
  ///
  /// ⚠️ **Every audit line here is a code bug, not an operational condition**, and each
  /// is written only when it fires — a clean pass writes nothing, because a daily "all
  /// well" line would bury the one that matters.
  ///
  /// ⚠️ **`adopted` and `refused` are separate tags on purpose.** They demand opposite
  /// readings: an adopted drift means *the tallies are correct again and a writer lost
  /// an adjustment*; a refused one means *the tallies are still suspect and the pass
  /// would not touch them*. One tag covering both would be a row an operator cannot act
  /// on, which is worse than no row.
  func reportReconciliation(report : Orders.Reconciliation) {
    if (report.adopted.size() > 0) {
      let rendered = report.adopted.map(
        func(d : Orders.Drift) : Text = d.status # " " # d.was.toText() # "→" # d.is.toText()
      );
      audit(
        "orders.countDrift",
        "raised to the recount over the non-terminal index: " # rendered.values().join(", ")
        # ". The counts are right again; the writer that lost the adjustment is not fixed.",
      );
    };
    if (report.refused.size() > 0) {
      let rendered = report.refused.map(
        func(d : Orders.Drift) : Text = d.status # " tally " # d.was.toText() # ", recount " # d.is.toText()
      );
      audit(
        "orders.countRecountLow",
        "the recount came out BELOW the maintained tally and was refused: " # rendered.values().join(", ")
        # ". Two causes with one response: either the non-terminal index is missing a member or a tally"
        # " gained an adjustment it should not have — both are bugs in Orders.mo. The maintained value"
        # " stands, which over-refuses rather than overselling. orders.unindexedHolders from the rotating"
        # " scan names the missing members if that is the cause.",
      );
    };
    if (report.promisedWas != report.promisedIs) {
      audit(
        if (report.promisedAdopted) "reserve.promisedRaised" else "reserve.promisedRecountLow",
        "promised tally " # report.promisedWas.toText() # ", recount over the non-terminal index "
        # report.promisedIs.toText()
        # (
          if (report.promisedAdopted) ". Raised: the tally had lost a hold, so the reserve was reading"
          # " as MORE available than it was. This is the direction that oversells, and it is now closed."
          else ". Refused: a recount below the tally is indistinguishable from an incomplete index, so"
          # " adopting it is the one move that could oversell the reserve. The maintained value stands and"
          # " over-refuses."
        ),
      );
    };
    if (report.staleHolders.size() > 0) {
      audit(
        "orders.staleHolders",
        report.staleHolders.size().toText() # " id(s) in the non-terminal index belonged to terminal orders"
        # " and were dropped: " # report.staleHolders.values().join(", ")
        # ". The order's own status is the authority, so this repair is sound — but the index is"
        # " maintained only by Orders.create and Orders.commitTransition, so something else wrote a"
        # " status. Find that writer; the drop is not the fix.",
      );
    };
    if (report.staleProblemIds.size() > 0) {
      audit(
        "orders.problemIndexDrift",
        report.staleProblemIds.size().toText() # " id(s) in the unresolved-problems index had no unresolved"
        # " problem and were dropped: " # report.staleProblemIds.values().join(", ")
        # ". That index is maintained only by Orders.fileProblem and Orders.resolveProblems, so something"
        # " else wrote order.problems. Find that writer; the drop is not the fix.",
      );
    };
    if (report.expiredIs < report.expiredWas) {
      audit(
        "orders.expiredWentBackwards",
        "the Expired tally fell from " # report.expiredWas.toText() # " to " # report.expiredIs.toText()
        # ", which the transition matrix makes impossible: #created → #expired is its only inbound edge"
        # " and it has no outbound one. A bookkeeping breach in Orders.bump. Reported once per decrease,"
        # " not daily, so a repeat means it fell again.",
      );
    };
    if (report.expiredOverflow) {
      audit(
        "orders.expiredOverflow",
        "Expired tally " # report.expiredIs.toText() # " plus " # Orders.promiseHolderCount(orderStore).toText()
        # " non-terminal orders exceeds the " # Orders.storedCount(orderStore).toText() # " orders in the store."
        # " The two sets are disjoint subsets of it, so this is arithmetically impossible and the Expired"
        # " tally is over-counted. Observability only — nothing decides on it — but it is a real breach.",
      );
    };
  };

  /// Reconcile the maintained tallies against the orders. Audits **only on a finding**:
  /// a clean pass every day would bury the one line that matters.
  ///
  /// Runs in its own message (see the call site) and takes no `await`, so it sees a
  /// consistent snapshot of the order store.
  ///
  /// ⚠️ **Its cost is now bounded by flow rather than by lifetime sales (#63)** — it
  /// recounts over `Orders.promiseHolders`, whose size the reserve caps. The pass it
  /// replaced summed every order ever created in one message and was on a path to the
  /// instruction limit.
  ///
  /// ⚠️ **Daily is now a sufficiency choice, not a cost one, and the old reason is
  /// gone.** It used to be daily *because* it was O(every order); it is daily now
  /// because drift can only come from a bookkeeping bug, which does not need a
  /// 15-minute detection window. Do not restore the old justification — it would
  /// describe a scan this function no longer performs.
  ///
  /// ⚠️ **Still not chunked, and that is the same reason as before**: a global sum
  /// cannot be split across messages, because mutations between chunks manufacture
  /// false drift. What changed is that the sums no longer need history. The check that
  /// *does* need every order — the outside direction of both indexes — is
  /// `scanIndexChunk`, which may be chunked precisely because it evaluates a per-order
  /// predicate rather than a sum.
  func reconcileCounts() {
    let report = Orders.reconcileBounded(orderStore);
    // Stamped from inside, not handed the sweep's clock: this message runs after the
    // one that scheduled it, and the two timestamps are compared against each other
    // (attempt vs success) to tell a failing reconcile from a due one.
    lastCountReconcile := ?{
      atNs = Time.now();
      drift = report.adopted;
      refused = report.refused;
      ordersRead = report.ordersRead;
    };
    reportReconciliation(report);
  };

  // ── The rotating index scan (#63) ───────────────────────────────────────

  /// Where the current coverage cycle has reached. `null` means a cycle is about to
  /// start from the beginning of the store.
  ///
  /// ⚠️ **Persistent, because the coverage claim is what this state is for.** A
  /// transient cursor would silently restart every cycle on every upgrade, so
  /// `lastIndexScanCycle` would report a completed pass that an upgrade had truncated —
  /// a green check that means nothing.
  var indexScanCursor : ?Types.OrderId = null;

  /// The cycle in progress: when it began, how many orders it has read, and how many
  /// disagreements it has repaired so far.
  var indexScanCycle : { startedAtNs : Int; ordersRead : Nat; repairs : Nat } = {
    startedAtNs = 0;
    ordersRead = 0;
    repairs = 0;
  };

  /// The last **completed** cycle — the only thing that licenses reading a clean scan
  /// as evidence about the whole store.
  ///
  /// ⚠️ **This field IS the third state.** `orders.problemIndexDrift` and
  /// `orders.unindexedHolders` only mean "a writer bypassed the maintaining functions"
  /// if the absence of those lines means "we looked". Without a completed-cycle stamp,
  /// silence means either *verified clean* or *not yet visited*, which are two readings
  /// with opposite responses — find the bug, versus wait for the next pass. So the three
  /// states are: an audit line (verified, disagreed), silence with a recent
  /// `completedAtNs` (verified, clean), and silence without one (unverified).
  var lastIndexScanCycle : ?{
    startedAtNs : Int;
    completedAtNs : Int;
    ordersRead : Nat;
    repairs : Nat;
  } = null;

  /// The expected time for one full coverage cycle, hence the detection latency for the
  /// outside direction. The arithmetic is `Recovery.indexScanCycleNs`, which is pure and
  /// unit-tested — this only supplies the three live inputs.
  func expectedIndexScanCycleNs() : Nat {
    Recovery.indexScanCycleNs(
      Orders.storedCount(orderStore),
      Orders.scanChunkSize,
      recoverySweepIntervalNs,
    );
  };

  /// One chunk of the rotating scan, on the sweep cadence.
  ///
  /// ⚠️ **Sweep cadence rather than daily, because one of its findings is money.**
  /// `unindexedHolders` is the one inconsistency the daily reconcile cannot see: an
  /// order that holds a promise, is missing from the index, and whose cycles are missing
  /// from `promised` too — index and tally agree, both low, and the reserve reads as
  /// more available than it is.
  ///
  /// ⚠️ **#63 turned unbounded WORK into unbounded LATENCY, and the honest claim is
  /// "bounded per message", not "bounded".** The daily reconcile verifies only the
  /// inside direction of each index; the outside direction is this scan, so detecting an
  /// order that holds a promise and is not indexed takes up to **one full cycle**, and
  /// the cycle grows **linearly in stored orders**:
  ///
  ///     cycle = ⌈storedOrders ÷ scanChunkSize⌉ × recoverySweepIntervalNs
  ///
  /// At the 15-minute default and 2,000 orders per chunk that is ~192,000 orders a day,
  /// so 365k orders is covered in about two days and 3.65M in about nineteen. That is
  /// the right trade — work that traps is fatal, latency that grows is degradable and
  /// observable — but it is a trade, and a comment claiming the reconcile is simply
  /// "bounded now" would hide the half that still grows.
  ///
  /// ⚠️ **`set_recovery_interval` is therefore a lever on this latency, and nothing
  /// about its name says so.** The cadence is operator-tunable up to the §5.1 ceiling of
  /// 6 h, which is **24× the default** — the same 365k store then takes ~46 days per
  /// cycle. `recovery_status.indexScan.expectedFullCycleNs` is computed from the live
  /// interval precisely so this is a number an operator reads rather than one they have
  /// to know to derive.
  ///
  /// ⚠️ **Detached into its own message by the caller, like the reconcile**, so a trap
  /// here cannot take the sweep — and therefore money-out — down with it. It takes no
  /// `await`, so its own state commits or rolls back as a unit.
  func scanIndexChunk() {
    let now = Time.now();
    let starting = indexScanCursor == null;
    if (starting) {
      indexScanCycle := { startedAtNs = now; ordersRead = 0; repairs = 0 };
    };
    let chunk = Orders.scanChunk(orderStore, indexScanCursor, Orders.scanChunkSize);
    let repairs = chunk.unindexedHolders.size() + chunk.unindexedProblems.size();
    indexScanCycle := {
      indexScanCycle with
      ordersRead = indexScanCycle.ordersRead + chunk.visited;
      repairs = indexScanCycle.repairs + repairs;
    };
    indexScanCursor := chunk.nextCursor;
    if (chunk.unindexedHolders.size() > 0) {
      audit(
        "orders.unindexedHolders",
        chunk.unindexedHolders.size().toText() # " order(s) hold a promise and were missing from the"
        # " non-terminal index; they have been added: " # chunk.unindexedHolders.values().join(", ")
        # ". ⚠️ This is the one bookkeeping error the daily reconcile cannot see — index and promise"
        # " tally can be missing the same order and agree with each other, so the reserve reads as MORE"
        # " available than it is and can be oversold. The next reconcile will raise `promised` to the"
        # " larger index. Find the writer that set a status outside Orders.create and"
        # " Orders.commitTransition; the repair is not the fix.",
      );
    };
    if (chunk.unindexedProblems.size() > 0) {
      audit(
        "orders.unindexedProblems",
        chunk.unindexedProblems.size().toText() # " order(s) carry an unresolved problem and were missing"
        # " from the unresolved-problems index; they have been added: "
        # chunk.unindexedProblems.values().join(", ")
        # ". Until now the worklist did not show those obligations and resolveByPaymentRef could not"
        # " reach them. Find the writer of order.problems outside Orders.fileProblem and"
        # " Orders.resolveProblems.",
      );
    };
    // ⚠️ **Only a null cursor licenses the coverage claim.** Every order that existed
    // when the cycle began was ahead of a cursor that started at the beginning, so a
    // cycle that ran to exhaustion visited all of them. Orders created mid-cycle may
    // land behind the cursor and wait for the next one — which is why the claim is
    // "every order that existed when this cycle began", and not "every order".
    if (chunk.nextCursor == null) {
      lastIndexScanCycle := ?{
        startedAtNs = indexScanCycle.startedAtNs;
        completedAtNs = Time.now();
        ordersRead = indexScanCycle.ordersRead;
        repairs = indexScanCycle.repairs;
      };
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
  /// Ask Stripe about `#created` orders whose expiry event never arrived (#52).
  ///
  /// ⚠️ **Bounded per pass and resumed on the next one.** The stranded population is
  /// **correlated** — one unprovisioned webhook secret or one frozen canister strands
  /// every order in that window at once — so "rare" describes incidents, not orders per
  /// incident. Uncapped, one incident becomes N outcalls an hour for as long as it lasts.
  ///
  /// ⚠️ **Bounded by the non-terminal index (#63), not by lifetime sales.** It still
  /// runs detached in its own message, because it makes outcalls and a release check
  /// must not be able to stop money-out. The `countOf(#created)` gate below is a
  /// maintained tally, so an idle pass is free.
  func sweepStrandedCreated() : async* Nat {
    if (expiryScanInFlight) return 0;
    if (Orders.countOf(orderStore, #created) == 0) return 0;
    expiryScanInFlight := true;
    try { await* runStrandedPass() } finally { expiryScanInFlight := false };
  };

  func runStrandedPass() : async* Nat {
    let now = Time.now();
    // Collect every due order first. This costs **no outcalls**, so it is the cheap
    // half; the cap applies to the expensive half below.
    //
    // ⚠️ **Over the non-terminal index, not the order store (#63).**
    // `Recovery.expiryCheckDue` matches `#created` alone, which holds its promise, so
    // the index is a superset of the population and the filter is exact. This used to
    // walk every order ever created on every hourly pass.
    let all = List.empty<Types.OrderId>();
    for (id in Orders.promiseHolderIds(orderStore)) {
      switch (Orders.get(orderStore, id)) {
        case (?order) {
          if (
            Recovery.expiryCheckDue(order.status, order.expiresAtNs, now, Recovery.expiryGraceNs)
            and not expiryChecksInFlight.contains(id)
          ) { all.add(id) };
        };
        case null {};
      };
    };
    let ids = all.toArray();
    if (ids.size() == 0) return 0;

    // Resume after the cursor, wrapping — so a permanently-due order cannot monopolise
    // the pass. Ids are opaque, so "after" is just lexicographic order over a stable set;
    // all that is required is that the starting point advances.
    var start = 0;
    label find for (i in ids.keys()) {
      if (ids[i] > expiryScanCursor) { start := i; break find };
    };

    var asked = 0;
    label ask for (offset in Nat.range(0, ids.size())) {
      if (asked >= Recovery.maxRetrievesPerPass) break ask;
      let id = ids[(start + offset) % ids.size()];
      expiryScanCursor := id;
      expiryChecksInFlight.add(id);
      try { await* checkSessionExpiry(id) } finally { expiryChecksInFlight.remove(id) };
      asked += 1;
    };
    asked;
  };

  /// One order: ask Stripe, then act on Stripe's answer and nothing else.
  func checkSessionExpiry(orderId : Types.OrderId) : async* () {
    let ?order = Orders.get(orderStore, orderId) else return;
    let ?sessionId = order.stripeSessionId else return;
    let answer = await* retrieveStripeSession(sessionId);

    // ⚠️ **Re-read the order. The await above is a window and the order can move
    // through it** — `cancel_order` from the buyer, a late `checkout.session.expired`,
    // even a late `completed` followed by a delivery. Acting on the copy read before the
    // await is the bug `create_order` warns about in the same shape.
    let ?fresh = Orders.get(orderStore, orderId) else return;

    switch (answer) {
      // ⚠️ **The THIRD Stripe outcall, and it needs the same latch as the other two
      // (#37 §2c).** These two arms passed the admission rule on a technicality: their
      // frequency is bounded by *our own* sweep cadence, which the rule accepts.
      //
      // ⚠️ **But our cadence bounds a RATE, and a rate against an unfixed persistent
      // condition is unbounded over time.** A revoked key — the exact cause
      // `#stripeApiFailing` exists for — fails the retrieve on every stranded order the
      // sweep touches: hourly, up to `maxRetrievesPerPass` each pass, forever, for one
      // unfixed problem. Roughly 240 permanent lines a day once the ring is gone. The
      // ring is what turned "bounded per day" into "bounded in total", and removing it
      // is what makes the difference matter.
      //
      // Same condition, not a fourth: a 401 on retrieve and a 401 on create are **one
      // incident with one lever**. Which is why the condition is named for the API.
      case (#unauthorized) {
        // The guidance the deleted `stripe.retrieveUnauthorized` line carried, kept
        // verbatim — it is the one message that names the fix, and RUNBOOK §8's P1 row
        // is keyed on this text now rather than on a tag that no longer exists.
        noteStripeApiFailed(
          "retrieve REFUSED (401/403): the restricted key needs WRITE on Checkout Sessions, which includes the read this sweep does. Stranded reserve capacity cannot be released until it does — rotate the key"
        );
      };
      case (#failed(detail)) {
        noteStripeApiFailed("retrieve: " # detail);
      };
      case (#ok(#open) or #ok(#unknown(_))) {
        // Nothing. Our clock decided when to ask; Stripe decides what is true, and it
        // has not said the session is finished. `#unknown` lands here on purpose: an
        // answer we cannot read must make this feature inert, never wrong.
        switch (answer) {
          case (#ok(#unknown(detail))) audit("stripe.retrieveUnreadable", "order " # orderId # ": " # detail);
          case (_) {};
        };
      };
      case (#ok(#expired)) {
        // **The leak this issue exists to close.** Stripe says nobody can ever pay this
        // session, so the promise is holding capacity against a sale that cannot happen.
        //
        // Through `expireWithCause`, never a status write: the matrix no-ops
        // `#cancelled → #expired` for free, which is what keeps a buyer's own
        // cancellation from being overwritten with a system expiry — and with it the
        // `expiredBy` provenance that says which of the two happened.
        switch (Orders.expireWithCause(orderStore, orderId, #sessionExpired, Time.now())) {
          case (#ok(_)) audit("stripe.strandedExpired", orderId # ": Stripe confirmed the session expired; reserve capacity released");
          case (#err(_)) {}; // moved under us — cancelled, paid, already expired. Correct to do nothing.
        };
      };
      case (#ok(#completePaid({ paymentIntent }))) {
        // The buyer paid and we never credited it: we missed the `completed` event.
        //
        // ⚠️ **This is NOT the leak, and the difference decides the urgency.** Capacity
        // held against an order the buyer genuinely paid for is capacity *correctly
        // committed* — the promise is doing its job and releases at delivery once the
        // event lands. So there is nothing to release here and nothing to hurry.
        //
        // Stripe redelivers for ~3 days (§4.2), so before the horizon the event is still
        // coming and the real credit path will handle it. Filing an obligation then would
        // put a self-resolving item in a bounded, evicting queue — noise that can push
        // real obligations out. The audit line is the support signal: a buyer who paid
        // sees their own page render expired from `expiresAtNs` and calls the same hour,
        // and this is how an operator confirms Stripe says the session completed.
        if (not Recovery.paidEscalationDue(fresh.createdAtNs, Time.now(), Recovery.paidRetryHorizonNs)) {
          audit("stripe.paidAwaitingEvent", orderId # ": Stripe says this session was paid; waiting for the completed event Stripe is still retrying");
          return;
        };
        // Past the horizon: nobody is going to credit this on its own.
        //
        // ⚠️ **Do not re-file — and that guard is now free.** `Problems.file` dedups on
        // the kind's `paymentRef`, so the explicit `hasUnresolvedPaidNotCredited` check
        // this used to need is gone along with the function.
        //
        // ⚠️ **The dedup is only safe because of one coupling, which survives the move:**
        // the problem cannot be closed while it still exists, because its closer is *the
        // order being credited*, not the money moving. Suppressing a duplicate therefore
        // cannot hide anything. **Do not move the closer onto money state without
        // revisiting this**, or the dedup silently becomes a hider.
        if (
          Orders.fileProblem(
            orderStore,
            orderId,
            #paidNotCredited({ paymentRef = paymentIntent; sessionId }),
            "Stripe says session " # sessionId # " was paid and this order was never credited, past the point where Stripe would still be retrying. **Resend the event from the Stripe Dashboard first, always** — that credits the order through the normal path and closes this problem. Refunding instead settles the money and leaves the order stranded in Created with no event left to release it.",
            Time.now(),
          )
        ) {
          audit("stripe.paidNotCredited", orderId # ": paid and uncredited past Stripe's retry horizon; obligation filed");
        };
      };
    };
  };

  func recoverySweep() : async () {
    if (recoverySweepInFlight) return;
    recoverySweepInFlight := true;
    try {
      // Detached into its own message rather than run inline, and it stays detached
      // even though #63 bounded its cost. The reason was never only the instruction
      // limit: **a bookkeeping check must not be able to stop orders from delivering**,
      // whatever makes it trap. Inline, any trap in the reconcile takes the whole sweep
      // down with it, leaving money-out dead while the reconcile stays due and traps
      // again on every tick.
      //
      // Claiming the cadence here, in the sweep's own message, is what bounds the
      // damage: this write commits whatever the detached message does, so a
      // trapping reconcile retries daily rather than every tick. Its cost is a
      // visibly stale `lastCountReconcile` (RUNBOOK §8), which is the right
      // signal — the tallies are unverified, not known-wrong.
      let now = Time.now();
      if (Recovery.reconcileDue(lastCountReconcileAttemptNs, now, countReconcileIntervalNs)) {
        lastCountReconcileAttemptNs := now;
        ignore async { reconcileCounts() };
      };
      // ── One chunk of the rotating index scan (#63) ──────────────────────────
      //
      // Every tick, not on a cadence of its own: the chunk is what bounds it, and the
      // coverage window is `stored orders ÷ (chunk × ticks per day)`, so a longer
      // cadence buys nothing and lengthens the window on the one finding that can
      // indicate an oversellable reserve. Detached for the same reason as the reconcile.
      //
      // ⚠️ **No cadence claim to make.** The cursor advances inside the detached
      // message, so a chunk that traps simply leaves the cursor where it was and the
      // next tick retries the same chunk — a permanently trapping chunk stalls coverage
      // (visible as a frozen `indexScan.inFlightCycle.ordersRead`) rather than
      // re-scanning from the start or skipping forward.
      ignore async { scanIndexChunk() };
      let pending = await* sweepDeliverable();
      lastRecoverySweep := ?{ atNs = Time.now(); pending };
      // ── Stranded `#created` capacity (#52) ──────────────────────────────────
      //
      // **Detached, like the count reconcile and for the same reason**: it reads the
      // whole order store AND makes outcalls, so it has two ways to fail that the
      // delivery sweep must survive. Money-out is the thing with cycles outstanding; a
      // release check must never be able to stop it.
      //
      // The cadence is claimed here, in the sweep's own message, so a detached pass that
      // traps retries hourly rather than every tick.
      let now3 = Time.now();
      if (Recovery.expiryScanDue(lastExpiryScanAtNs, now3, Recovery.expiryScanIntervalNs)) {
        lastExpiryScanAtNs := now3;
        ignore async { ignore await* sweepStrandedCreated() };
      };
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
    switch (Recovery.validateInterval(intervalNs, Delivery.ledgerDedupWindowNs)) {
      case (#err(e)) #err(e);
      case (#ok) {
        recoverySweepIntervalNs := intervalNs;
        Timer.cancelTimer(recoveryTimerId);
        recoveryTimerId := Timer.recurringTimer<system>(#nanoseconds(intervalNs), recoverySweep);
        // ⚠️ **This knob also sets the index scan's coverage window (#63), which its
        // name does not say.** The rotating scan runs one chunk per sweep, so coarsening
        // the cadence multiplies the detection latency for `orders.unindexedHolders` —
        // a finding that means the reserve was oversellable. Audited with the resulting
        // window so the consequence is in the same line as the cause, rather than
        // something an operator has to go and derive.
        auditAdmin(
          caller,
          "recovery.intervalSet",
          "sweep cadence set to " # intervalNs.toText() # " ns."
          # " The #63 index scan rides this cadence, so a full coverage cycle now takes about "
          # (expectedIndexScanCycleNs() / 1_000_000_000 / 3_600).toText()
          # " h at the current store size — that is the detection latency for orders.unindexedHolders.",
        );
        #ok;
      };
    };
  };

  /// §5.2 liveness observability, public (operational transparency, same stance as
  /// `reserve_status`): cadence + last completed timer sweep. A null or stale
  /// `lastSweep` means recovery is not running.
  /// This canister's OWN cycle balance and the floor the admission gate holds it
  /// against (public — the same operational-transparency stance as `reserve_status`;
  /// it is visible via `canister_status` regardless).
  ///
  /// ⚠️ **Gas, not stock.** This is what the canister spends to run; the cycles it
  /// sells live in its cycles-ledger account and are reported by `reserve_status`.
  /// Below the freezing threshold the canister stops accepting updates; at zero it is
  /// uninstalled and the order store, journals, and dedup sets go with it. Monitor it
  /// separately, and alert well above `minCanisterCycles` — that gate stops *sales*,
  /// it does not stop the burn. A sudden acceleration here is the
  /// signature of a cycle-drain attempt.
  public query func cycles_status() : async { balance : Nat; floor : Nat } {
    { balance = Cycles.balance(); floor = gateConfig.minCanisterCycles };
  };

  public query func recovery_status() : async {
    intervalNs : Nat;
    lastSweep : ?{ atNs : Int; pending : Nat };
    sweepInFlight : Bool;
    /// Last **successful** tally reconciliation. A non-empty `drift` means the
    /// incremental counts had diverged and were **raised** to the recount — the tallies
    /// are correct again, but the bug that moved them is not fixed. A non-empty
    /// `refused` means the recount came out **lower** and the pass would not adopt it,
    /// so those tallies are still suspect (#63). `recount_orders` is the on-demand form
    /// of the same pass, with the same rule.
    lastCountReconcile : ?{
      atNs : Int;
      drift : [Orders.Drift];
      refused : [Orders.Drift];
      ordersRead : Nat;
    };
    /// When one was last *attempted*. Reported alongside the success timestamp so
    /// "due tomorrow" and "attempted today and failed" are distinguishable without
    /// correlating against the sweep clock: an attempt materially newer than the
    /// success means the reconcile is trapping (RUNBOOK §8).
    lastCountReconcileAttemptNs : Int;
    /// When the RESERVE reconcile was last attempted (#30 PR-B). Its success clock
    /// is `reserve_status.reserveObservedAtNs`, and the two diverging is the one
    /// signal that says "the floor is stale on purpose": either the ledger read is
    /// failing, or every attempt has landed on a non-quiet window. Both under-sell
    /// rather than over-sell, so this is a P3 that explains refusals — not an
    /// incident.
    lastReserveReconcileAttemptNs : Int;
    /// The rotating index scan's **coverage** (#63) — the reader without which a clean
    /// scan says nothing.
    ///
    /// ⚠️ **Read `lastCompletedCycle` before reading the absence of an audit line as
    /// "no drift".** The scan verifies the one property that needs every order — that
    /// nothing *outside* an index satisfies the index's predicate — so it can only
    /// speak for what it has visited. Silence plus a recent `completedAtNs` means
    /// verified clean; silence with no completed cycle, or one much older than the
    /// window below, means **unverified**, which is not the same thing and carries the
    /// opposite response: wait for the pass rather than hunt for a writer.
    ///
    /// `inFlightCycle.ordersRead` against `storedOrders` is how far the current cycle
    /// has walked. `chunkSize` and the sweep interval give the expected window:
    /// `storedOrders ÷ (chunkSize × sweeps per day)` days per full cycle.
    indexScan : {
      chunkSize : Nat;
      storedOrders : Nat;
      /// How long a full coverage cycle is **expected** to take at the current store
      /// size and the current sweep cadence.
      ///
      /// ⚠️ **Computed, not configured, so it moves when either input does** — and the
      /// sweep cadence is one `set_recovery_interval` away from 24× the default. This is
      /// the detection latency for `orders.unindexedHolders`, which is a money finding,
      /// so it is reported rather than left as arithmetic an operator has to know to do.
      /// Compare `lastCompletedCycle.completedAtNs` against this: much older means the
      /// scan is behind its own expectation, not merely mid-cycle.
      expectedFullCycleNs : Nat;
      inFlightCycle : { startedAtNs : Int; ordersRead : Nat; repairs : Nat };
      lastCompletedCycle : ?{
        startedAtNs : Int;
        completedAtNs : Int;
        ordersRead : Nat;
        repairs : Nat;
      };
    };
  } {
    {
      intervalNs = recoverySweepIntervalNs;
      lastSweep = lastRecoverySweep;
      sweepInFlight = recoverySweepInFlight;
      lastCountReconcile;
      lastCountReconcileAttemptNs;
      lastReserveReconcileAttemptNs;
      indexScan = {
        chunkSize = Orders.scanChunkSize;
        storedOrders = Orders.storedCount(orderStore);
        expectedFullCycleNs = expectedIndexScanCycleNs();
        inFlightCycle = indexScanCycle;
        lastCompletedCycle = lastIndexScanCycle;
      };
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
  /// init and `recoverySweep` reaches the order store and the delivery journal,
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
