/// ck-USDC rail (§6.2) — the pure half.
///
/// ICRC-1/2 Candid types for the ck-USDC ledger, the approve→pull flow's
/// deterministic pull-intent construction, `icrc2_transfer_from` result
/// interpretation, the per-order pull journal, and the claim resume decision.
/// Everything here is synchronous and unit-testable; Main.mo owns the awaits,
/// the order store, and the §4.2 `processedCkUsdcBlocks` dedup set.
///
/// This is the money-IN twin of Cmc.mo's §5.1 invariant: `icrc2_transfer_from`
/// debits the *user's* ck-USDC, so it gets the same write-intent-before-call
/// treatment — the pull args (including `created_at_time`) are persisted in
/// one sync block before the ledger await. A call whose response is lost
/// (upgrade mid-pull) is recovered by replaying the *identical* args: the
/// ledger either performs the pull once or answers `#Duplicate` with the
/// original block. An intent older than the ledger's ~24 h dedup window
/// without a recorded block is never auto-replayed with fresh args (the
/// original pull's fate is unknowable — fresh args could debit the user
/// twice); it escalates to the operator, who reads the ck-USDC ledger.
///
/// Definite-rejection rule used by `interpretPull`: ic-icrc1 ledgers check
/// `created_at_time` dedup *before* balance/allowance checks, so an identical
/// transaction that already executed answers `#Duplicate`, never
/// `#InsufficientAllowance`/`#InsufficientFunds`/`#BadFee`. Those errors
/// therefore prove no attempt with these args has ever moved money — the
/// intent can be dropped and rebuilt fresh, which is what turns "approved too
/// little" (§6.2 amount-short mismatch) into a clean retryable user error
/// instead of a stuck order.
///
/// Treasury posture (§6.2, hold-ckUSDC): pulled ck-USDC accrues in the
/// canister's own ledger account — no per-order DEX swap. Mints come from the
/// shared ICP float; the operator periodically withdraws the accrued ck-USDC
/// (admin lever in Main.mo) and converts it to ICP off-chain to refill.
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Types "../Types";

