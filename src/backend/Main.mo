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
import Auth "Auth";
import Http "Http";
import Orders "Orders";
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

  // ── Orders (task 6) ─────────────────────────────────────────────────────

  /// §4.2 order store: `orders` + `principalsToOrders` history.
  let orderStore : Orders.Store = Orders.emptyStore();

  /// §3 fixed card tiers. Operator config (§7): controllers create the
  /// Payment Links in the Stripe Dashboard and register them here. Empty
  /// until first `set_card_tiers` — no made-up default prices.
  var cardTiers : [Tiers.Tier] = [];

  /// §3 pricing seam: gross USD cents → locked cycle quantity (net of fees).
  /// Fail-closed stub until the Forex subsystem lands (task 7, §3.1): with
  /// no rate source, order creation is BLOCKED ("rate temporarily
  /// unavailable"), never priced on a stale or invented rate. Transient —
  /// functions aren't stable, and task 7 swaps the body for the real quote.
  transient let quoteCyclesForUsdCents : Nat -> ?Nat = func _ = null;

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
    /// §3.1 fail-closed: no fresh rate, so no price, so no order. Retry.
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

  /// Create a card-rail order: II caller becomes the owner (ownership is
  /// captured here at the API edge, seam §11.1.3), the tier's USD amount is
  /// quoted into a locked cycle *quantity* (§3), and the ID comes from
  /// raw_rand. Tier and quote are captured before the await, so config
  /// changes mid-call can't mix two pricings; the store write after the
  /// await is atomic.
  public shared ({ caller }) func create_order(
    tierId : Text,
    destination : Types.Destination,
  ) : async Result.Result<CreatedOrder, CreateOrderError> {
    switch (Auth.checkUser(caller)) {
      case (#err(#anonymous)) return #err(#anonymous);
      case (#ok) {};
    };
    let ?tier = Tiers.find(cardTiers, tierId) else return #err(#unknownTier(tierId));
    let ?lockedCycles = quoteCyclesForUsdCents(tier.usdCents) else return #err(#rateUnavailable);
    let owner : Types.Owner = #ii(caller);
    var attempts = 0;
    while (attempts < maxIdAttempts) {
      let entropy = await management.raw_rand();
      let ?id = Orders.idFromEntropy(entropy) else return #err(#idGeneration);
      switch (Orders.create(orderStore, id, owner, #card, destination, lockedCycles, Time.now())) {
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

  // ── HTTP ingress ────────────────────────────────────────────────────────

  /// §6.0 body-size guard. Stripe events are a few KiB; 64 KiB is generous
  /// headroom and far below the 2 MiB ingress cap. Transient so a redeploy
  /// can retune it — a persistent let would freeze the first-deploy value.
  transient let maxRequestBodyBytes : Nat = 65_536;

  /// HTTP route table (binding seam §11.1.2) — exactly one anonymous,
  /// payload-authed route (§6.0). The handler is a stub until event
  /// ingestion (task 8) wires `Secret.get(webhookSecret)` into Card.verify;
  /// 503 makes Stripe keep retrying instead of treating the delivery as
  /// accepted (same answer ingestion will give while the secret is unset).
  transient let routes : [Http.Route] = [
    {
      method = "POST";
      path = "/webhook/stripe";
      upgrade = true;
      handler = func _ = Http.text(503, "stripe webhook not yet enabled");
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
