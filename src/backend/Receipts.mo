/// The buyer-verifiable receipt: what an order recorded, plus the two rate inputs that
/// make its price reproducible from first principles.
///
/// ⚠️ **A module rather than a type in `Main.mo`, because TWO endpoints return it** —
/// `receipt` (owner-scoped, a query) and `admin_receipt` (audited, an update) — and since
/// #120 those live in different mixins. A type declared in one mixin is not visible to
/// the other, and a copy in each is exactly the drift the single builder below exists to
/// prevent.
///
/// ⚠️ Pure: no state, no caller, no authorization. Both endpoints authorize first and
/// then call `of`, so this cannot become a way to read a receipt without one.
import Pricing "Pricing";
import Types "Types";

module {

  public type Receipt = {
    order : Types.Order;
    /// What the buyer actually paid, if they have.
    paidUsdCents : ?Nat;
    /// The **cycles-ledger** block the delivery transfer landed in — the on-chain
    /// proof, checkable by anyone against that ledger by the order id in the
    /// transfer's memo.
    deliveryBlockIndex : ?Nat;
    /// Cycles delivered to the buyer's account.
    cyclesDelivered : ?Nat;
    /// Recompute the quote from these and it must equal `order.lockedCycles`:
    ///   netCents × xdrPermyriadPerIcp × 10¹² / usdPerIcpMicros
    /// where netCents = usdCents − (⌈usdCents·feeBps/10⁴⌉ + feeFixedCents).
    /// Both rate inputs are queryable from the XRC and the CMC, so the price is
    /// reproducible from first principles rather than merely asserted by us.
    verification : {
      netCents : ?Nat;
      usdPerIcpMicros : Nat;
      xdrPermyriadPerIcp : Nat;
      rateReceivedRates : Nat;
      rateQueriedSources : Nat;
    };
  };

  /// One receipt, from an order and its journal entry.
  ///
  /// ⚠️ **One owner, because there are two endpoints and they must not drift.** `receipt`
  /// and `admin_receipt` differ only in who may call and whether the read is audited —
  /// the record itself is the same object, and it was built twice, field for field. A
  /// verification figure that disagreed between the buyer's copy and the operator's copy
  /// would be the worst possible place for a copy-paste divergence.
  public func of(order : Types.Order, journal : ?Types.JournalEntry) : Receipt {
    {
      order;
      paidUsdCents = order.paidUsdCents;
      deliveryBlockIndex = switch (journal) { case (?entry) entry.blockIndex; case null null };
      cyclesDelivered = switch (journal) { case (?entry) entry.cyclesDelivered; case null null };
      verification = {
        // `??`, because the fallback is exactly "unpaid, so quote the order's own figure".
        netCents = Pricing.netCents(order.pricing, order.paidUsdCents ?? order.pricing.usdCents);
        usdPerIcpMicros = order.pricing.usdPerIcpMicros;
        xdrPermyriadPerIcp = order.pricing.xdrPermyriadPerIcp;
        rateReceivedRates = order.pricing.rateReceivedRates;
        rateQueriedSources = order.pricing.rateQueriedSources;
      };
    };
  };

};
