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
/// Admin authz = caller ∈ controllers. The controller check is injected as a
/// predicate so this module stays pure and unit-testable; the composition
/// root passes `Principal.isController` (ic0.is_controller). Anonymous is
/// rejected *before* the predicate is consulted — `2vxsx-fae` must never be
/// an admin even if it somehow lands in the controller set.
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

  public type AdminError = { #anonymous; #notController };

  /// Gate for the II-authenticated user API: any non-anonymous principal.
  public func checkUser(caller : Principal) : Result.Result<(), UserError> {
    if (caller.isAnonymous()) return #err(#anonymous);
    #ok;
  };

  /// Gate for admin methods: non-anonymous AND in the controller set.
  public func checkAdmin(
    caller : Principal,
    isController : Principal -> Bool,
  ) : Result.Result<(), AdminError> {
    if (caller.isAnonymous()) return #err(#anonymous);
    if (not isController(caller)) return #err(#notController);
    #ok;
  };

};
