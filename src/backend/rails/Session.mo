/// Stripe Checkout Session creation and expiry, as pure functions (#33).
///
/// Everything here is deterministic and unit-testable: building the
/// form-encoded request, stripping the response for consensus, and parsing the
/// two fields we keep. The outcall itself lives in `Main.mo`, because the
/// transform has to be a `shared query` on the actor.
///
/// **Why sessions at all.** A Payment Link has no expiry field — the object
/// carries `active`, `inactive_message` and a completed-count `restrictions`
/// cap, and its URL accepts only UTM codes and `client_reference_id`. Per-order
/// expiry therefore requires a per-order session, and once you have one you also
/// get a per-order `success_url` and an arbitrary amount.
// `mo:ic` re-exports only the `ic` actor; the request/response types live in
// its `Types` module.
import IC "mo:ic/Types";
// These four are imported for their DOT NOTATION, not to be named: `c.toText()`,
// `n.toText()` and `blob.decodeUtf8()` resolve through the imported module, so
// dropping an "unused" import here is a compile error rather than a tidy-up.
import Char "mo:core/Char";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Json "../Json";

module {

  /// Stripe's Checkout Sessions collection.
  public let createUrl : Text = "https://api.stripe.com/v1/checkout/sessions";

  /// `POST /v1/checkout/sessions/{id}/expire` — what `cancel_order` calls to
  /// make an order provably unpayable before marking it `#cancelled`.
  public func expireUrl(sessionId : Text) : Text {
    createUrl # "/" # sessionId # "/expire";
  };

  /// The response reservation, in bytes.
  ///
  /// ⚠️ **The cap counts HEADERS as well as the body, and is checked TWICE against the
  /// same number.** Headers first, then the body against what remains; then the
  /// transform's *Candid-encoded* output against the same value. Two consequences the
  /// next editor would get wrong: **stripping headers in the transform cannot buy room**
  /// (the first two checks run before it), and a raw response that only just fits can
  /// still fail *after* the transform. Sizing at ~2× a measured response is the margin
  /// those checks need, not padding.
  ///
  /// A session response is ~3.5–6 KB of JSON plus 1–2 KB of headers, so 16 KB is ~2×
  /// headroom — an estimate; #4 captures the real fixture and the check to add then is
  /// `cap ≥ 2 × measured`.
  ///
  /// ⚠️ **The asymmetry decides the value: too small takes the rail DOWN, too large only
  /// costs cycles** (~10,400 per byte at n = 13). Never `null` — the `ic` package
  /// substitutes 2,000,000 and the call costs ~20.85 B.
  ///
  /// **Three distinct failure messages, and the middle one is actively
  /// misleading** — worth recognising before diagnosing the wrong thing:
  ///
  /// | Reject message | What actually happened |
  /// |---|---|
  /// | `Header size exceeds specified response size limit <N>` | the headers **alone** exceeded the cap |
  /// | `Http body exceeds size limit of <N> bytes.` | the body exceeded what was **left after** the headers. It prints the full cap, not the remainder, so **the body that failed can be well under `<N>`** |
  /// | `Transformed http response exceeds limit: <N>` | the transform's Candid-encoded output exceeded the cap |
  ///
  /// Raising the cap fixes all three. Stripping headers in the transform fixes
  /// only the last, because the first two are checked before it runs.
  public let maxResponseBytes : Nat64 = 16_384;

  /// Session lifetime handed to Stripe, in seconds.
  ///
  /// ⚠️ **35 minutes, not 30.** Stripe's floor is 30 minutes evaluated against
  /// *Stripe's* clock when the request arrives, so `now + 30 min` sits exactly on
  /// it: a few seconds of clock skew or consensus latency puts the value below the
  /// floor, Stripe rejects it, and **every** session creation fails — the whole
  /// rail, not one order. Five minutes of slack costs a promise held ~17% longer.
  ///
  /// This is only what we *ask* for. `expiresAtNs` is stamped from Stripe's
  /// response, so nothing downstream depends on this number.
  public let requestedLifetimeSeconds : Nat = 2_100; // 35 min

  /// Percent-encode for `application/x-www-form-urlencoded`.
  ///
  /// Unreserved set from RFC 3986 (`ALPHA / DIGIT / "-" / "." / "_" / "~"`);
  /// everything else is escaped, and a space becomes `%20` rather than `+` —
  /// both are accepted in a form body and `%20` needs no special case.
  ///
  /// Encoding is not optional here even though the current inputs look tame: the
  /// product name carries an amount, `success_url` carries `#/order/<id>`, and a
  /// bare `#` would truncate the value at the fragment. It is also the difference
  /// between an operator-set origin and a parameter-injection bug.
  public func formEncode(text : Text) : Text {
    var out = "";
    for (c in text.chars()) {
      if (isUnreserved(c)) {
        out #= c.toText();
      } else {
        // Per BYTE, not per char: a multi-byte character is escaped as each of
        // its UTF-8 bytes, which is what the form encoding expects.
        for (b in c.toText().encodeUtf8().values()) {
          out #= "%" # hexByte(b);
        };
      };
    };
    out;
  };

  func isUnreserved(c : Char) : Bool {
    (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')
    or c == '-' or c == '.' or c == '_' or c == '~';
  };

  func hexByte(b : Nat8) : Text {
    let digits = "0123456789ABCDEF";
    let hi = Nat8.toNat(b / 16);
    let lo = Nat8.toNat(b % 16);
    charAt(digits, hi) # charAt(digits, lo);
  };

  func charAt(t : Text, i : Nat) : Text {
    var n = 0;
    for (c in t.chars()) {
      if (n == i) return c.toText();
      n += 1;
    };
    "";
  };

  /// Everything the session body needs, gathered so the caller cannot pass them
  /// in the wrong order.
  public type CreateArgs = {
    orderId : Text;
    /// `<principal>_<orderId>` — the attribution mechanism, unchanged from the
    /// Payment Link flow, so webhook handling is untouched.
    clientReferenceId : Text;
    /// Gross USD cents. Stripe's `unit_amount`.
    usdCents : Nat;
    /// Operator-configured asset origin, e.g. `https://<canister>.icp0.io`.
    /// Admin config, never a caller parameter — a caller-supplied `success_url`
    /// is an open redirect Stripe renders after a real payment.
    origin : Text;
    /// Absolute Unix seconds. Stripe's clock decides whether it clears the floor.
    expiresAtSeconds : Nat;
  };

  /// The form-encoded create body.
  ///
  /// ⚠️ **`amount_total` is guaranteed to equal `unit_amount` only because of
  /// what is ABSENT here.** `mode=payment`, one line item, inline `price_data`,
  /// quantity 1 — Stripe Checkout then exposes no editable amount. Enabling any
  /// of these breaks that equality, and every one defaults to off:
  ///
  /// | Setting | Effect |
  /// |---|---|
  /// | `automatic_tax` | tax on top → total > unit_amount |
  /// | `adjustable_quantity` | buyer picks a quantity → a multiple |
  /// | `allow_promotion_codes` / `discounts` | buyer or we apply a code → less |
  /// | shipping options | adds a shipping amount |
  /// | `optional_items` | buyer adds items in the Checkout UI |
  /// | `line_items[][tax_rates]` | manual tax |
  /// | `after_expiration[recovery]` | the expired event carries a URL that spawns a payable copy-session for 30 days — a direct tally bypass |
  ///
  /// `adaptive_pricing[enabled]=false` is passed explicitly because it is
  /// Dashboard-toggleable, and pinning it costs one parameter. Inline `price_data` mints a
  /// fresh Product per session with nothing attached, so cross-sells are structurally
  /// neutralised and there are no Dashboard objects to keep in sync.
  ///
  /// ⚠️ **Keep the `amount_total == usdCents` check even though this shape makes it
  /// unreachable.** Stripe keeps adding Dashboard-side amount changers, and the table
  /// above is a snapshot of the ones that exist today.
  public func createBody(args : CreateArgs) : Text {
    let fields : [(Text, Text)] = [
      ("mode", "payment"),
      ("payment_method_types[]", "card"),
      ("line_items[0][quantity]", "1"),
      ("line_items[0][price_data][currency]", "usd"),
      ("line_items[0][price_data][unit_amount]", args.usdCents.toText()),
      ("line_items[0][price_data][product_data][name]", "Cycles for the Internet Computer"),
      ("client_reference_id", args.clientReferenceId),
      ("expires_at", args.expiresAtSeconds.toText()),
      // Back to the buyer's own order page, both ways. Without `cancel_url` a
      // buyer who backs out of Stripe lands somewhere we did not choose.
      ("success_url", args.origin # "/#/order/" # args.orderId),
      ("cancel_url", args.origin # "/#/order/" # args.orderId),
      ("adaptive_pricing[enabled]", "false"),
    ];
    var body = "";
    var first = true;
    for ((k, v) in fields.values()) {
      if (not first) body #= "&";
      first := false;
      body #= formEncode(k) # "=" # formEncode(v);
    };
    body;
  };

  /// Request headers for a session create.
  ///
  /// ⚠️ **`Idempotency-Key` does double duty, and the second job is easy to
  /// miss.** Every replica performs the outcall independently. Without the key,
  /// each one creates a *distinct* session with a distinct `id` and `url`, so
  /// (a) one order spawns many sessions and (b) **consensus can never be
  /// reached** — and no transform can repair that, because a transform strips
  /// variation, it cannot invent agreement. With the key, Stripe returns the
  /// same object to every replica.
  ///
  /// The order id is the natural key: one order, one session, for the life of
  /// the order. There is no session retry (#33 deleted `payment_session`), so it
  /// is never reused with a changed body — which Stripe rejects.
  public func createHeaders(apiKey : Text, orderId : Text) : [IC.HttpHeader] {
    [
      { name = "Authorization"; value = "Bearer " # apiKey },
      { name = "Content-Type"; value = "application/x-www-form-urlencoded" },
      { name = "Idempotency-Key"; value = orderId },
    ];
  };

  /// Headers for the expire call. Idempotent by nature — expiring an already
  /// expired session is not an error we need a key to deduplicate.
  /// Authorization and nothing else — shared by the expire POST and the retrieve GET.
  ///
  /// ⚠️ **No idempotency key here, deliberately.** `createHeaders` carries one because
  /// creating a session twice would charge a buyer twice; expiring or reading one is
  /// idempotent by nature, and Stripe ignores the header on a GET anyway.
  public func authHeaders(apiKey : Text) : [IC.HttpHeader] {
    [{ name = "Authorization"; value = "Bearer " # apiKey }];
  };

  /// The transform's whole job: **strip every response header.**
  ///
  /// Not "reduce" — strip all of them. Stripe returns a unique `request-id` per
  /// HTTP request, plus `Date`, the rate-limit family and Cloudflare headers.
  /// Each replica issues its own request, so **every** replica sees a different
  /// `request-id`: passing headers through fails consensus on *every single
  /// call*, not occasionally.
  ///
  /// ⚠️ **Replication-count independent.** Any `n > 1` breaks on unstripped
  /// per-request headers, so this is not something to tune against a node count.
  ///
  /// ⚠️ **The PocketIC suite cannot catch a mistake here.** It *mocks* outcalls,
  /// handing the canister whatever response the test constructs — so a transform
  /// that leaks a header passes the suite and fails only against real Stripe,
  /// where the replicas disagree. First observable in a manual run.
  public func strip(response : IC.HttpRequestResult) : IC.HttpRequestResult {
    { status = response.status; body = response.body; headers = [] };
  };

  public type Created = {
    id : Text;
    url : Text;
    /// Stripe's own deadline, in **seconds**. The caller multiplies by 10⁹.
    expiresAtSeconds : Nat;
    /// Whether the API key that created this is a live key. Checked against
    /// `expectLivemode` here, at creation, rather than at webhook time — before
    /// any money moves.
    livemode : Bool;
  };

  public type ParseError = {
    /// Not JSON at all, or not an object.
    #unparseable;
    /// JSON, but a field we require is absent or the wrong type. Names the
    /// field so an operator is not left guessing.
    #missingField : Text;
  };

  /// Pull the four fields we keep out of a session-create response.
  ///
  /// Deliberately strict: a session we cannot address (`id`) or hand to the
  /// buyer (`url`) is not a partial success, and a missing `expires_at` would
  /// leave the order with no deadline at all.
  public func parseCreated(body : Blob) : { #ok : Created; #err : ParseError } {
    let ?text = body.decodeUtf8() else return #err(#unparseable);
    let ?json = Json.parse(text) else return #err(#unparseable);
    let ?id = Json.textAt(json, "id") else return #err(#missingField("id"));
    let ?url = Json.textAt(json, "url") else return #err(#missingField("url"));
    let ?expires = Json.natAt(json, "expires_at") else return #err(#missingField("expires_at"));
    // `livemode` is required rather than defaulted: defaulting it either way
    // would silently pick a side of the test/live check it exists to drive.
    let ?livemode = Json.boolAt(json, "livemode") else return #err(#missingField("livemode"));
    #ok({ id; url; expiresAtSeconds = expires; livemode });
  };

  /// Seconds → nanoseconds for `Order.expiresAtNs`.
  ///
  /// ⚠️ **The single most likely implementation bug in this plan.** Stripe's
  /// `expires_at` is Unix **seconds**; IC time is **nanoseconds**. Store the raw
  /// value and every order looks expired since 1970: the open-order cap frees
  /// instantly, both of #30's detection predicates fire on everything, and the UI
  /// shows every order expired. It exists as a named function so the conversion
  /// has one home and one test.
  public func secondsToNs(seconds : Nat) : Int {
    seconds * 1_000_000_000;
  };

  /// How an outcall failed, in terms an operator can act on.
  ///
  /// The reject messages are the replica's, matched as substrings — the exact
  /// strings, not paraphrases. The distinction that matters is **retryable or
  /// not**, because there is no retry method here by design (#33): the buyer
  /// retries, and an audit line saying "outcall failed" leaves the operator
  /// unable to tell a transient subnet hiccup from Stripe being down from a bug
  /// in our own transform.
  public type FailureKind = {
    /// The subnet did not produce a response within 60 s. `SysTransient` — the
    /// retryable one. Nothing is known about whether Stripe created the session.
    #subnetTimeout;
    /// Stripe did not answer within 30 s. `SysFatal`.
    #remoteTimeout;
    /// ⚠️ **Replicas disagreed, which almost always means OUR transform.** The
    /// signature of a header that is not being stripped, or a body field that
    /// varies per request. This is the failure the PocketIC suite structurally
    /// cannot catch — it mocks outcalls, so a leaky transform passes there and
    /// only ever fails against the real API.
    #noConsensus;
    /// The response, or the transform's output, exceeded `max_response_bytes`.
    /// See the table on `maxResponseBytes`: the body message is misleading.
    #tooLarge;
    /// Attached fewer cycles than required — only reachable by hand-attaching,
    /// which this code never does.
    #insufficientCycles;
    #other;
  };

  /// Classify a reject message. Pure, so the mapping is unit-tested rather than
  /// discovered during an outage.
  public func classifyFailure(message : Text) : FailureKind {
    if (message.contains(#text "Canister http request timed out")) return #subnetTimeout;
    if (message.contains(#text "Deadline Exceeded")) return #subnetTimeout;
    if (message.contains(#text "Timeout expired")) return #remoteTimeout;
    if (message.contains(#text "No consensus could be reached")) return #noConsensus;
    if (message.contains(#text "exceeds specified response size limit")) return #tooLarge;
    if (message.contains(#text "exceeds size limit of")) return #tooLarge;
    if (message.contains(#text "Transformed http response exceeds limit")) return #tooLarge;
    if (message.contains(#text "cycles are required")) return #insufficientCycles;
    #other;
  };

  /// What an operator should do about it, for the audit line.
  public func failureAdvice(kind : FailureKind) : Text {
    switch (kind) {
      case (#subnetTimeout) "transient: the subnet did not answer in 60 s — retryable";
      case (#remoteTimeout) "Stripe did not answer in 30 s";
      case (#noConsensus) "REPLICAS DISAGREED — almost certainly the transform is leaking a per-request value; no test suite can catch this, check the transform";
      case (#tooLarge) "the response exceeded max_response_bytes (headers count, and the body message understates it) — raise the cap";
      case (#insufficientCycles) "too few cycles attached — Call.httpRequest should make this unreachable";
      case (#other) "unclassified";
    };
  };

  /// Whether Stripe's response says the session is no longer open.
  ///
  /// Used by the expire path, where "not open" is a distinguishable outcome
  /// rather than a failure: the session either completed or expired already, and
  /// we must not guess which from our own clock.
  ///
  /// ⚠️ **This matches Stripe's error PROSE, so the unit test checks our code
  /// against our own assumption of those strings, not against Stripe.** Getting it
  /// wrong is safe — a misclassified "not open" degrades to "could not cancel, try
  /// again", and the session expires on its own within 35 minutes — but it is an
  /// assumption, not a fact.
  ///
  /// #4 captures the real expire-on-completed response; pin this against that
  /// body then, or switch to matching the structured `error.code` instead of the
  /// message, which is what Stripe actually guarantees stable.
  public func isNotOpen(status : Nat, body : Blob) : Bool {
    if (status == 200) return false;
    let ?text = body.decodeUtf8() else return false;
    text.contains(#text "No such checkout.session")
    or text.contains(#text "in a status of complete")
    or text.contains(#text "in a status of expired");
  };


  /// `GET /v1/checkout/sessions/{id}` — the read the recovery sweep uses to settle a
  /// `#created` order whose expiry event never arrived (#52).
  ///
  /// ⚠️ **The id is Stripe's, never a caller's.** It is stamped into
  /// `Order.stripeSessionId` from the create response and read back from our own store,
  /// so nothing attacker-controlled reaches this URL. Said explicitly because a value
  /// interpolated into a request URL is exactly what a reviewer should check.
  public func retrieveUrl(sessionId : Text) : Text {
    createUrl # "/" # sessionId;
  };

  /// Cap for the retrieve, **larger than `maxResponseBytes`** and not a copy of it.
  ///
  /// Two reasons it must be bigger than the create response's cap. A *completed* session
  /// carries fields a freshly created one does not — `customer_details`, a resolved
  /// `payment_intent`, `total_details` — and the limit is enforced on the **raw**
  /// response, so Stripe's ~1–2 KB of response headers count against it before a byte of
  /// body arrives. `strip` cannot rescue an over-cap response: that check runs first.
  ///
  /// ⚠️ **The failure is total, not truncation** — an over-cap response fails the call
  /// every time — so this is sized with margin rather than measured to the byte. #4's
  /// fixture capture turns `cap >= 2x measured` into a check instead of an estimate.
  public let retrieveMaxResponseBytes : Nat64 = 32_768;

  /// What Stripe says about a session, reduced to the only distinction the sweep acts on.
  public type Status = {
    /// Still payable. The sweep does nothing: our clock decided when to ask, and Stripe
    /// says the deadline has not actually passed.
    #open;
    /// Complete **and paid**. The buyer's money is in and we never credited it.
    ///
    /// Carries the `payment_intent`, because **this is the only place it can be learned**
    /// — and the compiler proved it. A first draft read the intent off the order; the
    /// order never reached `#paid`, so nothing ever indexed the payment against it, and
    /// `paidIntents` is written *by* crediting. The retrieve is the sole source. It is
    /// what an operator looks up in Stripe and what a filed obligation records, so a
    /// complete+paid response without one classifies as `#unknown` rather than becoming
    /// an obligation nobody can reconcile.
    #completePaid : { paymentIntent : Text };
    /// Stripe expired it. Nobody can pay this session, so the order's promise is holding
    /// capacity against a sale that can never happen — the leak #52 exists to close.
    #expired;
    /// Anything we do not recognise, including a body we cannot parse. Carries the text
    /// for the audit line.
    #unknown : Text;
  };

  /// Classify a retrieve response.
  ///
  /// ⚠️ **`#unknown` is the safe answer and every unrecognised shape lands there.** The
  /// sweep treats it exactly like `#open` — do nothing, ask again — so a Stripe response
  /// change makes this feature inert rather than wrong. A classifier that guessed would
  /// be guessing about whether a buyer has been paid.
  ///
  /// ⚠️ **`complete` is split on `payment_status`, and that is not defensive padding.**
  /// A session can be `complete` with `payment_status = "unpaid"`: the buyer finished
  /// checkout with a delayed-notification method (SEPA, ACH, boleto), the session closed,
  /// and the money settles days later. **Our sessions cannot reach it** — `createBody`
  /// pins `payment_method_types[]=card` and cards settle synchronously — but folding it
  /// into the paid case would make the sweep file an operator-facing obligation claiming
  /// a buyer paid when nobody has. So it classifies as `#unknown`: silence, which is
  /// correct, because `checkout.session.async_payment_succeeded`/`_failed` already own
  /// that lifecycle if the card pin is ever removed.
  public func classify(body : Blob) : Status {
    let ?text = body.decodeUtf8() else return #unknown("response body is not UTF-8");
    let ?json = Json.parse(text) else return #unknown("response body is not JSON");
    let ?status = Json.textAt(json, "status") else return #unknown("no status field");
    switch (status) {
      case ("open") #open;
      case ("expired") #expired;
      case ("complete") {
        switch (Json.textAt(json, "payment_status")) {
          case (?"paid") {
            // The intent is required rather than optional: an obligation that cannot
            // name the payment is one an operator cannot reconcile, and a complete+paid
            // session without one would mean Stripe changed shape — which is exactly
            // what `#unknown` is for.
            switch (Json.textAt(json, "payment_intent")) {
              case (?intent) #completePaid({ paymentIntent = intent });
              case null #unknown("complete and paid with no payment_intent");
            };
          };
          case (?other) #unknown("complete but payment_status=" # other);
          case null #unknown("complete with no payment_status");
        };
      };
      case (other) #unknown("unrecognised status=" # other);
    };
  };

};
