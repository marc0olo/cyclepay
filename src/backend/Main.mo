/// Fully on-chain cycles gateway — composition root.
///
/// See design-docs/ONCHAIN_GATEWAY_SPEC.md (spec v2.1) and PRD.md for the
/// module layout this actor grows into: Orders.mo wiring, rails/, Cmc.mo,
/// Forex.mo, Treasury.mo, ErrorQueue.mo, Auth.mo.
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Call "mo:ic/Call";
import IC "mo:ic/Types";
import AuditLog "AuditLog";
import Auth "Auth";
import ErrorQueue "ErrorQueue";
import Forex "Forex";
import Http "Http";
import Idempotency "Idempotency";
import Orders "Orders";
import Card "rails/Card";
import Secret "Secret";
import Tiers "Tiers";
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
    Secret.set(webhookSecret, secret.encodeUtf8(), Time.now());
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

  // ── Forex (task 7, §3.1) ────────────────────────────────────────────────

  /// §3.1 stable `{rate, ts}` cache — orders read this; only staleness
  /// triggers an outcall. Survives upgrades, so a redeploy doesn't force a
  /// refresh before the first order.
  let forexCache : Forex.Cache = Forex.emptyCache();

  /// §3 fee formula + §3.1 staleness window + source URL. Admin-adjustable
  /// (§7 "adjust forex params") without a redeploy.
  var forexConfig : Forex.Config = Forex.defaultConfig();

  /// §3.1 single-flight guard: at most one outcall in flight; a burst
  /// hitting a stale cache fails closed (#rateUnavailable, retry shortly)
  /// instead of stampeding the source. Transient on purpose — a persistent
  /// flag left true by an upgrade mid-outcall would deadlock refreshes
  /// forever; an upgrade resets it.
  transient var forexRefreshInFlight = false;

  /// §3.1 in-call retry cap — consensus boundary-splits often clear on an
  /// immediate retry; API-down does not, so we bound the attempts and fail
  /// closed.
  transient let forexMaxAttempts : Nat = 3;

  /// The default source's USD-base body is ~4 KiB; cycles are charged on
  /// this ceiling, not the actual size, so keep it tight.
  transient let forexMaxResponseBytes : Nat64 = 16_000;

  /// §3.1 coarse-rounding transform: every replica reduces its raw response
  /// to a tiny canonical body (rounded micro-XDR/USD, or empty on parse
  /// failure), so consensus is over `"737000"`, not 4 KiB of live JSON.
  public query func forex_transform(args : { context : Blob; response : IC.HttpRequestResult }) : async IC.HttpRequestResult {
    { args.response with headers = []; body = Forex.transformBody(args.response.body) };
  };

  /// §3.1 lazy refresh: fire the outcall (≤ forexMaxAttempts), record the
  /// rate on success. Returns the fresh micro-rate, or null for the caller
  /// to fail closed. Never traps on outcall failure — the error becomes a
  /// blocked order, not a 5xx.
  func refreshForexRate() : async* ?Nat {
    if (forexRefreshInFlight) return null;
    forexRefreshInFlight := true;
    try {
      var attempts = 0;
      while (attempts < forexMaxAttempts) {
        let micros = try {
          let response = await Call.httpRequest({
            url = forexConfig.url;
            method = #get;
            max_response_bytes = ?forexMaxResponseBytes;
            body = null;
            headers = [
              { name = "Host"; value = Forex.hostOf(forexConfig.url) },
              { name = "User-Agent"; value = "cycles-gateway" },
            ];
            transform = ?{ function = forex_transform; context = "".encodeUtf8() };
            is_replicated = null;
          });
          if (response.status == 200) Forex.parseCanonicalMicros(response.body) else null;
        } catch (_) null;
        switch (micros) {
          case (?m) { Forex.record(forexCache, m, Time.now()); return ?m };
          case null attempts += 1;
        };
      };
      null;
    } finally {
      forexRefreshInFlight := false;
    };
  };

  /// Adjust forex params (§7): fee formula, staleness window, source URL.
  /// Validated atomically — a bad config never partially applies.
  public shared ({ caller }) func set_forex_config(config : Forex.Config) : async Result.Result<(), Forex.ConfigError> {
    requireAdmin(caller);
    switch (Forex.validateConfig(config)) {
      case (#ok) { forexConfig := config; #ok };
      case (#err(e)) #err(e);
    };
  };

  /// Cache + params, public: the rate is market data and the fee formula is
  /// what users are charged — nothing here is secret, and transparency is
  /// the product thesis.
  public query func forex_status() : async { rate : ?Forex.Rate; config : Forex.Config } {
    { rate = forexCache.rate; config = forexConfig };
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
  };

  public type CreatedOrder = {
    order : Types.Order;
    /// `<principal>_<orderId>` — the frontend appends this to the tier's
    /// Payment Link as `?client_reference_id=` (§6.1).
    clientReferenceId : Text;
  };

  /// One tier quote = one consistent epoch: fee config and cached rate are
  /// snapshotted together (config is read once here), and the §6.1 pricing
  /// snapshot persisted on the order is built from that same epoch — the
  /// webhook reprices a mismatched paid amount from it, never a fresh rate.
  func quoteTier(tier : Tiers.Tier) : { #ok : (Nat, Types.Pricing); #stale; #unpriceable } {
    let config = forexConfig;
    switch (Forex.quote(forexCache, config, tier.usdCents, Time.now())) {
      case (#ok(quoted)) #ok((
        quoted.cycles,
        {
          usdCents = tier.usdCents;
          xdrPerUsdMicros = quoted.xdrPerUsdMicros;
          feeBps = config.feeBps;
          feeFixedCents = config.feeFixedCents;
        },
      ));
      case (#stale) #stale;
      case (#unpriceable) #unpriceable;
    };
  };

  /// Create a card-rail order: II caller becomes the owner (ownership is
  /// captured here at the API edge, seam §11.1.3), the tier's USD amount is
  /// quoted into a locked cycle *quantity* (§3, net of fees at the cached
  /// rate — a stale cache refreshes lazily, a failed refresh fails closed
  /// §3.1), and the ID comes from raw_rand. Each quoteTier call snapshots
  /// fee config + rate together, so one order is always priced from one
  /// consistent epoch even when a refresh await interleaves with a config
  /// change; the store write after the awaits is atomic.
  public shared ({ caller }) func create_order(
    tierId : Text,
    destination : Types.Destination,
  ) : async Result.Result<CreatedOrder, CreateOrderError> {
    switch (Auth.checkUser(caller)) {
      case (#err(#anonymous)) return #err(#anonymous);
      case (#ok) {};
    };
    let ?tier = Tiers.find(cardTiers, tierId) else return #err(#unknownTier(tierId));
    let (lockedCycles, pricing) = switch (quoteTier(tier)) {
      case (#ok(quoted)) quoted;
      case (#unpriceable) return #err(#tierBelowFees(tierId));
      case (#stale) {
        ignore await* refreshForexRate();
        switch (quoteTier(tier)) {
          case (#ok(quoted)) quoted;
          case (#unpriceable) return #err(#tierBelowFees(tierId));
          case (#stale) return #err(#rateUnavailable);
        };
      };
    };
    let owner : Types.Owner = #ii(caller);
    var attempts = 0;
    while (attempts < maxIdAttempts) {
      let entropy = await management.raw_rand();
      let ?id = Orders.idFromEntropy(entropy) else return #err(#idGeneration);
      switch (Orders.create(orderStore, id, owner, #card, destination, lockedCycles, pricing, Time.now())) {
        case (#ok(order)) {
          return #ok({ order; clientReferenceId = Orders.clientReferenceId(owner, id) });
        };
        case (#err(#duplicateId(_))) {}; // re-draw fresh entropy
      };
      attempts += 1;
    };
    #err(#idGeneration);
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
    switch (Tiers.validate(tiers)) {
      case (#ok) { cardTiers := tiers; #ok };
      case (#err(e)) #err(e);
    };
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

  transient let webhookDeps : Card.Deps = {
    orders = orderStore;
    dedup;
    errorQueue;
    errorQueueCapacity;
    auditLog;
    auditLogCapacity;
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
    ErrorQueue.resolve(errorQueue, id, Time.now());
  };

  /// §4.2 operational trail, newest-last. Admin: details reference payment
  /// intents. Readers detect ring-buffer drops via gaps in `seq`.
  public shared query ({ caller }) func audit_log() : async [AuditLog.Event] {
    requireAdmin(caller);
    AuditLog.events(auditLog);
  };

  // ── HTTP ingress ────────────────────────────────────────────────────────

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
      handler = func req = Card.handleWebhook(
        webhookDeps,
        Secret.get(webhookSecret),
        req,
        Time.now(),
        Card.defaultToleranceSeconds,
      );
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
    Http.handleUpdate(routes, req, maxRequestBodyBytes);
  };

  /// Liveness probe; also used by the scaffold smoke test path.
  public query func health() : async Bool {
    true;
  };
};
