import { test; suite } "mo:test";
import Tiers "../src/backend/Tiers";

// Unit suite for the §3 fixed-tier config: validation (atomic config
// replacement depends on it) and lookup.

func tier(id : Text, usdCents : Nat) : Tiers.Tier {
  // `paymentLinkUrl` went with the Payment Links (#33): a preset is an amount
  // and an id, and the amount is pinned by the session the canister creates.
  { id; usdCents };
};

/// The bounds every case below validates against, except the ones probing a
/// bound itself. Matches Gate.defaultConfig() as of #33: $10 floor, $100 ceiling.
let floor : Nat = 1_000;
let ceiling : Nat = 10_000;

suite("validate", func() {
  test("empty config is valid (pre-launch state)", func() {
    assert Tiers.validate([], floor, ceiling) == #ok;
  });

  test("distinct ids and non-zero amounts pass", func() {
    assert Tiers.validate([tier("s", 1_000), tier("m", 2_000), tier("l", 5_000)], floor, ceiling) == #ok;
  });

  test("empty tier id is rejected", func() {
    assert Tiers.validate([tier("s", 1_000), tier("", 2_000)], floor, ceiling) == #err(#emptyTierId);
  });

  test("duplicate tier id is rejected and named", func() {
    assert Tiers.validate([tier("s", 1_000), tier("m", 2_000), tier("s", 9_000)], floor, ceiling) == #err(#duplicateTierId("s"));
  });

  test("zero-cent tier is rejected and named", func() {
    // Zero is reported as zero, not as below-floor: it is the distinct "a $0 tier
    // would mint on nothing" case, and it is checked first.
    assert Tiers.validate([tier("s", 1_000), tier("free", 0)], floor, ceiling) == #err(#zeroUsdCents("free"));
  });

  test("a tier above the per-purchase ceiling is rejected and named", func() {
    // The operator-typo case: a $1,000 tier registered as $100,000.
    assert Tiers.validate([tier("s", 1_000), tier("fat", 10_000_000)], floor, ceiling)
      == #err(#aboveCeiling({ id = "fat"; usdCents = 10_000_000; maxUsdCents = ceiling }));
  });

  test("a tier exactly at either bound is allowed", func() {
    assert Tiers.validate([tier("max", ceiling)], floor, ceiling) == #ok;
    assert Tiers.validate([tier("min", floor)], floor, ceiling) == #ok;
  });

  test("a tier below the floor is refused, mirroring the ceiling check", func() {
    // Registering one would put a tile on screen that `Gate.admit` then refuses:
    // sellable but unpayable, the same defect #aboveCeiling prevents at the top.
    assert Tiers.validate([tier("tiny", floor - 1)], floor, ceiling)
      == #err(#belowFloor({ id = "tiny"; usdCents = floor - 1; minUsdCents = floor }));
  });

  test("validation is atomic — one bad tier rejects the whole batch", func() {
    // The caller relies on this: a rejected batch must leave the live tier
    // list untouched rather than applying the good entries.
    assert Tiers.validate([tier("ok1", 1_000), tier("bad", 0), tier("ok2", 2_000)], floor, ceiling)
      == #err(#zeroUsdCents("bad"));
  });
});

suite("find", func() {
  let tiers = [tier("s", 1_000), tier("m", 2_000)];

  test("hit returns the tier", func() {
    assert Tiers.find(tiers, "m") == ?tier("m", 2_000);
  });

  test("miss returns null", func() {
    assert Tiers.find(tiers, "xl") == null;
    assert Tiers.find([], "s") == null;
  });
});
