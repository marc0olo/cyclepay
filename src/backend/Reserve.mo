/// Solvency of the cycles reserve.
///
///     available = icrc1_balance_of(reserveAccount) − promisedTotal
///
/// The ledger owns the balance and anyone can read it, so this canister never caches
/// it. What only this canister knows is how much of that balance is already spoken for.
/// Selling the same cycles twice is the failure this module prevents.
///
/// Why the gate can decide against a maintained floor with no ledger call, and the three
/// rules that keep the floor a lower bound: `docs/DESIGN.md` §5.4.
///
/// `promised` has no fee term: the ledger charges its fee on top of the amount, so
/// delivering `lockedCycles − fee` moves the balance by exactly `lockedCycles`. Summing
/// `lockedCycles + fee` double-counts, under-reports `available`, and refuses sales that
/// would have worked.
///
/// ⚠️ **`lockedCycles` must stay immutable after creation.** The amount an order promises
/// IS its locked quantity, so no second per-order copy is stored. Anything that mutates
/// it breaks this tally **silently**, and the design then needs a stored per-order amount.
import Result "mo:core/Result";
import Delivery "Delivery";
import Types "Types";

module {

  /// Is this order's promise still held?
  ///
  /// ⚠️ **Phrased as "not terminal", never as a list of the statuses that hold.** The two
  /// phrasings fail in opposite directions when a status is added: an enumerated hold-list
  /// omits the newcomer and **releases its promise while the order is still live**, which
  /// oversells the reserve. This phrasing counts the newcomer, which at worst holds cycles
  /// longer than needed and shows up in `availableToSell`.
  public func holdsPromise(status : Types.OrderStatus) : Bool {
    switch (status) {
      case (#delivered or #expired or #cancelled or #abandoned) false;
      case (_) true;
    };
  };

  /// How the tally moves for one status transition. A sign rather than an amount, so the
  /// caller multiplies by the order's own `lockedCycles` and one place knows the
  /// arithmetic.
  ///
  /// ⚠️ **`#created → #paid` is ZERO: release is at DELIVERY, not at payment.** Releasing
  /// when the money arrives lets a second order be admitted against capacity the first
  /// still needs, and both then have to be paid out of a reserve that only ever covered
  /// one.
  public func tallyDelta(from : Types.OrderStatus, to : Types.OrderStatus) : { #add; #release; #none } {
    switch (holdsPromise(from), holdsPromise(to)) {
      case (false, true) #add;
      case (true, false) #release;
      case (_, _) #none;
    };
  };

  /// Apply a delta to a total, reporting whether it had to saturate.
  ///
  /// Saturates rather than traps: an underflow means the tally had already diverged, and
  /// trapping on the money path over a bookkeeping error is worse than reporting zero.
  ///
  /// ⚠️ **`saturated` must be surfaced, not dropped.** A silent saturation is
  /// indistinguishable from an exact release, so the first evidence would wait for the
  /// daily reconcile — up to a day of a wrong tally gating real sales.
  public func applyDelta(
    total : Nat,
    delta : { #add; #release; #none },
    lockedCycles : Nat,
  ) : { total : Nat; saturated : Bool } {
    switch (delta) {
      case (#add) ({ total = total + lockedCycles; saturated = false });
      case (#release) {
        if (lockedCycles > total) {
          ({ total = 0; saturated = true });
        } else {
          ({ total = total - lockedCycles : Nat; saturated = false });
        };
      };
      case (#none) ({ total; saturated = false });
    };
  };

  /// Why a withdrawal cannot proceed, or the amount it may move.
  ///
  /// ⚠️ **A structural subtype of `withdraw_reserve`'s error type**, minus `#transferFailed`
  /// — which is not a decision, it is what the ledger said afterwards. So `#err(e)` returns
  /// straight out of the endpoint with no mapping layer (T4).
  public type WithdrawRefusal = {
    #ordersOutstanding : { holders : Nat; promised : Nat };
    #nothingToWithdraw;
    #belowLedgerFee : { floor : Nat; fee : Nat };
  };

  /// The whole refusal ladder for `withdraw_reserve` (§5.4, #103), as one decision.
  ///
  /// ⚠️ **The endpoint calls this TWICE — once before observing the ledger, once after —
  /// and that repetition is the point.** An `await` sits inside the observe while the
  /// floor is still full, so the holder count has to be re-tested afterwards: a create
  /// queued in that window would otherwise be admitted against a reserve about to leave.
  /// The re-check used to be a second inline `if`, which is a place for the two tests to
  /// drift apart. One function called twice cannot drift.
  ///
  /// ⚠️ **`holders` must be the INDEX, never the tally.** `applyDelta` clamps a release
  /// to zero when the tally has diverged low, so `promised` can read 0 while promise
  /// holders still exist — the state `tallySaturations` surfaces. A ladder guarded on the
  /// tally would permit a withdrawal with live orders outstanding, which is the one thing
  /// it exists to prevent. `promised` is carried in the refusal for diagnosis only, and
  /// the two figures disagreeing is itself the signal.
  ///
  /// Order matters and is asserted in `test/reserve.test.mo`: outstanding orders outrank
  /// an empty floor, because "nothing to withdraw" invites a retry while orders
  /// outstanding is a state the operator has to clear.
  /// The holders gate on its own, because the endpoint needs it BEFORE the floor arms.
  ///
  /// ⚠️ **The floor cannot be judged until the ledger has been observed.** An unobserved
  /// top-up leaves the floor reading 0, so a `#nothingToWithdraw` decided before the
  /// observe would strand it — which is the whole reason `withdraw_reserve` observes
  /// first. An earlier version of this extraction ran the full ladder in both passes and
  /// moved that refusal ahead of the observe; this split is what keeps the original
  /// ordering. `withdrawable` calls it too, so the test itself exists once.
  public func ordersOutstanding(holders : Nat, promised : Nat) : ?WithdrawRefusal {
    if (holders > 0) ?#ordersOutstanding({ holders; promised }) else null;
  };

  public func withdrawable(
    holders : Nat,
    promised : Nat,
    floor : Nat,
    fee : Nat,
  ) : Result.Result<{ debited : Nat; amount : Nat }, WithdrawRefusal> {
    switch (ordersOutstanding(holders, promised)) {
      case (?refusal) return #err(refusal);
      case null {};
    };
    if (floor == 0) return #err(#nothingToWithdraw);
    // Draining means transferring `floor - fee`: the ledger charges the fee on top, so
    // below the fee there is nothing recoverable at all.
    // ⚠️ **`Delivery.deliverableCycles`, not a copy of it.** These are the TWO outflow
    // classes of one account, and Reserve.mo's own framing is "two destination classes,
    // ONE outflow mechanism" — a fee correction that diverged between delivery and
    // withdrawal is exactly what that framing exists to prevent. An earlier version of
    // this function re-implemented the arithmetic here while its comment claimed it was
    // "the same function", which replaced a shared call site with a second place to
    // change. `Delivery` does not import `Reserve`, so this direction is acyclic.
    let ?amount = Delivery.deliverableCycles(floor, fee) else {
      return #err(#belowLedgerFee({ floor; fee }));
    };
    #ok({ debited = floor; amount });
  };

  /// The promise total derived independently from the orders themselves.
  ///
  /// The TEST ORACLE only — no production path may call it, since it is O(every order ever
  /// created). `Orders.reconcileBounded` derives the same total from the non-terminal
  /// index; what makes this worth keeping is that no index sits in its chain. It shares
  /// `holdsPromise` with the tally on purpose and must keep sharing it: that predicate *is*
  /// the definition of a promise, and a second one here would make the check fire on
  /// disagreements about the definition rather than on the bookkeeping bug.
  ///
  /// ⚠️ **Never derive it from a stored per-order promise.** A leaked promise would sit in
  /// both sums, so the check could never fail — a detector that cannot fail.
  public func recount(orders : [Types.Order]) : Nat {
    var total = 0;
    for (order in orders.values()) {
      if (holdsPromise(order.status)) total += order.lockedCycles;
    };
    total;
  };

  /// What is left to sell. Saturates at zero because an over-promised reserve is a real
  /// state — a risen ledger fee is absorbed by the reserve, which can put the balance
  /// fractionally under what is promised. The answer there is "sell nothing", not "trap".
  public func available(balance : Nat, promised : Nat) : Nat {
    if (promised >= balance) 0 else balance - promised;
  };

  // ── The reserve floor (§5.4) ─────────────────────────────────────────────
  //
  // ⚠️ **TWO destination classes, ONE outflow mechanism, and the enforcement is the
  // actor type rather than this comment.**
  //
  // The mechanism is `icrc1_transfer` and nothing else. What #103 added is a second
  // *destination class*, so the phrase "one outflow" must not be read as "one kind of
  // recipient" — and the gate step greps declared METHODS, not destinations, so nothing
  // else would catch that drift:
  //
  //   1. **Delivery** — to a buyer's own account, for an order they paid for. Bounded by
  //      the order's `lockedCycles`, which the gate admitted against the floor, and by
  //      §2's own-destination rule: `create_order` refuses any destination but the
  //      caller's.
  //   2. **Withdrawal** (#103) — to a controller. Bounded by there being **no
  //      promise-holder at all**, so nothing is owed to any buyer, and it grants a
  //      controller no capability they lack: a controller can already move the reserve
  //      by upgrading this canister. `Main.withdraw_reserve` carries the full argument.
  //
  // Both decrement the floor by `amount + fee` before the transfer is issued (rule 2),
  // so the accounting below is identical for either class.
  //
  // ⚠️ **ONE outflow mechanism, and the enforcement is the actor type, not this comment.**
  // `Delivery.CyclesLedgerService` declares exactly `icrc1_transfer` and
  // `icrc1_balance_of`. `icrc2_approve` and the ledger's `withdraw` are absent, so this
  // canister *cannot* call them — not "does not plan to". A gate step greps the backend
  // for such declarations, so adding one has to be deliberate.
  //
  // ⚠️ **A grep finds `icrc1_transfer` at THREE call sites, and that is still one outflow
  // per execution.** Two of them are a delivery's attempt and its `#BadFee` re-issue of
  // the same intent; at most one can debit, and the ledger deduplicates if an earlier
  // attempt landed. Reading "two call sites" as "two outflows" and adding a second
  // decrement double-counts every delivery. The third is `withdraw_reserve` (#103), a
  // separate execution entirely, which decrements once by the figure it debits.

  /// What the ledger should read after an outflow, at minimum. Every term is observed or
  /// derivable, so the reconcile can recompute it and report drift.
  public func floorAfterOutflow(floor : Nat, debited : Nat) : Nat {
    if (debited >= floor) 0 else floor - debited : Nat;
  };

  /// Adopt a fresh observation — **and the guard that makes adopting safe.**
  ///
  /// ⚠️ **`quiet` is the safety property, not an optimisation.** Adopting a balance read
  /// taken before an outflow erases that outflow's decrement while the transfer still
  /// debits, leaving the floor optimistic with nothing left to re-decrement it. The caller
  /// establishes `quiet` by checking nothing was in flight before the read, nothing after
  /// it, and nothing was issued in between. Skipping is cheap: a top-up waits, never lost.
  public func adoptObservation(
    floor : Nat,
    observed : Nat,
    quiet : Bool,
  ) : { floor : Nat; unexplainedShortfall : Nat; adopted : Bool } {
    if (not quiet) {
      return { floor; unexplainedShortfall = 0; adopted = false };
    };
    if (observed >= floor) {
      { floor = observed; unexplainedShortfall = 0; adopted = true };
    } else {
      // ⚠️ The ledger holding LESS than the floor with nothing in flight means an outflow
      // this canister did not cause, which §5.4's asymmetry says is impossible. Report it
      // and adopt anyway: selling against a bound the ledger contradicts is worse than
      // under-selling.
      { floor = observed; unexplainedShortfall = floor - observed : Nat; adopted = true };
    };
  };

  /// Can the reserve cover one more order of this size?
  ///
  /// Inclusive: the ledger charges its fee on top of the amount, and the amount is what is
  /// promised, so an order that exactly exhausts what is left is fine. An exclusive check
  /// would strand the last order's cycles forever.
  public func canCover(floor : Nat, promised : Nat, lockedCycles : Nat) : Bool {
    available(floor, promised) >= lockedCycles;
  };

};
