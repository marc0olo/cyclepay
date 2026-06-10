/// Order store + the §4 state machine.
///
/// The state machine owns *transitions only*. Expiry policy, float checks,
/// dedup, and delivery are the callers' business (per-rail money-in, §5
/// money-out) — they ask for a transition and this module answers whether it
/// is legal. Seam §11.1.3: `create` takes the owner as a parameter and never
/// reads a caller itself; Card/ck-USDC owners come from an II Candid call,
/// a future Base owner from a verified EIP-3009 signature.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import List "mo:core/List";
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Result "mo:core/Result";
import Types "Types";
import Util "Util";

module {

  /// 128 bits of raw_rand entropy per order ID (§2: random, not a counter —
  /// the ID is public inside `client_reference_id`, so it must not leak
  /// order volume or be enumerable; it is NOT a bearer secret).
  public let idEntropyBytes : Nat = 16;

  /// Derive an order ID (32 lowercase hex chars) from the first
  /// `idEntropyBytes` of a raw_rand blob; null if the entropy is too short
  /// (raw_rand returns 32 bytes, so null means a broken caller, not bad luck).
  public func idFromEntropy(entropy : Blob) : ?Types.OrderId {
    if (entropy.size() < idEntropyBytes) return null;
    let prefix = entropy.toArray().sliceToArray(0, idEntropyBytes);
    ?Util.hexEncode(Blob.fromArray(prefix));
  };

  /// §6.1 — the value carried on the tier's Payment Link URL:
  /// `<principal>_<orderId>`. Unambiguous to split: principal text is
  /// `[a-z0-9-]`, the ID is hex, so the one `_` is the separator. Claimed,
  /// not trusted — webhook ingestion (task 8) re-resolves and verifies it.
  public func clientReferenceId(owner : Types.Owner, id : Types.OrderId) : Text {
    switch (owner) {
      case (#ii(p)) p.toText() # "_" # id;
    };
  };

  public type Store = {
    /// §4.2 — `orders : Map<OrderId, Order>`.
    orders : Map.Map<Types.OrderId, Types.Order>;
    /// §4.2 — order history per principal (fixes the lost-receipt problem).
    principalsToOrders : Map.Map<Principal, List.List<Types.OrderId>>;
  };

  public func emptyStore() : Store {
    {
      orders = Map.empty<Types.OrderId, Types.Order>();
      principalsToOrders = Map.empty<Principal, List.List<Types.OrderId>>();
    };
  };

  public type CreateError = {
    /// raw_rand collision (astronomically unlikely) — caller retries with
    /// fresh randomness rather than silently overwriting an order.
    #duplicateId : Types.OrderId;
  };

  public type TransitionError = {
    #notFound : Types.OrderId;
    #illegalTransition : { from : Types.OrderStatus; to : Types.OrderStatus };
  };

  /// The §4 diagram plus the two error-queue edges it implies:
  /// `#minting → #errorQueue` (stale intent without a block_index, §5.1) and
  /// `#icpAtCmc → #errorQueue` (failed forward → Type 2, §4.1/§5).
  /// `#delivered` and `#errorQueue` are terminal — error-queue resolution is
  /// human/off-chain on the queue entry (§4.1), not an order transition.
  public func isLegalTransition(from : Types.OrderStatus, to : Types.OrderStatus) : Bool {
    switch (from, to) {
      case (#created, #expired) true; // never paid; advisory only (§4)
      case (#created, #paid) true; // webhook verified, deduped, amount honored
      case (#expired, #paid) true; // late real payment still honored (§4)
      case (#paid, #minting) true; // ICP float sufficient
      case (#paid, #awaitingTreasury) true; // float short (§5.3)
      case (#awaitingTreasury, #minting) true; // float refilled
      case (#awaitingTreasury, #errorQueue) true; // max-wait exceeded (§5.3)
      case (#minting, #icpAtCmc) true; // block_index recorded (§5)
      case (#minting, #errorQueue) true; // intent aged past dedup window (§5.1)
      case (#icpAtCmc, #delivered) true; // notify + forward succeeded
      case (#icpAtCmc, #errorQueue) true; // forward failed → Type 2 (§4.1)
      case _ false;
    };
  };

  /// Pure transition: legal → updated copy, illegal → error. Callers decide
  /// *when* to ask (expiry timers, float checks); this decides *whether*.
  public func transition(
    order : Types.Order,
    to : Types.OrderStatus,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    if (isLegalTransition(order.status, to)) {
      #ok({ order with status = to; updatedAtNs = nowNs });
    } else {
      #err(#illegalTransition({ from = order.status; to }));
    };
  };

  /// Create an order in `#created`, locking the cycle quantity (§3). Owner is
  /// a parameter, never a caller read (seam §11.1.3).
  public func create(
    store : Store,
    id : Types.OrderId,
    owner : Types.Owner,
    rail : Types.Rail,
    destination : Types.Destination,
    lockedCycles : Nat,
    nowNs : Int,
  ) : Result.Result<Types.Order, CreateError> {
    if (store.orders.containsKey(id)) {
      return #err(#duplicateId(id));
    };
    let order : Types.Order = {
      id;
      owner;
      rail;
      destination;
      lockedCycles;
      status = #created;
      createdAtNs = nowNs;
      updatedAtNs = nowNs;
    };
    store.orders.add(id, order);
    let principal = switch (owner) { case (#ii(p)) p };
    switch (store.principalsToOrders.get(principal)) {
      case (?ids) ids.add(id);
      case null {
        let ids = List.empty<Types.OrderId>();
        ids.add(id);
        store.principalsToOrders.add(principal, ids);
      };
    };
    #ok(order);
  };

  /// Look up, validate, and persist a transition in one step.
  public func applyTransition(
    store : Store,
    id : Types.OrderId,
    to : Types.OrderStatus,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        switch (transition(order, to, nowNs)) {
          case (#ok(updated)) {
            store.orders.add(id, updated);
            #ok(updated);
          };
          case (#err(e)) #err(e);
        };
      };
    };
  };

  public func get(store : Store, id : Types.OrderId) : ?Types.Order {
    store.orders.get(id);
  };

  /// Authz-guarded lookup for the user API: `caller == order.owner` (§2).
  public func getOwned(store : Store, id : Types.OrderId, caller : Principal) : ?Types.Order {
    switch (store.orders.get(id)) {
      case (?order) {
        if (Types.isOwnedBy(order.owner, caller)) ?order else null;
      };
      case null null;
    };
  };

  /// Order history for a principal, newest-last (insertion order).
  public func ordersFor(store : Store, caller : Principal) : [Types.Order] {
    switch (store.principalsToOrders.get(caller)) {
      case null [];
      case (?ids) {
        ids.values().filterMap<Types.OrderId, Types.Order>(func(id) = store.orders.get(id)).toArray();
      };
    };
  };

};
