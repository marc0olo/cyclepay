/// Fully on-chain cycles gateway — composition root.
///
/// The module layout this actor composes: Orders.mo, Delivery.mo, Pricing.mo,
/// Reserve.mo, Gate.mo, Problems.mo, Orphans.mo, Auth.mo, Card.mo, Http.mo.
/// Decision record for the `§N` comments: `docs/DESIGN.md`.
import Array "mo:core/Array";
import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
// ⚠️ Referenced only through dot-notation sugar (`someIter.toArray()`), which resolves
// via the imported module — so this reads as an unused import and is not. Removing it
// fails with M0072 "field toArray does not exist", nowhere near the import.
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
import SecretsMixin "mixins/Secrets";
import PrincipalsMixin "mixins/Principals";
import MonitoringMixin "mixins/Monitoring";
import ConfigMixin "mixins/Config";
import OrdersMixin "mixins/Orders";
import WebhookMixin "mixins/Webhook";
import BuyingMixin "mixins/Buying";
import AdminOrdersMixin "mixins/AdminOrders";
import MaintenanceMixin "mixins/Maintenance";
import Session "rails/Session";
import Secret "Secret";
import Tiers "Tiers";
import Types "Types";

persistent actor CyclesGateway {

  // §7 secret one of TWO: the Stripe webhook signing key. Plaintext by design,
  // SEV-SNP posture documented in Secret.mo. Persists across upgrades; rotation
  // never requires a redeploy.
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

  /// Stripe's two operator-set values: where buyers are returned, and which mode
  /// this deployment serves.
  /// ⚠️ **A record rather than loose `var` fields, because `include` passes by value**
  /// (#120): a mixin handed a bare `var` gets a snapshot from install time, so its
  /// writes land on a copy and its reads never move. A record is a heap object, so the
  /// mixin and the actor share one. Grouped by subsystem, which is the slice a mixin
  /// asks for (`reviewing-motoko` A6) rather than an accessor per field.
  let stripeState : {
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
    var origin : ?Text;
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
    var expectLivemode : ?Bool;
  } = {
    var origin = null;
    var expectLivemode = null;
  };

  /// Principals granted the CASES tier (#68). Controllers are not listed here and do not
  /// need to be — `Auth.checkAdmin` passes them anyway.
  ///
  /// ⚠️ **A principal here is derived from the origin the admin signed in at**, because
  /// Internet Identity derives per origin. Naming a canonical origin is owner-owned and
  /// lands before production; until it is pinned, grants made now may need re-granting by
  /// a controller. Alternative origins let a second origin obtain the canonical origin's
  /// principal — they do not retroactively fix principals derived before one was declared.
  let adminPrincipals = Set.empty<Principal>();

  // Principals allowed to create orders **while this gateway accepts free Stripe
  // test payments** (#99 2b).
  //
  // ⚠️ **Without it a sandbox deployment is a cycles faucet.** Stripe test
  // payments are free and unlimited, so `4242 4242 4242 4242` pays any session
  // for anyone who reaches the page. The simulation divisor caps the loss *per
  // order*; only this list caps the total.
  //
  // ⚠️ **An EMPTY list is not "refuse everyone" per buyer** — that would refuse
  // every buyer on a sandbox deployment before this list is populated, which is
  // the state a fresh gateway is configured in. What bounds the empty case is
  // `Gate.Reason.unboundedGiveaway`, which refuses the moment there is something
  // to sell. So an empty list means unrestricted while the reserve floor is zero
  // (where nothing can be sold anyway) and refusing-everyone once it is not.
  //
  // ⚠️ At go-live (`stripe.expectLivemode == ?true`) it has no effect whatsoever. A list
  // that keeps filtering after go-live is an outage nobody would look for.
  let allowedBuyers = Set.empty<Principal>();

  /// The RULES tier: controller only. Traps rather than returning an error so an
  /// unauthorized call can never be mistaken for a handled outcome.
  ///
  /// ⚠️ **Everything that changes the rules is here, and `scripts/check-admin-tiers.py`
  /// is what keeps it that way** — it reads each method's body and fails when the guard it
  /// calls is not the one its tier declares. A table alone would prove the list complete
  /// and say nothing about whether the code honours it.
  func requireController(caller : Principal) {
    switch (Auth.checkController(caller, Principal.isController)) {
      case (#ok) {};
      case (#err(#anonymous)) Runtime.trap("admin API: anonymous caller rejected");
      case (#err(_)) Runtime.trap("admin API: caller is not a controller");
    };
  };

  /// The CASES tier: a controller, or a principal a controller has granted.
  func requireAdmin(caller : Principal) {
    switch (Auth.checkAdmin(caller, Principal.isController, isGrantedAdmin)) {
      case (#ok) {};
      case (#err(#anonymous)) Runtime.trap("admin API: anonymous caller rejected");
      case (#err(_)) Runtime.trap("admin API: caller is not an admin");
    };
  };

  func isGrantedAdmin(p : Principal) : Bool {
    adminPrincipals.contains(p);
  };





  // ── The buyer allow-list (#99 2b) ────────────────────────────────────────
  //
  // ⚠️ **Controller-only, like everything that changes the RULES.** The list
  // decides who may take cycles out of a funded reserve for free test money, so
  // it is not a per-case decision an admin makes — it is a rule.




  // ── Order + tier state (task 6) ─────────────────────────────────────────

  /// §4.2 order store: `orders` + `principalsToOrders` history.
  let orderStore : Orders.Store = Orders.emptyStore();

  // The price tiles, as one record.
  // ⚠️ **A record rather than loose `var` fields, because `include` passes by value**
  // (#120): a mixin handed a bare `var` gets a snapshot from install time, so its
  // writes land on a copy and its reads never move. A record is a heap object, so the
  // mixin and the actor share one. Grouped by subsystem, which is the slice a mixin
  // asks for (`reviewing-motoko` A6) rather than an accessor per field.
  let tierState : {
    /// §3 fixed card tiers. Operator config (§7): controllers create the
    /// amounts the UI offers as tiles. Presentational since #33: a buyer can order
    /// any amount between the gate's floor and ceiling, so an empty list means "no
    /// tiles", not "rail off". Empty
    /// until first `set_card_tiers` — no made-up default prices.
    var cards : [Tiers.Tier];
  } = {
    var cards = [];
  };

  /// The admission gate's mutable state, as ONE record (#120).
  ///
  /// ⚠️ **A record rather than three `var` fields, because `include` passes by value** —
  /// a mixin handed a bare `var` gets a snapshot from install time, so its writes land
  /// on a copy and its reads never move. A record is a heap object, so the mixin and the
  /// actor share it. Grouped by subsystem rather than one wrapper per field: that is the
  /// slice a mixin asks for (`reviewing-motoko` A6), and it keeps the include sites from
  /// carrying an accessor per field.
  let gateState : {
    /// Pre-creation admission policy (Gate.mo) — open-order cap, own-cycles
    /// floor, per-purchase ceiling. These default to real
    /// values: they are safety limits, and a zero default would brick the
    /// canister rather than protect it.
    var config : Gate.Config;
    /// Refusal tallies and the rail-state latch (#61).
    ///
    /// ⚠️ **Stable, because they replace an audit line.** These carry the content
    /// of the per-attempt `order.notAdmitted` line that #61 removed, and losing
    /// them on upgrade would lose the volume signal the monitoring rows read.
    var refusals : Gate.RefusalCounts;
    var latch : Gate.RailStateLatch;
  } = {
    var config = Gate.defaultConfig();
    var refusals = Gate.noRefusals();
    var latch = Gate.admitting();
  };

  /// `payment_intent` → the order it paid for. Financial record, never pruned;
  /// the only way `charge.refunded` can tell whether the refunded payment had
  /// already been delivered as cycles.
  let paidIntents = Map.empty<Text, Types.OrderId>();

  // ── Pricing rates (§3/§3.1) ─────────────────────────────────────────────

  /// Both §3 rate inputs, cached together. Persistent, so a redeploy does not
  /// blank the price — an upgrade only costs pricing if it outlasts the
  /// staleness window, which the one-shot refresh below covers.
  let rateCache : Pricing.Cache = Pricing.emptyCache();

  /// Pricing policy and the last refresh attempt, as one record.
  /// ⚠️ **A record rather than loose `var` fields, because `include` passes by value**
  /// (#120): a mixin handed a bare `var` gets a snapshot from install time, so its
  /// writes land on a copy and its reads never move. A record is a heap object, so the
  /// mixin and the actor share one. Grouped by subsystem, which is the slice a mixin
  /// asks for (`reviewing-motoko` A6) rather than an accessor per field.
  let pricingState : {
    /// §3 fee formula + staleness window + the delta guard. Admin-adjustable
    /// without a redeploy. There is deliberately no rate-source setting: the XRC
    /// and CMC ids are pinned in their modules, because a settable rate source is
    /// a money lever that does not look like one.
    var config : Pricing.Config;
    /// Liveness for ops. A stale rate is ambiguous between "the timer is dead"
    /// and "XRC is erroring", and those want different responses — so both the
    /// last attempt and the last error are recorded.
    var lastAttempt : ?{ atNs : Int; ok : Bool; detail : Text };
  } = {
    var config = Pricing.defaultConfig();
    var lastAttempt = null;
  };


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

  // Consecutive refresh failures, for backoff. Transient — an upgrade is a
  // fine moment to retry immediately.
  transient var rateRefreshFailures : Nat = 0;

  /// Ticks to skip after a failure, doubling to this cap. XRC answers
  /// `RateLimited` if we hammer it, so backing off is both cheaper and the
  /// behaviour that recovers fastest.
  transient let rateBackoffMaxTicks : Nat = 8;

  /// Remaining ticks to skip before the next attempt.
  transient var rateTicksToSkip : Nat = 0;


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
  /// used to read `tiers.cards.size() > 0`, which was a proxy inherited from the
  /// Payment Link design — and with custom amounts it would stop nothing.
  ///
  /// It gates the rate-refresh timer, so this also fixes a real waste: a gateway
  /// with presets but no API key used to pay for XRC calls it could never use.
  func railsLive() : Bool {
    Secret.status(stripeApiKey).isSet and Secret.status(webhookSecret).isSet;
  };

  func recordRateAttempt(ok : Bool, detail : Text) {
    pricingState.lastAttempt := ?{ atNs = Time.now(); ok; detail };
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
      if (quality.receivedRates < pricingState.config.minRateSources) {
        recordRateAttempt(
          false,
          "too few rate sources: " # quality.receivedRates.toText() # " of "
          # quality.queriedSources.toText() # " answered, need "
          # pricingState.config.minRateSources.toText(),
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
      let previous = switch (Pricing.freshRates(rateCache, pricingState.config.maxAgeNs, Time.now())) {
        case (?prior) ?prior.usdPerIcpMicros;
        case null null;
      };
      if (not Pricing.withinDelta(previous, usdPerIcpMicros, pricingState.config.maxRateDeltaBps)) {
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
    let half = Int.abs(pricingState.config.maxAgeNs) / 2;
    if (half < 30_000_000_000) 30_000_000_000 else half;
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
  func sessionConfig() : { #ok : { apiKey : Text; origin : Text }; #err : Session.Error } {
    let ?apiKey = Secret.get(stripeApiKey) else return #err(#railClosed);
    let ?keyText = apiKey.decodeUtf8() else return #err(#railClosed);
    let ?origin = stripeState.origin else return #err(#originUnset);
    #ok({ apiKey = keyText; origin });
  };

  func createStripeSession(
    config : { apiKey : Text; origin : Text },
    orderId : Types.OrderId,
    clientReferenceId : Text,
    usdCents : Nat,
  ) : async* { #ok : Session.Created; #err : Session.Error } {
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
        switch (stripeState.expectLivemode) {
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
  func expireStripeSession(sessionId : Text) : async* Session.ExpireOutcome {
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
    // ⚠️ Classified in ONE place, by status. See `Session.expireOutcome`: this used to
    // grep the error prose for three invented phrases, so the "already paid" branch
    // could never fire against real Stripe.
    Session.expireOutcome(response.status, response.body);
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


  func sessionErrorToText(e : Session.Error) : Text {
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


  /// Read every admission input, synchronously, immediately before deciding —
  /// no awaits in between, so there is no TOCTOU window between observing and
  /// admitting. `Cycles.balance()` is this canister's own **gas**, which is a
  /// different pot from the reserve it sells — solvency is decided separately, and
  /// synchronously, against the maintained floor.
  func gateObservation(caller : Principal) : Gate.Observation {
    {
      openOrders = Orders.openOrderCount(orderStore, caller, Time.now());
      canisterCycles = Cycles.balance();
      // The maintained floor, read synchronously like everything else here. Used
      // by the faucet check as `> 0` only — never as a solvency input, which is
      // decided separately in `admitOrder`. See `Gate.Observation.reserveFloor`.
      reserveFloor = reserveState.floor;
      // ⚠️ `!= ?true`, so `null` ("either mode") counts as accepting test
      // payments. It is also the DEFAULT, so a freshly installed canister is in
      // this state — a predicate keyed on `?false` would miss exactly that.
      acceptsTestPayments = stripeState.expectLivemode != ?true;
      buyerAllowlistEmpty = allowedBuyers.size() == 0;
      // ⚠️ **The anonymous principal is EXEMPT from the list, and the exemption
      // cannot widen anything.** `create_order` rejects `#anonymous` through
      // `Auth.checkUser` before the gate is consulted, so the shared identity still
      // cannot buy. What this preserves is `can_purchase`: it is a query the
      // frontend calls *before* sign-in, and every suite in this repo probes it
      // anonymously to ask "is the gateway open right now". Filtered, an anonymous
      // probe answered `#buyerNotAllowed` and could no longer see the gas floor,
      // the short reserve or the faucet behind it.
      //
      // The answer to "can this anonymous caller buy" is decided by `#anonymous`,
      // not by a list — so the list has nothing to say about it.
      buyerAllowed = caller.isAnonymous() or allowedBuyers.contains(caller);
    };
  };

  /// The §5.3-adjacent admission gate: refuse to *quote* when fulfilment is
  /// already known to be impossible, rather than taking the user's money and
  /// discovering it at delivery time. Audited on refusal — a rail that has quietly
  /// stopped selling is something the operator must be able to see.
  func admit(caller : Principal, usdCents : Nat) : Result.Result<(), Gate.Reason> {
    switch (Gate.admit(gateState.config, gateObservation(caller), usdCents)) {
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
    // ⚠️ **Synchronous, and that is the whole design.** `reserveState.floor` is a
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
    switch (Gate.solvent(reserveState.floor, Orders.promised(orderStore), lockedCycles)) {
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
        gateState.latch := Gate.latchAdmission(gateState.latch);
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
    gateState.refusals := Gate.countRefusal(gateState.refusals, reason);
    let latched = Gate.latchRefusal(gateState.latch, reason);
    gateState.latch := latched.latch;
    if (latched.announce) {
      audit("gate.startedRefusing", Gate.reasonToText(reason));
    };
  };

  /// Which `sessionConfig` failures are rail **state** — a configuration fact
  /// about this gateway rather than anything about the request.
  ///
  /// ⚠️ **Exhaustive on purpose.** `sessionConfig` can only produce the first two
  /// today, but a new `Session.Error` must decide whether it is a persistent
  /// configuration state (latch it, announce once) or a transient outcall failure
  /// (do not latch — a transient that latched would be cleared by the next
  /// success anyway, but announcing it as "the rail started refusing" would be a
  /// false report).
  func railClosureCondition(e : Session.Error) : ?Gate.RailCondition {
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
  func noteRailClosed(e : Session.Error) {
    gateState.refusals := Gate.countRailClosed(gateState.refusals);
    switch (railClosureCondition(e)) {
      case (?condition) {
        let latched = Gate.latchCondition(gateState.latch, condition);
        gateState.latch := latched.latch;
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
  /// ⚠️ **Takes a DETAIL rather than a `Session.Error`, because the callers know
  /// different things.** It used to render `sessionErrorToText(e)`, and the retrieve
  /// path's `#unauthorized` has no honest `Session.Error` to pass: `#railClosed` renders
  /// as "the API key is not provisioned", which is exactly wrong — the key is present
  /// and Stripe is refusing it. The remedy differs too (rotate versus provision), so
  /// squeezing three call sites through one enum produced a confident wrong sentence.
  func noteStripeApiFailed(detail : Text) {
    gateState.refusals := Gate.countStripeApiFailed(gateState.refusals);
    let latched = Gate.latchCondition(gateState.latch, #stripeApiFailing);
    gateState.latch := latched.latch;
    if (latched.announce) {
      audit("gate.startedRefusing", "stripeApiFailing: " # detail);
    };
  };

  /// Built per request rather than held in a transient field: it carries
  /// `maxPurchaseUsdCents` from the live gate config, so a ceiling change takes
  /// effect on the very next webhook.
  func webhookDeps() : Card.Deps {
    {
      // The live set: `Deps` is rebuilt per call, so this is never a stale copy.
      cancelRequests;
      orders = orderStore;
      dedup;
      orphanStore;
      expectLivemode = stripeState.expectLivemode;
      auditLog;
      paidIntents;
      maxPurchaseUsdCents = gateState.config.maxPurchaseUsdCents;
    };
  };











  // ── Delivery from the reserve (§5/§5.1) ─────────────────────────────────

  /// The reserve's own mutable state, as ONE record (#120).
  ///
  /// ⚠️ **A record rather than four `var` fields, because `include` passes by value.**
  /// A mixin handed `var reserveState.floor` would get a snapshot from install time — its
  /// writes would land on a copy and its reads would never move. A record is a heap
  /// object, so the mixin and the actor share it. The alternative, an accessor closure
  /// per field, puts four of them at every include site to work around the same
  /// semantics; grouping by subsystem is also what `reviewing-motoko` A6 asks for —
  /// a mixin receives the slice it uses, not the fields one at a time.
  ///
  /// ⚠️ **This moved the stable shape**, deliberately and once: pre-launch, with no
  /// migration chain (#32), a reinstall is the documented loop and there is no data to
  /// preserve. `deployed/backend.most` is promoted in the same commit, and
  /// `scripts/check-stable-promotion.sh` reports it as a REAL shape change rather than
  /// renumbering — which is the distinction that makes the promotion reviewable.
  let reserveState : {
    /// #30 PR-B — a maintained **lower bound** on the reserve's ledger balance.
    ///
    /// Sound because the balance can only fall when we transfer out — delivery to a
    /// buyer, or `withdraw_reserve` to a controller (#103), both of which decrement this
    /// floor before issuing; no allowance exists for anyone to pull from the account, and
    /// the ledger's own `withdraw` is owner-only and not declared. It can only rise on a
    /// top-up we cannot see until we look. So every unobserved change is in our favour. `Reserve.mo`'s floor section has the
    /// full argument and the three maintenance rules.
    ///
    /// ⚠️ It is a bound, not the balance. The **actual** reserve is a public account
    /// on a public ledger that anyone — the operator, the frontend, monitoring — can
    /// read for free without asking this canister. `reserve_status` reports all three
    /// figures so "the ledger says 100 T and the gateway will sell 0" is diagnosable
    /// at a glance rather than a mystery.
    var floor : Nat;

    /// Monotone count of transfers ISSUED out of the reserve. Only purpose: letting a
    /// reconcile prove no outflow happened across its balance read (see
    /// `refresh_reserve`). Transient is wrong here — an upgrade mid-reconcile would
    /// make the counter look unchanged — so it is stable.
    var outflowsIssued : Nat;

    /// When `reserveState.floor` was last reconciled against the ledger, so staleness is
    /// legible rather than invisible. Null until the first observation — which is
    /// also why a fresh canister sells nothing until the operator refreshes.
    var observedAtNs : ?Int;

    /// The cycles ledger's transfer fee, as last learned from the ledger (#30 PR-B).
    ///
    /// ⚠️ **Stored rather than awaited, and `#BadFee` is why that is safe.** An ICRC-1
    /// ledger rejects a wrong fee **definitively and reports the expected one**, so a stale
    /// value costs one rejected call, self-corrects in the same message, and is persisted
    /// for every later order. In exchange the delivery path loses an await — and with it
    /// the failure mode where a ledger hiccup on a *read* stalled a delivery that was fully
    /// funded and ready.
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
    var cyclesLedgerFee : Nat;
  } = {
    var floor = 0;
    var outflowsIssued = 0;
    var observedAtNs = null;
    var cyclesLedgerFee = Delivery.cyclesLedgerDefaultFee;
  };

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

  /// Orders whose OWNER has asked to cancel, recorded before the Stripe outcall (§4.3).
  ///
  /// ⚠️ **`cancel_order` expires the session at Stripe BEFORE recording the cancel**
  /// (#33 option B: nothing is ever half-cancelled). Between those two steps the order
  /// looks expired to everyone, because it is: Stripe fires `checkout.session.expired`
  /// immediately, and three writers can reach the order first — that webhook, the #52
  /// sweep, and the admin expire. The buyer's own cancellation was recorded as
  /// `#sessionExpired`, which is exactly the provenance #34 added `expiredBy` to keep.
  ///
  /// ⚠️ **Intent, not a lock, and that distinction is the fix.** An earlier attempt used
  /// a transient set and made the sweep skip; the webhook lives in another module that
  /// could not see it, so it went on winning. Preventing the race needs every writer to
  /// remember a guard. Recording the intent means whoever wins ATTRIBUTES correctly, so
  /// the race stops mattering. `Orders.settleUnpayable` is the one place that reads it.
  ///
  /// ⚠️ **`expireWithCause`'s own no-op guard cannot cover this.** That guard protects
  /// an order that is ALREADY `#cancelled`; here the cancel has not been recorded yet.
  ///
  /// ⚠️ **Stable, because a trap or an upgrade mid-cancel must not lose the intent** —
  /// that is precisely the window where the order settles without the buyer. A new
  /// stable var is upgrade-compatible; this is not a field on an existing record.
  ///
  /// ⚠️ **Membership implies `#created`, and every exit from `#created` removes.** That
  /// is the bound, and it has to be enumerated rather than asserted, because the earlier
  /// claim here — "pruned when the order goes terminal" — was simply not true of the
  /// paths that return an error. `isLegalTransition` gives `#created` three exits:
  ///
  ///  * `#cancelled` and `#expired` — every writer goes through `Orders.settleUnpayable`
  ///    or `Orders.expireBySession`, which remove the id in the act of deciding with it,
  ///    plus `cancel_order`'s own success and already-settled returns below.
  ///  * `#paid` — one writer, `Orders.markPaid`, called only from `rails/Card.mo`, which
  ///    removes it there: the payment won, and `#cancelled` is unreachable from `#paid`,
  ///    so nothing could honour the intent afterwards.
  ///
  /// `expireWithCause` is the apparent fourth writer and needs no removal: it fires only
  /// for an order whose session never attached, and `cancel_order` records nothing for
  /// one of those — with no session id it takes the sessionless branch.
  ///
  /// ⚠️ **A stale entry could never mis-attribute even so**, because a delivered or paid
  /// order cannot transition to `#cancelled`. The reason to bound it is stable growth,
  /// not correctness — which is why the fix is one removal at the third exit rather than
  /// threading the set through every status writer.
  let cancelRequests = Set.empty<Types.OrderId>();

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

  /// Delivery policy, as one record.
  /// ⚠️ **A record rather than loose `var` fields, because `include` passes by value**
  /// (#120): a mixin handed a bare `var` gets a snapshot from install time, so its
  /// writes land on a copy and its reads never move. A record is a heap object, so the
  /// mixin and the actor share one. Grouped by subsystem, which is the slice a mixin
  /// asks for (`reviewing-motoko` A6) rather than an accessor per field.
  let deliveryState : {
    /// The two thresholds the delivery timeline reads: alert at 2 h, terminate at 72 h.
    var config : Delivery.Config;
  } = {
    var config = Delivery.defaultConfig();
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
        switch (Delivery.waitStage(order.updatedAtNs, Time.now(), deliveryState.config)) {
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
          // makes a stored copy self-correcting. See `reserveState.cyclesLedgerFee`.
          //
          // ⚠️ **Do not put an await back between here and the transfer issue.** Two
          // things depend on there being none: the post-await re-read this case used
          // to need is gone (nothing can move the order in a synchronous stretch),
          // and `unsettledDeliveries` — the reconcile's quiet-window predicate —
          // relies on an intent never being visible without its transfer having been
          // issued in the same message. Its doc spells that out.
          let fee = reserveState.cyclesLedgerFee;
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
          reserveState.floor := Reserve.floorAfterOutflow(reserveState.floor, debited);
          reserveState.outflowsIssued += 1;
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
              reserveState.floor += debited;
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
              reserveState.cyclesLedgerFee := expected;
              audit("delivery.feeChanged", orderId # ": ledger expects " # expected.toText() # " (intent implies " # fee.toText() # "); reserve absorbs the difference, and " # expected.toText() # " is now the stored fee");
              // ── Rule 3 (§5.4): a DEFINITIVE rejection credits the floor back ──
              // `#BadFee` means the ledger processed the call and refused it, so nothing
              // moved and rule 2's decrement was not a real debit.
              // ⚠️ If the re-issue then fails with no reply, the LARGER decrement stands
              // — correctly pessimistic.
              reserveState.floor += debited;
              let reDebited = intent.amountCycles + expected;
              reserveState.floor := Reserve.floorAfterOutflow(reserveState.floor, reDebited);
              reserveState.outflowsIssued += 1;
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
                  reserveState.floor += reDebited;
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
              reserveState.floor += debited;
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
              reserveState.floor += debited;
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




  /// The journal half of the quiet-window predicate: a transfer issued and no block
  /// recorded. Says nothing about status on purpose — the ORDER supplies that, and
  /// `unsettledDeliveries` is the one place the two meet.
  ///
  /// ⚠️ **Soundness requires NO AWAIT between the intent write and the transfer issue, and
  /// nothing in the type system enforces it.** The one await that used to sit in that
  /// stretch (`icrc1_fee`) became a stored value, which is why the two are adjacent today.
  /// Reintroduce an await there and a reconcile can adopt a balance while a transfer it
  /// cannot see is in flight. This comment is the guard.
  func openTransfer(entry : Types.JournalEntry) : Bool {
    entry.transferIntent != null and entry.blockIndex == null;
  };

  /// Every promise-holding order paired with its journal entry — **the only route either
  /// reader takes to the journal**, so neither can be bounded and the other not.
  ///
  /// ⚠️ Bounded by `promiseHolders`, which is bounded by flow (§5.4), NOT by the journal,
  /// which gains an entry per `#paid` order and never loses one.
  func forEachPromisedDelivery(f : (Types.Order, Types.JournalEntry) -> ()) {
    for (id in Orders.promiseHolderIds(orderStore)) {
      switch (Orders.get(orderStore, id), deliveryJournal.get(id)) {
        case (?order, ?entry) f(order, entry);
        case _ {};
      };
    };
  };

  /// Deliveries that may still respond: a transfer issued, no recorded block, on an order
  /// that is still `#paid`. The quiet-window predicate — why it is a superset of "in
  /// flight", and why the cost is not a deadlock: `docs/DESIGN.md` §5.4.
  ///
  /// ⚠️ **The `#paid` clause is load-bearing, and leaving it out froze the reserve.** An
  /// escalated order keeps the intent-without-block shape *forever*, so without it one
  /// escalation makes the quiet window unsatisfiable for the life of the canister: every
  /// reconcile skips, every `refresh_reserve` skips, and top-ups stop registering.
  ///
  /// ⚠️ **This count going LOW is the oversell direction** — a quiet window that reads
  /// quiet while a transfer is in flight lets the floor adopt a balance the transfer has
  /// already left. So completeness is the property to protect, and it is by construction
  /// rather than by recount: a transfer is only ever issued from `#paid`, `#paid` holds
  /// the promise, and `promiseHolders` is maintained on that same `Reserve.holdsPromise`
  /// predicate inside `Orders.commitTransition`. Every order with a transfer in flight is
  /// therefore in the index. Its three exits keep it that way — `#delivered` records the
  /// block in the same patch, `#needsReview` is still non-terminal and still indexed, and
  /// `#abandoned` is **refused while a transfer is open** (`abandon_order`).
  ///
  /// ⚠️ A stale index member is harmless here and does not need dropping: its order reads
  /// non-`#paid`, so it simply does not count.
  ///
  /// ⚠️ **Do not add a force flag to `refresh_reserve`.** Adopting across an unsettled
  /// delivery is the exact bug this predicate prevents, so a lever for it is a lever for
  /// the bug.
  func unsettledDeliveries() : Nat {
    var n = 0;
    forEachPromisedDelivery(
      func(order, entry) {
        if (order.status == #paid and openTransfer(entry)) n += 1;
      }
    );
    n;
  };


  /// How long a `#paid` order has waited, as a stage; `null` for any other status.
  ///
  /// ⚠️ **ONE read of the clock per order.** "Is it delayed" and "is it past max hold" are
  /// both answered off this single value. Calling `waitStage` twice worked — it is
  /// deterministic — but it put a second call site of the same computation in the code
  /// whose point is one definition, and `pastMaxHold` would have diverged silently if this
  /// predicate's clock or config source ever changed.
  ///
  /// ⚠️ **`#paid` only, and NOT gated on a journal entry or an intent existing.** A
  /// delivery that BAILS before issuing a transfer — a short reserve, a stale rate, the gas
  /// floor — leaves a `#paid` order with no intent, and that is exactly the order an
  /// operator must see, because nothing else will surface it. So this reads the ORDER's
  /// clock. Going through the order↔journal join, as `deliveriesOutstanding` does, would
  /// silently under-report it.
  ///
  /// (Not "before the first sweep runs": the webhook drives delivery itself, so a paid
  /// order normally has its entry and intent immediately.)
  func deliveryStage(order : Types.Order, nowNs : Int) : ?{ #retry; #alert; #terminate } {
    if (order.status != #paid) return null;
    ?Delivery.waitStage(order.updatedAtNs, nowNs, deliveryState.config);
  };

  /// Which stages are worth an operator's attention — **the one definition**, shared by
  /// `delayed_deliveries` and `operator_summary`. Two copies would let the paged list and
  /// the summary count disagree, and the summary is the number someone acts on.
  func stageIsDelayed(stage : { #retry; #alert; #terminate }) : Bool {
    switch (stage) {
      case (#retry) false;
      case (#alert or #terminate) true;
    };
  };

  func deliveryDelayed(order : Types.Order, nowNs : Int) : Bool {
    switch (deliveryStage(order, nowNs)) {
      case (?stage) stageIsDelayed(stage);
      case null false;
    };
  };

  /// How many deliveries are late — the count behind `delayed_deliveries`' page.
  ///
  /// ⚠️ Bounded by `promiseHolders`, which is bounded by flow (§5.4), not by lifetime
  /// sales.
  func delayedDeliveryCount(nowNs : Int) : Nat {
    var n = 0;
    for (id in Orders.promiseHolderIds(orderStore)) {
      switch (Orders.get(orderStore, id)) {
        case (?order) { if (deliveryDelayed(order, nowNs)) n += 1 };
        case null {};
      };
    };
    n;
  };



  /// ⚠️ `quiet` must mean "no outflow could have moved the balance between the read
  /// and this call" — see `Reserve.adoptObservation`, and `refresh_reserve` for how
  /// it is established. Passing `true` loosely reintroduces the bug this design
  /// exists to remove.
  func reconcileReserve(observed : Nat, quiet : Bool) {
    let adopted = Reserve.adoptObservation(reserveState.floor, observed, quiet);
    if (not adopted.adopted) {
      audit("reserve.reconcileSkipped", "deliveries were in flight across the balance read; keeping the maintained floor of " # reserveState.floor.toText());
      return;
    };
    if (adopted.unexplainedShortfall > 0) {
      audit(
        "reserve.unexplainedShortfall",
        "ledger holds " # observed.toText() # " but the floor said at least "
        # reserveState.floor.toText() # " — short by " # adopted.unexplainedShortfall.toText()
        # ". No outflow but ours is possible, so treat this as a bookkeeping breach and reconcile before selling more.",
      );
    };
    reserveState.floor := adopted.floor;
    reserveState.observedAtNs := ?Time.now();
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
  /// ⚠️ **`holdersAfter` is returned rather than left for the caller to re-read, and
  /// that is the point.** `withdraw_reserve` must re-check the promise-holder count
  /// after this await — the floor is still full across it, so a `create_order` queued
  /// here would be admitted against a reserve about to leave. Handing the count back
  /// from the await the caller is already forced to make means there is nothing left to
  /// forget: a comment saying "re-read this" is the weakest possible guard, and this
  /// makes the value arrive with the result instead.
  ///
  /// Read AFTER the await, deliberately — a count captured before it answers the wrong
  /// question.
  func observeReserve() : async* { observed : Nat; quiet : Bool; holdersAfter : Nat } {
    let unsettledBefore = unsettledDeliveries();
    let issuedBefore = reserveState.outflowsIssued;
    let observed = await cyclesLedger.icrc1_balance_of(Delivery.reserveAccount(selfPrincipal()));
    let quiet = unsettledBefore == 0 and unsettledDeliveries() == 0 and reserveState.outflowsIssued == issuedBefore;
    reconcileReserve(observed, quiet);
    ({ observed; quiet; holdersAfter = Orders.promiseHolderCount(orderStore) });
  };














  // ── Recovery timer (task 11, §5.2) ──────────────────────────────────────

  /// The recovery machinery's mutable state, as ONE record (#120, docs/DESIGN.md §9.1).
  ///
  /// ⚠️ Four independent passes write here — the stranded sweep, the tally reconcile, the
  /// reserve reconcile and the rotating index scan — and `recovery_status` reads all of
  /// them. Grouped so a mixin receives one slice rather than eight fields, and shared by
  /// reference because `include` passes by value.
  let recoveryState : {
    /// §5.2 sweep cadence. Persistent — an operator-tuned cadence survives
    /// upgrades; the transient timer below re-arms at this value. Bounded by
    /// Recovery.validateInterval (≪ the §5.1 ledger dedup window).
    var sweepIntervalNs : Nat;
    /// Last *completed* timer sweep — recovery liveness for ops (the §5.2
    /// timer is the backstop for every detached webhook kick that dies, so
    /// "is it actually firing" must be observable).
    var lastSweep : ?{ atNs : Int; pending : Nat };
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
    };
    /// When the reserve reconcile was last *attempted*. Same attempt-vs-success split
    /// as the count reconcile below, for the same reason: `reserveState.observedAtNs` records
    /// success, and gating the cadence on that alone would retry a failing (or
    /// perpetually non-quiet) read on every single tick.
    var lastReserveReconcileAttemptNs : Int;
    /// When a reconcile was last *attempted*, which is what gates the cadence.
    ///
    /// Separate from the success timestamp on purpose. A trap rolls back every
    /// state change in its own message, so a reconcile that traps cannot record
    /// that it ran — gating on success alone would leave it due on the next tick
    /// and every tick after, trapping forever. This is written by the **sweep's**
    /// message, which commits regardless of what the detached reconcile does.
    var lastCountReconcileAttemptNs : Int;
    /// Where the current coverage cycle has reached. `null` means a cycle is about to
    /// start from the beginning of the store.
    ///
    /// ⚠️ **Persistent, because the coverage claim is what this state is for.** A
    /// transient cursor would silently restart every cycle on every upgrade, so
    /// `lastIndexScanCycle` would report a completed pass that an upgrade had truncated —
    /// a green check that means nothing.
    var indexScanCursor : ?Types.OrderId;
    /// The cycle in progress: when it began, how many orders it has read, and how many
    /// disagreements it has repaired so far.
    var indexScanCycle : { startedAtNs : Int; ordersRead : Nat; repairs : Nat };
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
    };
  } = {
    var sweepIntervalNs = Recovery.defaultIntervalNs;
    var lastSweep = null;
    var lastCountReconcile = null;
    var lastReserveReconcileAttemptNs = 0;
    var lastCountReconcileAttemptNs = 0;
    var indexScanCursor = null;
    var indexScanCycle = {
      startedAtNs = 0;
      ordersRead = 0;
      repairs = 0;
    };
    var lastIndexScanCycle = null;
  };

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
  /// Measured, not theorised: two integration scenarios failed with "the sweep never
  /// retrieved session …" because their order sat behind ten permanently-due neighbours.
  ///
  /// ⚠️ **An id, NOT an index.** An index into a snapshot is meaningless across ticks,
  /// because an insert shifts every later position.
  ///
  /// The lesson belongs with the deletion discipline rather than here: **a disposal
  /// record has to carry the invariants the deleted code satisfied**, not only where its
  /// behaviour went, or the next thing of that shape pays for them again.
  ///
  /// This pages the **due set** rather than the store, because "due" is not a
  /// store-order property — collecting it costs one scan and no outcalls, and the cap
  /// applies to the expensive half.
  transient var expiryScanCursor : Text = "";





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
        func d = d.status # " " # d.was.toText() # "→" # d.is.toText()
      );
      audit(
        "orders.countDrift",
        "raised to the recount over the non-terminal index: " # rendered.values().join(", ")
        # ". The counts are right again; the writer that lost the adjustment is not fixed.",
      );
    };
    if (report.refused.size() > 0) {
      let rendered = report.refused.map(
        func d = d.status # " tally " # d.was.toText() # ", recount " # d.is.toText()
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
  /// **Its cost is now bounded by flow rather than by lifetime sales (#63)** — it
  /// recounts over `Orders.promiseHolders`, whose size the reserve caps. The pass it
  /// replaced summed every order ever created in one message and was on a path to the
  /// instruction limit.
  ///
  /// ⚠️ **Daily is a SUFFICIENCY choice, not a cost one.** Drift can only come from a
  /// bookkeeping bug, which does not need a 15-minute detection window. Do not justify
  /// the cadence by cost — that would describe a scan this function no longer performs.
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
    recoveryState.lastCountReconcile := ?{
      atNs = Time.now();
      drift = report.adopted;
      refused = report.refused;
      ordersRead = report.ordersRead;
    };
    reportReconciliation(report);
  };

  // ── The rotating index scan (#63) ───────────────────────────────────────




  /// The expected time for one full coverage cycle, hence the detection latency for the
  /// outside direction. The arithmetic is `Recovery.indexScanCycleNs`, which is pure and
  /// unit-tested — this only supplies the three live inputs.
  func expectedIndexScanCycleNs() : Nat {
    Recovery.indexScanCycleNs(
      Orders.storedCount(orderStore),
      Orders.scanChunkSize,
      recoveryState.sweepIntervalNs,
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
  /// ⚠️ **The honest claim is "bounded PER MESSAGE", not "bounded".** The daily reconcile
  /// verifies only the inside direction of each index; the outside direction is this scan,
  /// so detecting an unindexed promise-holder takes up to one full cycle — and the cycle
  /// grows **linearly in stored orders** (`⌈stored ÷ chunk⌉ × interval`). The right trade
  /// (work that traps is fatal; latency that grows is degradable and observable) but a
  /// trade, so do not describe the reconcile as simply "bounded".
  ///
  /// ⚠️ **`set_recovery_interval` is a lever on this latency and its name does not say
  /// so** — tunable to 24× the default. `recovery_status.indexScan.expectedFullCycleNs` is
  /// computed from the live interval so an operator reads the window rather than deriving
  /// it.
  ///
  /// ⚠️ **Detached into its own message by the caller, like the reconcile**, so a trap
  /// here cannot take the sweep — and therefore money-out — down with it. It takes no
  /// `await`, so its own state commits or rolls back as a unit.
  func scanIndexChunk() {
    let now = Time.now();
    let starting = recoveryState.indexScanCursor == null;
    if (starting) {
      recoveryState.indexScanCycle := { startedAtNs = now; ordersRead = 0; repairs = 0 };
    };
    let chunk = Orders.scanChunk(orderStore, recoveryState.indexScanCursor, Orders.scanChunkSize);
    let repairs = chunk.unindexedHolders.size() + chunk.unindexedProblems.size();
    recoveryState.indexScanCycle := {
      recoveryState.indexScanCycle with
      ordersRead = recoveryState.indexScanCycle.ordersRead + chunk.visited;
      repairs = recoveryState.indexScanCycle.repairs + repairs;
    };
    recoveryState.indexScanCursor := chunk.nextCursor;
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
      recoveryState.lastIndexScanCycle := ?{
        startedAtNs = recoveryState.indexScanCycle.startedAtNs;
        completedAtNs = Time.now();
        ordersRead = recoveryState.indexScanCycle.ordersRead;
        repairs = recoveryState.indexScanCycle.repairs;
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
        switch (Orders.settleUnpayable(orderStore, cancelRequests, orderId, #sessionExpired, Time.now())) {
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
        // file a self-resolving obligation on the order — noise in a worklist that
        // never drops anything, so it buries the real ones. The audit line is the
        // support signal instead: a buyer who paid
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
      if (Recovery.reconcileDue(recoveryState.lastCountReconcileAttemptNs, now, Recovery.countReconcileIntervalNs)) {
        recoveryState.lastCountReconcileAttemptNs := now;
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
      recoveryState.lastSweep := ?{ atNs = Time.now(); pending };
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
      if (Recovery.reconcileDue(recoveryState.lastReserveReconcileAttemptNs, now2, Recovery.reserveReconcileIntervalNs)) {
        recoveryState.lastReserveReconcileAttemptNs := now2;
        try { ignore (await* observeReserve()).observed } catch (e) {
          audit("reserve.observeFailed", "could not read the reserve balance: " # e.message() # " — the floor stands, so the gateway under-sells until the next attempt");
        };
      };
    } finally {
      recoverySweepInFlight := false;
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




  /// §5.2 the timer itself. Transient initializer = runs on install AND on
  /// every upgrade (postupgrade re-initialization), so a deploy can never
  /// leave recovery dead; the IC drops timers across upgrades, so there is
  /// no stale duplicate to cancel.
  ///
  /// Declared last in the actor body: the initializer evaluates during actor
  /// init and `recoverySweep` reaches the order store and the delivery journal,
  /// both of which must already be initialized (M0016 otherwise).
  transient var recoveryTimerId : Timer.TimerId =
    Timer.recurringTimer<system>(#nanoseconds(recoveryState.sweepIntervalNs), recoverySweep);

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

  // ── Endpoints, by feature (#120; the rules are docs/DESIGN.md §9.1) ─────────
  //
  // ⚠️ **Every `include` sits at the END of the actor body, and that is required rather
  // than tidy.** Its arguments are evaluated once, right here, so each must name a field
  // or helper already declared above — `auditAdmin` is defined ~2,000 lines up. An
  // include placed where the endpoints used to be would capture bindings that do not
  // exist yet.
  //
  // ⚠️ **A `var` field is passed as an ACCESSOR PAIR, never as the field.** `include`
  // takes its arguments by value, so handing over `stripe.origin` would give the mixin a
  // snapshot from install time: the setter would mutate a copy and the getter would
  // answer that snapshot forever. Records and collections (`Secret.Store`,
  // `Orders.Store`, the maps and sets) are heap objects, so those pass directly and
  // write through.
  //
  // ⚠️ **Accessors rather than wrapping the `var` in a record**, which is the other fix
  // and the expensive one: wrapping changes the actor's stable shape, and with no
  // migration chain (#32) that means a reinstall. Closures are parameters, never stable
  // state, so `deployed/backend.most` does not move for this split.
  include MaintenanceMixin(
    orderStore,
    rateCache,
    cyclesLedger,
    reserveState,
    {
      auditAdmin;
      requireAdmin;
      requireController;
      refreshRates;
      observeReserve;
      reportReconciliation;
    },
  );

  include AdminOrdersMixin(
    orderStore,
    dedup,
    orphanStore,
    auditLog,
    deliveryJournal,
    paidIntents,
    cancelRequests,
    {
      audit;
      auditAdmin;
      requireAdmin;
      isGrantedAdmin;
      noteStripeApiFailed;
      tryTransition;
      expireStripeSession;
      deliveryStage;
      stageIsDelayed;
      openTransfer;
      forEachPromisedDelivery;
    },
  );

  include BuyingMixin(
    orderStore,
    rateCache,
    reserveState,
    gateState,
    pricingState,
    tierState,
    {
      audit;
      admit;
      gateObservation;
      admitOrder;
      noteStripeApiFailed;
      sessionConfig;
      createStripeSession;
      createOrderWithFreshId;
      noteRailClosed;
      sessionErrorToText;
    },
  );

  include WebhookMixin(
    routes,
    maxRequestBodyBytes,
    {
      // Read and cleared as one step, so a stale value cannot trigger a second kick.
      take = func() : ?Types.OrderId {
        let taken = webhookPaidOrder;
        webhookPaidOrder := null;
        taken;
      };
    },
    { processDelivery },
  );

  include OrdersMixin(
    orderStore,
    deliveryJournal,
    cancelRequests,
    {
      audit;
      auditAdmin;
      noteStripeApiFailed;
      tryTransition;
      expireStripeSession;
      processDelivery;
      isGrantedAdmin;
      deliveryInFlight = func(id : Types.OrderId) = deliveriesInFlight.contains(id);
    },
  );

  include ConfigMixin(
    orderStore,
    rateCache,
    reserveState,
    gateState,
    pricingState,
    stripeState,
    tierState,
    deliveryState,
    recoveryState,
    {
      requireController;
      auditAdmin;
      expectedIndexScanCycleNs;
      rearmRateTimer = func<system>() {
        Timer.cancelTimer(rateTimerId);
        rateTimerId := Timer.recurringTimer<system>(#nanoseconds(rateIntervalNs()), rateTimerJob);
      };
      rearmRecoveryTimer = func<system>(intervalNs : Nat) {
        Timer.cancelTimer(recoveryTimerId);
        recoveryTimerId := Timer.recurringTimer<system>(#nanoseconds(intervalNs), recoverySweep);
      };
    },
  );

  include MonitoringMixin(
    orderStore,
    dedup,
    orphanStore,
    paidIntents,
    rateCache,
    reserveState,
    gateState,
    pricingState,
    stripeState,
    recoveryState,
    {
      requireAdmin;
      selfPrincipal;
      unsettledDeliveries;
      delayedDeliveryCount;
      expectedIndexScanCycleNs;
      lastXrcCanisterId = func() = lastXrcCanisterId;
      recoverySweepInFlight = func() = recoverySweepInFlight;
    },
  );

  include PrincipalsMixin(
    adminPrincipals,
    allowedBuyers,
    reserveState,
    stripeState,
    requireController,
    auditAdmin,
  );

  include SecretsMixin(
    webhookSecret,
    stripeApiKey,
    { get = func() = stripeState.origin; set = func(v : ?Text) { stripeState.origin := v } },
    requireController,
    requireAdmin,
    auditAdmin,
    func() = Time.now(),
  );
};
