// Unit suite for the CMC rate read — the one thing this canister asks the Cycles
// Minting Canister for.
//
// The rate is pinned against the CMC's actual scheme rather than against itself, and
// the staleness bound is the assertion that matters: a stale rate misprices an order
// without anything appearing broken.
import { suite; test } "mo:test";
import Cmc "../src/backend/Cmc";

suite("constants pinned to the CMC scheme", func() {
  test("the rate staleness guard is 15 min (ns)", func() {
    // ⚠️ A bound, not a preference: a rate older than this misprices an order and
    // nothing looks broken while it happens. The ledger's own dedup window is
    // delivery's business — `test/delivery.test.mo` pins it.
    assert Cmc.cmcRateMaxAgeNs == 900_000_000_000;
  });
});

suite("freshCmcRate (§5 staleness guard)", func() {
  let rate : Cmc.IcpXdrConversionRate = {
    timestamp_seconds = 1_000_000;
    xdr_permyriad_per_icp = 35_000;
  };
  let rateNs : Int = 1_000_000 * 1_000_000_000;

  test("fresh inside the window", func() {
    assert Cmc.freshCmcRate(rate, rateNs + Cmc.cmcRateMaxAgeNs - 1, Cmc.cmcRateMaxAgeNs) == ?35_000;
  });

  test("stale at exactly the window (age >= window convention)", func() {
    assert Cmc.freshCmcRate(rate, rateNs + Cmc.cmcRateMaxAgeNs, Cmc.cmcRateMaxAgeNs) == null;
  });

  test("a CMC timestamp ahead of now is fresh, not an error", func() {
    assert Cmc.freshCmcRate(rate, rateNs - 60_000_000_000, Cmc.cmcRateMaxAgeNs) == ?35_000;
  });

  test("zero rate is stale regardless of age", func() {
    let zero = { rate with xdr_permyriad_per_icp = 0 : Nat64 };
    assert Cmc.freshCmcRate(zero, rateNs, Cmc.cmcRateMaxAgeNs) == null;
  });
});
