/// CMC mint pipeline — the pure half (§5, §5.1).
///
/// Candid interfaces for the ICP ledger + CMC + cycles ledger, deterministic
/// transfer-intent construction, ICP amount derivation off the CMC rate, and
/// the resume/replay decision logic. Everything here is synchronous and
/// unit-testable; Main.mo owns the awaits, the journal/order stores, and the
/// forward step.
///
/// §5.1 invariant this module exists to uphold: the transfer args are
/// **deterministic and persisted before the ledger call** (write-intent-
/// before-call). Recovery replays the *identical* args — the ledger either
/// performs the transfer once or answers `#Duplicate { duplicate_of }`;
/// either way the `block_index` is recovered with no double-spend. An intent
/// older than the ledger's ~24 h dedup window without a known block_index is
/// never auto-replayed (the original transfer's fate is unknowable) — it
/// escalates to the error queue.
///
/// Delivery is **mint-to-self-then-forward** (§5): one notify path,
/// `notify_top_up(self)` with the TPUP memo, for *both* destination kinds —
/// cycles always land in the app canister's own balance first, so a failed
/// forward strands them exactly where Type 2 (§4.1) says they are. The
/// CMC's `notify_mint_cycles`/MINT path is deliberately unused: it would
/// strand value in the app's *cycles-ledger* balance instead, splitting the
/// Type-2 invariant across two places.
import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Types "Types";

