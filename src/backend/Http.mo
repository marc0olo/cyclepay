/// Hand-rolled HTTP ingress (§6.0) — deliberately NOT mo:server, which drags
/// in deprecated mo:base plus asset/caching/certification machinery this
/// canister doesn't need (assets live on a separate canister; this one only
/// takes POSTs whose query responses the gateway discards on upgrade).
///
/// Requests arrive as the *anonymous* principal (§6.0): routes here are
/// authenticated by payload only, never by caller. Dispatch is off a route
/// *table* with a per-route `upgrade` flag (binding seam §11.1.2) — "exactly
/// one route" is policy, not architecture; a future rail adds rows.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import List "mo:core/List";
import Text "mo:core/Text";

module {

  public type HeaderField = (Text, Text);

  /// IC HTTP-gateway request. `certificate_version` is omitted — Candid
  /// record subtyping drops it on decode, and we never certify responses
  /// (every M1 response is either discarded pre-upgrade or an error).
  public type Request = {
    method : Text;
    url : Text;
    headers : [HeaderField];
    body : Blob;
  };

  public type Response = {
    status_code : Nat16;
    headers : [HeaderField];
    body : Blob;
    /// `?true` from `http_request` makes the gateway re-issue the request
    /// to `http_request_update` through consensus (§6.0).
    upgrade : ?Bool;
  };

  public type Handler = Request -> Response;

  /// One row of the dispatch table (seam §11.1.2). `upgrade` happens to be
  /// true on every M1 route, but it is per-route by design.
  public type Route = {
    method : Text;
    path : Text;
    upgrade : Bool;
    handler : Handler;
  };

  /// Path component of the request url: everything before the first `?`.
  /// The gateway passes the raw url (e.g. `/webhook/stripe?source=stripe`);
  /// routing must not depend on the query string.
  public func pathOf(url : Text) : Text {
    switch (url.split(#char '?').next()) {
      case (?path) path;
      case (null) "";
    };
  };

  /// First value of the named header. Header *names* are compared
  /// case-insensitively (RFC 9110 §5.1 — Stripe sends `Stripe-Signature`,
  /// proxies may re-case it); values are returned untouched.
  public func headerValue(headers : [HeaderField], name : Text) : ?Text {
    let want = asciiLower(name);
    for ((key, value) in headers.values()) {
      if (asciiLower(key) == want) return ?value;
    };
    null;
  };

  /// ASCII-only lowercase. Header names are ASCII tokens, so this is enough
  /// — and it avoids Unicode case-folding surprises.
  func asciiLower(text : Text) : Text {
    text.map(func c = if (c >= 'A' and c <= 'Z') Char.fromNat32(c.toNat32() + 32) else c);
  };

  public func response(statusCode : Nat16, headers : [HeaderField], body : Blob) : Response {
    { status_code = statusCode; headers; body; upgrade = null };
  };

  public func text(statusCode : Nat16, body : Text) : Response {
    response(statusCode, [("content-type", "text/plain; charset=utf-8")], body.encodeUtf8());
  };

  /// Query half (§6.0): match the table; an upgrade route answers
  /// `upgrade = ?true` *without* running its handler (the gateway re-issues
  /// to the update half), a non-upgrade route runs its handler right here.
  /// The body-size guard runs before the upgrade decision so oversized
  /// payloads are rejected without paying for consensus.
  public func handleQuery(routes : [Route], req : Request, maxBodyBytes : Nat) : Response {
    dispatch(routes, req, maxBodyBytes, true);
  };

  /// Update half (§6.0): same matching, always runs the handler. Callable
  /// directly via Candid by anyone — so it re-applies every guard rather
  /// than trusting that the query half ran first.
  public func handleUpdate(routes : [Route], req : Request, maxBodyBytes : Nat) : Response {
    dispatch(routes, req, maxBodyBytes, false);
  };

  func dispatch(routes : [Route], req : Request, maxBodyBytes : Nat, isQuery : Bool) : Response {
    let path = pathOf(req.url);
    let allowed = List.empty<Text>();
    for (route in routes.values()) {
      if (route.path == path) {
        if (route.method == req.method) {
          if (req.body.size() > maxBodyBytes) {
            return text(413, "payload too large");
          };
          if (isQuery and route.upgrade) {
            return { status_code = 200; headers = []; body = Blob.fromArray([]); upgrade = ?true };
          };
          return route.handler(req);
        };
        allowed.add(route.method);
      };
    };
    if (allowed.isEmpty()) {
      text(404, "not found");
    } else {
      response(405, [("allow", allowed.values().join(", "))], "method not allowed".encodeUtf8());
    };
  };

};
