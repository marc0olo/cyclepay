import { test; suite } "mo:test";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import CkUsdc "../src/backend/rails/CkUsdc";
import Types "../src/backend/Types";

// Unit suite for the §6.2 ck-USDC rail's pure half: amount/config
// validation, deterministic pull-intent construction (write-intent-before-
// call, money-IN edition), transfer_from result interpretation (incl. the
// dedup-first definite-rejection rule), the pull journal, and the claimStage
// resume decision.

let window = CkUsdc.ledgerDedupWindowNs;

let gateway = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
let user = Principal.fromText("ryjl3-tyaaa-aaaa" # "a-aaaba-cai");
let orderId = "aabbccddeeff00112233445566778899";

func intentAt(nowNs : Int) : CkUsdc.PullIntent {
  CkUsdc.buildPullIntent(user, orderId, 5_000_000, 10_000, nowNs);
};

func entryWith(intent : CkUsdc.PullIntent, blockIndex : ?Nat, escalatedAtNs : ?Int) : CkUsdc.PullEntry {
  {
    orderId;
    intent;
    blockIndex;
    escalatedAtNs;
    createdAtNs = 1_000;
    updatedAtNs = 1_000;
  };
};

suite("constants pinned to the ck-USDC ledger", func() {
  test("mainnet ledger id", func() {
    assert CkUsdc.ledgerId == "xevnm-gaaaa-aaaar-qafnq-cai";
  });

  test("6 decimals and 1:1 USD peg make one cent exactly 10^4 units", func() {
    assert CkUsdc.unitsPerCent == 10_000;
  });

  test("ledger dedup window is 24h (ns), matching the ICP ledger's", func() {
    assert CkUsdc.ledgerDedupWindowNs == 86_400_000_000_000;
  });
});

suite("unitsForCents (§3 exact pricing — no forex on the money-in side)", func() {
  test("$5.00 tier-equivalent = 5 ck-USDC = 5_000_000 units", func() {
    assert CkUsdc.unitsForCents(500) == 5_000_000;
  });

  test("one cent = 10_000 units; zero = zero", func() {
    assert CkUsdc.unitsForCents(1) == 10_000;
    assert CkUsdc.unitsForCents(0) == 0;
  });
});

suite("defaultConfig fails closed", func() {
  test("rail disabled (maxUsdCents = 0), zero fee formula, real ledger fee", func() {
    let config = CkUsdc.defaultConfig();
    assert config.maxUsdCents == 0;
    assert config.minUsdCents == 0;
    assert config.feeBps == 0;
    assert config.feeFixedCents == 0;
    assert config.ledgerFeeUnits == 10_000;
  });

  test("default config rejects every amount as #railDisabled", func() {
    assert CkUsdc.validateAmount(CkUsdc.defaultConfig(), 500) == #err(#railDisabled);
    assert CkUsdc.validateAmount(CkUsdc.defaultConfig(), 1) == #err(#railDisabled);
  });
});

suite("validateConfig", func() {
  func config(min : Nat, max : Nat, bps : Nat) : CkUsdc.Config {
    { minUsdCents = min; maxUsdCents = max; feeBps = bps; feeFixedCents = 0; ledgerFeeUnits = 10_000 };
  };

  test("fee boundary: 9_999 bps legal, 10_000 rejected", func() {
    assert CkUsdc.validateConfig(config(0, 1_000, 9_999)) == #ok;
    assert CkUsdc.validateConfig(config(0, 1_000, 10_000)) == #err(#feeBpsTooHigh);
  });

  test("min > max rejected when the rail is enabled", func() {
    assert CkUsdc.validateConfig(config(1_001, 1_000, 0)) == #err(#minAboveMax);
    assert CkUsdc.validateConfig(config(1_000, 1_000, 0)) == #ok;
  });

  test("disabled rail (max = 0) tolerates any min", func() {
    assert CkUsdc.validateConfig(config(5_000, 0, 0)) == #ok;
  });
});

suite("validateAmount boundaries", func() {
  let config : CkUsdc.Config = {
    minUsdCents = 100;
    maxUsdCents = 10_000;
    feeBps = 0;
    feeFixedCents = 0;
    ledgerFeeUnits = 10_000;
  };

  test("exactly min and exactly max accepted", func() {
    assert CkUsdc.validateAmount(config, 100) == #ok;
    assert CkUsdc.validateAmount(config, 10_000) == #ok;
  });

  test("min − 1 and max + 1 rejected, carrying the bound", func() {
    assert CkUsdc.validateAmount(config, 99) == #err(#belowMinimum(100));
    assert CkUsdc.validateAmount(config, 10_001) == #err(#aboveMaximum(10_000));
  });

  test("zero is #zeroAmount even when min is 0", func() {
    let zeroMin = { config with minUsdCents = 0 };
    assert CkUsdc.validateAmount(zeroMin, 0) == #err(#zeroAmount);
    assert CkUsdc.validateAmount(zeroMin, 1) == #ok;
  });
});

suite("buildPullIntent + transferFromArgs (§5.1 write-intent, money-IN)", func() {
  test("memo is the order ID's UTF-8 — exactly the 32-byte ICRC-1 bound", func() {
    let intent = intentAt(1_700_000_000_000_000_000);
    assert intent.memo == orderId.encodeUtf8();
    assert intent.memo.size() == 32;
  });

  test("intent freezes everything the ledger dedups on", func() {
    let intent = intentAt(1_700_000_000_000_000_000);
    assert intent.createdAtTimeNs == Nat64.fromIntWrap(1_700_000_000_000_000_000);
    assert intent.amountUnits == 5_000_000;
    assert intent.feeUnits == 10_000;
    assert intent.fromOwner == user;
  });

  test("wire form: from = owner's main account, to = gateway, fee/memo/time set", func() {
    let intent = intentAt(42);
    let args = CkUsdc.transferFromArgs(gateway, intent);
    assert args.spender_subaccount == null;
    assert args.from == { owner = user; subaccount = null };
    assert args.to == { owner = gateway; subaccount = null };
    assert args.amount == 5_000_000;
    assert args.fee == ?10_000;
    assert args.memo == ?orderId.encodeUtf8();
    assert args.created_at_time == ?Nat64.fromIntWrap(42);
  });

  test("replay is bit-identical by construction (pure projection)", func() {
    let intent = intentAt(42);
    assert CkUsdc.transferFromArgs(gateway, intent) == CkUsdc.transferFromArgs(gateway, intent);
    assert intentAt(42) == intentAt(42);
  });
});

suite("interpretPull (dedup-first definite-rejection rule)", func() {
  test("#Ok and #Duplicate both recover the block — the replay payoff", func() {
    assert CkUsdc.interpretPull(#Ok(77)) == #pulled(77);
    assert CkUsdc.interpretPull(#Err(#Duplicate({ duplicate_of = 77 }))) == #pulled(77);
  });

  test("amount-short mismatch (§6.2): InsufficientAllowance drops the intent", func() {
    assert CkUsdc.interpretPull(#Err(#InsufficientAllowance({ allowance = 1_000 }))) == #drop(#insufficientAllowance({ allowance = 1_000 }));
  });

  test("InsufficientFunds and BadFee are definite rejections too", func() {
    assert CkUsdc.interpretPull(#Err(#InsufficientFunds({ balance = 3 }))) == #drop(#insufficientFunds({ balance = 3 }));
    assert CkUsdc.interpretPull(#Err(#BadFee({ expected_fee = 20_000 }))) == #drop(#badFee({ expectedFee = 20_000 }));
  });

  test("BadBurn maps to a generic definite rejection", func() {
    switch (CkUsdc.interpretPull(#Err(#BadBurn({ min_burn_amount = 1 })))) {
      case (#drop(#rejected(_))) {};
      case (_) assert false;
    };
  });

  test("transient errors keep the intent for replay", func() {
    switch (CkUsdc.interpretPull(#Err(#TemporarilyUnavailable))) {
      case (#retry(_)) {};
      case (_) assert false;
    };
    switch (CkUsdc.interpretPull(#Err(#CreatedInFuture({ ledger_time = 9 })))) {
      case (#retry(_)) {};
      case (_) assert false;
    };
    switch (CkUsdc.interpretPull(#Err(#GenericError({ error_code = 1; message = "x" })))) {
      case (#retry(_)) {};
      case (_) assert false;
    };
  });

  test("TooOld is the stale-intent uncertainty — never a drop, never a retry", func() {
    switch (CkUsdc.interpretPull(#Err(#TooOld))) {
      case (#uncertain(_)) {};
      case (_) assert false;
    };
  });
});

suite("pull journal", func() {
  test("openPull persists the intent with no block and no escalation", func() {
    let journal = CkUsdc.emptyPullJournal();
    let entry = CkUsdc.openPull(journal, orderId, intentAt(42), 1_000);
    assert journal.get(orderId) == ?entry;
    assert entry.blockIndex == null;
    assert entry.escalatedAtNs == null;
    assert entry.createdAtNs == 1_000;
  });

  test("recordPullBlock / markEscalated patch in place; missing id is a no-op", func() {
    let journal = CkUsdc.emptyPullJournal();
    ignore CkUsdc.openPull(journal, orderId, intentAt(42), 1_000);
    CkUsdc.recordPullBlock(journal, orderId, 77, 2_000);
    CkUsdc.markEscalated(journal, orderId, 3_000);
    let ?entry = journal.get(orderId) else { assert false; return };
    assert entry.blockIndex == ?77;
    assert entry.escalatedAtNs == ?3_000;
    assert entry.updatedAtNs == 3_000;
    assert entry.intent == intentAt(42); // the intent itself never mutates
    CkUsdc.recordPullBlock(journal, "missing", 1, 4_000);
    CkUsdc.markEscalated(journal, "missing", 4_000);
    assert journal.size() == 1;
  });

  test("dropPull removes the entry so the next claim builds fresh", func() {
    let journal = CkUsdc.emptyPullJournal();
    ignore CkUsdc.openPull(journal, orderId, intentAt(42), 1_000);
    CkUsdc.dropPull(journal, orderId);
    assert journal.get(orderId) == null;
  });
});

suite("claimStage (the §5.1-style resume decision, money-IN)", func() {
  test("only #created and #expired are claimable — pinned over all 8 states", func() {
    let claimable : [Types.OrderStatus] = [#created, #expired];
    let blocked : [Types.OrderStatus] = [#paid, #minting, #icpAtCmc, #delivered, #awaitingTreasury, #errorQueue];
    for (status in claimable.values()) {
      assert CkUsdc.claimStage(status, null, 0, window) == #fresh;
    };
    for (status in blocked.values()) {
      assert CkUsdc.claimStage(status, null, 0, window) == #notClaimable;
      // status gates before the journal: even a replayable entry is inert
      assert CkUsdc.claimStage(status, ?entryWith(intentAt(0), null, null), 1, window) == #notClaimable;
    };
  });

  test("fresh intent replays — identical args, first attempt and recovery alike", func() {
    let intent = intentAt(1_000);
    assert CkUsdc.claimStage(#created, ?entryWith(intent, null, null), 1_001, window) == #replay(intent);
  });

  test("staleness boundary: window − 1 ns replays, exactly window escalates", func() {
    let intent = intentAt(1_000);
    assert CkUsdc.claimStage(#created, ?entryWith(intent, null, null), 1_000 + window - 1, window) == #replay(intent);
    assert CkUsdc.claimStage(#created, ?entryWith(intent, null, null), 1_000 + window, window) == #escalate(intent);
  });

  test("an escalated entry answers #alreadyEscalated — queued exactly once", func() {
    let intent = intentAt(1_000);
    assert CkUsdc.claimStage(#created, ?entryWith(intent, null, ?5_000), 1_000 + window, window) == #alreadyEscalated;
  });

  test("a recorded block heals via #recoverBlock, even past the window", func() {
    let intent = intentAt(1_000);
    assert CkUsdc.claimStage(#created, ?entryWith(intent, ?77, null), 1_000 + window * 2, window) == #recoverBlock(77);
    // block beats the escalation mark: money moved, credit it
    assert CkUsdc.claimStage(#created, ?entryWith(intent, ?77, ?5_000), 1_000 + window * 2, window) == #recoverBlock(77);
  });

  test("#expired with a fresh intent still replays (§4 expiry is advisory)", func() {
    let intent = intentAt(1_000);
    assert CkUsdc.claimStage(#expired, ?entryWith(intent, null, null), 1_001, window) == #replay(intent);
  });
});
