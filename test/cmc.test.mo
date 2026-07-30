import { test; suite } "mo:test";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Cmc "../src/backend/Cmc";
import Types "../src/backend/Types";

// Unit suite for the §5/§5.1 mint-pipeline pure half: e8s derivation off the
// CMC rate (staleness-guarded), deterministic intent construction (write-
// intent-before-call), ledger/CMC result interpretation, journal patching,
// and the stageOf resume/replay decision.
//
// Pinned vectors (subaccount layout, memo bytes, e8s math) were computed
// externally in python this iteration — the implementation is checked
// against the CMC's actual scheme, not against itself.

let window = Cmc.ledgerDedupWindowNs;
let maxRetries = 5;

func intentAt(nowNs : Int) : Types.TransferIntent {
  Cmc.buildIntent(Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"), 123_456, nowNs);
};

func entryWith(
  intent : ?Types.TransferIntent,
  blockIndex : ?Nat,
  cyclesMinted : ?Nat,
  retries : Nat,
) : Types.JournalEntry {
  {
    orderId = "aabbccddeeff00112233445566778899";
    status = #minting;
    destination = #canister(Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"));
    transferIntent = intent;
    blockIndex;
    cyclesMinted;
    retries;
    createdAtNs = 1_000;
    updatedAtNs = 1_000;
  };
};

suite("constants pinned to the CMC scheme", func() {
  test("TPUP memo = little-endian 0x50555054, zero-padded to 8 bytes", func() {
    assert Cmc.topUpMemo == Blob.fromArray([0x54, 0x50, 0x55, 0x50, 0, 0, 0, 0]);
  });

  test("ledger dedup window is 24h, CMC rate guard 15min (ns)", func() {
    assert Cmc.ledgerDedupWindowNs == 86_400_000_000_000;
    assert Cmc.cmcRateMaxAgeNs == 900_000_000_000;
  });
});

suite("topUpSubaccount (§5: length-prefixed principal, zero-padded to 32)", func() {
  test("pinned vector: ICP ledger principal (10-byte body)", func() {
    let sub = Cmc.topUpSubaccount(Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai"));
    assert sub == Blob.fromArray([
      10, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]);
  });

  test("pinned vector: rrkah-fqaaa-aaaaa-aaaaq-cai", func() {
    let sub = Cmc.topUpSubaccount(Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"));
    assert sub == Blob.fromArray([
      10, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]);
  });

  test("pinned vector: short principal (anonymous, 1-byte body)", func() {
    let sub = Cmc.topUpSubaccount(Principal.fromText("2vxsx-fae"));
    assert sub == Blob.fromArray([
      1, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]);
  });
});

suite("icpE8sForCycles (§5: one e8s mints xdr_permyriad_per_icp cycles)", func() {
  test("externally computed vectors, exact and ceiling", func() {
    // 3.5T cycles at 3.5 XDR/ICP = exactly 1 ICP
    assert Cmc.icpE8sForCycles(3_500_000_000_000, 35_000) == ?100_000_000;
    assert Cmc.icpE8sForCycles(1, 35_000) == ?1; // rounds up, never zero
    assert Cmc.icpE8sForCycles(35_001, 35_000) == ?2; // just past one e8s
    assert Cmc.icpE8sForCycles(70_000, 35_000) == ?2; // exact, no over-round
    assert Cmc.icpE8sForCycles(13_370_000_000_000, 41_234) == ?324_246_981;
    assert Cmc.icpE8sForCycles(999_999_999_999, 100_000) == ?10_000_000;
  });

  test("zero rate is a refusal, not a trap", func() {
    assert Cmc.icpE8sForCycles(1_000_000, 0) == null;
  });

  test("zero cycles needs zero e8s", func() {
    assert Cmc.icpE8sForCycles(0, 35_000) == ?0;
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

suite("buildIntent + transferArgs (§5.1 determinism)", func() {
  test("intent fields: CMC owner, gateway top-up subaccount, TPUP memo", func() {
    let gateway = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
    let intent = Cmc.buildIntent(gateway, 123_456, 42_000_000_000);
    assert intent.createdAtTimeNs == 42_000_000_000;
    assert intent.amountE8s == 123_456;
    assert intent.to.owner == Principal.fromText(Cmc.cmcId);
    assert intent.to.subaccount == ?Cmc.topUpSubaccount(gateway);
    assert intent.memo == Cmc.topUpMemo;
  });

  test("identical inputs build identical intents (replay = bit-identical)", func() {
    assert intentAt(42) == intentAt(42);
  });

  test("transferArgs is a pure projection of the stored intent", func() {
    let intent = intentAt(42_000_000_000);
    let args = Cmc.transferArgs(intent);
    assert args.from_subaccount == null;
    assert args.to == intent.to;
    assert args.amount == intent.amountE8s;
    assert args.fee == ?Cmc.icpTransferFeeE8s;
    assert args.memo == ?intent.memo;
    assert args.created_at_time == ?intent.createdAtTimeNs;
    assert Cmc.transferArgs(intent) == args; // deterministic
  });
});

suite("interpretTransfer (§5.1)", func() {
  test("Ok and Duplicate both recover the block index — the replay payoff", func() {
    assert Cmc.interpretTransfer(#Ok(7)) == #blockIndex(7);
    assert Cmc.interpretTransfer(#Err(#Duplicate({ duplicate_of = 9 }))) == #blockIndex(9);
  });

  test("nothing-recorded errors are retriable with identical args", func() {
    func retriable(r : Cmc.TransferResult) : Bool {
      switch (Cmc.interpretTransfer(r)) {
        case (#retriable(_)) true;
        case (_) false;
      };
    };
    assert retriable(#Err(#TemporarilyUnavailable));
    assert retriable(#Err(#InsufficientFunds({ balance = 5 })));
    assert retriable(#Err(#CreatedInFuture({ ledger_time = 1 })));
    assert retriable(#Err(#GenericError({ error_code = 1; message = "x" })));
  });

  test("replay-can-never-succeed errors escalate", func() {
    func escalates(r : Cmc.TransferResult) : Bool {
      switch (Cmc.interpretTransfer(r)) {
        case (#escalate(_)) true;
        case (_) false;
      };
    };
    assert escalates(#Err(#TooOld));
    assert escalates(#Err(#BadFee({ expected_fee = 10_000 })));
    assert escalates(#Err(#BadBurn({ min_burn_amount = 1 })));
  });
});

suite("interpretNotify (§5)", func() {
  test("Ok carries the minted cycles", func() {
    assert Cmc.interpretNotify(#Ok(5_000_000_000)) == #minted(5_000_000_000);
  });

  test("Processing and Other are retriable (notify is idempotent, §5.2)", func() {
    func retriable(r : Cmc.NotifyTopUpResult) : Bool {
      switch (Cmc.interpretNotify(r)) {
        case (#retriable(_)) true;
        case (_) false;
      };
    };
    assert retriable(#Err(#Processing));
    assert retriable(#Err(#Other({ error_code = 1; error_message = "x" })));
  });

  test("Refunded and rejections escalate", func() {
    func escalates(r : Cmc.NotifyTopUpResult) : Bool {
      switch (Cmc.interpretNotify(r)) {
        case (#escalate(_)) true;
        case (_) false;
      };
    };
    assert escalates(#Err(#Refunded({ reason = "memo"; block_index = null })));
    assert escalates(#Err(#InvalidTransaction("bad block")));
    assert escalates(#Err(#TransactionTooOld(1)));
  });
});

suite("journal", func() {
  func order() : Types.Order {
    {
      id = "aabbccddeeff00112233445566778899";
      owner = #ii(Principal.fromText("2ibo7-dia"));
      rail = #card;
      destination = #canister(Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"));
      lockedCycles = 1_000_000_000_000;
      pricing = {
  usdCents = 500;
  usdPerIcpMicros = 4_550_000; // $4.55 per ICP
  xdrPermyriadPerIcp = 35_000; // 3.5 XDR per ICP
  rateStandardDeviation = 0;
  rateReceivedRates = 5;
  rateQueriedSources = 5;
  feeBps = 290;
  feeFixedCents = 30;
};
      status = #paid;
      createdAtNs = 1;
      updatedAtNs = 2;
    };
  };

  test("openEntry persists the intent at #minting with zero retries", func() {
    let journal = Cmc.emptyJournal();
    let intent = intentAt(42);
    let entry = Cmc.openEntry(journal, order(), intent, 100);
    assert journal.get(order().id) == ?entry;
    assert entry.status == #minting;
    assert entry.transferIntent == ?intent;
    assert entry.blockIndex == null;
    assert entry.cyclesMinted == null;
    assert entry.retries == 0;
    assert entry.createdAtNs == 100 and entry.updatedAtNs == 100;
  });

  test("patch updates only the requested fields and bumps updatedAt", func() {
    let journal = Cmc.emptyJournal();
    let entry = Cmc.openEntry(journal, order(), intentAt(42), 100);
    Cmc.patch(journal, entry.orderId, { status = ?#icpAtCmc; blockIndex = ?77; cyclesMinted = null; bumpRetries = false }, 200);
    let ?after = journal.get(entry.orderId) else { assert false; return };
    assert after.status == #icpAtCmc;
    assert after.blockIndex == ?77;
    assert after.cyclesMinted == null;
    assert after.retries == 0;
    assert after.transferIntent == entry.transferIntent; // untouched
    assert after.updatedAtNs == 200 and after.createdAtNs == 100;
  });

  test("bumpRetries accumulates", func() {
    let journal = Cmc.emptyJournal();
    let entry = Cmc.openEntry(journal, order(), intentAt(42), 100);
    Cmc.patch(journal, entry.orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, 200);
    Cmc.patch(journal, entry.orderId, { status = null; blockIndex = null; cyclesMinted = null; bumpRetries = true }, 300);
    let ?after = journal.get(entry.orderId) else { assert false; return };
    assert after.retries == 2;
  });

  test("patch on a missing id is a no-op, never a trap", func() {
    let journal = Cmc.emptyJournal();
    Cmc.patch(journal, "nope", { status = ?#delivered; blockIndex = null; cyclesMinted = null; bumpRetries = true }, 200);
    assert journal.get("nope") == null;
  });
});

suite("stageOf (§5.1/§5.2 resume decision)", func() {
  test("#paid begins a fresh mint", func() {
    assert Cmc.stageOf(#paid, null, 0, window, maxRetries) == #begin;
  });

  test("#minting with a fresh intent and no block replays the identical transfer", func() {
    let intent = intentAt(1_000);
    let entry = entryWith(?intent, null, null, 0);
    assert Cmc.stageOf(#minting, ?entry, 1_000 + window - 1, window, maxRetries) == #replayTransfer(intent);
  });

  test("§5.1 boundary: at exactly the dedup window the intent is stale — never auto-replayed", func() {
    let intent = intentAt(1_000);
    let entry = entryWith(?intent, null, null, 0);
    assert Cmc.stageOf(#minting, ?entry, 1_000 + window, window, maxRetries) == #escalate(#staleIntent);
  });

  test("#minting with retries exhausted escalates before replaying", func() {
    let entry = entryWith(?intentAt(1_000), null, null, maxRetries);
    assert Cmc.stageOf(#minting, ?entry, 1_001, window, maxRetries) == #escalate(#retriesExhausted);
  });

  test("#minting with a recorded block heals forward to notify", func() {
    let entry = entryWith(?intentAt(1_000), ?42, null, 0);
    assert Cmc.stageOf(#minting, ?entry, 1_001, window, maxRetries) == #notifyCmc(42);
  });

  test("#minting without a journal entry or intent escalates", func() {
    assert Cmc.stageOf(#minting, null, 0, window, maxRetries) == #escalate(#missingJournal);
    let entry = entryWith(null, null, null, 0);
    assert Cmc.stageOf(#minting, ?entry, 0, window, maxRetries) == #escalate(#missingJournal);
  });

  test("#icpAtCmc with a block and no pre-forward marker notifies", func() {
    let entry = entryWith(?intentAt(1_000), ?42, null, 0);
    assert Cmc.stageOf(#icpAtCmc, ?entry, 1_001, window, maxRetries) == #notifyCmc(42);
  });

  test("#icpAtCmc with the pre-forward marker set is an ambiguous forward — at-most-once", func() {
    let entry = entryWith(?intentAt(1_000), ?42, ?1_000_000_000_000, 0);
    assert Cmc.stageOf(#icpAtCmc, ?entry, 1_001, window, maxRetries) == #escalate(#ambiguousForward);
  });

  test("#icpAtCmc ambiguity wins over retries exhaustion", func() {
    let entry = entryWith(?intentAt(1_000), ?42, ?1, maxRetries);
    assert Cmc.stageOf(#icpAtCmc, ?entry, 1_001, window, maxRetries) == #escalate(#ambiguousForward);
  });

  test("#icpAtCmc with retries exhausted escalates", func() {
    let entry = entryWith(?intentAt(1_000), ?42, null, maxRetries);
    assert Cmc.stageOf(#icpAtCmc, ?entry, 1_001, window, maxRetries) == #escalate(#retriesExhausted);
  });

  test("#icpAtCmc without journal/block escalates", func() {
    assert Cmc.stageOf(#icpAtCmc, null, 0, window, maxRetries) == #escalate(#missingJournal);
    let entry = entryWith(?intentAt(1_000), null, null, 0);
    assert Cmc.stageOf(#icpAtCmc, ?entry, 1_001, window, maxRetries) == #escalate(#missingJournal);
  });

  test("no money-out work for the remaining statuses", func() {
    for (status in [#created, #expired, #awaitingTreasury, #delivered, #errorQueue].values()) {
      assert Cmc.stageOf(status, null, 0, window, maxRetries) == #none;
    };
  });
});
