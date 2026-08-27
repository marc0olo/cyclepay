/// Delivering cycles from the reserve: the pure half.
///
/// Everything money-out needs and nothing it does not — the cycles-ledger interface,
/// the crash-safe journal, the intent that makes a replay byte-identical, the resume
/// decision, and the timeline that bounds how long a buyer waits.
///
/// ⚠️ **`CyclesLedgerService` is the reserve floor's enforcement mechanism.**
/// `Reserve.mo`'s floor is a lower bound only because the balance cannot fall except
/// when this canister transfers out, and what makes that true is the declaration
/// below: `icrc2_approve` and the ledger's `withdraw` are absent, so they cannot be
/// called. `scripts/test-all.sh` fails the gate on a declaration that widens it.
///
/// ⚠️ **One logical outflow.** `icrc1_transfer` is called twice — the attempt and its
/// `#BadFee` re-issue of the same intent — and at most one debits: the re-issue runs
/// only after the ledger definitively refused, and a landed earlier attempt is
/// deduplicated. `Reserve.mo`'s rules 2 and 3 net to one decrement per execution, so
/// reading "two call sites" as "two outflows" would double-count every delivery.
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Text "mo:core/Text";
import Types "Types";

module {

  // ── Well-known principals (identical on PocketIC's NNS subnet, §9) ──────

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









  /// ⚠️ **THIS TYPE IS THE RESERVE FLOOR'S ENFORCEMENT MECHANISM.** `Reserve.mo`'s
  /// floor is sound only because the reserve balance cannot fall except when we
  /// transfer out — and the reason it cannot is right here: **the account's owner
  /// could call `icrc2_approve` or `withdraw` on the cycles ledger, and neither is
  /// declared, so neither can be called.** Not "we do not plan to add them"; the
  /// compiler will not let this canister reach them.
  ///
  /// So breaking the floor's premise takes a visible act in this file — adding a
  /// method to this type — and `scripts/test-all.sh` fails the gate on exactly that.
  /// Adding one here without reading `Reserve.mo`'s floor section turns a bound into
  /// a guess, silently and in the optimistic direction.
  public type CyclesLedgerService = actor {
    /// **The one outflow.** Delivery pays the buyer from the canister's own
    /// cycles-ledger account. Two syntactic call sites — the attempt and its
    /// `#BadFee` re-issue — are ONE logical transfer of one intent, and at most one
    /// of them debits: the re-issue only runs after a definitively-rejected attempt,
    /// and a duplicate is deduplicated by the ledger. That is precisely why rules 2
    /// and 3 net to one floor decrement per real execution.
    icrc1_transfer : shared TransferArg -> async TransferResult;
    /// The reserve's authoritative balance, read by the hourly reconcile and by
    /// `refresh_reserve` — **never by the gate.** ⚠️ An earlier version of this
    /// comment said `create_order` called it as the gate's read; #30 PR-B removed
    /// that read entirely, because an awaited value is historical by the time it is
    /// used. The gate decides against the maintained floor, synchronously.
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




  /// **Seed** for the stored cycles-ledger transfer fee (#30 PR-B). The live value
  /// lives in `Main.cyclesLedgerFee`, because the ledger owns it and can move it.
  ///
  /// It is a seed and not a constant: `#BadFee` carries the ledger's expected fee,
  /// so the first delivery after any change corrects the stored copy and every
  /// later one uses the corrected value. That self-correction is why delivery no
  /// longer awaits `icrc1_fee` — see the stored variable's doc for the trade.
  ///
  /// ⚠️ **Not disclosed through `quote_previews`.** The fee applies to the transfer
  /// the gateway makes, so it is the operator's cost, not a line in the buyer's
  /// quote; the frontend reads the ledger for what a buyer's own transfer would
  /// cost. Do not add it to the preview — `docs/STRIPE.md` explains why absorbing
  /// it rather than grossing it up is the safe direction.
  public let cyclesLedgerDefaultFee : Nat = 100_000_000;


  /// The cycles ledger deduplicates on `created_at_time` for ~24 h (§5.1).
  /// At/after this age an intent without a block_index must escalate, never
  /// replay. (86_400 s in ns; module-level lets must be static — no arithmetic.)
  public let ledgerDedupWindowNs : Int = 86_400_000_000_000;


  // ── Pure derivations ─────────────────────────────────────────────────────





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
  /// `amountCycles` carries **cycles** here, not e8s. The name is wrong and is
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
      amountCycles = cycles;
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
  /// original fee arithmetically — `lockedCycles - intent.amountCycles`, because
  /// `deliverableCycles` produced the amount by subtracting it — so a replay is
  /// byte-identical whatever the ledger keys on. A corrected fee is only ever sent
  /// after a **definitive** `#BadFee` rejection, where the ledger has told us it
  /// did not execute.
  public func deliveryArgs(intent : Types.TransferIntent, fee : Nat) : TransferArg {
    {
      from_subaccount = null;
      to = intent.to;
      amount = intent.amountCycles;
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
    /// Its own case, and neither retriable nor an escalation: delivery re-sends
    /// with the reported fee and **persists it**, so a risen fee is absorbed by the
    /// reserve rather than shorting the buyer.
    ///
    /// ⚠️ **This case IS the fee-refresh mechanism**, which is what lets delivery
    /// never await `icrc1_fee`: a stale stored copy costs one rejected call, once,
    /// and never a wrong debit. `#BadFee` is definitive — the ledger tells us the
    /// number it wants — so the correction cannot loop.
    #badFee : Nat;
    #escalate : Text;
  };

  public func interpretTransfer(result : TransferResult) : TransferOutcome {
    switch (result) {
      case (#Ok(block)) #delivered(block);
      case (#Err(#Duplicate({ duplicate_of }))) #deduplicated(duplicate_of);
      // Retriable: the ledger did NOT record a transfer, and the identical
      // intent can succeed later (reserve refunded, ledger back up, ledger
      // clock caught up to created_at_time).
      case (#Err(#TemporarilyUnavailable)) #retriable("ledger temporarily unavailable");
      case (#Err(#InsufficientFunds({ balance }))) #retriable("reserve short: balance " # balance.toText() # " cycles");
      case (#Err(#CreatedInFuture(_))) #retriable("created_at_time ahead of ledger clock");
      case (#Err(#GenericError({ error_code; message }))) #retriable("ledger error " # error_code.toText() # ": " # message);
      // Escalations: replaying the identical args can never succeed.
      case (#Err(#TooOld)) #escalate("intent aged past the ledger dedup window");
      case (#Err(#BadFee({ expected_fee }))) #badFee(expected_fee);
      case (#Err(#BadBurn(_))) #escalate("ledger answered BadBurn to a transfer");
    };
  };



  // ── Journal (§4.2 `journal : Map<OrderId, JournalEntry>`) ───────────────

  public type Journal = Map.Map<Types.OrderId, Types.JournalEntry>;

  public func emptyJournal() : Journal {
    Map.empty<Types.OrderId, Types.JournalEntry>();
  };

  /// §5.1 step 1: persist the intent. Written in the same synchronous block as the
  /// status transition, *before* the transfer await — so a trap between the two is
  /// impossible and there is no window where money moved with no record of it.
  public func openEntry(journal : Journal, order : Types.Order, intent : Types.TransferIntent, nowNs : Int) : Types.JournalEntry {
    let entry : Types.JournalEntry = {
      orderId = order.id;
      // ⚠️ **The ORDER's status, never a literal.** `unsettledDeliveries` — the
      // predicate deciding whether a reserve observation may be adopted — reads this
      // field back and tests it for `#paid`. A literal here that disagrees with the
      // order makes that predicate match nothing, the quiet window is then always
      // satisfied, and a reconcile can overwrite the reserve floor while a transfer
      // it cannot see is in flight. A hardcoded status is not a tidiness question here; it
      // is a silent solvency bug three files away.
      status = order.status;
      destination = order.destination;
      transferIntent = ?intent;
      blockIndex = null;
      cyclesDelivered = null;
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
      cyclesDelivered : ?Nat;
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
        cyclesDelivered = switch (changes.cyclesDelivered) { case (?c) ?c; case null entry.cyclesDelivered };
        retries = entry.retries + (if (changes.bumpRetries) 1 else 0);
        updatedAtNs = nowNs;
      },
    );
  };

  // ── Resume/replay decision (§5.1, §5.2) ──────────────────────────────────

  /// Why the resume decision stopped, when it cannot continue on its own.
  public type EscalateReason = {
    /// The intent is past the ledger's ~24 h dedup window with no recorded block, so
    /// a replay is no longer protected and its fate is **unknown**. The only case
    /// where retrying is the unsafe option.
    #staleIntent;
    /// The transfer landed and the order never moved — the buyer HAS their cycles.
    /// Should be unreachable: the block and the transition commit in one synchronous
    /// block. Handled so a future regression degrades to something an operator can
    /// resolve rather than to a paid order whose buyer already holds the cycles.
    #landedNotRecorded;
    /// The order's status implies a money-out position the journal cannot support.
    #missingJournal;
  };

  public func escalateReasonToText(reason : EscalateReason) : Text {
    switch (reason) {
      case (#staleIntent) "staleIntent";
      case (#landedNotRecorded) "landedNotRecorded";
      case (#missingJournal) "missingJournal";
    };
  };

  /// The driver's next move for one order, derived from status + journal.
  public type Stage = {
    /// Nothing to do — the order is terminal or not yet paid.
    #none;
    #beginDelivery;
    /// A fresh delivery intent and no block: (re)issue the identical cycles
    /// transfer, reading the STORED args and **never rebuilding them** — a rebuilt
    /// `created_at_time` defeats the ledger's dedup and pays the buyer twice.
    #replayDelivery : Types.TransferIntent;
    /// The transfer landed and the `#delivered` transition did not. Carries the
    /// block so the journal and the receipt still name it.
    #finishDelivery : Nat;
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
  /// The dangerous cell, and the reason this exists: a `#paid` order whose transfer
  /// already landed (`blockIndex` journaled) and whose `#delivered` transition never
  /// ran. Read off the status alone it looks like "never delivered", and the
  /// instruction that follows — deliver it — is **factually wrong**: the buyer
  /// already has their cycles. Following it pays twice. That cell is why
  /// `#landedNotRecorded` is its own reason with its own instruction (record, do not
  /// send), and why the journal outranks the status here.
  public func terminationFor(
    status : Types.OrderStatus,
    entry : ?Types.JournalEntry,
  ) : { stage : Text; detail : Text } {
    switch (status) {
      // `#paid`'s money position depends on the JOURNAL, not the status: an order
      // with an unconfirmed transfer is not in the same position as one that never
      // started, and the operator's action differs completely.
      case (#paid) {
        switch (entry) {
          case (?e) {
            switch (e.blockIndex, e.transferIntent) {
              case (?block, _) {
                {
                  stage = escalateReasonToText(#landedNotRecorded);
                  detail = "cycles WERE delivered (ledger block " # block.toText() # ") but the order never moved to delivered — the buyer HAS their cycles. Confirm the block on the cycles ledger, then resolve; do NOT re-send.";
                };
              };
              case (null, ?intent) {
                {
                  stage = escalateReasonToText(#staleIntent);
                  detail = "cycles transfer unconfirmed — establish its fate on the cycles ledger by matching memo " # intent.memo.size().toText() # "-byte order id, created_at_time " # intent.createdAtTimeNs.toText() # " and amount " # intent.amountCycles.toText() # " cycles. Executed -> the buyer has them; mark it resolved. Not executed -> fiat in, nothing delivered; re-deliver by hand or refund. NEVER rebuild the intent: past the dedup window a rebuilt one pays twice.";
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
      // ⚠️ Only `#paid` reaches this function — it is called from the 72 h bound and
      // from the escalate route, both of which run on the one in-flight status. Every
      // other status is either pre-payment or terminal, so there is no money-out
      // position to report and saying so beats inventing one.
      case (_) {
        {
          stage = "notInFlight";
          detail = "this order has no delivery in flight, so it has no money-out position — if an escalation names this stage, the drive loop reached it from a status it should not have.";
        };
      };
    };
  };

  /// Decide the next move. Pure — the §5.1/§5.2 resume semantics in one testable
  /// place.
  ///
  /// ⚠️ **No retry-budget parameter, and do not add one.** Retrying is bounded by
  /// *time* on both ends: the ~24 h dedup window escalates a stale intent, and §5.3's
  /// 72 h max-wait gets a human involved. A count-based budget adds nothing between
  /// those two, and it fails in the wrong direction — exhausting it escalates an
  /// order that a further replay would have completed.
  public func stageOf(
    status : Types.OrderStatus,
    entry : ?Types.JournalEntry,
    nowNs : Int,
    dedupWindowNs : Int,
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
      // second bounces off `processDelivery`'s in-flight set, which is checked and
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
                // ⚠️ **No retry cap here, deliberately.** A replay is *provably* safe
                // — byte-identical args, the ledger deduplicates, `#Duplicate` recovers
                // the block — so a cap would convert a recoverable state into a manual
                // one for no safety gain.
                //
                // Retrying is bounded twice over, by time rather than by a count: the
                // ~24 h dedup window escalates the intent on the very next line, and
                // §5.3's 72 h max-wait gets a human involved for the buyer's sake long
                // before that.
                //
                // Past the dedup window a replay is no longer protected, so a blind
                // retry could pay twice. **This is the one ambiguous case in money-out**
                // and the only thing that escalates on this path.
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
      case (#created or #cancelled or #expired or #delivered or #needsReview or #abandoned) #none;
    };
  };



  /// The two thresholds. This is the Candid type `set_delivery_config` takes.
  public type Config = {
    /// How long an order may sit with money in and nothing delivered before it is
    /// **terminated** and the operator refunds.
    ///
    /// Terminating matters, and not for tidiness: a buyer left waiting indefinitely
    /// files a chargeback, which is strictly worse for the operator than a refund —
    /// dispute fees, a dispute process, and damage to Stripe account health.
    /// Refunding proactively is the *protective* action. By the time this elapses
    /// the cause is not transient either.
    maxHoldNs : Int;
    /// When to raise the alert, which is **not** when to give up. Complementary to
    /// `maxHoldNs`: the alert fires while the cause is still fixable, so the
    /// operator gets a chance to fix it and the sale completes.
    alertAfterNs : Int;
  };

  public func defaultConfig() : Config {
    {
      maxHoldNs = 259_200_000_000_000; // 72 h — terminate, operator refunds
      alertAfterNs = 7_200_000_000_000; // 2 h — tell someone while it is fixable
    };
  };

  public type ConfigError = {
    /// A zero/negative max hold would escalate every order instantly.
    #nonPositiveMaxHold;
    #nonPositiveAlertAfter;
    /// An alert at or after the terminal bound would never be actionable: the
    /// operator would be told at the moment the decision was already taken.
    #alertNotBeforeMaxHold : { alertAfterNs : Int; maxHoldNs : Int };
  };

  public func validateConfig(config : Config) : Result.Result<(), ConfigError> {
    if (config.maxHoldNs <= 0) return #err(#nonPositiveMaxHold);
    if (config.alertAfterNs <= 0) return #err(#nonPositiveAlertAfter);
    if (config.alertAfterNs >= config.maxHoldNs) {
      return #err(#alertNotBeforeMaxHold({ alertAfterNs = config.alertAfterNs; maxHoldNs = config.maxHoldNs }));
    };
    #ok;
  };

  /// The timeline for an order with money in and nothing delivered.
  ///
  /// Three outcomes, not two: quiet retry while it is probably transient, then an
  /// alert while it is still fixable, then termination once it plainly is not.
  /// Splitting these is what lets the alert be early *without* making the give-up
  /// early too.
  ///
  /// ⚠️ **A per-state bound, not end-to-end.** The age it reads is
  /// `order.updatedAtNs`, which retries deliberately do not move — a retry is not a
  /// transition, so the clock stays pinned to the moment the order entered its
  /// current state.
  public func waitStage(
    heldSinceNs : Int,
    nowNs : Int,
    config : Config,
  ) : { #retry; #alert; #terminate } {
    let waited = nowNs - heldSinceNs;
    if (waited >= config.maxHoldNs) return #terminate;
    if (waited >= config.alertAfterNs) return #alert;
    #retry;
  };

};
