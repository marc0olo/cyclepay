import { test; suite } "mo:test";
import Treasury "../src/backend/Treasury";

// Unit suite for §5.3: rolling burn-cap window math, the pre-gate decision
// (cap before float, exact boundaries), the AwaitingTreasury max-wait, the
// manual override, and the low-float soft-gate signal.

let hour : Int = 60 * 60 * 1_000_000_000;

// A config with the cap armed — defaults keep it 0 (fail-closed).
func armedConfig() : Treasury.Config {
  {
    burnCapE8s = 1_000;
    burnWindowNs = 24 * hour;
    maxHoldNs = 72 * hour;
    alertAfterNs = 2 * hour;
    lowFloatThresholdE8s = 500;
  };
};

suite("config", func() {
  test("default fails closed: cap 0, alert disarmed, valid otherwise", func() {
    let config = Treasury.defaultConfig();
    assert config.burnCapE8s == 0;
    assert config.lowFloatThresholdE8s == 0;
    assert Treasury.validateConfig(config) == #ok;
  });

  test("rejects non-positive window and max hold", func() {
    let config = armedConfig();
    assert Treasury.validateConfig({ config with burnWindowNs = 0 }) == #err(#nonPositiveBurnWindow);
    assert Treasury.validateConfig({ config with burnWindowNs = -1 }) == #err(#nonPositiveBurnWindow);
    assert Treasury.validateConfig({ config with maxHoldNs = 0 }) == #err(#nonPositiveMaxHold);
    assert Treasury.validateConfig(config) == #ok;
  });
});

suite("burn window math", func() {
  test("empty ledger sums to zero", func() {
    let ledger = Treasury.emptyLedger();
    assert Treasury.burnedInWindow(ledger, 24 * hour, 1_000_000) == 0;
  });

  test("in-window burns sum", func() {
    let ledger = Treasury.emptyLedger();
    Treasury.recordBurn(ledger, 24 * hour, 100, 0);
    Treasury.recordBurn(ledger, 24 * hour, 250, hour);
    assert Treasury.burnedInWindow(ledger, 24 * hour, 2 * hour) == 350;
  });

  test("burn exactly window-old is out, 1ns younger is in", func() {
    let ledger = Treasury.emptyLedger();
    Treasury.recordBurn(ledger, 24 * hour, 100, 0);
    Treasury.recordBurn(ledger, 24 * hour, 7, 1);
    // at t = 24h the t=0 burn has age == window -> out (house convention)
    assert Treasury.burnedInWindow(ledger, 24 * hour, 24 * hour) == 7;
    // 1 ns earlier both are still in
    assert Treasury.burnedInWindow(ledger, 24 * hour, 24 * hour - 1) == 107;
  });

  test("recordBurn prunes aged-out entries from the front", func() {
    let ledger = Treasury.emptyLedger();
    Treasury.recordBurn(ledger, 24 * hour, 100, 0);
    Treasury.recordBurn(ledger, 24 * hour, 200, hour);
    assert Treasury.size(ledger) == 2;
    // the t=0 entry is 24.5h old here and drops; t=1h (23.5h old) survives
    Treasury.recordBurn(ledger, 24 * hour, 300, 24 * hour + hour / 2);
    assert Treasury.size(ledger) == 2;
    assert Treasury.burnedInWindow(ledger, 24 * hour, 24 * hour + hour / 2) == 500;
  });

  test("manual override clears the window", func() {
    let ledger = Treasury.emptyLedger();
    Treasury.recordBurn(ledger, 24 * hour, 900, 0);
    Treasury.reset(ledger);
    assert Treasury.size(ledger) == 0;
    assert Treasury.burnedInWindow(ledger, 24 * hour, 0) == 0;
  });
});

