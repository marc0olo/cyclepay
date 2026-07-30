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

  /// Query authz is `caller == order.owner` (§2). Centralised pattern match;
  /// new owner cases make this a compile error rather than a silent assumption.
  public func isOwnedBy(owner : Owner, caller : Principal) : Bool {
    switch (owner) {
      case (#ii(p)) p == caller;
    };
  };

  /// Money-in rails in scope (§6). Base/x402 deferred (§6.3, §11).
  public type Rail = { #card; #ckUsdc };

  /// ICRC-1 account (cycles ledger destination).
  public type Account = { owner : Principal; subaccount : ?Blob };

  /// Where minted cycles are forwarded (§5, mint-to-self-then-forward).
  /// `#canister` deposits to a canister's cycle balance and can fail (deleted
  /// target → error queue Type 2); `#cyclesLedgerAccount` essentially never
  /// fails (§5, "no pre-validation" decision).
  public type Destination = {
    #canister : Principal;
    #cyclesLedgerAccount : Account;
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
    /// On the ck-USDC rail this always equals `pricing.usdCents`: the canister
    /// pulls the exact quoted price, so a mismatch is structurally impossible.
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
