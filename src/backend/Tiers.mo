/// Fixed card tiers (§3): one permanent static Stripe Payment Link per tier,
/// so the paid amount is structurally pinned by which link was used. Tiers
/// are operator config (controllers create the links in the Stripe Dashboard
/// and register them here, §7 "set tiers"); the canister never talks to the
/// Stripe API. `usdCents` is the quote input for net-of-fees pricing (§3,
/// Forex task 7); `paymentLinkUrl` is what the frontend appends
/// `?client_reference_id=` to.
import Array "mo:core/Array";
import Result "mo:core/Result";

module {

  public type Tier = {
    /// Operator-chosen handle, referenced by `create_order` and the frontend.
    id : Text;
    /// Gross tier price; the fee formula (task 7) nets this down (§3).
    usdCents : Nat;
    /// The tier's permanent Stripe Payment Link.
    paymentLinkUrl : Text;
  };

  public type ValidateError = {
    #emptyTierId;
    #duplicateTierId : Text;
    #zeroUsdCents : Text;
  };

  /// Config-time sanity: ids non-empty and unique (lookup keys), amounts
  /// non-zero (a $0 tier would mint on nothing). O(n²) is fine — tiers are a
  /// handful of entries by design.
  public func validate(tiers : [Tier]) : Result.Result<(), ValidateError> {
    var i = 0;
    for (tier in tiers.values()) {
      if (tier.id == "") return #err(#emptyTierId);
      if (tier.usdCents == 0) return #err(#zeroUsdCents(tier.id));
      var j = 0;
      for (other in tiers.values()) {
        if (j > i and other.id == tier.id) {
          return #err(#duplicateTierId(tier.id));
        };
        j += 1;
      };
      i += 1;
    };
    #ok;
  };

  public func find(tiers : [Tier], id : Text) : ?Tier {
    tiers.find(func(tier) = tier.id == id);
  };

};
