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

suite("checkAdmin (controller allowlist gate)", func() {
  test("accepts a non-anonymous controller", func() {
    assert Auth.checkAdmin(alice, func p = p == alice) == #ok;
  });

  test("rejects a non-controller", func() {
    assert Auth.checkAdmin(bob, func p = p == alice) == #err(#notController);
  });

  test("rejects with an empty controller set", func() {
    assert Auth.checkAdmin(alice, func _ = false) == #err(#notController);
  });

  test("rejects anonymous even when the predicate would admit it", func() {
    // 2vxsx-fae in the controller set must still never be an admin —
    // the anonymous check fires before the predicate is consulted.
    assert Auth.checkAdmin(anon, func _ = true) == #err(#anonymous);
  });
});
