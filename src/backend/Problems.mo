import Array "mo:core/Array";
import Types "Types";

/// Problems that belong to an order, and the resolution semantics for them.
///
/// **A problem that belongs to an order lives on the order. Nothing drops.** Payments
/// with no order to attach to keep a narrow list of their own (`Orphans.mo`).
///
/// ## ⚠️ The admission rule
///
/// > A problem earns its place only if it holds **information that exists nowhere else**,
/// > AND **an action nobody has taken yet**.
///
/// Both halves are load-bearing. A reading that self-resolves fails the second (a delivery
/// running late is `delayed_deliveries`, not a problem); a record whose every field is
/// copied from the order fails the first.
///
/// ⚠️ **Identity fields are structural here, not carried.** The order supplies "which
/// order this is about", so a kind carries only **what it says, plus resolution state** —
/// anything already on the order or its journal entry is duplication that can disagree.

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
  /// ⚠️ **Dedup is by kind-SHAPE, not by equality**, so re-filing on every sweep does not
  /// flood — and the order itself carries the guard, so no second structure is needed.
  ///
  /// ⚠️ **A match REFRESHES the payload; suppressing instead is a regression.**
  /// `#refundAfterDelivery`'s `refundedCents` is *cumulative*, so suppression leaves an
  /// operator reading the **stale, smaller** figure — and reconciling against Stripe by
  /// amount is the whole reason that field is sized. Same for `#deliveryStuck`'s `stage`:
  /// it is the money position, and an operator acts on the *current* one.
  ///
  /// Two separate concerns, then: **shape** decides whether this is the same problem, and
  /// a match **updates** what it says. `filedAtNs` is preserved — when the trouble started
  /// is not something a refresh may overwrite.
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

  /// The reference that identifies **which** problem of a kind this is, where the kind
  /// has one.
  ///
  /// ⚠️ **This is the PAYLOAD, not `paymentRefOf`'s accessor**, and the two must not be
  /// confused. `paymentRefOf` answers "can a refund close this", so it withholds the
  /// ref from `#refundAfterDelivery` and `#paidNotCredited` on purpose. This answers
  /// "which one are we talking about", which those kinds can and must answer.
  ///
  /// ⚠️ **Null for `#deliveryStuck` because there can only be one.** `sameShape`
  /// matches it on the discriminator alone, so a second unresolved one on the same
  /// order is unrepresentable — nothing needs distinguishing.
  public func identifyingRef(kind : Kind) : ?Text {
    switch (kind) {
      case (#duplicate({ paymentRef })) ?paymentRef;
      case (#refundAfterDelivery({ paymentRef })) ?paymentRef;
      case (#paidNotCredited({ paymentRef })) ?paymentRef;
      case (#deliveryStuck(_)) null;
    };
  };

  /// Two kinds describe the same problem for dedup purposes.
  ///
  /// ⚠️ **The discriminator plus the identifying reference, never every field.** Comparing
  /// `#refundAfterDelivery`'s cumulative `refundedCents` would file a fresh problem per
  /// partial refund; comparing nothing would swallow a genuinely different payment.
  ///
  /// ⚠️ **Expressed through `identifyingRef` so the dedup key and the operator's selector
  /// cannot drift apart.** Problems in an array have no id, so **the key IS the handle** —
  /// when they were separate, `resolve_problem` was coarser than the dedup and closed
  /// every problem of a kind at once. One definition, both users.
  public func sameShape(a : Kind, b : Kind) : Bool {
    kindToText(a) == kindToText(b) and identifyingRef(a) == identifyingRef(b);
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
