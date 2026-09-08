import IC "mo:ic/Types";
import Http "../Http";
import Session "../rails/Session";
import Types "../Types";

/// The HTTP surface: the two halves of `http_request` and the outcall transform (§6.0).
///
/// ⚠️ **These three are the only endpoints here that are not authenticated by a caller**,
/// and two of them cannot be: Stripe cannot sign in, and the transform is invoked by the
/// replica. Authentication is on the PAYLOAD instead — the webhook route verifies an
/// HMAC over the body — so the dispatcher re-applies every guard on the update half,
/// because anyone can call it directly through Candid.
///
/// ⚠️ **`routes` and `maxRequestBodyBytes` pass directly and that is safe**, unlike a
/// mutable `var`: both are transient `let`s built during initialisation, which is also
/// when `include` evaluates its arguments, and neither ever changes afterwards. The
/// rule in `docs/DESIGN.md` §9.1 is about MUTABLE state; an immutable snapshot of an
/// immutable value is the value.
///
/// ⚠️ **`paidOrder` is a take-once handoff, not a getter.** The dispatcher sets it inside
/// the update half and this mixin consumes it in the same message; reading and clearing
/// as one operation is what stops a second delivery kick from a stale value, and it is
/// why the accessor is `take` rather than a get/set pair.
mixin (
  routes : [Http.Route],
  maxRequestBodyBytes : Nat,
  paidOrder : { take : () -> ?Types.OrderId },
  ops : {
    processDelivery : (Types.OrderId) -> async* ();
  },
) {

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
    switch (paidOrder.take()) {
      case (?orderId) {
        ignore async { await* ops.processDelivery(orderId) };
      };
      case null {};
    };
    response;
  };
};
