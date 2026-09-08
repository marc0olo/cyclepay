// `Array` for the receiver `.map()` on the amounts a preview is asked for.
import Array "mo:core/Array";
// ⚠️ `Nat` has no `Nat.` call here and is required: it resolves `.toText()` on a cents
// figure. Removing it and `Int` and `Principal` together compiled individually and
// failed as a set — an "unused" verdict per import does not compose, because one module
// can cover another's receiver methods.
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Time "mo:core/Time";
import Auth "../Auth";
import Gate "../Gate";
import Orders "../Orders";
import Pricing "../Pricing";
import Session "../rails/Session";
import Tiers "../Tiers";
import Types "../Types";

/// Money in: the quote a buyer is shown, the admission preflight, the price tiles, and
/// `create_order` itself (§3, §6.1).
///
/// ⚠️ **`create_order` is the most entangled endpoint in the system, and `ops` is that
/// entanglement made visible rather than hidden.** Three of the things it needs cannot
/// live in a mixin at all:
///
///   * `createStripeSession` issues the HTTPS outcall — `Call.httpRequest`, and a
///     reference to the actor's own transform function.
///   * `createOrderWithFreshId` calls `management.raw_rand()`, so it needs the
///     management-canister actor reference.
///   * `noteRailClosed` latches a `Gate.RailCondition` and writes an audit line, which
///     the create path shares with the recovery sweep.
///
/// All three stay in the composition root and arrive as closures. That is `A3` read
/// honestly: an endpoint body should be authorize → delegate → map, and the delegate
/// target belongs in the root when it is actor-bound. Passing them also keeps ONE
/// implementation shared with the timers, which is what stops the create path and the
/// sweep from diverging.
///
/// ⚠️ **`quoteCents` moved in, and the others did not, for one reason: it is pure.** It
/// reads the rate cache and the pricing config and returns arithmetic — no await, no
/// capability, no actor reference.
mixin (
  orderStore : Orders.Store,
  rateCache : Pricing.Cache,
  reserveState : { var floor : Nat; var cyclesLedgerFee : Nat },
  gateState : { var config : Gate.Config; var latch : Gate.RailStateLatch },
  pricingState : { var config : Pricing.Config },
  tierState : { var cards : [Tiers.Tier] },
  ops : {
    audit : (Text, Text) -> ();
    admit : (Principal, Nat) -> Result.Result<(), Gate.Reason>;
    gateObservation : (Principal) -> Gate.Observation;
    admitOrder : (Principal, Nat, Nat) -> Result.Result<(), Gate.Reason>;
    noteStripeApiFailed : (Text) -> ();
    /// Actor-bound: the outcall, the transform reference, and the rail latch.
    sessionConfig : () -> { #ok : { apiKey : Text; origin : Text }; #err : Session.Error };
    createStripeSession : ({ apiKey : Text; origin : Text }, Types.OrderId, Text, Nat) -> async* { #ok : Session.Created; #err : Session.Error };
    createOrderWithFreshId : (Principal, Nat, Types.Owner, Types.Rail, Types.Destination, Nat, Types.Pricing) -> async* Result.Result<Types.Order, { #idGeneration; #notAdmitted : Gate.Reason }>;
    noteRailClosed : (Session.Error) -> ();
    sessionErrorToText : (Session.Error) -> Text;
  },
) {

  /// What the buyer is paying for: a preset, or an amount they typed (#33).
  ///
  /// A variant rather than a second method, so the quote, the gate and the
  /// session path stay single. Everything downstream keys off gross USD cents,
  /// which is what both cases resolve to — the floor and the ceiling then apply
  /// uniformly instead of one bound per entry point.
  type Amount = {
    #tier : Text;
    /// Gross USD cents, straight from the buyer. Bounded by
    /// `Gate.Config`'s floor and ceiling like any other amount — and bounded
    /// **here**, not only in the frontend, because a frontend-only bound is not a
    /// bound.
    #custom : Nat;
  };

  /// What a given amount buys right now (§3), before anyone commits to an order.
  type QuotePreview = {
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

  type CreateOrderError = {
    /// Anonymous principal — a shared identity can't own orders (§7).
    #anonymous;
    /// No configured preset with this id. Only reachable for `#tier`.
    #unknownTier : Text;
    /// §3 fee formula swallows the tier's gross amount — a tier/fee config
    /// problem for the operator, not something a retry fixes.
    ///
    /// ⚠️ **The buyer's fix is "pick a larger amount", which is why the
    /// simulation-scale case below is NOT folded in here.** Telling a buyer that
    /// payment processing is too large, when the cause is this gateway's
    /// simulation divisor, names the wrong party and prescribes a fix that may
    /// not work (#99 review finding 2).
    #tierBelowFees : Text;
    /// The SCALED cycles would not clear the flat cycles-ledger deposit fee: this
    /// gateway's simulation divisor is too large for this purchase (#99 2d).
    ///
    /// Not the buyer's fault and not fixable by them — it is an operator's
    /// configuration. Carries both figures so the refusal is diagnosable.
    #simulationScaleTooSmall : { scaledCycles : Nat; ledgerFee : Nat };
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

  type CreatedOrder = {
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

  type QuotePreviews = {
    quotes : [QuotePreview];
    /// The rate pair the quotes came from, so a caller can reproduce the
    /// arithmetic without a second call. Null when nothing usable is cached.
    rates : ?Pricing.Rates;
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
  /// = the Stripe formula in `pricing.config`) over
  /// the one shared rate cache.
  func quoteCents(fee : { feeBps : Nat; feeFixedCents : Nat }, usdCents : Nat) : {
    #ok : (Nat, Types.Pricing);
    #stale;
    #unpriceable : Pricing.Unpriceable;
  } {
    switch (
      Pricing.quote(
        rateCache,
        fee,
        pricingState.config.maxAgeNs,
        usdCents,
        Time.now(),
        pricingState.config.divisor,
        reserveState.cyclesLedgerFee,
      )
    ) {
      case (#stale) #stale;
      case (#unpriceable(cause)) #unpriceable(cause);
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
    let config = switch (ops.sessionConfig()) {
      case (#ok(c)) c;
      case (#err(e)) {
        ops.noteRailClosed(e);
        return #err(#sessionUnavailable(ops.sessionErrorToText(e)));
      };
    };
    // Both cases collapse to gross USD cents here, and everything after this is
    // identical for a preset and a typed amount — which is the point of the
    // variant: one quote path, one gate, one session.
    let (usdCents, quoteLabel) = switch (amount) {
      case (#tier(tierId)) {
        let ?tier = Tiers.find(tierState.cards, tierId) else return #err(#unknownTier(tierId));
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
    switch (ops.admit(caller, usdCents)) {
      case (#err(reason)) return #err(#notAdmitted(reason));
      case (#ok) {};
    };
    let fee = { feeBps = pricingState.config.feeBps; feeFixedCents = pricingState.config.feeFixedCents };
    let (lockedCycles, pricing) = switch (quoteCents(fee, usdCents)) {
      case (#ok(quoted)) quoted;
      case (#unpriceable(#stripeFee)) return #err(#tierBelowFees(quoteLabel));
      case (#unpriceable(#simulationScale(figures))) {
        return #err(#simulationScaleTooSmall(figures));
      };
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
    // `reserveState.floor` is a maintained lower bound moved only by our own outflows
    // (§5.4), so the check and the hold sit in ONE block inside
    // `createOrderWithFreshId` with no await between them. Motoko messages do not
    // interleave except at an await, so whichever block runs second sees the first
    // one's hold. **Splitting them across an await lets two concurrent creates
    // promise the same cycles** — which is what an earlier version did, and no
    // fresher balance read can fix it: an awaited value is historical the moment
    // the continuation resumes.
    let order = switch (
      await* ops.createOrderWithFreshId(caller, usdCents, owner, #card, destination, lockedCycles, pricing)
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
    switch (await* ops.createStripeSession(config, order.id, clientReferenceId, order.pricing.usdCents)) {
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
        ops.noteStripeApiFailed("create: " # ops.sessionErrorToText(e));
        return #err(#sessionUnavailable(ops.sessionErrorToText(e)));
      };
      case (#ok(created)) {
        // Stripe answered, so the outcall is working again. This is the ONLY
        // evidence that bears on `#stripeApiFailing` — `latchAdmission` cannot
        // clear it, because admission runs *before* this call and says nothing
        // about it (#37 §2c).
        gateState.latch := Gate.latchStripeApiOk(gateState.latch);
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
            ops.audit("stripe.sessionOrphaned", order.id # ": cancelled during creation; session " # created.id # " left to expire");
            #err(#cancelledDuringCreation);
          };
        };
      };
    };
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
    Gate.admit(gateState.config, ops.gateObservation(caller), usdCents);
  };

  /// Public — the frontend renders the amount tiles from this. There is no link
  /// to render: the canister creates a session per order (#33).
  public query func card_tiers() : async [Tiers.Tier] {
    tierState.cards;
  };

  /// Batch pre-purchase quote, public.
  ///
  /// ⚠️ **The price a buyer is shown is computed by the SAME function that prices the
  /// order.** A client reimplementing the formula would be one refactor away from quoting
  /// a number the gateway does not honour, with no way for the buyer to tell which was
  /// wrong. Batched because the tier grid needs every price in one round trip.
  ///
  /// **Unbounded input on purpose**, unlike the paged queries. The work is constant
  /// per element the caller already transmitted — no state scan, no amplification — so
  /// the ingress size limit already bounds it. A cap would only buy **silent truncation**,
  /// which is worse than what it prevents.
  ///
  /// Does not disclose the cycles-ledger fee: that is the ledger's number and the
  /// operator's cost — `docs/DESIGN.md` §3.2 for the split and why a stored copy would
  /// be wrong here.
  public query func quote_previews(amounts : [Nat]) : async QuotePreviews {
    let fee : { feeBps : Nat; feeFixedCents : Nat } = {
      feeBps = pricingState.config.feeBps;
      feeFixedCents = pricingState.config.feeFixedCents;
    };
    let quotes = amounts.map(
      func(usdCents) {
        {
          usdCents;
          feeCents = Pricing.feeCents(fee, usdCents);
          netCents = Pricing.netCents(fee, usdCents);
          cycles = switch (quoteCents(fee, usdCents)) {
            case (#ok((cycles, _))) ?cycles;
            case (#stale or #unpriceable(_)) null;
          };
        };
      },
    );
    {
      quotes;
      rates = Pricing.lastRates(rateCache);
    };
  };
};