module {

  /// ck-USDC ledger (mainnet; PocketIC suites deploy their own and override).
  public let ledgerId : Text = "xevnm-gaaaa-aaaar-qafnq-cai";

  /// ck-USDC has 6 decimals and is 1:1 USD by construction, so one US cent
  /// is exactly 10^4 ledger units. Pricing in `usdCents` is exact on this
  /// rail — no forex enters the money-in side (only the cycles quote).
  public let unitsPerCent : Nat = 10_000;

  /// ICRC ledgers (ic-icrc1) deduplicate on `created_at_time` for ~24 h.
  /// At/after this age a pull intent without a block must escalate, never
  /// replay. (Same constant as Cmc.ledgerDedupWindowNs; kept local so the
  /// rail module stays self-contained.)
  public let ledgerDedupWindowNs : Int = 86_400_000_000_000;

  // ── Candid interfaces (only the methods this rail calls) ─────────────────

  public type TransferArg = {
    from_subaccount : ?Blob;
    to : Types.Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferResult = { #Ok : Nat; #Err : TransferError };

  public type TransferFromArgs = {
    spender_subaccount : ?Blob;
    from : Types.Account;
    to : Types.Account;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };

  public type TransferFromError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #InsufficientAllowance : { allowance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  public type TransferFromResult = { #Ok : Nat; #Err : TransferFromError };

  public type LedgerService = actor {
    icrc2_transfer_from : shared TransferFromArgs -> async TransferFromResult;
    icrc1_transfer : shared TransferArg -> async TransferResult;
    icrc1_balance_of : shared query Types.Account -> async Nat;
  };

  // ── Rail config (§7 operator config) ─────────────────────────────────────

  /// `minUsdCents`/`maxUsdCents` bound the user-chosen amount (no fixed
  /// tiers here — nothing structural pins the amount the way a card Payment
  /// Link does, and the canister pulls the exact price itself). `feeBps`/
  /// `feeFixedCents` is the §3 net-of-fees formula for this rail.
  /// `ledgerFeeUnits` is the ck-USDC ledger transfer fee the user's approval
  /// must also cover (a protocol fact, not a pricing decision; a drift
  /// surfaces as `#BadFee` → operator updates the config).
  public type Config = {
    minUsdCents : Nat;
    maxUsdCents : Nat;
    feeBps : Nat;
    feeFixedCents : Nat;
    ledgerFeeUnits : Nat;
  };

  /// Fail closed: `maxUsdCents = 0` keeps the rail disabled until the
  /// operator consciously sizes it (the empty-tier-list stance — bounds on a
  /// money rail are an operator decision, not a default invented here). The
  /// fee formula defaults to zero — unlike Stripe's 2.9% + 30¢ there is no
  /// structural processor fee on this rail (ledger fees are paid by the
  /// user); the operator absorbs off-chain conversion costs per the §3
  /// at-cost posture, and can set a fee here if that changes.
  public func defaultConfig() : Config {
    {
      minUsdCents = 0;
      maxUsdCents = 0;
      feeBps = 0;
      feeFixedCents = 0;
      ledgerFeeUnits = 10_000;
    };
  };

  public type ConfigError = {
    /// Fee ≥ 100% can never net out.
    #feeBpsTooHigh;
    /// An enabled rail (max > 0) with min > max can never accept an order.
    #minAboveMax;
  };

  public func validateConfig(config : Config) : Result.Result<(), ConfigError> {
    if (config.feeBps >= 10_000) return #err(#feeBpsTooHigh);
    if (config.maxUsdCents > 0 and config.minUsdCents > config.maxUsdCents) {
      return #err(#minAboveMax);
    };
    #ok;
  };

  public type AmountError = {
    /// `maxUsdCents = 0` — the operator has not enabled this rail.
    #railDisabled;
    /// A $0 order would mint on nothing.
    #zeroAmount;
    /// Carries the bound so the frontend can say what *would* be accepted.
    #belowMinimum : Nat;
    #aboveMaximum : Nat;
  };

  public func validateAmount(config : Config, usdCents : Nat) : Result.Result<(), AmountError> {
    if (config.maxUsdCents == 0) return #err(#railDisabled);
    if (usdCents == 0) return #err(#zeroAmount);
    if (usdCents < config.minUsdCents) return #err(#belowMinimum(config.minUsdCents));
    if (usdCents > config.maxUsdCents) return #err(#aboveMaximum(config.maxUsdCents));
    #ok;
  };

  // ── Pure derivations ─────────────────────────────────────────────────────

  /// Ledger units the claim pulls for a quoted gross amount.
  public func unitsForCents(usdCents : Nat) : Nat {
    usdCents * unitsPerCent;
  };

  /// The §5.1-style deterministic pull args, persisted *before* the ledger
  /// call. Everything the ledger dedups on is fixed here; replaying this
  /// intent can never debit the user twice. The memo is the order ID's UTF-8
  /// (32 hex chars = exactly the 32-byte ICRC-1 memo bound), tying the
  /// ledger transaction to the order for off-chain audit.
  public type PullIntent = {
    createdAtTimeNs : Nat64;
    amountUnits : Nat;
    feeUnits : Nat;
    fromOwner : Principal;
    memo : Blob;
  };

  public func buildPullIntent(
    fromOwner : Principal,
    orderId : Types.OrderId,
    amountUnits : Nat,
    feeUnits : Nat,
    nowNs : Int,
  ) : PullIntent {
    {
      createdAtTimeNs = Nat64.fromIntWrap(nowNs);
      amountUnits;
      feeUnits;
      fromOwner;
      memo = orderId.encodeUtf8();
    };
  };

  /// The intent's wire form. A pure projection — replay maps the *stored*
  /// intent through this, so the replayed call is bit-identical to the first.
  /// `gateway` (the spender = recipient) is the canister's own principal,
  /// constant across upgrades.
  public func transferFromArgs(gateway : Principal, intent : PullIntent) : TransferFromArgs {
    {
      spender_subaccount = null;
      from = { owner = intent.fromOwner; subaccount = null };
      to = { owner = gateway; subaccount = null };
      amount = intent.amountUnits;
      fee = ?intent.feeUnits;
      memo = ?intent.memo;
      created_at_time = ?intent.createdAtTimeNs;
    };
  };

  // ── Result interpretation ────────────────────────────────────────────────

  /// Why a definite rejection happened — each maps to a user-actionable
  /// error, and per the module-doc dedup-first rule each *proves* nothing
  /// has ever moved under these args, so the caller drops the intent.
  public type DropReason = {
    /// §6.2 amount-short mismatch: the approval doesn't cover amount + fee.
    #insufficientAllowance : { allowance : Nat };
    /// The user's ck-USDC balance doesn't cover amount + fee.
    #insufficientFunds : { balance : Nat };
    /// `ledgerFeeUnits` config drifted from the ledger's actual fee.
    #badFee : { expectedFee : Nat };
    /// Structurally impossible rejections (e.g. BadBurn on a transfer_from).
    #rejected : Text;
  };

  /// What the claim driver does next.
  public type PullOutcome = {
    /// Block recovered — `#Ok` or `#Duplicate` (the §5.1 replay payoff).
    #pulled : Nat;
    /// Definite rejection: drop the intent, surface the reason. Nothing moved.
    #drop : DropReason;
    /// Transient: keep the intent, replay on the next claim (always safe
    /// within the dedup window).
    #retry : Text;
    /// The ledger can no longer answer for these args (`#TooOld`) — a lost
    /// earlier attempt could have executed. Escalate; never rebuild fresh.
    #uncertain : Text;
  };

  public func interpretPull(result : TransferFromResult) : PullOutcome {
    switch (result) {
      case (#Ok(block)) #pulled(block);
      case (#Err(#Duplicate({ duplicate_of }))) #pulled(duplicate_of);
      // Definite rejections — dedup-first ledger semantics prove no prior
      // lost attempt executed either (it would have answered #Duplicate).
      case (#Err(#InsufficientAllowance({ allowance }))) #drop(#insufficientAllowance({ allowance }));
      case (#Err(#InsufficientFunds({ balance }))) #drop(#insufficientFunds({ balance }));
      case (#Err(#BadFee({ expected_fee }))) #drop(#badFee({ expectedFee = expected_fee }));
      case (#Err(#BadBurn(_))) #drop(#rejected("ledger answered BadBurn to a transfer_from"));
      // Transient: identical args can succeed later; replay is safe.
      case (#Err(#TemporarilyUnavailable)) #retry("ledger temporarily unavailable");
      case (#Err(#CreatedInFuture(_))) #retry("created_at_time ahead of ledger clock");
      case (#Err(#GenericError({ error_code; message }))) #retry("ledger error " # error_code.toText() # ": " # message);
      // TooOld: past the dedup window the ledger can't distinguish "never
      // executed" from "executed, then forgotten" — the §5.1 stale-intent
      // uncertainty, money-in edition.
      case (#Err(#TooOld)) #uncertain("pull intent aged past the ledger dedup window");
    };
  };

  /// Admin-facing rendering for the withdraw lever's ICRC-1 errors.
  public func transferErrorToText(error : TransferError) : Text {
    switch (error) {
      case (#BadFee({ expected_fee })) "BadFee: ledger expects " # expected_fee.toText();
      case (#BadBurn(_)) "BadBurn";
      case (#InsufficientFunds({ balance })) "InsufficientFunds: balance " # balance.toText() # " units";
      case (#TooOld) "TooOld";
      case (#CreatedInFuture(_)) "CreatedInFuture";
      case (#Duplicate({ duplicate_of })) "Duplicate of block " # duplicate_of.toText();
      case (#TemporarilyUnavailable) "TemporarilyUnavailable";
      case (#GenericError({ error_code; message })) "GenericError " # error_code.toText() # ": " # message;
    };
  };

  // ── Pull journal (§4.2-adjacent: the money-IN record for this rail) ──────

  /// One pull per order, keyed by order ID. Financial record — kept for
  /// years, never pruned (it is what proves which ledger block paid which
  /// order, alongside `processedCkUsdcBlocks`).
  public type PullEntry = {
    orderId : Types.OrderId;
    intent : PullIntent;
    blockIndex : ?Nat;
    /// Set when the stale-intent uncertainty was queued for the operator —
    /// guards against re-queueing on every subsequent claim attempt.
    escalatedAtNs : ?Int;
    createdAtNs : Int;
    updatedAtNs : Int;
  };

  public type PullJournal = Map.Map<Types.OrderId, PullEntry>;

  public func emptyPullJournal() : PullJournal {
    Map.empty<Types.OrderId, PullEntry>();
  };

  /// Persist the intent — same sync block as its construction, before the
  /// transfer_from await.
  public func openPull(journal : PullJournal, orderId : Types.OrderId, intent : PullIntent, nowNs : Int) : PullEntry {
    let entry : PullEntry = {
      orderId;
      intent;
      blockIndex = null;
      escalatedAtNs = null;
      createdAtNs = nowNs;
      updatedAtNs = nowNs;
    };
    journal.add(orderId, entry);
    entry;
  };

  /// No-op on a missing id — a pipeline bug must degrade to a stuck claim,
  /// never a trap mid-money-flow (the Cmc.patch convention).
  public func recordPullBlock(journal : PullJournal, orderId : Types.OrderId, blockIndex : Nat, nowNs : Int) {
    let ?entry = journal.get(orderId) else return;
    journal.add(orderId, { entry with blockIndex = ?blockIndex; updatedAtNs = nowNs });
  };

  public func markEscalated(journal : PullJournal, orderId : Types.OrderId, nowNs : Int) {
    let ?entry = journal.get(orderId) else return;
    journal.add(orderId, { entry with escalatedAtNs = ?nowNs; updatedAtNs = nowNs });
  };

  /// Remove the intent — only legal when nothing moved under it (definite
  /// rejection, or operator-verified via the ledger).
  public func dropPull(journal : PullJournal, orderId : Types.OrderId) {
    journal.remove(orderId);
  };

  // ── Claim resume decision ────────────────────────────────────────────────

  /// The claim driver's next move for one order, derived from status + pull
  /// journal — the whole §5.1-style resume decision as one pure function.
  public type ClaimStage = {
    /// Order status is past money-in (or terminal) — nothing to claim.
    #notClaimable;
    /// No intent yet: build one, persist it, pull.
    #fresh;
    /// Intent persisted, no block, within the dedup window: (re)issue the
    /// identical pull — first attempt and recovery replay are the same move.
    #replay : PullIntent;
    /// Block recorded but the `#paid` transition never committed (a healed
    /// regression path, unreachable today — both commit in one sync block).
    #recoverBlock : Nat;
    /// Intent aged past the dedup window without a block — queue for the
    /// operator (once), then answer #alreadyEscalated.
    #escalate : PullIntent;
    #alreadyEscalated;
  };

  public func claimStage(
    status : Types.OrderStatus,
    entry : ?PullEntry,
    nowNs : Int,
    dedupWindowNs : Int,
  ) : ClaimStage {
    switch (status) {
      // #expired stays claimable: §4 expiry is advisory — a late real
      // payment still completes at the locked quantity.
      case (#created or #expired) {};
      case (_) return #notClaimable;
    };
    let ?e = entry else return #fresh;
    switch (e.blockIndex) {
      case (?block) return #recoverBlock(block);
      case null {};
    };
    if (e.escalatedAtNs != null) return #alreadyEscalated;
    if (nowNs - e.intent.createdAtTimeNs.toNat() >= dedupWindowNs) {
      return #escalate(e.intent);
    };
    #replay(e.intent);
  };

};