suite("pre-gate (§5.3)", func() {
  test("cap 0 (the default) holds even with a full float", func() {
    let ledger = Treasury.emptyLedger();
    let config = Treasury.defaultConfig();
    switch (Treasury.gate(ledger, config, 1_000_000_000, 1, 10, 0)) {
      case (#hold(#burnCapReached({ burnedE8s = 0; capE8s = 0 }))) {};
      case (_) assert false;
    };
  });

  test("reaching the cap exactly proceeds; one e8s over holds", func() {
    let ledger = Treasury.emptyLedger();
    let config = armedConfig(); // cap 1_000
    Treasury.recordBurn(ledger, config.burnWindowNs, 600, 0);
    assert Treasury.gate(ledger, config, 1_000_000, 400, 10, 0) == #proceed;
    switch (Treasury.gate(ledger, config, 1_000_000, 401, 10, 0)) {
      case (#hold(#burnCapReached({ burnedE8s = 600; capE8s = 1_000 }))) {};
      case (_) assert false;
    };
  });

  test("float must cover amount + transfer fee, exactly is enough", func() {
    let ledger = Treasury.emptyLedger();
    let config = armedConfig();
    assert Treasury.gate(ledger, config, 410, 400, 10, 0) == #proceed;
    switch (Treasury.gate(ledger, config, 409, 400, 10, 0)) {
      case (#hold(#floatShort({ floatE8s = 409; neededE8s = 410 }))) {};
      case (_) assert false;
    };
  });

  test("burn cap is checked before float (blast-radius bound wins)", func() {
    let ledger = Treasury.emptyLedger();
    let config = armedConfig();
    // both violated: cap exceeded AND float short -> the cap reason reports
    switch (Treasury.gate(ledger, config, 0, 2_000, 10, 0)) {
      case (#hold(#burnCapReached(_))) {};
      case (_) assert false;
    };
  });

  test("window rolls: consumed cap frees up after the window passes", func() {
    let ledger = Treasury.emptyLedger();
    let config = armedConfig(); // cap 1_000, window 24h
    Treasury.recordBurn(ledger, config.burnWindowNs, 1_000, 0);
    switch (Treasury.gate(ledger, config, 1_000_000, 1, 10, hour)) {
      case (#hold(#burnCapReached(_))) {};
      case (_) assert false;
    };
    // at t = 24h the burn ages out -> "resets next window" with no timer
    assert Treasury.gate(ledger, config, 1_000_000, 1_000, 10, 24 * hour) == #proceed;
  });
});

suite("hold max-wait (§5.3)", func() {
  test("escalates at exactly the bound, retries 1ns earlier", func() {
    let maxHold = 72 * hour;
    assert Treasury.holdStage(0, maxHold, maxHold) == #escalate;
    assert Treasury.holdStage(0, maxHold - 1, maxHold) == #retry;
    assert Treasury.holdStage(0, 0, maxHold) == #retry;
  });
});

suite("low-float signal (§5.3 soft gate)", func() {
  test("threshold 0 disarms the signal entirely", func() {
    let config = Treasury.defaultConfig();
    assert not Treasury.isLowFloat(config, 0);
    assert not Treasury.lowFloatSignal(config, null);
    assert not Treasury.lowFloatSignal(config, ?{ e8s = 0; atNs = 0 });
  });

  test("below threshold is low, exactly at threshold is not", func() {
    let config = armedConfig(); // threshold 500
    assert Treasury.isLowFloat(config, 499);
    assert not Treasury.isLowFloat(config, 500);
    assert Treasury.lowFloatSignal(config, ?{ e8s = 499; atNs = 0 });
    assert not Treasury.lowFloatSignal(config, ?{ e8s = 500; atNs = 0 });
  });

  test("armed threshold with no observation yet reads low (conservative)", func() {
    assert Treasury.lowFloatSignal(armedConfig(), null);
  });
});

suite("waitStage — the §5.3 timeline for money in, nothing delivered", func() {
  // Three outcomes, not two. Splitting the alert from the terminal bound is what
  // lets the operator be told early WITHOUT giving up on the sale early.
  test("quiet retry before the alert threshold", func() {
    assert Treasury.waitStage(0, 1 * hour, armedConfig()) == #retry;
    assert Treasury.waitStage(0, 2 * hour - 1, armedConfig()) == #retry;
  });

  test("alert from alertAfterNs, and keep retrying — not terminal", func() {
    assert Treasury.waitStage(0, 2 * hour, armedConfig()) == #alert;
    assert Treasury.waitStage(0, 71 * hour, armedConfig()) == #alert;
  });

  test("terminate at maxHoldNs — the spec's max-wait bound", func() {
    // A buyer left waiting files a chargeback, which costs the operator more
    // than a refund; and by 72h the cause is structural, not transient.
    assert Treasury.waitStage(0, 72 * hour, armedConfig()) == #terminate;
    assert Treasury.waitStage(0, 1_000 * hour, armedConfig()) == #terminate;
  });

  test("the default config alerts long before it terminates", func() {
    let d = Treasury.defaultConfig();
    assert d.alertAfterNs < d.maxHoldNs;
    // The alert must leave real room to act, not fire just before the deadline.
    assert d.alertAfterNs * 4 < d.maxHoldNs;
  });

  test("an alert at or after the terminal bound is refused as config", func() {
    // Alerting after the decision is already taken is useless.
    assert Treasury.validateConfig({ armedConfig() with alertAfterNs = armedConfig().maxHoldNs })
      == #err(#alertNotBeforeMaxHold({ alertAfterNs = armedConfig().maxHoldNs; maxHoldNs = armedConfig().maxHoldNs }));
    assert Treasury.validateConfig({ armedConfig() with alertAfterNs = 0 }) == #err(#nonPositiveAlertAfter);
  });

  test("a clock that has not advanced never alerts", func() {
    assert Treasury.waitStage(5 * hour, 5 * hour, armedConfig()) == #retry;
  });
});
