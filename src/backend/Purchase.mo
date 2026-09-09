// ⚠️ `Nat` looks unused: it is what makes `cents.toText()` resolve (M0070 without it).
import Nat "mo:core/Nat";
import Result "mo:core/Result";
import Gate "Gate";
import Pricing "Pricing";
import Tiers "Tiers";
import Types "Types";

/// The purchase decision: what a buyer's request costs, whether it is admitted, and what
/// it locks — **decided before anything is committed and before any outcall**.
///
/// ⚠️ **Extracted from `create_order` so the ERROR PRECEDENCE is testable without an IC
/// environment** (#127, A3). Which refusal a buyer sees when several conditions hold at
/// once was previously observable only through PocketIC: an unknown tier and a stale rate
/// both apply, and only the sequence decides which one is reported. That sequence is now
/// a signature with unit tests rather than a run of `switch` blocks in an endpoint.
///
/// ⚠️ **What deliberately did NOT move: the commit, the outcall, and the order between
/// them.** `create_order` commits the order and takes the reserve hold in one block with
/// no `await`, and only then creates the Stripe session — the order id IS the
/// `client_reference_id`, so it cannot be otherwise. That ordering needs actor
/// capabilities (`raw_rand`, the outcall) and is guarded by integration scenario 67b,
/// which observes the hold while the outcall is parked. Moving it here would make it
/// harder to see, not easier.
module {

  /// Everything the commit and the session need, decided once.
  ///
  /// ⚠️ **`lockedCycles` is carried, never recomputed.** The commit takes the hold for
  /// this figure and the delivery pays it out, with an `await` in between — so a second
  /// quote taken after that await would deliver a different number of cycles than the
  /// reserve reserved for it. That is the oversell this whole ordering exists to prevent,
  /// wearing the costume of a tidier refactor. Integration scenario 67c pins it: the
  /// rate is moved while the outcall is parked, and what is delivered is what was held.
  public type Plan = {
    usdCents : Nat;
    /// How the amount was expressed, for the refusals that name it back.
    quoteLabel : Text;
    lockedCycles : Nat;
    pricing : Types.Pricing;
    owner : Types.Owner;
  };

  /// Why no plan could be made.
  ///
  /// ⚠️ **A structural SUBTYPE of `create_order`'s error type, which is why no mapping
  /// layer exists.** Motoko variant subtyping lets `#err(e)` return straight out of the
  /// endpoint. The arms this cannot produce — `#anonymous`, `#idGeneration`,
  /// `#sessionUnavailable`, `#cancelledDuringCreation`, `#destinationNotOwned` — are
  /// deliberately absent rather than declared and unreachable (T4).
  public type PlanError = {
    #unknownTier : Text;
    #notAdmitted : Gate.Reason;
    #tierBelowFees : Text;
    #simulationScaleTooSmall : { scaledCycles : Nat; ledgerFee : Nat };
    #rateUnavailable;
    #quoteChanged : { quoted : Nat; minimum : Nat };
  };

  /// The quote, as the caller's own state provides it. A function rather than the rate
  /// cache itself, so this module needs no view of pricing state or of the clock.
  public type Quoter = (Nat) -> {
    #ok : (Nat, Types.Pricing);
    #stale;
    #unpriceable : Pricing.Unpriceable;
  };

  /// Admission, as the caller's own gate provides it. Also a function, and for a sharper
  /// reason: it reads the live order count and the reserve floor, so passing those as
  /// values would make them a snapshot taken before the decision they are meant to gate.
  public type Admitter = (Nat) -> Result.Result<(), Gate.Reason>;

  /// ⚠️ **The order of these four steps is the behaviour, not the implementation.**
  ///
  /// 1. **the amount** — a preset resolves against the tier list, a custom amount is
  ///    taken as given. Both collapse to gross USD cents here, and everything after is
  ///    identical for the two, which is the point of the variant.
  /// 2. **admission** — a cheap pre-refusal, so a spamming principal is turned away
  ///    before this does any pricing work. ⚠️ It can only refuse, never admit: the
  ///    authoritative decision is the one inside the commit block, which additionally
  ///    checks solvency with no `await` between check and hold.
  /// 3. **the quote** — §3's fee formula and §3.1's rate freshness.
  /// 4. **the caller's floor** — `minCycles`, checked last because it compares against
  ///    the quote produced in 3.
  ///
  /// Step 2 sits between 1 and 3 rather than first because it needs the resolved cents,
  /// and before 3 rather than after because pricing is the expensive part. Reordering
  /// them changes which refusal a buyer sees when several apply, which is why
  /// `test/purchase.test.mo` pins each pair.
  public func plan(
    caller : Principal,
    amount : Types.Amount,
    minCycles : ?Nat,
    tiers : [Tiers.Tier],
    admit : Admitter,
    quote : Quoter,
  ) : Result.Result<Plan, PlanError> {
    let (usdCents, quoteLabel) = switch (amount) {
      case (#tier(tierId)) {
        let ?tier = Tiers.find(tiers, tierId) else return #err(#unknownTier(tierId));
        (tier.usdCents, tierId);
      };
      // NOT validated against the presets: a custom amount is any amount the gate
      // admits, and the gate is the only bound. Checking it against the tier list would
      // make presets a constraint again.
      case (#custom(cents)) (cents, cents.toText() # " cents");
    };

    switch (admit(usdCents)) {
      case (#err(reason)) return #err(#notAdmitted(reason));
      case (#ok) {};
    };

    let (lockedCycles, pricing) = switch (quote(usdCents)) {
      case (#ok(quoted)) quoted;
      case (#unpriceable(#stripeFee)) return #err(#tierBelowFees(quoteLabel));
      case (#unpriceable(#simulationScale(figures))) {
        return #err(#simulationScaleTooSmall(figures));
      };
      case (#stale) return #err(#rateUnavailable);
    };

    switch (minCycles) {
      case (?minimum) if (lockedCycles < minimum) {
        return #err(#quoteChanged({ quoted = lockedCycles; minimum }));
      };
      case null {};
    };

    #ok({ usdCents; quoteLabel; lockedCycles; pricing; owner = #ii(caller) });
  };

};
