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
    /// Delivery since #30: the reserve pays the buyer from the canister's OWN
    /// cycles-ledger account, rather than the canister minting per order and
    /// depositing from its gas balance.
    icrc1_transfer : shared TransferArg -> async TransferResult;
    /// The live transfer fee, read at delivery time. Not a constant here: the
    /// buyer's delivered amount is `lockedCycles - fee`, so a stale copy would
    /// either short the buyer or make every transfer answer `#BadFee`.
    icrc1_fee : shared query () -> async Nat;
    /// The reserve's authoritative balance. ⚠️ #30 PR-B calls this inside
    /// `create_order` as the gate's read; nothing else should treat it as a
    /// cached value.
    icrc1_balance_of : shared query Types.Account -> async Nat;
  };

  /// The canister's own cycles-ledger account — the reserve.
  ///
  /// Default subaccount, matching #29's rule for a buyer's destination: one
  /// canonical form, so "the reserve" names exactly one account in the ledger,
  /// in `reserve_status`, and in whatever an operator types at a terminal.
  public func reserveAccount(gateway : Principal) : Types.Account {
    { owner = gateway; subaccount = null };
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

  /// Cycles the cycles ledger deducts from a `deposit`. The buyer therefore
  /// receives this much less than the order's locked quantity, on every order —
  /// there is one destination and it goes through the ledger (#29).
  ///
  /// Deliberately **not** grossed up into the quote: minting extra cycles to
  /// cover a per-order fee would let anyone drain the operator by opening
  /// orders, so the fee is disclosed to the buyer rather than absorbed. Exposed
  /// through `quote_previews` for exactly that purpose.
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

  /// §5.1 for the reserve (#30 PR-A) — the delivery transfer's frozen args.
  ///
  /// ⚠️ **`memo` is the order id, and that is a correctness requirement, not a
  /// convenience.** The ledger dedups on `(created_at_time, from, to, amount,
  /// memo)` — *not* on the order. Two `#paid` orders from one buyer for the same
  /// amount are reachable (the open-order cap counts only `#created`, so
  /// pay → create → pay produces exactly that), and if both intents are built in
  /// the same round they share `Time.now()`, destination and amount. Identical
  /// args means the second transfer is **falsely deduplicated**: order B is
  /// marked delivered against order A's block and the buyer is shorted a whole
  /// purchase. The order id makes every intent unique whatever the timing, and
  /// it makes ledger blocks self-attributing for free.
  ///
  /// `amountE8s` carries **cycles** here, not e8s. The name is wrong and is
  /// deliberately left for #30 PR-C, which renames this family in one pass
  /// rather than half-renaming it under a money change.
  public func buildDeliveryIntent(
    orderId : Types.OrderId,
    to : Types.Account,
    cycles : Nat,
    nowNs : Int,
  ) : Types.TransferIntent {
    {
      createdAtTimeNs = Nat64.fromIntWrap(nowNs);
      amountE8s = cycles;
      to;
      memo = orderId.encodeUtf8();
    };
  };

  /// The delivery intent's wire form. The fee is passed **explicitly** so that a
  /// change shows up as `#BadFee` and can be audited, rather than being absorbed
  /// silently by passing `null`.
  ///
  /// ⚠️ **The caller must pass the fee the intent was BUILT with, not a fresh
  /// read.** This comment used to claim the fee sits outside the ledger's dedup
  /// key, so a replay carrying a corrected fee was still byte-identical "as far as
  /// the ledger is concerned". That was an unverified assertion about another
  /// canister's internals, and the at-most-once guarantee rested on it: if the fee
  /// IS in the key, a transfer that executed, lost its response and is replayed
  /// after a fee change is a DISTINCT transaction, and the buyer is paid twice.
  ///
  /// The claim is gone rather than checked. `Main.driveDelivery` recovers the
  /// original fee arithmetically — `lockedCycles - intent.amountE8s`, because
  /// `deliverableCycles` produced the amount by subtracting it — so a replay is
  /// byte-identical whatever the ledger keys on. A corrected fee is only ever sent
  /// after a **definitive** `#BadFee` rejection, where the ledger has told us it
  /// did not execute.
  public func deliveryArgs(intent : Types.TransferIntent, fee : Nat) : TransferArg {
    {
      from_subaccount = null;
      to = intent.to;
      amount = intent.amountE8s;
      fee = ?fee;
      memo = ?intent.memo;
      created_at_time = ?intent.createdAtTimeNs;
    };
  };

  /// What the buyer receives: the locked quantity less the ledger's transfer fee.
  ///
  /// Probe-measured (#30): the ledger debits `amount + fee`, so sending
  /// `lockedCycles - fee` moves the reserve by **exactly `lockedCycles`**. That
  /// is why #30's promise tally is `Σ lockedCycles` with no separate fee term —
  /// an earlier draft wrote `Σ (lockedCycles + fee)` and double-counted.
  ///
  /// Null when the fee swallows the whole order, which the purchase floor makes
  /// unreachable ($10 buys ~7 T cycles against a 100 M fee) but which must not
  /// be an underflow trap on the money path if either number ever moves.
  public func deliverableCycles(lockedCycles : Nat, fee : Nat) : ?Nat {
    if (fee >= lockedCycles) return null;
    ?(lockedCycles - fee);
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
    /// This call moved the money: the ledger accepted it and recorded a block.
    #delivered : Nat;
    /// An EARLIER call moved the money; this one was deduplicated and handed back
    /// the original block. Still success — the §5.1 replay payoff.
    ///
    /// ⚠️ **Distinct from `#delivered`, and #30 PR-B is why.** These were one case
    /// (`#blockIndex`) until the reserve floor needed to know whether *this* call
    /// debited the ledger: the floor is decremented when a transfer is issued, so a
    /// deduplicated call must credit its decrement back (an earlier attempt's
    /// decrement is the real one and is still standing), while a fresh block must
    /// keep it. Collapsing them refunds real debits — optimistic — or under-counts
    /// every healed replay by a whole order. Every other consumer treats them
    /// identically, and says so.
    #deduplicated : Nat;
    #retriable : Text;
    /// The ledger's fee is not what we passed; it reports the expected one.
    ///
    /// Its own case because the two callers answer it differently and both are
    /// right: the ICP mint path escalates (a protocol-wide ICP fee change is not
    /// something to paper over), while reserve delivery (#30) re-reads
    /// `icrc1_fee` and retries, so a risen fee is absorbed by the reserve rather
    /// than shorting the buyer. Returning one verdict here would force one of
    /// them to be wrong.
    #badFee : Nat;
    #escalate : Text;
  };

  public func interpretTransfer(result : TransferResult) : TransferOutcome {
    switch (result) {
      case (#Ok(block)) #delivered(block);
      case (#Err(#Duplicate({ duplicate_of }))) #deduplicated(duplicate_of);
      // Retriable: the ledger did NOT record a transfer, and the identical
      // intent can succeed later (float refilled, ledger back up, ledger
      // clock caught up to created_at_time).
      case (#Err(#TemporarilyUnavailable)) #retriable("ledger temporarily unavailable");
      case (#Err(#InsufficientFunds({ balance }))) #retriable("insufficient float: balance " # balance.toText() # " e8s");
      case (#Err(#CreatedInFuture(_))) #retriable("created_at_time ahead of ledger clock");
      case (#Err(#GenericError({ error_code; message }))) #retriable("ledger error " # error_code.toText() # ": " # message);
      // Escalations: replaying the identical args can never succeed.
      case (#Err(#TooOld)) #escalate("intent aged past the ledger dedup window");
      case (#Err(#BadFee({ expected_fee }))) #badFee(expected_fee);
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
    /// `#paid`, no intent yet (LEGACY mint path): derive the amount, write the
    /// intent, transfer ICP. Reached only from the treasury-hold retry now that
    /// #30 PR-A routes `#paid` to `#beginDelivery`; #36 deletes it.
    #begin;
    /// #30 PR-A — no delivery intent yet: read `icrc1_fee`, write the intent,
    /// transfer cycles from the reserve.
    ///
    /// ⚠️ The delivery stages are deliberately **separate constructors** from the
    /// mint ones rather than a shared stage that branches on status. They address
    /// **different ledgers**, and a stage that could mean either would put the
    /// choice of ledger in the caller's hands on a money path — replaying an ICP
    /// intent against the cycles ledger is exactly the class of bug worth making
    /// unrepresentable. It also lets #36 delete the mint stages by name.
    #beginDelivery;
    /// LEGACY: a fresh ICP intent and no block — (re)issue the identical
    /// transfer. First attempt and recovery replay are the same move (§5.1).
    #replayTransfer : Types.TransferIntent;
    /// #30 PR-A — a fresh delivery intent and no block: (re)issue the identical
    /// cycles transfer, reading the STORED args and never rebuilding them.
    #replayDelivery : Types.TransferIntent;
    /// The transfer landed and the `#delivered` transition did not (#30 PR-A).
    /// Carries the block so the journal and the receipt still name it.
    #finishDelivery : Nat;
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
      // #30 PR-A: `#paid` is where delivery now happens, so its money position
      // depends on the journal — a paid order with an unconfirmed transfer is
      // NOT the same position as one that never started.
      case (#paid) {
        switch (entry) {
          case (?e) {
            switch (e.blockIndex, e.transferIntent) {
              case (?block, _) {
                {
                  stage = escalateReasonToText(#retriesExhausted);
                  detail = "cycles WERE delivered (ledger block " # block.toText() # ") but the order never moved to delivered — the buyer HAS their cycles. Confirm the block on the cycles ledger, then resolve; do NOT re-send.";
                };
              };
              case (null, ?intent) {
                {
                  stage = escalateReasonToText(#staleIntent);
                  detail = "cycles transfer unconfirmed — establish its fate on the cycles ledger by matching memo " # intent.memo.size().toText() # "-byte order id, created_at_time " # intent.createdAtTimeNs.toText() # " and amount " # intent.amountE8s.toText() # " cycles. Executed -> the buyer has them; mark it resolved. Not executed -> fiat in, nothing delivered; re-deliver by hand or refund. NEVER rebuild the intent: past the dedup window a rebuilt one pays twice.";
                };
              };
              case (null, null) {
                {
                  stage = "deliveryWaitExceeded";
                  detail = "paid but nothing was ever sent past the max wait: fiat received, no transfer attempted — refund in the Stripe Dashboard.";
                };
              };
            };
          };
          case null {
            {
              stage = "deliveryWaitExceeded";
              detail = "paid but nothing was ever sent past the max wait: fiat received, no transfer attempted — refund in the Stripe Dashboard.";
            };
          };
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
      // #30 PR-A: delivery is ONE transfer from #paid, so the retry state lives
      // in the journal rather than in a status of its own. Three cases, and the
      // middle one is the whole point of persisting an intent before the call:
      //
      //   no entry / no intent  → #begin: read the fee, build the intent, send
      //   intent, no block      → #replayTransfer: re-send the STORED args
      //   intent + block        → #finishDelivery: the transfer landed, the
      //                           transition did not (unreachable today — both
      //                           commit in one sync block — handled so a future
      //                           regression degrades to something resumable)
      //
      // ⚠️ Never rebuild the intent on a retry: a rebuilt one carries a fresh
      // `created_at_time`, the ledger does not dedup it, and the buyer is paid
      // twice.
      //
      // ⚠️ **Correction, because the difference matters if anyone touches the
      // mutex.** Two drivers (the webhook's detached kick and the recovery sweep)
      // do *arrive* at one order concurrently, but they do not both run: the
      // second bounces off `processMint`'s in-flight set, which is checked and
      // added in one synchronous block and released in a `finally`, and every
      // path into delivery goes through it. **That mutex is the first line of
      // defence; replay-dedup is the second.** They are not interchangeable —
      // `openEntry` overwrites, so two drivers past the post-await re-check would
      // build intents with different `created_at_time`, the second overwriting the
      // first while the first still holds its copy: two non-duplicate transfers.
      // Do not remove the mutex on the theory that dedup alone covers it.
      case (#paid) {
        let ?e = entry else return #beginDelivery;
        switch (e.blockIndex) {
          case (?block) #finishDelivery(block);
          case null {
            switch (e.transferIntent) {
              case null #beginDelivery;
              case (?intent) {
                if (e.retries >= maxRetries) return #escalate(#retriesExhausted);
                // Past the dedup window a replay is no longer protected, so a
                // blind retry could pay twice. This is #30's ONE ambiguous case
                // and the only thing that escalates on the delivery path.
                if (nowNs - intent.createdAtTimeNs.toNat() >= dedupWindowNs) {
                  #escalate(#staleIntent);
                } else {
                  #replayDelivery(intent);
                };
              };
            };
          };
        };
      };
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
      case (#created or #cancelled or #expired or #awaitingTreasury or #delivered or #needsReview or #abandoned) #none;
    };
  };

};
