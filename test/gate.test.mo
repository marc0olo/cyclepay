import { test; suite } "mo:test";
import Gate "../src/backend/Gate";
import Text "mo:core/Text";

// Unit suite for the pre-creation admission gate. Every case is pure
// arithmetic over an Observation, so the whole admission policy is pinned here
// without an IC environment — the same seam style as Delivery/Recovery.

/// An observation that admits: room on every axis.
let healthy : Gate.Observation = {
  openOrders = 0;
  canisterCycles = 20_000_000_000_000; // 20T // 100 ICP // 50 ICP // 10 ICP
};

let config = Gate.defaultConfig();
/// Well inside BOTH default bounds as of #33: the floor is $10 and the ceiling
/// is $100, so the old $5 fixture is now below the floor.
let amount : Nat = 2_000;

suite("defaults", func() {
  test("safety limits ship non-zero", func() {
    // These three are safety limits, not money decisions: a 0 default would refuse
    // every order rather than protect anything, which is fail-closed in the wrong
    // direction. The one value that does gate money — cycles available to sell — has
    // no default at all, because it is whatever the operator funded the reserve with.
    assert config.maxOpenOrdersPerPrincipal > 0;
    assert config.minCanisterCycles > 0;
    assert config.maxPurchaseUsdCents > 0;
  });

  test("the default config validates", func() {
    assert Gate.validateConfig(config, []) == #ok;
  });

  test("a zero open-order cap or purchase ceiling is refused as config", func() {
    assert Gate.validateConfig({ config with maxOpenOrdersPerPrincipal = 0 }, []) == #err(#zeroOpenOrderCap);
    assert Gate.validateConfig({ config with maxPurchaseUsdCents = 0 }, []) == #err(#zeroPurchaseCeiling);
  });

  test("a zero own-cycles floor is allowed — opting out is a valid choice", func() {
    assert Gate.validateConfig({ config with minCanisterCycles = 0 }, []) == #ok;
  });
});

suite("admit", func() {
  test("a healthy observation admits", func() {
    assert Gate.admit(config, healthy, amount) == #ok;
  });

  test("amount above the ceiling is refused, carrying both numbers", func() {
    let over = config.maxPurchaseUsdCents + 1;
    assert Gate.admit(config, healthy, over)
      == #err(#amountAboveMax({ usdCents = over; maxUsdCents = config.maxPurchaseUsdCents }));
  });

  test("amount below the floor is refused, and distinguishably so (#33)", func() {
    // Distinct from the ceiling case because the buyer acts on them differently
    // — "ask for less" versus "ask for more" — and with custom amounts both are
    // reachable by typing.
    let under = config.minPurchaseUsdCents - 1;
    assert Gate.admit(config, healthy, under)
      == #err(#amountBelowMin({ usdCents = under; minUsdCents = config.minPurchaseUsdCents }));
  });

  test("both bounds are inclusive", func() {
    assert Gate.admit(config, healthy, config.minPurchaseUsdCents) == #ok;
    assert Gate.admit(config, healthy, config.maxPurchaseUsdCents) == #ok;
  });

  test("the ceiling is checked before the floor, so a typo names one bound", func() {
    // Not a property worth much on its own, but it pins that an absurd amount
    // reports `#amountAboveMax` rather than whichever check happens to run first
    // after a refactor.
    assert Gate.admit(config, healthy, 0) == #err(#amountBelowMin({ usdCents = 0; minUsdCents = config.minPurchaseUsdCents }));
  });

  test("exactly at the ceiling is admitted", func() {
    assert Gate.admit(config, healthy, config.maxPurchaseUsdCents) == #ok;
  });

  test("the open-order cap is exclusive — at the cap, the next order is refused", func() {
    let max = config.maxOpenOrdersPerPrincipal;
    assert Gate.admit(config, { healthy with openOrders = max - 1 }, amount) == #ok;
    assert Gate.admit(config, { healthy with openOrders = max }, amount)
      == #err(#tooManyOpenOrders({ open = max; max }));
  });

  test("own-cycles floor: below refuses, exactly at the floor admits", func() {
    let floor = config.minCanisterCycles;
    assert Gate.admit(config, { healthy with canisterCycles = floor }, amount) == #ok;
    assert Gate.admit(config, { healthy with canisterCycles = floor - 1 }, amount)
      == #err(#canisterCyclesLow({ balance = floor - 1; min = floor }));
  });

  test("solvency is NOT decided here, and the split is the point", func() {
    // Solvency lives in `Gate.solvent`, deliberately a SEPARATE function.
    // Reading the reserve means awaiting the cycles ledger, and `admit` is
    // synchronous precisely so there is no window between observing and deciding.
    // Folding solvency in would force every caller to supply a balance —
    // including `can_purchase`, a query that cannot await one. So #30's ask to
    // "narrow can_purchase's contract" is a fact about the code here, not a
    // sentence in a doc comment.
    assert Gate.admit(config, healthy, amount) == #ok;
  });

  test("solvent: the reserve must cover this order ON TOP of what is owed", func() {
    // Inclusive at the boundary: the fee is charged on top of the amount, and the
    // amount is what is promised, so an order that exactly exhausts what is left
    // is fine. An exclusive check would strand the last order's cycles forever.
    assert Gate.solvent(10_000, 0, 10_000) == #ok;
    assert Gate.solvent(10_000, 4_000, 6_000) == #ok;
    assert Gate.solvent(10_000, 4_000, 6_001)
      == #err(#reserveShort({ requested = 6_001; available = 6_000 }));
  });

  test("solvent: a fully promised reserve refuses, and names what is left", func() {
    // The refusal carries both figures so the frontend can offer a smaller amount
    // instead of a bare failure, and an operator knows whether to top up or hunt.
    assert Gate.solvent(10_000, 10_000, 1)
      == #err(#reserveShort({ requested = 1; available = 0 }));
    // Over-promised (a risen ledger fee absorbed by the reserve) reads as zero
    // available rather than trapping.
    assert Gate.solvent(100, 101, 1)
      == #err(#reserveShort({ requested = 1; available = 0 }));
  });

  test("the amount ceiling is checked before the per-principal cap", func() {
    // Ordering matters for the error the user sees: an amount that can never be
    // accepted should say so even if the caller is also at their order cap.
    let over = config.maxPurchaseUsdCents + 1;
    assert Gate.admit(config, { healthy with openOrders = config.maxOpenOrdersPerPrincipal }, over)
      == #err(#amountAboveMax({ usdCents = over; maxUsdCents = config.maxPurchaseUsdCents }));
  });
});

