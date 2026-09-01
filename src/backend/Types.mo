/// Core shared types for the cycles gateway.
///
/// Decision record: `docs/DESIGN.md` — §2 ownership, §3 the locked quantity,
/// §4 the state machine, §4.2 this data model, §5.1 transfer intent,
/// §11.1 the binding seams.
import Principal "mo:core/Principal";

module {

  /// Seam §11.1.1 — a single-case variant from day one, and it must stay one.
  /// Adding a case is a migration-free extension; widening to a bare `Principal`
  /// forces a stable-state migration plus an audit of every authz site.
  public type Owner = { #ii : Principal };

  /// Query authz is `caller == order.owner` (§2). Centralised so that adding an
  /// `Owner` case cannot compile until every match on it is updated — ask
  /// `mops check -- -Werror` for the list rather than maintaining one here.
  ///
  /// ⚠️ **That guarantee rests on `-Werror`, not on the language.** A non-exhaustive
  /// match is M0145, a *warning*, so a plain `mops check` reports every one and still
  /// succeeds — leaving each unhandled site to trap at runtime. On the webhook path
  /// that trap is a 5xx Stripe retries for ~3 days.
  ///
  /// ⚠️ **What `-Werror` does NOT catch:** `Orders.openOrderCount` and
  /// `Orders.ordersFor` look owners up through `principalsToOrders`, a
  /// Principal-keyed index, and never pattern-match. A non-principal owner would
  /// compile clean and silently return nothing for those. Fail-closed, but the seam
  /// work has to **reindex**, not just re-match.
  public func isOwnedBy(owner : Owner, caller : Principal) : Bool {
    switch (owner) {
      case (#ii(p)) p == caller;
    };
  };

  /// Money-in rail. Single-case variant for the same reason `Owner` is: it names the
  /// dimension, so a second rail is additive rather than a schema-wide edit.
  public type Rail = { #card };

  /// ICRC-1 account (cycles ledger destination).
  public type Account = { owner : Principal; subaccount : ?Blob };

  /// Where cycles are delivered (§5) — the buyer's **own** cycles-ledger account,
  /// default subaccount. `create_order` refuses anything else, so a crafted call
  /// cannot send cycles to a third party.
  ///
  /// ⚠️ **Depositing straight to a canister's cycle balance is not the case to add.**
  /// It fails on a deleted or refusing target *after* the cycles have left — a
  /// send-then-lose class this app does not have.
  public type Destination = {
    #cyclesLedgerAccount : Account;
  };

  /// Whether a destination delivers to `caller` and nobody else.
  ///
  /// **`null` is the one accepted spelling of the default subaccount, and equivalent
  /// forms are refused rather than normalised.** ICRC-1 makes an all-zero
  /// 32-byte subaccount the *same account* as `null`, so this rejects a request
  /// naming an account the caller does own. Deliberate: a destination is stored,
  /// compared and rendered, and two stable values for one account is a defect source
  /// — an audit line and a receipt disagreeing about the same account.
  ///
  /// So `#destinationNotOwned` is imprecise for exactly that input. Accepted
  /// because nothing but this app calls it; if a third-party integrator ever does,
  /// canonicalise at the edge rather than widening this predicate.
  ///
  /// A genuinely different subaccount is refused for the plain reason: it is not the
  /// balance the app shows or that `icp cycles balance` reads by default, so
  /// delivering there strands the buyer's cycles somewhere they will not look.
  public func isOwnDestination(destination : Destination, caller : Principal) : Bool {
    switch (destination) {
      case (#cyclesLedgerAccount(account)) account.owner == caller and account.subaccount == null;
    };
  };

  /// Random, `raw_rand`-derived hex, not a monotonic counter (§2) — the id sits in the
  /// public `client_reference_id`. Not a bearer secret.
  public type OrderId = Text;

  /// §4 — one order, one state machine. Transitions live in `Orders.mo`; expiry
  /// *policy* is per-rail money-in behaviour and stays out of the core (§11.1.4).
  ///
  /// **A state no order can enter must not be representable** (§4). An unreachable
  /// status has to be carried by every `switch` and asserted unreachable by a test
  /// that passes whether or not the code is right. Deleting the state is the stronger
  /// guarantee — the same move as `#cancelled → #paid` being absent from the matrix
  /// rather than guarded.
  public type OrderStatus = {
    #created;
    /// The buyer gave up before paying. Terminal.
    #cancelled;
    #expired;
    #paid;
    #delivered;
    /// A money position whose outcome is not known — typically a transfer past the
    /// ledger's ~24 h dedup window. A human checks the ledger. The promise is **still
    /// held**.
    #needsReview;
    /// The operator ended the order, having refunded by hand. Terminal, and the
    /// promise is **released**.
    #abandoned;
  };

  public func statusToText(status : OrderStatus) : Text {
    switch (status) {
      case (#created) "Created";
      case (#cancelled) "Cancelled";
      case (#expired) "Expired";
      case (#paid) "Paid";
      case (#delivered) "Delivered";
      case (#needsReview) "NeedsReview";
      case (#abandoned) "Abandoned";
    };
  };

  /// §3 pricing snapshot captured at order creation, carrying the gross amount, both
  /// rate inputs and the fee formula from one consistent epoch.
  ///
  /// ⚠️ **The webhook does not reprice from it.** The session carries the amount we
  /// set, so the webhook requires the paid amount to *equal* the quote and a mismatch
  /// delivers nothing. The snapshot is **evidence**: what a buyer recomputes their own
  /// price from, and the record of which rates a delivered order was priced at.
  public type Pricing = {
    /// Gross USD cents the order was quoted for.
    usdCents : Nat;
    /// USD per ICP × 10⁶ from the Exchange Rate Canister at creation.
    usdPerIcpMicros : Nat;
    /// XDR per ICP × 10⁴ from the Cycles Minting Canister at creation.
    ///
    /// **Both rate inputs are stored, never the derived result.** Anyone can query
    /// the XRC and the CMC and recompute the quote from first principles; storing only
    /// the derived number makes the price checkable but not *auditable*.
    xdrPermyriadPerIcp : Nat;
    /// XRC quality signal for the ICP price: how many sources answered out of how many
    /// were asked, and their spread. A price from two sources is not the same product
    /// as one from twelve.
    rateStandardDeviation : Nat;
    rateReceivedRates : Nat;
    rateQueriedSources : Nat;
    /// §3 fee formula at creation.
    feeBps : Nat;
    feeFixedCents : Nat;
    /// When the rate pair was **read**, not when the order was created.
    ///
    /// Quotes are served from a timer-refreshed cache, so these rates predate the
    /// order by up to the staleness window. Without this field an auditor comparing
    /// the stored rates against XRC/CMC history at `createdAtNs` concludes the quote
    /// used the wrong rate.
    ratesFetchedAtNs : Int;
  };

  /// Immutable order record; status changes go through `Orders.transition`, which
  /// returns an updated copy.
  public type Order = {
    id : OrderId;
    owner : Owner;
    rail : Rail;
    destination : Destination;
    /// The cycle *quantity* locked at creation (§3) — delivery sends exactly this many
    /// regardless of later rate movement.
    ///
    /// ⚠️ **Nothing may write it after creation.** The promise tally is exact rather
    /// than conservative because of that; a second writer takes it away **silently**.
    lockedCycles : Nat;
    pricing : Pricing;
    status : OrderStatus;
    /// What the buyer **actually paid**, in USD cents; null until paid. Distinct from
    /// `pricing.usdCents`, which is what the order was *quoted*. Recorded on the money
    /// record so "what did this buyer pay?" is answerable from state.
    paidUsdCents : ?Nat;
    /// Why an order is `#expired`; null for every other status.
    ///
    /// Buyer cancellation is **not** here — it is `#cancelled`, a status. "Can this
    /// still be paid?" is a transition-matrix question, and answering it with a status
    /// plus a runtime check on a provenance field puts two owners on one decision.
    expiredBy : ?ExpiredBy;
    /// Stripe's `expires_at` for this order's session, in **nanoseconds** (Stripe
    /// reports Unix seconds). Null until the session exists — an order still null
    /// minutes after creation is a stranded-capacity signal.
    ///
    /// ⚠️ **Stamped once and never re-stamped.** Expiry used to be recomputed from the
    /// *current* global TTL, so changing that config retroactively re-dated every
    /// existing order. This is the deadline, singular.
    expiresAtNs : ?Int;
    /// The Checkout Session this order is paid through.
    ///
    /// The URL must survive a reload while the order is payable: without it a buyer
    /// who closed the tab has no route back, and the open-order cap then refuses them
    /// a second attempt.
    stripeSessionId : ?Text;
    stripeSessionUrl : ?Text;
    createdAtNs : Int;
    updatedAtNs : Int;
    /// When this order first crossed the delivery alert threshold while waiting, or
    /// null if it never did.
    ///
    /// ⚠️ **Setting this must NOT move `updatedAtNs`.** `Delivery.waitStage` reads
    /// `updatedAtNs` as the held-since clock, so touching it here resets the very wait
    /// being recorded and the order can never reach the max-hold bound.
    delayedAtNs : ?Int;
    /// Why an operator ended this order; set only on `#abandoned`.
    abandonedReason : ?Text;
    /// Problems that belong to this order, with their resolution state. See
    /// `Problems.mo` for the kinds and the admission rule they must pass.
    problems : [Problem];
  };

  /// Why an `#expired` order expired. **Two producers and only two** — Stripe's
  /// `checkout.session.expired`, and a failure to create the session at all. Nothing
  /// else can reach `#expired`, so null means "not `#expired`".
  public type ExpiredBy = {
    #sessionExpired;
    #sessionFailed;
  };

  /// An order-bound problem. The order it hangs off supplies the identity, so no arm
  /// carries an `orderId`.
  public type ProblemKind = {
    /// Refund-resolvable — a genuine second, distinct payment for an order already
    /// handled.
    #duplicate : { paymentRef : Text };
    /// A delivery stopped where it cannot continue automatically. Not
    /// refund-resolvable: the fiat is in, and what happens next depends on the money
    /// position rather than on the reason it stopped.
    ///
    /// ⚠️ **`stage` is a stringly-typed discriminator and must stay advisory.** It is
    /// safe only because the journal is the authority. **Never branch a money decision
    /// on comparing it** — ask the journal the way `Delivery.terminationFor` does, or
    /// make it a variant first.
    #deliveryStuck : { stage : Text };
    /// Not refund-resolvable — the money moved *both* ways. A `charge.refunded`
    /// arrived for a payment already delivered as cycles, so the fiat went back and the
    /// cycles are irreversibly gone. This **records a loss to reconcile** rather than
    /// starting a recovery flow.
    #refundAfterDelivery : {
      paymentRef : Text;
      cycles : Nat;
      /// Cumulative cents returned to the payer. Sized, because a partial refund is a
      /// partial loss and the operator reconciles against Stripe by **amount**.
      refundedCents : Nat;
      /// Whether that settled the whole charge.
      fullRefund : Bool;
    };
    /// Stripe says this session was paid and we never credited it.
    ///
    /// ⚠️ **The order stays `#created` deliberately.** `#created → #paid` is the only
    /// edge a resent event can travel, so keeping it there is what preserves the remedy
    /// that delivers to the buyer. Route it anywhere else and the operator's only exit
    /// becomes a refund.
    #paidNotCredited : { paymentRef : Text; sessionId : Text };
  };

  public type Problem = {
    kind : ProblemKind;
    detail : Text;
    filedAtNs : Int;
    resolvedAtNs : ?Int;
  };

  /// §5.1 — deterministic transfer args persisted *before* the ledger call. Replaying
  /// the identical args is safe: the ledger dedups on `created_at_time` within its
  /// ~24 h window.
  public type TransferIntent = {
    createdAtTimeNs : Nat64;
    amountCycles : Nat;
    to : Account;
    memo : Blob;
  };

  /// §4.2 — per-order money-out journal.
  public type JournalEntry = {
    orderId : OrderId;
    status : OrderStatus;
    destination : Destination;
    transferIntent : ?TransferIntent;
    blockIndex : ?Nat;
    cyclesDelivered : ?Nat;
    retries : Nat;
    /// The ledger's own words from the most recent failed attempt, or null if nothing
    /// has failed.
    ///
    /// **Overwritten, not accumulated.** An operator acts on the *current* obstacle;
    /// a growing list of every historical rejection is unbounded state fed by retries,
    /// and `retries` already says how many there were.
    lastError : ?Text;
    createdAtNs : Int;
    updatedAtNs : Int;
  };

};
