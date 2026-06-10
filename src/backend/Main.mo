/// Fully on-chain cycles gateway — composition root.
///
/// See design-docs/ONCHAIN_GATEWAY_SPEC.md (spec v2.1) and PRD.md for the
/// module layout this actor grows into: Orders.mo wiring, rails/, Cmc.mo,
/// Forex.mo, Treasury.mo, ErrorQueue.mo, Auth.mo.
import Error "mo:core/Error";
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
import { ic } "mo:ic";
import Call "mo:ic/Call";
import IC "mo:ic/Types";
import AuditLog "AuditLog";
import Auth "Auth";
import Cmc "Cmc";
import ErrorQueue "ErrorQueue";
import Forex "Forex";
import Http "Http";
import Idempotency "Idempotency";
import Orders "Orders";
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
      case (#ok) { treasuryConfig := config; #ok };
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
    audit("treasury.burnWindowReset", cleared.toText() # " e8s of window consumption cleared by operator");
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
    var held = 0;
    for ((_, order) in orderStore.orders.entries()) {
      if (order.status == #awaitingTreasury) held += 1;
    };
    {
      config = treasuryConfig;
      burnedInWindowE8s = Treasury.burnedInWindow(burnLedger, treasuryConfig.burnWindowNs, Time.now());
      lastObservedFloat = lastFloatObservation;
      lowFloat = Treasury.lowFloatSignal(treasuryConfig, lastFloatObservation);
      heldOrders = held;
    };
  };

  func audit(tag : Text, detail : Text) {
    ignore AuditLog.append(auditLog, auditLogCapacity, Time.now(), tag, detail);
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
            audit("mint.rateFetchFailed", orderId # ": " # e.message());
            return; // stays #paid; the next sweep retries
          };
          let ?permyriad = Cmc.freshCmcRate(rate.data, Time.now(), Cmc.cmcRateMaxAgeNs) else {
            audit("mint.rateStale", orderId);
            return;
          };
          // §5.3 pre-gate input: the live float balance (also feeds the
          // balance-alert observation).
          let floatE8s = try {
            await icpLedger.icrc1_balance_of({ owner = selfPrincipal(); subaccount = null });
          } catch (e) {
            audit("mint.balanceFetchFailed", orderId # ": " # e.message());
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
          let ?e8s = Cmc.icpE8sForCycles(fresh.lockedCycles, permyriad) else return;
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

  /// Sweep every order with money-out work pending (#paid/#minting/
  /// #icpAtCmc/#awaitingTreasury — the §5.3 hold retries until refill or
  /// max-wait) through the driver. Kicked after webhook ingestion; the
  /// §5.2 recurring recovery timer (task 11) reuses it.
  func sweepMintable() : async* Nat {
    let pending = List.empty<Types.OrderId>();
    for ((id, order) in orderStore.orders.entries()) {
      switch (order.status) {
        case (#paid or #minting or #icpAtCmc or #awaitingTreasury) pending.add(id);
        case (_) {};
      };
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
    if (Orders.get(orderStore, id) == null) return #err(#notFound);
    if (mintsInFlight.contains(id)) return #err(#inFlight);
    await* processMint(id);
    switch (Orders.get(orderStore, id)) {
      case (?order) #ok(order);
      case null #err(#notFound);
    };
  };

  /// Money-out journal for one order (admin, §4.2) — intent, block_index,
  /// minted cycles, retries.
  public shared query ({ caller }) func mint_journal(id : Types.OrderId) : async ?Types.JournalEntry {
    requireAdmin(caller);
    mintJournal.get(id);
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
    let response = Http.handleUpdate(routes, req, maxRequestBodyBytes);
    // A verified checkout marked its order #paid synchronously inside the
    // dispatch above; kick money-out (§5) as a detached self-message so the
    // Stripe ack is never held hostage by ledger/CMC latency. The §5.2
    // recovery timer (task 11) is the backstop if this message dies.
    ignore async { ignore await* sweepMintable() };
    response;
  };

  /// Liveness probe; also used by the scaffold smoke test path.
  public query func health() : async Bool {
    true;
  };
};
