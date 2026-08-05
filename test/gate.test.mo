import { test; suite } "mo:test";
import Gate "../src/backend/Gate";
import Text "mo:core/Text";

// Unit suite for the pre-creation admission gate. Every case is pure
// arithmetic over an Observation, so the whole admission policy is pinned here
// without an IC environment — the same seam style as Treasury/Recovery.

/// An observation that admits: room on every axis.
let healthy : Gate.Observation = {
  openOrders = 0;
  canisterCycles = 20_000_000_000_000; // 20T
  burnedInWindowE8s = 0;
  burnCapE8s = 10_000_000_000; // 100 ICP
  observedFloatE8s = ?5_000_000_000; // 50 ICP
  lowFloatThresholdE8s = 1_000_000_000; // 10 ICP
};

let config = Gate.defaultConfig();
let amount : Nat = 500; // well inside the default ceiling

suite("defaults", func() {
  test("safety limits ship non-zero, unlike the money levers", func() {
    // The burn cap and the ck-USDC bound default to 0 so no money moves until
    // an operator sizes them. These three are safety limits: a 0 default would
    // refuse every order rather than protect anything.
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

  test("a spent burn window refuses before any money is taken", func() {
    assert Gate.admit(config, { healthy with burnedInWindowE8s = healthy.burnCapE8s }, amount)
      == #err(#burnCapExhausted({ burnedE8s = healthy.burnCapE8s; capE8s = healthy.burnCapE8s }));
  });

  test("the fail-closed default cap of 0 refuses every order", func() {
    // A cap of 0 means "no minting at all", so quoting would only ever lead to
    // an #awaitingTreasury hold and a manual refund.
    assert Gate.admit(config, { healthy with burnCapE8s = 0; burnedInWindowE8s = 0 }, amount)
      == #err(#burnCapExhausted({ burnedE8s = 0; capE8s = 0 }));
  });

  test("float below the threshold refuses; exactly at it admits", func() {
    let threshold = healthy.lowFloatThresholdE8s;
    assert Gate.admit(config, { healthy with observedFloatE8s = ?threshold }, amount) == #ok;
    assert Gate.admit(config, { healthy with observedFloatE8s = ?(threshold - 1) }, amount)
      == #err(#floatLow({ observedE8s = ?(threshold - 1); thresholdE8s = threshold }));
  });

  test("float gating is opt-in: threshold 0 admits even with no observation", func() {
    assert Gate.admit(
      config,
      { healthy with lowFloatThresholdE8s = 0; observedFloatE8s = null },
      amount,
    ) == #ok;
  });

  test("a configured threshold with no observation refuses", func() {
    // "Enforce this" plus "I have never looked" is not a state to sell into —
    // the go-live checklist calls refresh_float after funding for this reason.
    assert Gate.admit(config, { healthy with observedFloatE8s = null }, amount)
      == #err(#floatLow({ observedE8s = null; thresholdE8s = healthy.lowFloatThresholdE8s }));
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
  test("every reason renders, including the never-observed float", func() {
    // The audit trail records refusals through this, so no case may be empty.
    let reasons : [Gate.Reason] = [
      #tooManyOpenOrders({ open = 20; max = 20 }),
      #canisterCyclesLow({ balance = 1; min = 2 }),
      #burnCapExhausted({ burnedE8s = 5; capE8s = 5 }),
      #floatLow({ observedE8s = ?1; thresholdE8s = 2 }),
      #floatLow({ observedE8s = null; thresholdE8s = 2 }),
      #amountAboveMax({ usdCents = 3; maxUsdCents = 2 }),
    ];
    for (reason in reasons.values()) {
      assert Gate.reasonToText(reason) != "";
    };
    assert Gate.reasonToText(#floatLow({ observedE8s = null; thresholdE8s = 2 }))
      == "floatLow(never observed<2)";
  });
});

suite("the ceiling cannot be lowered under a live tier", func() {
  // `set_card_tiers` already refuses a tier above the ceiling. Without the inverse
  // check, lowering the ceiling left that tier SELLABLE BUT UNPAYABLE: the buyer
  // completes checkout and the webhook files a Type 1, and `attach_payment` then
  // refuses to rescue it until the ceiling goes back up — so the operator has to
  // connect a refused rescue to a config change made earlier.
  let tiers : [(Text, Nat)] = [("tier5", 500), ("tier50", 5_000)];

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
    assert Gate.validateConfig({ config with maxPurchaseUsdCents = 1 }, []) == #ok;
  });

  test("the error carries what the operator needs to fix it", func() {
    switch (Gate.validateConfig({ config with maxPurchaseUsdCents = 100 }, tiers)) {
      case (#err(e)) {
        let text = Gate.configErrorToText(e);
        assert Text.contains(text, #text "tier5");
      };
      case (#ok) assert false;
    };
  });
});
