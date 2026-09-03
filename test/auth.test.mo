import { test; suite } "mo:test";
import Principal "mo:core/Principal";
import Auth "../src/backend/Auth";

// Unit suite for the §7 authz guards. The controller check is an injected
// predicate, so admin paths are testable without an IC environment; the
// real wiring (Principal.isController) is exercised by the PocketIC suite.

let anon = Principal.anonymous();
let alice = Principal.fromText("aaaaa-aa");
let bob = Principal.fromText("2ibo7-dia");

suite("checkUser (user API gate)", func() {
  test("rejects the anonymous principal", func() {
    assert Auth.checkUser(anon) == #err(#anonymous);
  });

  test("accepts any non-anonymous principal", func() {
    assert Auth.checkUser(alice) == #ok;
    assert Auth.checkUser(bob) == #ok;
  });
});

suite("checkController (the RULES tier)", func() {
  test("accepts a non-anonymous controller", func() {
    assert Auth.checkController(alice, func p = p == alice) == #ok;
  });

  test("rejects a non-controller", func() {
    assert Auth.checkController(bob, func p = p == alice) == #err(#notController);
  });

  test("rejects with an empty controller set", func() {
    assert Auth.checkController(alice, func _ = false) == #err(#notController);
  });

  test("rejects anonymous even when the predicate would admit it", func() {
    // 2vxsx-fae in the controller set must still never be an admin —
    // the anonymous check fires before the predicate is consulted.
    assert Auth.checkController(anon, func _ = true) == #err(#anonymous);
  });
});

suite("checkAdmin (the CASES tier: controller OR granted, #68)", func() {
  let noController = func(_ : Principal) : Bool = false;
  let noAdmin = func(_ : Principal) : Bool = false;

  test("a granted principal passes without being a controller", func() {
    assert Auth.checkAdmin(bob, noController, func p = p == bob) == #ok;
  });

  test("⚠️ a controller passes WITHOUT being granted — the tiers are nested", func() {
    // Denying a controller a per-order decision would only mean they add themselves to
    // the list first, and would make the controller a weaker principal than the admin it
    // grants.
    assert Auth.checkAdmin(alice, func p = p == alice, noAdmin) == #ok;
  });

  test("neither a controller nor granted is refused, and says which", func() {
    // ⚠️ `#notAdmin`, not `#notController`: telling an ungranted admin they are "not a
    // controller" points them at the wrong fix.
    assert Auth.checkAdmin(bob, noController, noAdmin) == #err(#notAdmin);
  });

  test("⚠️ anonymous is refused even when BOTH predicates would admit it", func() {
    // The shared identity must never hold either tier, and the ordering is what
    // guarantees it: the anonymous check fires before any predicate is consulted.
    assert Auth.checkAdmin(anon, func _ = true, func _ = true) == #err(#anonymous);
  });

  test("the two tiers are genuinely different: granted does NOT pass checkController", func() {
    // The whole point of the split. If this ever passed, an admin could rotate the
    // webhook secret, which is mint authority.
    assert Auth.checkAdmin(bob, noController, func p = p == bob) == #ok;
    assert Auth.checkController(bob, noController) == #err(#notController);
  });
});
