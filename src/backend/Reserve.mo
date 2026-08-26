/// Solvency of the cycles reserve (#30 PR-B).
///
/// The gateway sells cycles it already holds, in its own cycles-ledger account.
/// Two numbers decide whether it can accept one more order, and they have
/// different owners:
///
///     available = icrc1_balance_of(reserveAccount)  −  promisedTotal
///                 \________ the LEDGER's ________/     \___ OURS ___/
///
/// The ledger owns the balance — anyone can read it, including the frontend, so
/// this canister never caches it. What only this canister knows is how much of
/// that balance is already **spoken for** by orders that exist and have not been
/// settled. Selling the same cycles twice is the failure this module prevents.
///
/// ⚠️ **`promised` has no fee term.** The ledger charges its transfer fee on top
/// of the amount, so delivering `lockedCycles − fee` moves the balance by exactly
/// `lockedCycles`. An earlier draft wrote `Σ (lockedCycles + fee)` and
/// double-counted, which under-reports `available` and refuses sales that would
/// have worked.
///
/// ⚠️ **`lockedCycles` must stay immutable after creation.** The whole design
/// rests on it: the amount an order promises IS its locked quantity, so no second
/// per-order copy is stored. #33 deleted `attach_payment` and the repricing
/// branch, and #30 PR-A made `markPaid` stop taking a quantity, so nothing writes
/// it after creation. **If a future feature ever mutates it, this tally breaks
/// silently** and the design has to go back to a stored per-order amount.
import Types "Types";

