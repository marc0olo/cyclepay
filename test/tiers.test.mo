import { test; suite } "mo:test";
import Tiers "../src/backend/Tiers";

// Unit suite for the §3 fixed-tier config: validation (atomic config
// replacement depends on it) and lookup.

func tier(id : Text, usdCents : Nat) : Tiers.Tier {
  { id; usdCents; paymentLinkUrl = "https://buy.stripe.com/" # id };
};

suite("validate", func() {
  test("empty config is valid (pre-launch state)", func() {
    assert Tiers.validate([]) == #ok;
  });

  test("distinct ids and non-zero amounts pass", func() {
    assert Tiers.validate([tier("s", 500), tier("m", 2_000), tier("l", 10_000)]) == #ok;
  });

  test("empty tier id is rejected", func() {
    assert Tiers.validate([tier("s", 500), tier("", 2_000)]) == #err(#emptyTierId);
  });

  test("duplicate tier id is rejected and named", func() {
    assert Tiers.validate([tier("s", 500), tier("m", 2_000), tier("s", 9_000)]) == #err(#duplicateTierId("s"));
  });

  test("zero-cent tier is rejected and named", func() {
    assert Tiers.validate([tier("s", 500), tier("free", 0)]) == #err(#zeroUsdCents("free"));
  });
});

suite("find", func() {
  let tiers = [tier("s", 500), tier("m", 2_000)];

  test("hit returns the tier", func() {
    assert Tiers.find(tiers, "m") == ?tier("m", 2_000);
  });

  test("miss returns null", func() {
    assert Tiers.find(tiers, "xl") == null;
    assert Tiers.find([], "s") == null;
  });
});