suite("reasonToText", func() {
  test("every reason renders, including the new reserve one", func() {
    // The audit trail records refusals through this, so no case may be empty —
    // and `-Werror` makes this list exhaustive by construction, so a new reason
    // cannot be added without appearing here.
    let reasons : [Gate.Reason] = [
      #tooManyOpenOrders({ open = 20; max = 20 }),
      #canisterCyclesLow({ balance = 1; min = 2 }),
      #reserveShort({ requested = 7; available = 3 }),
      #amountAboveMax({ usdCents = 3; maxUsdCents = 2 }),
      #amountBelowMin({ usdCents = 1; minUsdCents = 2 }),
    ];
    for (reason in reasons.values()) {
      assert Gate.reasonToText(reason) != "";
    };
    // The figures an operator acts on are both in the text.
    let short = Gate.reasonToText(#reserveShort({ requested = 7; available = 3 }));
    assert short.contains(#text "7") and short.contains(#text "3");
  });
});

suite("the ceiling cannot be lowered under a live tier", func() {
  // `set_card_tiers` already refuses a tier above the ceiling. Without the inverse
  // check, lowering the ceiling left that tier SELLABLE BUT UNPAYABLE: the buyer
  // completes checkout and the webhook files a Type 1 instead of delivering. There is
  // no rescue path: the buyer's money is taken and given back over a config change
  // made earlier, which is why the guard is worth more than the error message it
  // produces.
  // The #33 presets: $10 / $20 / $50. The old $5 entry is below the new floor,
  // so it would be refused by `#tierBelowFloor` before the ceiling check ran and
  // every assertion here would be about the wrong bound.
  let tiers : [(Text, Nat)] = [("tier10", 1_000), ("tier50", 5_000)];

  test("a ceiling above every tier is fine", func() {
    assert Gate.validateConfig({ config with maxPurchaseUsdCents = 5_000 }, tiers) == #ok;
    assert Gate.validateConfig({ config with maxPurchaseUsdCents = 100_000 }, tiers) == #ok;
  });

  test("a ceiling below a tier is refused, and names which one", func() {
    assert Gate.validateConfig({ config with maxPurchaseUsdCents = 4_999 }, tiers)
      == #err(#tierAboveCeiling({ tierId = "tier50"; usdCents = 5_000; maxUsdCents = 4_999 }));
  });

  test("the boundary: equal to the most expensive tier is allowed", func() {
    // The gate refuses `usdCents > ceiling`, so equality must pass or the most
    // expensive tier could never be sold at all.
    assert Gate.validateConfig({ config with maxPurchaseUsdCents = 5_000 }, tiers) == #ok;
  });

  test("no tiers registered means nothing to contradict", func() {
    // The floor moves with it: a ceiling of 1 under a $10 floor is refused as
    // `#floorAboveCeiling`, which is a different (and correct) complaint.
    assert Gate.validateConfig({ config with maxPurchaseUsdCents = 1; minPurchaseUsdCents = 1 }, []) == #ok;
  });

  test("a floor above the ceiling admits nothing, so it is refused (#33)", func() {
    assert Gate.validateConfig({ config with minPurchaseUsdCents = 20_000 }, [])
      == #err(#floorAboveCeiling({ minUsdCents = 20_000; maxUsdCents = config.maxPurchaseUsdCents }));
  });

  test("raising the floor over a live tier is refused, and names it (#33)", func() {
    // The mirror of the ceiling rule, for the same reason: it would leave the
    // tier sellable but unpayable, and the operator would have to connect a
    // refused order to a config change made earlier.
    assert Gate.validateConfig({ config with minPurchaseUsdCents = 2_000 }, tiers)
      == #err(#tierBelowFloor({ tierId = "tier10"; usdCents = 1_000; minUsdCents = 2_000 }));
  });

  test("the error carries what the operator needs to fix it", func() {
    switch (Gate.validateConfig({ config with maxPurchaseUsdCents = 100; minPurchaseUsdCents = 100 }, tiers)) {
      case (#err(e)) {
        let text = Gate.configErrorToText(e);
        // The full rendered sentence, not a substring: `#text "tier10"` is also
        // a prefix of nothing here, but the same trap applied to "tier5"/"tier50"
        // before — a substring assertion would not have told us which tier was
        // named.
        assert text == "tierAboveCeiling(tier tier10 costs 1000 cents, ceiling would be 100)";
      };
      case (#ok) assert false;
    };
  });
});