module {

  /// Is this order's promise still held?
  ///
  /// ⚠️ Expressed as "**not terminal**" rather than as a list of the statuses that
  /// hold, and that is not a stylistic choice. The membership list changes during
  /// the #30/#36 staging window: `#minting`, `#icpAtCmc` and `#awaitingTreasury`
  /// survive in-tree until #36, they are **not terminal**, so under this rule they
  /// are counted — correctly. Under an enumerated list they would be omitted, and
  /// any transition into one would **silently release the promise while the order
  /// is still live**. Nothing should enter them after #30 PR-A; the rule makes
  /// that a belt-and-braces question rather than a correctness one.
  ///
  /// The terminal set is also the smaller and more stable list, and getting it
  /// wrong fails in the safe direction: an over-counted promise refuses a sale, an
  /// under-counted one sells the same cycles twice.
  public func holdsPromise(status : Types.OrderStatus) : Bool {
    switch (status) {
      // Terminal, and nothing else is: delivered (the cycles left), expired or
      // cancelled (never paid), abandoned (the operator ended it, having refunded
      // by hand).
      case (#delivered or #expired or #cancelled or #abandoned) false;
      case (_) true;
    };
  };

  /// How the tally moves for one status transition, in units of `lockedCycles`.
  ///
  /// `+1` entering the counted set, `−1` leaving it, `0` within it. Returned as a
  /// sign rather than an amount so the caller multiplies by the order's own
  /// `lockedCycles` and there is one place that knows the arithmetic.
  ///
  /// ⚠️ **`#created → #paid` is ZERO**, and that is worth stating because an
  /// earlier draft of #30 listed `markPaid` as one of two adjustment sites. It is
  /// neither: payment does not settle anything, it only means the money arrived.
  /// **Release is at DELIVERY.** Releasing at `#paid` would let a second order
  /// claim capacity the first still needs — order A holds 72 T, the buyer pays,
  /// the tally drops 72 T, order B for 72 T is admitted against capacity that is
  /// still owed, and both must be paid out of a reserve that only ever covered
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
  /// Saturating rather than trapping: an underflow means the tally has ALREADY
  /// diverged, and trapping on the money path over a bookkeeping error is worse
  /// than reporting zero.
  ///
  /// ⚠️ **But it is reported, not swallowed.** A silent saturation is
  /// indistinguishable from an exact release, so the first evidence of a broken
  /// invariant would wait for the daily recount — up to 24 h of a wrong tally
  /// gating real sales. `saturated` lets the caller audit it in the same message
  /// the damage happened in.
  public func applyDelta(
    total : Nat,
    delta : { #add; #release; #none },
    lockedCycles : Nat,
  ) : { total : Nat; saturated : Bool } {
    switch (delta) {
      case (#add) ({ total = total + lockedCycles; saturated = false });
      case (#release) {
        if (lockedCycles > total) {
          // Releasing more than is held: the tally was already wrong before this
          // order got here.
          ({ total = 0; saturated = true });
        } else {
          ({ total = total - lockedCycles : Nat; saturated = false });
        };
      };
      case (#none) ({ total; saturated = false });
    };
  };

  /// The **recount**: the same quantity derived independently, for drift detection.
  ///
  /// ⚠️ **What this actually cross-checks is the BOOKKEEPING, not the semantics.**
  /// It shares `holdsPromise` with the tally deliberately — that predicate *is*
  /// the definition of a promise, and two definitions would be worse than one. So
  /// a wrong definition is invisible to this check, while a missed or doubled
  /// adjustment site is exactly what it catches. That is the useful half: #30's
  /// history has one missed site (this PR's own `expireWithCause`/
  /// `expireBySession`) and zero disputed definitions.
  ///
  /// It is still a real check, which took three attempts to get right. An earlier
  /// draft stored a per-order `promisedCycles` and recounted
  /// `Σ promisedCycles where ≠ null` — a **tautology**: a leaked promise sits in
  /// both sums, so it could never detect anything.
  ///
  /// ⚠️ `#needsReview` **must** be counted here, matching `holdsPromise`. An
  /// earlier version excluded it while the design said it legitimately holds, so
  /// the first genuine escalation would have fired a false drift alarm on the one
  /// detector the design relies on — and an operator learns fast to ignore a
  /// detector that cries wolf.
  ///
  /// O(n) over every order ever created, so it belongs on the daily reconcile and
  /// the admin recount, never on a hot path. #37 adds a status index.
  public func recount(orders : [Types.Order]) : Nat {
    var total = 0;
    for (order in orders.values()) {
      if (holdsPromise(order.status)) total += order.lockedCycles;
    };
    total;
  };

  /// What is left to sell.
  ///
  /// Saturating at zero because an over-promised reserve is a real state: a risen
  /// ledger fee is absorbed by the reserve (#30 PR-A), which can put the balance
  /// fractionally under what is promised. The answer there is "sell nothing", not
  /// "trap on every order".
  public func available(balance : Nat, promised : Nat) : Nat {
    if (promised >= balance) 0 else balance - promised;
  };

  /// The promise figure to decide against, given a **stale balance** and a **live
  /// tally**.
  ///
  /// ⚠️ Pure and separate so it is testable, because the interleaving it guards is
  /// hard to stage: a delivery whose continuation runs between the balance read
  /// and the decision debits the ledger *and* releases its promise, so a live-only
  /// read pairs a not-yet-lowered balance with an already-released promise and
  /// overstates `available` by a whole order. `max` makes the staleness one-sided:
  ///
  /// - delivery released in the gap → snapshot wins → exact (delivery does not
  ///   move `balance − promised`; it settles a counted promise with reserved
  ///   cycles);
  /// - a concurrent hold in the gap → live wins → the other order is honoured;
  /// - an expiry or cancel released in the gap → snapshot wins → understates for
  ///   one scheduling gap, refusing a sale that would have worked. The safe
  ///   direction, and the honest cost.
  public func promisedForDecision(promisedAtRead : Nat, promisedNow : Nat) : Nat {
    if (promisedAtRead > promisedNow) promisedAtRead else promisedNow;
  };

  /// Can the reserve cover one more order of this size?
  ///
  /// Inclusive: an order that exactly exhausts the reserve is fine, because the
  /// fee is charged on top of the amount and the amount is what is promised. An
  /// exclusive check would strand the last order's worth of cycles forever.
  public func canCover(balance : Nat, promised : Nat, lockedCycles : Nat) : Bool {
    available(balance, promised) >= lockedCycles;
  };

};
