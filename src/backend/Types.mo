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

  /// Immutable order record; status changes go through Orders.transition,
  /// which returns an updated copy. `lockedCycles` is the cycle *quantity*
  /// locked at creation (§3) — fulfillment delivers exactly this many cycles
  /// regardless of later rate movement; the operator absorbs ICP-cost drift.
  public type Order = {
    id : OrderId;
    owner : Owner;
    rail : Rail;
    destination : Destination;
    lockedCycles : Nat;
    status : OrderStatus;
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
