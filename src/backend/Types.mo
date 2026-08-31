/// Core shared types for the cycles gateway.
///
/// Decision record: design-docs/ONCHAIN_GATEWAY_SPEC.md — §2 (ownership),
/// §3 (locked cycle quantity), §4 (state machine), §4.2 (data model),
/// §5.1 (transfer intent), §11.1 (binding Base seams).
import Principal "mo:core/Principal";

module {

  /// Seam §11.1.1 — single-case variant from day one. If Base/x402 returns,
  /// `#evmAddress : Blob` is a migration-free, compatible extension; a bare
  /// `Principal` field would force a stable-state migration plus an audit of
  /// every authz site. Pattern-match at every authz check.
  public type Owner = { #ii : Principal };

  /// Query authz is `caller == order.owner` (§2). Centralised pattern match.
  ///
  /// **Adding an `Owner` case cannot compile until every match on it is updated.**
  /// Deliberately not enumerated here — a hand-maintained list of call sites goes
  /// stale silently, which is the same failure this comment used to have. Ask the
  /// compiler: `mops check -- -Werror` names every one. Both forms are caught, the
  /// `switch` and the refutable `let #ii(x) = …`.
  ///
  /// That guarantee rests on `-Werror`, not on the language: a non-exhaustive match
  /// is M0145, a *warning*, so a plain `mops check` reports them all and still
  /// succeeds — leaving each unhandled site to trap at runtime when the new case
  /// reaches it. On the webhook path that trap is a 5xx, which Stripe retries for
  /// ~3 days. The gate therefore runs `-Werror` (scripts/test-all.sh and CI);
  /// verified by adding `#evmAddress` and watching the build fail.
  ///
  /// ⚠️ What `-Werror` does **not** catch: `Orders.ordersFor` and
  /// `Orders.openOrderCount` look owners up through `principalsToOrders`, a
  /// Principal-keyed index, and never pattern-match. A future non-principal owner
  /// would compile clean and silently return nothing for those two. Fail-closed —
  /// no data is exposed — but the seam work has to reindex, not just re-match.
  public func isOwnedBy(owner : Owner, caller : Principal) : Bool {
    switch (owner) {
      case (#ii(p)) p == caller;
    };
  };

  /// Money-in rail. Single-case, and a variant for the same reason `Owner` is
  /// one: it names the dimension, so a second rail is an additive change rather
  /// than a schema-wide edit. The audit log, the error queue and the delivery
  /// journal are all keyed by it.
  public type Rail = { #card };

  /// ICRC-1 account (cycles ledger destination).
  public type Account = { owner : Principal; subaccount : ?Blob };

  /// Where cycles are delivered (§5). The buyer's **own** cycles-ledger
  /// account, default subaccount — `create_order` refuses anything else, so a
  /// crafted call cannot send cycles to a third party.
  ///
  /// Single-case, and a variant for the same reason `Owner` and `Rail` are: it
  /// names the dimension, so a second destination kind is an additive change
  /// rather than a schema-wide edit.
  ///
  /// ⚠️ Depositing straight to a canister's cycle balance is **not** the case to
  /// add. It fails on a deleted or refusing target *after* the cycles have left,
  /// which is a send-then-lose class this app does not have (#29).
  public type Destination = {
    #cyclesLedgerAccount : Account;
  };

  /// Whether a destination delivers to `caller` and nobody else (#29).
  ///
  /// **`null` is the one accepted spelling of the default subaccount, and
  /// equivalent forms are refused rather than normalised.** ICRC-1 makes an
  /// all-zero 32-byte subaccount the *same account* as `null` — measured against
  /// the cycles ledger, both spellings return one balance — so this rejects a
  /// request that names an account the caller does in fact own. That is
  /// deliberate: a destination is stored, compared and rendered, and two stable
  /// values that are semantically one account is a defect source (an audit line
  /// and a receipt that disagree about the same account). One representation in,
  /// nothing to canonicalise later.
  ///
  /// ⚠️ So `#destinationNotOwned` is imprecise for exactly that input — the
  /// account IS owned, it is spelled non-canonically. Accepted because the app
  /// never sends it and nothing else calls this method; revisit if a third-party
  /// integrator ever does, and canonicalise at the edge rather than widening the
  /// predicate.
  ///
  /// A genuinely different subaccount is refused for the plain reason: it is not
  /// the balance the app shows or that `icp cycles balance` reads by default, so
  /// delivering there strands the buyer's cycles somewhere they will not look.
  ///
  /// Centralised beside `isOwnedBy` for the same reason: `-Werror` then names
  /// every site when a second destination kind arrives.
  public func isOwnDestination(destination : Destination, caller : Principal) : Bool {
    switch (destination) {
      case (#cyclesLedgerAccount(account)) account.owner == caller and account.subaccount == null;
    };
  };

  /// Random, raw_rand-derived (hex text), not a monotonic counter (§2) — the
  /// ID sits in the public `client_reference_id`. Not a bearer secret.
  public type OrderId = Text;

  /// §4 — one Order, one state machine. Transitions live in Orders.mo;
  /// expiry *policy* is per-rail money-in behavior and stays out of the core
  /// (seam §11.1.4).
  /// §4 statuses — **seven, and adding an eighth is a design decision, not a
  /// detail.** Each says exactly one thing, and the promise state (#30) is a
  /// function of the status alone, which is what lets `promiseHeld` be total.
  ///
  /// ⚠️ **A state no order can enter should not be representable.** An
  /// unreachable status has to be carried by every `switch` and asserted
  /// unreachable by a test, and that test passes whether or not the code is
  /// right. Deleting the state is the stronger guarantee, and it is the one this
  /// codebase reaches for everywhere: the money-out surface declares two ledger
  /// methods so no third one exists to call, and `#cancelled → #paid` is absent
  /// from the matrix rather than guarded.
  public type OrderStatus = {
    #created;
    /// The buyer gave up before paying. Terminal, and `#cancelled → #paid` is
    /// absent from the matrix — that absence IS the guarantee (#34).
    #cancelled;
    #expired;
    #paid;
    #delivered;
    /// A money position whose outcome is not known — typically a transfer past
    /// the ledger's ~24 h dedup window. A human checks the ledger. The order's
    /// **promise is still held** (#30).
    #needsReview;
    /// The operator ended the order, typically after refunding by hand.
    /// Terminal, and the **promise is released** (#30).
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

  /// §3/§6.1 pricing snapshot captured at order creation, carrying the gross
  /// amount, both rate inputs and the fee formula from one consistent epoch.
  ///
  /// ⚠️ **The webhook does not reprice from it.** A per-order Checkout Session
  /// carries the amount we set, so the webhook requires the paid amount to equal
  /// the quoted one and a mismatch delivers nothing. What the snapshot is *for* is
  /// evidence: it is what a buyer recomputes their own price from (`receipt`), and
  /// the record of which rates a delivered order was priced at.
  public type Pricing = {
    /// Gross USD cents the order was quoted for (the tier price).
    usdCents : Nat;
    /// USD per ICP × 10⁶ as read from the Exchange Rate Canister at creation.
    usdPerIcpMicros : Nat;
    /// XDR per ICP × 10⁴ as read from the Cycles Minting Canister at creation.
    ///
    /// Both rate inputs are stored rather than the derived result, so the quote
    /// is reproducible from first principles: anyone can query the XRC and the
    /// CMC and recompute `netCents × xdrPermyriadPerIcp × 10¹² /
    /// usdPerIcpMicros`. Storing only the derived number would make the price
    /// checkable but not *auditable*.
    xdrPermyriadPerIcp : Nat;
    /// XRC quality signal for the ICP price above: how many sources answered
    /// out of how many were asked, and their spread. A price assembled from two
    /// sources is not the same product as one from twelve.
    rateStandardDeviation : Nat;
    rateReceivedRates : Nat;
    rateQueriedSources : Nat;
    /// §3 fee formula at creation.
    feeBps : Nat;
    feeFixedCents : Nat;
    /// When the rate pair above was **read**, not when the order was created.
    ///
    /// Quotes are served from a cache refreshed on a timer, so these rates were
    /// observed up to `maxAgeNs` before the order existed. Without this the only
    /// timestamp on the record is `createdAtNs`, and an auditor comparing the
    /// stored rates against XRC/CMC history at that moment can conclude the
    /// quote used the wrong rate. It is also the only way to ask, after the fact,
    /// whether an order was priced off a rate that was about to go stale.
    ratesFetchedAtNs : Int;
  };

  /// Immutable order record; status changes go through Orders.transition,
  /// which returns an updated copy. `lockedCycles` is the cycle *quantity*
  /// locked at creation (§3) — fulfillment delivers exactly this many cycles
  /// regardless of later rate movement; the operator absorbs ICP-cost drift.
  ///
  /// ⚠️ **Nothing writes it after creation.** Webhook ingestion used to replace
  /// it through `Orders.markPaid` when the paid amount differed from the quote;
  /// #33 deleted repricing and `markPaid` no longer takes a quantity at all, so
  /// the immutability is structural rather than a rule to remember. #30's tally
  /// is exact rather than conservative because of it — anything that gives this
  /// field a second writer takes that away.
  public type Order = {
    id : OrderId;
    owner : Owner;
    rail : Rail;
    destination : Destination;
    lockedCycles : Nat;
    pricing : Pricing;
    status : OrderStatus;
    /// What the buyer **actually paid**, in USD cents. Null until paid.
    ///
    /// Distinct from `pricing.usdCents`, which is what the order was *quoted*
    /// for. The two differ whenever a card payment arrives for a different
    /// amount. Recorded here, on the money record, so "what did this buyer
    /// pay?" is answerable from state forever — the audit ring buffer is
    /// telemetry and drops its oldest entries, so it cannot be the only place
    /// a fact about money lives.
    ///
    paidUsdCents : ?Nat;
    /// Why an order is `#expired`. Null for every other status. Both producers
    /// are Stripe-side, and they are the only ones: #33 deleted the retention
    /// sweep, so there is no third way for an order to reach `#expired` and no
    /// tag for one.
    ///
    /// Buyer cancellation is **not** here: it is `#cancelled`, a status. The
    /// question "can this still be paid?" is a transition-matrix question, and
    /// answering it with a status plus a runtime check on a provenance field puts
    /// two owners on one decision.
    expiredBy : ?ExpiredBy;
    /// Stripe's `expires_at` for this order's Checkout Session, in
    /// **nanoseconds** (Stripe reports Unix seconds; #33 multiplies by 10⁹).
    ///
    /// Stamped once from the session-create response and never re-stamped, since
    /// there is no session retry. Null until the session exists — an order still
    /// null minutes after creation is #30's detection predicate 2.
    ///
    /// This is the deadline, singular. Expiry used to be recomputed from the
    /// *current* global TTL, so changing that config retroactively re-dated every
    /// existing order.
    expiresAtNs : ?Int;
    /// The Checkout Session this order is paid through (#33). The URL must
    /// survive a reload: without it a buyer who closed the tab has no route back
    /// to paying an order that is still payable, and the open-order cap then
    /// refuses them a second attempt.
    stripeSessionId : ?Text;
    stripeSessionUrl : ?Text;
    createdAtNs : Int;
    updatedAtNs : Int;
    /// When this order first crossed `alertAfterNs` while waiting to deliver, or
    /// null if it never did (#37).
    ///
    /// ⚠️ **The historical half of the dropped `#deliveryDelayed` entry.** That
    /// entry carried `resolvedAtNs`, so "a delay happened here and was closed" was
    /// recorded; `delayed_deliveries` is a live view and leaves no trace once the
    /// order delivers. Removing a capability is not the same as dropping a worklist
    /// item, so the record moves onto the order rather than vanishing — which is
    /// this issue's own thesis.
    ///
    /// ⚠️ **A field, deliberately, and NOT the `delayedAlerts` map returning.** That
    /// map existed to remember an *entry id* so the entry could be resolved later,
    /// and leaking it was a real failure mode. Nothing needs resolving here, so the
    /// state lives on the order and "set it if unset" is idempotent — there is no
    /// second structure to fall out of step with this one.
    ///
    /// ⚠️ **Setting this must NOT move `updatedAtNs`.** `Delivery.waitStage` reads
    /// `updatedAtNs` as the held-since clock, so touching it here would reset the
    /// very wait being recorded and the order could never reach `maxHoldNs`.
    delayedAtNs : ?Int;
  };

  /// Why an `#expired` order expired. Two producers, and they are the only two:
  /// Stripe's `checkout.session.expired` event, and a failure to create the
  /// session at all. #33 deleted the retention sweep, so nothing else can reach
  /// `#expired` and no expiry leaves this null — null means "not `#expired`".
  public type ExpiredBy = {
    #sessionExpired;
    #sessionFailed;
  };

  /// §5.1 — deterministic transfer args persisted *before* the ledger call
  /// (write-intent-before-call). Replaying the identical args is safe: the
  /// ledger dedups on `created_at_time` within its ~24h window.
  public type TransferIntent = {
    createdAtTimeNs : Nat64;
    amountCycles : Nat;
    to : Account;
    memo : Blob;
  };

  /// §4.2 — per-order money-out journal: transfer intent, block_index, cycles
  /// delivered, retries, timestamps, destination.
  public type JournalEntry = {
    orderId : OrderId;
    status : OrderStatus;
    destination : Destination;
    transferIntent : ?TransferIntent;
    blockIndex : ?Nat;
    cyclesDelivered : ?Nat;
    retries : Nat;
    /// The ledger's own words from the most recent failed attempt, or null if
    /// nothing has failed (#37 §1b).
    ///
    /// ⚠️ **The one thing `#deliveryStuck` carried that exists nowhere else.** Its
    /// `orderId`, `status`, `blockIndex` and `retries` are all already here, so once
    /// the error text lives on the journal the kind's identity fields are pure
    /// duplication — which is what lets the problem move onto the order carrying only
    /// its stage and resolution state.
    ///
    /// ⚠️ **Overwritten, not accumulated.** An operator acts on the *current*
    /// obstacle; a growing list of every historical rejection is unbounded state fed
    /// by retries, and `retries` already says how many there were.
    lastError : ?Text;
    createdAtNs : Int;
    updatedAtNs : Int;
  };

};
