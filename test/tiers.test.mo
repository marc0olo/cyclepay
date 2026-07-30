import { test; suite } "mo:test";
import Tiers "../src/backend/Tiers";

// Unit suite for the §3 fixed-tier config: validation (atomic config
// replacement depends on it) and lookup.

func tier(id : Text, usdCents : Nat) : Tiers.Tier {
  { id; usdCents; paymentLinkUrl = "https://buy.stripe.com/" # id };
};

/// The per-purchase ceiling every case below validates against, except the
/// ones probing the ceiling itself. Matches Gate.defaultConfig().
let ceiling : Nat = 100_000;

suite("validate", func() {
  test("empty config is valid (pre-launch state)", func() {
    assert Tiers.validate([], ceiling) == #ok;
  });

  test("distinct ids and non-zero amounts pass", func() {
    assert Tiers.validate([tier("s", 500), tier("m", 2_000), tier("l", 10_000)], ceiling) == #ok;
  });

  test("empty tier id is rejected", func() {
    assert Tiers.validate([tier("s", 500), tier("", 2_000)], ceiling) == #err(#emptyTierId);
  });

  test("duplicate tier id is rejected and named", func() {
    assert Tiers.validate([tier("s", 500), tier("m", 2_000), tier("s", 9_000)], ceiling) == #err(#duplicateTierId("s"));
  });

  test("zero-cent tier is rejected and named", func() {
    assert Tiers.validate([tier("s", 500), tier("free", 0)], ceiling) == #err(#zeroUsdCents("free"));
  });

  test("a tier above the per-purchase ceiling is rejected and named", func() {
    // The operator-typo case: a $1,000 tier registered as $100,000.
    assert Tiers.validate([tier("s", 500), tier("fat", 10_000_000)], ceiling)
      == #err(#aboveCeiling({ id = "fat"; usdCents = 10_000_000; maxUsdCents = ceiling }));
  });

  test("a tier exactly at the ceiling is allowed", func() {
    assert Tiers.validate([tier("max", ceiling)], ceiling) == #ok;
  });

  test("validation is atomic — one bad tier rejects the whole batch", func() {
    // The caller relies on this: a rejected batch must leave the live tier
    // list untouched rather than applying the good entries.
    assert Tiers.validate([tier("ok1", 500), tier("bad", 0), tier("ok2", 900)], ceiling)
      == #err(#zeroUsdCents("bad"));
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
