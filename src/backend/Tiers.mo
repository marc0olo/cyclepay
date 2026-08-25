/// Card presets (§3) — operator-configured amounts the UI offers as tiles.
///
/// **Presentational as of #33.** A buyer can order any amount between
/// `Gate.Config`'s floor and ceiling, so a preset is a convenience, not a
/// constraint: it saves typing and nothing more. Two consequences worth stating
/// because both used to be false:
///
/// - **An empty tier list no longer pauses the rail.** A custom amount is
///   orderable without any preset, so an empty list means only "no tiles shown".
///   The rail's switch is both Stripe secrets being provisioned.
/// - **The amount is no longer pinned by which link was used.** It is pinned by
///   the session the canister creates: `mode=payment`, one line item, inline
///   `price_data` with a fixed `unit_amount`, quantity 1 — see
///   `rails/Session.mo` for the settings that would break that.
///
/// They stay backend config rather than moving to the frontend so the amounts a
/// gateway offers are on-chain and auditable.
import Array "mo:core/Array";
import Result "mo:core/Result";

module {

  public type Tier = {
    /// Operator-chosen handle, referenced by `create_order` and the frontend.
    id : Text;
    /// Gross preset price; the fee formula (task 7) nets this down (§3).
    usdCents : Nat;
  };

  public type ValidateError = {
    #emptyTierId;
    #duplicateTierId : Text;
    #zeroUsdCents : Text;
    /// Above `Gate.Config.maxPurchaseUsdCents`. The ceiling exists to catch an
    /// operator typo — a tier registered at 100× its intended price would
    /// otherwise be quoted and minted without complaint, and the burn cap
    /// would only notice after the money arrived.
    #aboveCeiling : { id : Text; usdCents : Nat; maxUsdCents : Nat };
    /// Below `Gate.Config.minPurchaseUsdCents`. Registering one would put a tile
    /// on screen that `Gate.admit` then refuses — sellable but unpayable, the
    /// same defect `#aboveCeiling` prevents at the other end.
    #belowFloor : { id : Text; usdCents : Nat; minUsdCents : Nat };
  };

  /// Config-time sanity: ids non-empty and unique (lookup keys), amounts
  /// non-zero (a $0 tier would mint on nothing) and within the per-purchase
  /// ceiling. O(n²) is fine — tiers are a handful of entries by design.
  public func validate(tiers : [Tier], minUsdCents : Nat, maxUsdCents : Nat) : Result.Result<(), ValidateError> {
    var i = 0;
    for (tier in tiers.values()) {
      if (tier.id == "") return #err(#emptyTierId);
      if (tier.usdCents == 0) return #err(#zeroUsdCents(tier.id));
      if (tier.usdCents > maxUsdCents) {
        return #err(#aboveCeiling({ id = tier.id; usdCents = tier.usdCents; maxUsdCents }));
      };
      if (tier.usdCents < minUsdCents) {
        return #err(#belowFloor({ id = tier.id; usdCents = tier.usdCents; minUsdCents }));
      };
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