module {

  // ── Well-known principals (identical on PocketIC's NNS subnet, §9) ──────

  /// ICP ledger.
  public let icpLedgerId : Text = "ryjl3-tyaaa-aaaaa-aaaba-cai";
  /// Cycles minting canister.
  public let cmcId : Text = "rkp4c-7iaaa-aaaaa-aaaca-cai";
  /// Cycles ledger (forward target for `#cyclesLedgerAccount` destinations).
  public let cyclesLedgerId : Text = "um5iw-rqaaa-aaaaq-qaaba-cai";

  // ── Candid interfaces (only the methods this pipeline calls) ────────────

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

  public type LedgerService = actor {
    icrc1_transfer : shared TransferArg -> async TransferResult;
    icrc1_balance_of : shared query Types.Account -> async Nat;
  };

  public type NotifyTopUpArg = { block_index : Nat64; canister_id : Principal };

  public type NotifyError = {
    #Refunded : { reason : Text; block_index : ?Nat64 };
    #InvalidTransaction : Text;
    #Other : { error_code : Nat64; error_message : Text };
    #Processing;
    #TransactionTooOld : Nat64;
  };

  /// `#Ok` carries the cycles minted to `canister_id`'s balance.
  public type NotifyTopUpResult = { #Ok : Nat; #Err : NotifyError };

  public type IcpXdrConversionRate = {
    timestamp_seconds : Nat64;
    xdr_permyriad_per_icp : Nat64;
  };

  public type IcpXdrConversionRateResponse = {
    data : IcpXdrConversionRate;
    hash_tree : Blob;
    certificate : Blob;
  };

  public type CmcService = actor {
    notify_top_up : shared NotifyTopUpArg -> async NotifyTopUpResult;
    get_icp_xdr_conversion_rate : shared query () -> async IcpXdrConversionRateResponse;
  };

  public type DepositArgs = { to : Types.Account; memo : ?Blob };

  public type CyclesLedgerService = actor {
    deposit : shared DepositArgs -> async { balance : Nat; block_index : Nat };
  };

  // ── Constants ────────────────────────────────────────────────────────────

  /// ICP ledger transfer fee (e8s). Fixed protocol-wide; a change would
  /// surface as `#BadFee` → escalation, never a silent wrong transfer.
  public let icpTransferFeeE8s : Nat = 10_000;

  /// How far the CMC's mint may fall short of the locked quantity before the
  /// order is escalated instead of delivered.
  ///
  /// `icpE8sForCycles` rounds **up**, so the ICP sent normally mints slightly
  /// *more* than the locked quantity. A shortfall therefore means the CMC's rate
  /// moved unfavourably between sizing the transfer and notifying it — up to
  /// 15 min under the staleness guard, or arbitrarily long when a recovery sweep
  /// notifies a transfer stranded by an outage.
  ///
  /// A gap of a few cycles is still tolerated because the rate is quantised per
  /// e8s and putting a human on single cycles is absurd. A *material* gap is a
  /// real rate move, and covering it silently would subsidise the buyer out of
  /// this canister's gas without limit — invisible, unbudgeted, and eventually a
  /// trap when the balance cannot cover it. 1 G cycles is ~0.001 XDR: far above
  /// quantisation, far below anything worth absorbing.
  public let maxMintShortfallCycles : Nat = 1_000_000_000;

  /// Did the CMC mint materially less than the order locked?
  ///
  /// Pure so the boundary is pinned by test rather than by reading the call site:
  /// the consequence of getting it wrong in either direction is silent — too
  /// strict escalates healthy orders, too loose subsidises buyers from this
  /// canister's gas.
  public func isMaterialShortfall(minted : Nat, locked : Nat) : Bool {
    minted + maxMintShortfallCycles < locked;
  };

  /// Cycles the cycles ledger deducts from a `deposit`. A
  /// `#cyclesLedgerAccount` destination therefore receives this much less than
  /// the order's locked quantity; a `#canister` top-up pays nothing.
  ///
  /// Deliberately **not** grossed up into the quote: minting extra cycles to
  /// cover a per-order fee would let anyone drain the operator by opening
  /// account-destination orders, so the fee is disclosed to the buyer rather
  /// than absorbed. Exposed through `quote_previews` for exactly that purpose.
  public let cyclesLedgerDepositFee : Nat = 100_000_000;

  /// The CMC recognizes a top-up by this icrc1 memo: the 8-byte little-endian
  /// encoding of 0x50555054 ("TPUP"). Pinned by test vector.
  public let topUpMemo : Blob = "\54\50\55\50\00\00\00\00";

  /// The ICP ledger deduplicates on `created_at_time` for ~24 h (§5.1).
  /// At/after this age an intent without a block_index must escalate, never
  /// replay. (86_400 s in ns; module-level lets must be static — no arithmetic.)
  public let ledgerDedupWindowNs : Int = 86_400_000_000_000;

  /// §5 staleness guard on the CMC conversion rate, mirroring CyclePay's
  /// post-incident 15 min (in ns).
  public let cmcRateMaxAgeNs : Int = 900_000_000_000;

  // ── Pure derivations ─────────────────────────────────────────────────────

  /// The CMC subaccount that credits `canister` on `notify_top_up`:
  /// 32 bytes = length-prefixed principal, zero-padded. Pinned by test vector.
  public func topUpSubaccount(canister : Principal) : Blob {
    let raw = canister.toBlob().toArray();
    let sub = Array.tabulate<Nat8>(
      32,
      func(i) {
        if (i == 0) { Nat8.fromNat(raw.size()) } else if (i <= raw.size()) {
          raw[i - 1];
        } else { 0 };
      },
    );
    Blob.fromArray(sub);
  };

  /// ICP e8s that mint (at least) `cycles` at the CMC rate. 1 ICP =
  /// `xdr_permyriad_per_icp`·10⁻⁴ XDR and 1 XDR = 10¹² cycles, so one e8s
  /// mints exactly `xdr_permyriad_per_icp` cycles — rounding *up* means the
  /// mint covers the locked quantity; the dust overshoot stays in the app
  /// balance (operator side, §3 "operator absorbs drift"). Null on a zero
  /// rate (a broken CMC answer must fail the mint, not trap the sweep).
  public func icpE8sForCycles(cycles : Nat, xdrPermyriadPerIcp : Nat) : ?Nat {
    if (xdrPermyriadPerIcp == 0) return null;
    ?((cycles + xdrPermyriadPerIcp - 1) / xdrPermyriadPerIcp);
  };

  /// §5 staleness guard: the rate iff younger than `maxAgeNs` (age ≥ window =
  /// stale, the Forex/Idempotency convention) and positive. The CMC clock is
  /// authoritative — a timestamp ahead of `nowNs` is fresh, not an error.
  public func freshCmcRate(rate : IcpXdrConversionRate, nowNs : Int, maxAgeNs : Int) : ?Nat {
    let rateNs : Int = rate.timestamp_seconds.toNat() * 1_000_000_000;
    if (nowNs - rateNs >= maxAgeNs) return null;
    let permyriad = rate.xdr_permyriad_per_icp.toNat();
    if (permyriad == 0) return null;
    ?permyriad;
  };

  /// §5.1 step 1 — the deterministic transfer args persisted *before* the
  /// ledger call. Everything the ledger dedups on is fixed here; replaying
  /// this intent can never move money twice.
  public func buildIntent(gateway : Principal, amountE8s : Nat, nowNs : Int) : Types.TransferIntent {
    {
      createdAtTimeNs = Nat64.fromIntWrap(nowNs);
      amountE8s;
      to = {
        owner = Principal.fromText(cmcId);
        subaccount = ?topUpSubaccount(gateway);
      };
      memo = topUpMemo;
    };
  };

  /// The intent's wire form. A pure projection — replay maps the *stored*
  /// intent through this, so the replayed call is bit-identical to the first.
  public func transferArgs(intent : Types.TransferIntent) : TransferArg {
    {
      from_subaccount = null;
      to = intent.to;
      amount = intent.amountE8s;
      fee = ?icpTransferFeeE8s;
      memo = ?intent.memo;
      created_at_time = ?intent.createdAtTimeNs;
    };
  };

  // ── Result interpretation ────────────────────────────────────────────────

  /// What the driver does next; `#retriable` leaves state untouched for the
  /// recovery sweep, `#escalate` is terminal (error queue, §5.1).
  public type TransferOutcome = {
    /// Block index recovered — `#Ok` or `#Duplicate` (the §5.1 replay payoff:
    /// a replayed intent that already executed *returns* its block).
    #blockIndex : Nat;
    #retriable : Text;
    #escalate : Text;
  };

  public func interpretTransfer(result : TransferResult) : TransferOutcome {
    switch (result) {
      case (#Ok(block)) #blockIndex(block);
      case (#Err(#Duplicate({ duplicate_of }))) #blockIndex(duplicate_of);
      // Retriable: the ledger did NOT record a transfer, and the identical
      // intent can succeed later (float refilled, ledger back up, ledger
      // clock caught up to created_at_time).
      case (#Err(#TemporarilyUnavailable)) #retriable("ledger temporarily unavailable");
      case (#Err(#InsufficientFunds({ balance }))) #retriable("insufficient float: balance " # balance.toText() # " e8s");
      case (#Err(#CreatedInFuture(_))) #retriable("created_at_time ahead of ledger clock");
      case (#Err(#GenericError({ error_code; message }))) #retriable("ledger error " # error_code.toText() # ": " # message);
      // Escalations: replaying the identical args can never succeed.
      case (#Err(#TooOld)) #escalate("intent aged past the ledger dedup window");
      case (#Err(#BadFee({ expected_fee }))) #escalate("ledger fee changed: expected " # expected_fee.toText() # " e8s");
      case (#Err(#BadBurn(_))) #escalate("ledger answered BadBurn to a transfer");
    };
  };

  public type NotifyOutcome = {
    /// Cycles credited to the app canister's balance.
    #minted : Nat;
    #retriable : Text;
    #escalate : Text;
  };

  public func interpretNotify(result : NotifyTopUpResult) : NotifyOutcome {
    switch (result) {
      case (#Ok(cycles)) #minted(cycles);
      case (#Err(#Processing)) #retriable("CMC still processing this block");
      case (#Err(#Other({ error_code; error_message }))) #retriable("CMC error " # error_code.toText() # ": " # error_message);
      // Refunded = the CMC sent the ICP back (minus fee) and minted nothing;
      // the order cannot complete automatically. InvalidTransaction /
      // TransactionTooOld = the CMC rejects this block outright.
      case (#Err(#Refunded({ reason; block_index = _ }))) #escalate("CMC refunded: " # reason);
      case (#Err(#InvalidTransaction(reason))) #escalate("CMC rejected block: " # reason);
      case (#Err(#TransactionTooOld(_))) #escalate("CMC: transaction too old");
    };
  };

  // ── Journal (§4.2 `journal : Map<OrderId, JournalEntry>`) ───────────────

  public type Journal = Map.Map<Types.OrderId, Types.JournalEntry>;

  public func emptyJournal() : Journal {
    Map.empty<Types.OrderId, Types.JournalEntry>();
  };

  /// §5.1 step 1: persist the intent. Written in the same synchronous block
  /// as the `#paid → #minting` transition, *before* the transfer await.
  public func openEntry(journal : Journal, order : Types.Order, intent : Types.TransferIntent, nowNs : Int) : Types.JournalEntry {
    let entry : Types.JournalEntry = {
      orderId = order.id;
      status = #minting;
      destination = order.destination;
      transferIntent = ?intent;
      blockIndex = null;
      cyclesMinted = null;
      retries = 0;
      createdAtNs = nowNs;
      updatedAtNs = nowNs;
    };
    journal.add(order.id, entry);
    entry;
  };

  /// Patch the entry; no-op on a missing id (a pipeline bug must degrade to
  /// a stuck order the sweep escalates, never a trap mid-money-flow).
  public func patch(
    journal : Journal,
    orderId : Types.OrderId,
    changes : {
      status : ?Types.OrderStatus;
      blockIndex : ?Nat;
      cyclesMinted : ?Nat;
      bumpRetries : Bool;
    },
    nowNs : Int,
  ) {
    let ?entry = journal.get(orderId) else return;
    journal.add(
      orderId,
      {
        entry with
        status = switch (changes.status) { case (?s) s; case null entry.status };
        blockIndex = switch (changes.blockIndex) { case (?b) ?b; case null entry.blockIndex };
        cyclesMinted = switch (changes.cyclesMinted) { case (?c) ?c; case null entry.cyclesMinted };
        retries = entry.retries + (if (changes.bumpRetries) 1 else 0);
        updatedAtNs = nowNs;
      },
    );
  };

  // ── Resume/replay decision (§5.1, §5.2) ──────────────────────────────────

  /// Why a mint can no longer proceed automatically.
  public type EscalateReason = {
    /// Intent without a block_index aged past the dedup window — the original
    /// transfer's fate is unknowable; auto-replay risks a double-spend (§5.1).
    #staleIntent;
    /// Retry budget exhausted on a retriable error that never cleared.
    #retriesExhausted;
    /// The pre-forward marker is set but the order never reached #delivered —
    /// the forward may or may not have happened; re-forwarding risks double
    /// delivery, so the operator checks the destination instead.
    #ambiguousForward;
    /// Order status implies money-out state the journal doesn't have.
    #missingJournal;
  };

  public func escalateReasonToText(reason : EscalateReason) : Text {
    switch (reason) {
      case (#staleIntent) "staleIntent";
      case (#retriesExhausted) "retriesExhausted";
      case (#ambiguousForward) "ambiguousForward";
      case (#missingJournal) "missingJournal";
    };
  };

  /// The driver's next move for one order, derived from status + journal.
  public type Stage = {
    /// Nothing to do (terminal, pre-payment, or treasury-held).
    #none;
    /// `#paid`, no intent yet: derive the amount, write the intent, transfer.
    #begin;
    /// `#minting` with a fresh intent and no block: (re)issue the identical
    /// transfer — first attempt and recovery replay are the same move (§5.1).
    #replayTransfer : Types.TransferIntent;
    /// Block known, mint unconfirmed: `notify_top_up` (idempotent on
    /// block_index, §5.2), then forward.
    #notifyCmc : Nat;
    #escalate : EscalateReason;
  };

  /// What to escalate when a **time bound** terminates an order, and the exact
  /// instruction to hand the operator.
  ///
  /// ⚠️ **Derived from the journal, not from the status.** The status says where
  /// the order stopped; the *journal* says where the money is, and the money
  /// position is what determines the operator's action. Three consecutive defects
  /// in this codebase came from deciding an escalation off status alone, so the
  /// decision lives here as one pure function with every arm pinned by unit test
  /// — the composition is what kept going wrong, not the pieces.
  ///
  /// The dangerous cell, and the reason this exists: an `#icpAtCmc` order whose
  /// notify already succeeded (`cyclesMinted` journaled) died mid-forward. Read
  /// off the status it looks like "notify never completed", and the instruction
  /// "notify manually, the ICP is parked" is then **factually wrong** — the ICP
  /// was consumed, the cycles exist, and they may already be at the destination.
  /// Following it invites exactly the double delivery `#ambiguousForward` exists
  /// to prevent.
  public func terminationFor(
    status : Types.OrderStatus,
    entry : ?Types.JournalEntry,
  ) : { stage : Text; detail : Text } {
    switch (status) {
      case (#icpAtCmc) {
        let ?e = entry else {
          return {
            stage = escalateReasonToText(#missingJournal);
            detail = "order is #icpAtCmc with no money-out journal — invariant breach, should be unreachable. Reconstruct from audit_log and the ICP ledger before moving any money.";
          };
        };
        // Pre-forward marker set: the mint happened and the forward's fate is
        // unknown. Never re-forward automatically, and never tell anyone the ICP
        // is recoverable — it is already spent.
        if (e.cyclesMinted != null) {
          return {
            stage = escalateReasonToText(#ambiguousForward);
            detail = "cycles WERE minted and the forward outcome is unknown — check the destination balance against mint_journal.cyclesMinted BEFORE anything else. Do not re-forward and do not notify the CMC again: the ICP is already consumed. Arrived -> resolve. Not arrived -> the cycles are in this canister's balance; deliver them manually.";
          };
        };
        // The instruction names a block index, so it has to exist. Status
        // #icpAtCmc means one was recorded; if the journal disagrees, say so
        // rather than emitting an instruction nobody can follow.
        let ?block = e.blockIndex else {
          return {
            stage = escalateReasonToText(#missingJournal);
            detail = "order is #icpAtCmc but the journal has no block index — invariant breach. The ICP left the float, so find the transfer on the ICP ledger before moving any money.";
          };
        };
        {
          stage = escalateReasonToText(#retriesExhausted);
          detail = "ICP reached the CMC (block " # block.toText() # ") but notify_top_up did not succeed — notify manually with that block; notify is idempotent. The ICP is parked at the CMC top-up subaccount, not lost.";
        };
      };
      case (#minting) {
        let ?e = entry else {
          return {
            stage = escalateReasonToText(#missingJournal);
            detail = "order is #minting with no money-out journal — invariant breach, should be unreachable. Reconstruct from audit_log and the ICP ledger before moving any money.";
          };
        };
        switch (e.blockIndex) {
          // Transfer confirmed, only the notify outstanding — same position as
          // #icpAtCmc without cycles, so the same instruction.
          case (?block) {
            {
              stage = escalateReasonToText(#retriesExhausted);
              detail = "the ICP transfer IS confirmed (block " # block.toText() # ") but notify_top_up did not complete — notify manually with that block. The ICP is parked at the CMC, not lost.";
            };
          };
          // No block: whether the transfer executed is unknown. The recovery
          // instruction is only followable if the intent is there to match on.
          case null {
            switch (e.transferIntent) {
              case null {
                {
                  stage = escalateReasonToText(#missingJournal);
                  detail = "order is #minting with neither a block index nor a transfer intent — invariant breach. Nothing can be matched on the ledger; reconstruct from audit_log before moving any money.";
                };
              };
              case (?intent) {
                {
                  stage = escalateReasonToText(#staleIntent);
                  detail = "ICP transfer unconfirmed — establish its fate on the ICP ledger by matching created_at_time " # intent.createdAtTimeNs.toText() # " and amount " # intent.amountE8s.toText() # " e8s. Executed -> the ICP is at the CMC, notify with the found block. Not executed -> fiat in, nothing moved, refund. NEVER rebuild the intent.";
                };
              };
            };
          };
        };
      };
      case (#awaitingTreasury) {
        {
          stage = "treasuryWaitExceeded";
          detail = "held past the max wait: fiat received, nothing minted — refund in the Stripe Dashboard.";
        };
      };
      case (_) {
        {
          stage = "mintWaitExceeded";
          detail = "paid but unminted past the max wait: fiat received, nothing minted — refund in the Stripe Dashboard.";
        };
      };
    };
  };

  /// Decide the next move. Pure — the §5.1/§5.2 resume semantics in one
  /// testable place. `maxRetries` bounds the retriable-error loop on stages
  /// the 24 h window doesn't already bound (notify can otherwise retry
  /// forever).
  public func stageOf(
    status : Types.OrderStatus,
    entry : ?Types.JournalEntry,
    nowNs : Int,
    dedupWindowNs : Int,
    maxRetries : Nat,
  ) : Stage {
    switch (status) {
      case (#paid) #begin;
      case (#minting) {
        let ?e = entry else return #escalate(#missingJournal);
        if (e.retries >= maxRetries) return #escalate(#retriesExhausted);
        switch (e.blockIndex) {
          // Block recorded but the #icpAtCmc transition didn't commit —
          // unreachable today (both happen in one sync block), handled so a
          // future regression degrades to a resumable state.
          case (?block) #notifyCmc(block);
          case null {
            let ?intent = e.transferIntent else return #escalate(#missingJournal);
            if (nowNs - intent.createdAtTimeNs.toNat() >= dedupWindowNs) {
              #escalate(#staleIntent);
            } else {
              #replayTransfer(intent);
            };
          };
        };
      };
      case (#icpAtCmc) {
        let ?e = entry else return #escalate(#missingJournal);
        // cyclesMinted is the pre-forward marker: set *before* the forward
        // await, so its presence here (status never reached #delivered)
        // means the forward's fate is unknown. At-most-once delivery —
        // never auto-re-forward.
        if (e.cyclesMinted != null) return #escalate(#ambiguousForward);
        if (e.retries >= maxRetries) return #escalate(#retriesExhausted);
        let ?block = e.blockIndex else return #escalate(#missingJournal);
        #notifyCmc(block);
      };
      case (#created or #expired or #awaitingTreasury or #delivered or #errorQueue) #none;
    };
  };

};
