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
  /// than a schema-wide edit. The audit log, the error queue and the mint
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
  /// which is a mint-then-lose class this app no longer has (#29).
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
  public type OrderStatus = {
    #created;
    #expired;
    #paid;
    #minting;
    #icpAtCmc;
    #delivered;
    #awaitingTreasury;
    #errorQueue;
  };

  public func statusToText(status : OrderStatus) : Text {
    switch (status) {
      case (#created) "Created";
      case (#expired) "Expired";
      case (#paid) "Paid";
      case (#minting) "Minting";
      case (#icpAtCmc) "IcpAtCMC";
      case (#delivered) "Delivered";
      case (#awaitingTreasury) "AwaitingTreasury";
      case (#errorQueue) "ErrorQueue";
    };
  };

  /// §3/§6.1 pricing snapshot captured at order creation. `lockedCycles`
  /// is the §3 quantity for the *expected* (tier) amount; this snapshot is
  /// what lets the webhook honor a **different actual paid amount** at the
  /// same locked rate + fee formula instead of a fresh rate — "no quote
  /// drift" holds even off the happy path.
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
  };

  /// Immutable order record; status changes go through Orders.transition,
  /// which returns an updated copy. `lockedCycles` is the cycle *quantity*
  /// locked at creation (§3) — fulfillment delivers exactly this many cycles
  /// regardless of later rate movement; the operator absorbs ICP-cost drift.
  /// (Webhook ingestion replaces it via Orders.markPaid when the actual paid
  /// amount differs from the quoted tier, repriced from `pricing`.)
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
    createdAtNs : Int;
    updatedAtNs : Int;
  };

  /// §5.1 — deterministic transfer args persisted *before* the ledger call
  /// (write-intent-before-call). Replaying the identical args is safe: the
  /// ledger dedups on `created_at_time` within its ~24h window.
  public type TransferIntent = {
    createdAtTimeNs : Nat64;
    amountE8s : Nat;
    to : Account;
    memo : Blob;
  };

  /// §4.2 — per-order money-out journal: transfer intent, block_index,
  /// minted cycles, retries, timestamps, destination.
  public type JournalEntry = {
    orderId : OrderId;
    status : OrderStatus;
    destination : Destination;
    transferIntent : ?TransferIntent;
    blockIndex : ?Nat;
    cyclesMinted : ?Nat;
    retries : Nat;
    createdAtNs : Int;
    updatedAtNs : Int;
  };

};
