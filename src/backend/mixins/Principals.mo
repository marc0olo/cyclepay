// ⚠️ `Iter` carries no `Iter.` call here and is required anyway: it is what makes
// `.toArray()` resolve on the iterator `Set.values()` returns.
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Set "mo:core/Set";

/// The two principal lists: who may act as an admin, and who may buy while this
/// gateway accepts free test payments.
///
/// ⚠️ **Both arrive as the `Set` itself, not as accessors.** A `Set` is a heap object, so
/// passing it shares it — `add`/`remove` write through to the actor's own field. Only a
/// `var` holding an immutable value needs the accessor treatment; see `mixins/Secrets.mo`
/// for the one that does, and `Main.mo`'s include block for the rule.
///
/// ⚠️ **`reserveState` and `stripeState` are here for ONE audit line**, in
/// `remove_allowed_buyer`: emptying the list against a funded reserve while test payments
/// are accepted is `Gate.Reason.unboundedGiveaway`, and the line says so rather than
/// leaving an operator to discover the gateway has closed. They are passed read-only in
/// spirit — this mixin writes neither.
mixin (
  adminPrincipals : Set.Set<Principal>,
  allowedBuyers : Set.Set<Principal>,
  reserveState : { var floor : Nat },
  stripeState : { var expectLivemode : ?Bool },
  requireController : (Principal) -> (),
  auditAdmin : (Principal, Text, Text) -> (),
) {

  /// Why a principal could not be added to, or removed from, one of the two lists
  /// (#123).
  ///
  /// ⚠️ **One type for both lists and both directions**, because the four methods refuse
  /// for exactly these three reasons and a caller acts on the reason, not on which list
  /// it was. `#alreadyPresent` and `#notPresent` carry the principal so a console can
  /// name it without re-deriving it from the argument it just sent.
  ///
  /// ⚠️ **`#anonymousNotAllowed` is not "invalid input".** The anonymous principal is a
  /// real, callable identity that every unauthenticated caller shares, so granting it
  /// admin would grant the world admin, and allow-listing it would let anyone buy while
  /// test payments are on. It is refused for a specific reason, and the tag says which.
  type ListError = {
    #anonymousNotAllowed;
    #alreadyPresent : { principal : Principal };
    #notPresent : { principal : Principal };
  };

  /// Grant the CASES tier to a principal (controller only, audited).
  ///
  /// ⚠️ **The grant is on a PRINCIPAL, and an admin's principal comes from the origin
  /// they signed in at.** The flow is: the admin reads their own principal from
  /// `admin_status`, gives it to a controller, and then acts from a CLI identity linked to
  /// the same Internet Identity — `icp identity link web <name> --app <origin>`. ⚠️ Without
  /// `--app` the CLI links a principal derived from the auth domain's own default
  /// (`cli.id.ai`), which is not this app, so the grant would sit on a principal the
  /// admin never sees.
  public shared ({ caller }) func add_admin(p : Principal) : async Result.Result<(), ListError> {
    requireController(caller);
    // Belt and braces: `Auth.checkAdmin` rejects anonymous before consulting either
    // predicate, so a granted `2vxsx-fae` would be inert — but a list that contains it
    // reads as though it were not.
    if (p.isAnonymous()) return #err(#anonymousNotAllowed);
    if (adminPrincipals.contains(p)) return #err(#alreadyPresent({ principal = p }));
    adminPrincipals.add(p);
    auditAdmin(caller, "admin.granted", p.toText());
    #ok;
  };

  /// Revoke the CASES tier (controller only, audited).
  public shared ({ caller }) func remove_admin(p : Principal) : async Result.Result<(), ListError> {
    requireController(caller);
    // ⚠️ Not "not an admin": that is the authz trap's wording, and an operator reading it
    // back cannot tell whether THEY were refused or the target simply was not listed.
    if (not adminPrincipals.contains(p)) return #err(#notPresent({ principal = p }));
    adminPrincipals.remove(p);
    auditAdmin(caller, "admin.revoked", p.toText());
    #ok;
  };

  /// Who holds the CASES tier (controller only).
  ///
  /// ⚠️ Controllers are NOT listed — they pass `checkAdmin` without being granted, so an
  /// empty list does not mean nobody can act.
  public shared query ({ caller }) func admins() : async [Principal] {
    requireController(caller);
    adminPrincipals.values().toArray();
  };

  /// Allow a principal to buy while this gateway accepts free test payments
  /// (controller only, audited).
  public shared ({ caller }) func add_allowed_buyer(p : Principal) : async Result.Result<(), ListError> {
    requireController(caller);
    // The anonymous principal is a shared identity: `create_order` rejects it
    // before the gate, so a listed `2vxsx-fae` would be inert — but a list that
    // contains it reads as though it were not.
    if (p.isAnonymous()) return #err(#anonymousNotAllowed);
    if (allowedBuyers.contains(p)) return #err(#alreadyPresent({ principal = p }));
    allowedBuyers.add(p);
    auditAdmin(caller, "buyer.allowed", p.toText());
    #ok;
  };

  /// Revoke a buyer's allowance (controller only, audited).
  ///
  /// ⚠️ **Removing the LAST entry does not open the gateway up — it closes it.**
  /// An empty list plus a funded reserve plus test payments is
  /// `Gate.Reason.unboundedGiveaway`, which refuses everyone. The audit line says
  /// so, because "revoked the last buyer" and "the gateway stopped selling" are
  /// the same event and an operator should not have to connect them later.
  public shared ({ caller }) func remove_allowed_buyer(p : Principal) : async Result.Result<(), ListError> {
    requireController(caller);
    if (not allowedBuyers.contains(p)) return #err(#notPresent({ principal = p }));
    allowedBuyers.remove(p);
    let emptied = allowedBuyers.size() == 0;
    auditAdmin(
      caller,
      "buyer.disallowed",
      p.toText()
      # (
        if (emptied and stripeState.expectLivemode != ?true and reserveState.floor > 0) {
          " — ⚠️ the list is now EMPTY against a funded reserve, so the gateway refuses every buyer (unboundedGiveaway)";
        } else if (emptied) { " — the list is now empty" } else { "" }
      ),
    );
    #ok;
  };

  /// Who may buy while test payments are accepted (controller only).
  ///
  /// ⚠️ An empty list does not mean "everyone" — see `allowedBuyers`.
  public shared query ({ caller }) func allowed_buyers() : async [Principal] {
    requireController(caller);
    allowedBuyers.values().toArray();
  };
};
