import Array "mo:core/Array";
import Types "Types";

/// Problems that belong to an order, and the resolution semantics that came with
/// them from the queue that is now `Orphans` (#37).
///
/// **Problems that belong to an order live on the order. Nothing drops.** Four of
/// the queue's six remaining kinds have an `orderId`, so "which order is this
/// about" is always answerable — those live here, on `Types.Order.problems`. The
/// two that have no order by definition (`#unattributed`, `#unprocessable`) keep a
/// narrow list of their own, because a payment we cannot attribute has nothing to
/// attach to.
///
/// ## What a problem may be
///
/// ⚠️ **The admission rule, shared with `Orphans.mo` because it is the
/// queue's definition restated:**
///
/// > A problem earns its place only if it holds **information that exists nowhere
/// > else**, AND **an action nobody has taken yet**.
///
/// #37 dropped two kinds against it. `#deliveryDelayed` failed both halves — every
/// field was copied off the order, the stage was a constant, and it self-resolved,
/// so it was a *reading* and became `delayed_deliveries`. `#abandoned` failed both
/// once review established the refund is tracked by `stripe.refundOfEscalated`: the
/// status, the journal patch and an audit line already carried the decision, so it
/// was *history* and became `Order.abandonedReason`.
///
/// ⚠️ **Identity fields are gone, and that is the point of moving.** The old kinds
/// each carried an `orderId`; here it is structural. `#deliveryStuck` also carried a
/// `blockIndex`, which is already on the `JournalEntry` along with `status`,
/// `retries` and `updatedAtNs` — and #37 §1b moved the last thing it held alone, the
/// ledger's error text, to `JournalEntry.lastError`. What survives per problem is
/// **kind, detail, and resolution state**.
module {
  /// The kinds and the record live in `Types.mo`, because `Types.Order` carries them
  /// and a module cannot import the module that imports it. This module owns the
  /// *semantics*: what a refund can settle, how filing dedups, and the admission rule
  /// above.
  public type Kind = Types.ProblemKind;
  public type Problem = Types.Problem;

  /// Can a `charge.refunded` for the same payment settle this on its own?
  ///
  /// ⚠️ **True only where the remedy is exactly "refund the fiat".** Anything else
  /// needs a decision a webhook cannot make.
  public func refundResolvable(kind : Kind) : Bool {
    switch (kind) {
      case (#duplicate(_)) true;
      // Refunding blind here could pay a buyer who already holds their cycles: the
      // money position is unknown until someone reads the ledger.
      case (#deliveryStuck(_)) false;
      // The refund is what CREATED this, so matching on it would close the recorded
      // loss the instant it was recorded.
      case (#refundAfterDelivery(_)) false;
      // ⚠️ **False even though refunding is a legal thing for the operator to do
      // here.** The question is whether a `charge.refunded` settles it *on its own*,
      // and it does not: the refund returns the money and leaves the order stranded
      // in `#created` holding reserve capacity, with no event left that can release
      // it. Answering true would auto-close the only record pointing at that. The
      // remedy that settles it whole is a **resend**.
      case (#paidNotCredited(_)) false;
    };
  };

  /// The payment reference a `charge.refunded` resolves — refund-resolvable kinds
  /// only.
  ///
  /// ⚠️ **That is the accessor, not the payload.** `#refundAfterDelivery` and
  /// `#paidNotCredited` both carry a `paymentRef` and both return null here,
  /// deliberately and for different reasons — see `refundResolvable`. The two must
  /// agree: a refund can settle a problem exactly when this gives the closer
  /// something to match on.
  public func paymentRefOf(kind : Kind) : ?Text {
    switch (kind) {
      case (#duplicate({ paymentRef })) ?paymentRef;
      case (#deliveryStuck(_) or #refundAfterDelivery(_) or #paidNotCredited(_)) null;
    };
  };

  public func isUnresolved(problem : Problem) : Bool {
    problem.resolvedAtNs == null;
  };

  /// File a problem — or **refresh** the unresolved one of the same shape that is
  /// already there.
  ///
  /// ⚠️ **Dedup is by kind-shape, not by equality.** Re-filing on every sweep is the
  /// flood that `#deliveryDelayed`'s `delayedAlerts` map existed to suppress; here the
  /// order itself carries the answer, so the guard needs no second structure.
  ///
  /// ⚠️ **A match REFRESHES the payload and the detail, and suppressing instead would
  /// be a regression.** The queue's `add` had no dedup at all, so a second partial
  /// refund filed a second entry carrying the larger *cumulative* `refundedCents`.
  /// Plain suppression would leave an operator reading the **stale, smaller** figure —
  /// reconciling against Stripe by amount is the whole reason that field is sized.
  /// The same applies to `#deliveryStuck`'s `stage`: it is the money position, and an
  /// operator acts on the *current* one, not the first one observed.
  ///
  /// So the two halves are separate concerns: **shape** decides whether this is the
  /// same problem, and a match then **updates** what the problem currently says.
  /// `filedAtNs` is preserved, because when the trouble started is not something a
  /// refresh may overwrite.
  public func file(
    problems : [Problem],
    kind : Kind,
    detail : Text,
    nowNs : Int,
  ) : { problems : [Problem]; filed : Bool } {
    var found = false;
    let refreshed = problems.map(
      func(p : Problem) : Problem {
        if (not found and isUnresolved(p) and sameShape(p.kind, kind)) {
          found := true;
          // `filedAtNs` deliberately kept: first seen, not last seen.
          { p with kind; detail };
        } else { p };
      }
    );
    if (found) return { problems = refreshed; filed = false };
    {
      problems = problems.concat([{ kind; detail; filedAtNs = nowNs; resolvedAtNs = null }]);
      filed = true;
    };
  };

  /// Two kinds describe the same problem for dedup purposes.
  ///
  /// ⚠️ **Compared on the discriminator plus the identifying reference, not on every
  /// field.** `#refundAfterDelivery`'s `refundedCents` is *cumulative*, so a second
  /// partial refund arrives with a larger figure — comparing it would file a fresh
  /// problem per partial, and comparing nothing at all would let a genuinely
  /// different payment be swallowed.
  public func sameShape(a : Kind, b : Kind) : Bool {
    switch (a, b) {
      case (#duplicate(x), #duplicate(y)) x.paymentRef == y.paymentRef;
      case (#deliveryStuck(_), #deliveryStuck(_)) true;
      case (#refundAfterDelivery(x), #refundAfterDelivery(y)) x.paymentRef == y.paymentRef;
      case (#paidNotCredited(x), #paidNotCredited(y)) x.paymentRef == y.paymentRef;
      case (_, _) false;
    };
  };

  /// Mark every unresolved problem matching `pred` resolved. Returns the updated
  /// array and how many closed.
  public func resolveWhere(
    problems : [Problem],
    pred : Kind -> Bool,
    nowNs : Int,
  ) : { problems : [Problem]; closed : Nat } {
    var closed = 0;
    let out = problems.map(
      func(p) {
        if (isUnresolved(p) and pred(p.kind)) {
          closed += 1;
          { p with resolvedAtNs = ?nowNs };
        } else { p };
      }
    );
    { problems = out; closed };
  };

  public func unresolvedCount(problems : [Problem]) : Nat {
    var n = 0;
    for (p in problems.vals()) { if (isUnresolved(p)) n += 1 };
    n;
  };

  /// Short tag for audit lines and operator output.
  public func kindToText(kind : Kind) : Text {
    switch (kind) {
      case (#duplicate(_)) "duplicate";
      case (#deliveryStuck(_)) "deliveryStuck";
      case (#refundAfterDelivery(_)) "refundAfterDelivery";
      case (#paidNotCredited(_)) "paidNotCredited";
    };
  };

};
