/// Authorization guards (§7).
///
/// Governance is a *flat controller allowlist with equal privileges*: the
/// allowlist IS the canister's controller set (IC OR-semantics — any one
/// controller can upgrade, withdraw, rotate the secret, resolve errors,
/// pause, or edit the set itself). Editing the allowlist is therefore
/// `canister settings update --add/remove-controller`, not canister code;
/// true M-of-N needs a multisig canister installed as the sole controller
/// (the documented hardening path, §7).
///
/// ⚠️ **Authz is TWO tiers, not one (#68).** "Admin authz = caller ∈ controllers" was
/// true until an app-admin role existed:
///
///   - `checkController` — the controller set, unchanged. Everything that changes the
///     RULES: secrets, pricing, the gate, the mode, the delivery bounds, and the admin
///     list itself. A controller can upgrade, withdraw and rotate, so this tier is
///     canister control.
///   - `checkAdmin` — controller **or** a listed admin principal. Everything that resolves
///     an individual CASE: the operator reads, the idempotent levers, and the per-order
///     decisions. An admin can end one order and cannot upgrade the canister.
///
/// ⚠️ **Why an admin tier at all, and it is not ergonomics: the audit trail becomes
/// truthful.** Every admin method audits `caller`. With controller-only mutations, an
/// action is attributed to whoever holds the controller key regardless of who decided it.
///
/// Both checks inject their predicates so this module stays pure and unit-testable; the
/// composition root passes `Principal.isController` (ic0.is_controller) and a membership
/// test over the stable admin set. Anonymous is rejected *before* either predicate is
/// consulted — `2vxsx-fae` must never be an admin even if it somehow lands in a set.
///
/// User authz: anything caller-keyed (order creation/lookup, task 6) must
/// reject the anonymous principal — it is a shared identity, so an order
/// owned by it would be readable and claimable by anyone (§6.0/§7). The
/// webhook route is exempt by design: HTTP ingress arrives as anonymous and
/// is payload-authenticated (HMAC) instead.
import Principal "mo:core/Principal";
import Result "mo:core/Result";

module {

  public type UserError = { #anonymous };

  public type AdminError = { #anonymous; #notController; #notAdmin };

  /// Gate for the II-authenticated user API: any non-anonymous principal.
  public func checkUser(caller : Principal) : Result.Result<(), UserError> {
    if (caller.isAnonymous()) return #err(#anonymous);
    #ok;
  };

  /// The RULES tier: non-anonymous AND in the controller set.
  public func checkController(
    caller : Principal,
    isController : Principal -> Bool,
  ) : Result.Result<(), AdminError> {
    if (caller.isAnonymous()) return #err(#anonymous);
    if (not isController(caller)) return #err(#notController);
    #ok;
  };

  /// The CASES tier: non-anonymous AND (a controller OR a listed admin).
  ///
  /// ⚠️ **A controller passes here too, deliberately.** The tiers are nested, not
  /// disjoint: a controller can already change the rules, so denying them a per-order
  /// decision would only mean adding themselves to the list first. Reading it as an
  /// either/or would make the controller a weaker principal than the admin it grants.
  public func checkAdmin(
    caller : Principal,
    isController : Principal -> Bool,
    isAdmin : Principal -> Bool,
  ) : Result.Result<(), AdminError> {
    if (caller.isAnonymous()) return #err(#anonymous);
    if (isController(caller)) return #ok;
    if (not isAdmin(caller)) return #err(#notAdmin);
    #ok;
  };

};
