import { test; suite } "mo:test";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Cmc "../src/backend/Cmc";
import Delivery "../src/backend/Delivery";
import Types "../src/backend/Types";

// Unit suite for the §5/§5.1 mint-pipeline pure half: e8s derivation off the
// CMC rate (staleness-guarded), deterministic intent construction (write-
// intent-before-call), ledger/CMC result interpretation, journal patching,
// and the stageOf resume/replay decision.
//
// Pinned vectors (subaccount layout, memo bytes, e8s math) were computed
// externally in python this iteration — the implementation is checked
// against the CMC's actual scheme, not against itself.

let window = Delivery.ledgerDedupWindowNs;

func intentAt(nowNs : Int) : Types.TransferIntent {
  Delivery.buildDeliveryIntent(
    "aabbccddeeff00112233445566778899",
    { owner = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"); subaccount = null },
    123_456,
    nowNs,
  );
};

func entryWith(
  intent : ?Types.TransferIntent,
  blockIndex : ?Nat,
  cyclesDelivered : ?Nat,
  retries : Nat,
) : Types.JournalEntry {
  {
    orderId = "aabbccddeeff00112233445566778899";
    // ⚠️ `#paid` since #36: the mint statuses are deleted, and `#paid` is where a
    // journal entry is opened on the one money-out path.
    status = #paid;
    destination = #cyclesLedgerAccount({ owner = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"); subaccount = null });
    transferIntent = intent;
    blockIndex;
    cyclesDelivered;
    retries;
    createdAtNs = 1_000;
    updatedAtNs = 1_000;
  };
};






suite("delivery: the fee is RECOVERABLE from the intent (#30 PR-A)", func() {
  // ⚠️ This is what replaced an unverified claim about the cycles ledger's dedup
  // key. The replay path must send the fee the intent was BUILT with, or a
  // transfer that executed and lost its response could be replayed as a distinct
  // transaction and pay the buyer twice. Rather than checking what the ledger
  // keys on, the fee is derived: `deliverableCycles` subtracts it, so
  // `locked - amount` gives it back exactly.
  //
  // This suite is that arithmetic, pinned. If `deliverableCycles` ever stops
  // being a plain subtraction, the replay path silently starts sending a wrong
  // fee — and these are the assertions that would catch it.
  test("locked - amount recovers the exact fee, across magnitudes", func() {
    for ((locked, fee) in ([
      (3_500_000_000_000, 100_000_000), // the §3 vector at today's fee
      (7_238_461_538_461, 100_000_000), // a $10 order
      (1_000, 1),
      (2, 1), // the tightest non-degenerate case
    ] : [(Nat, Nat)]).values()) {
      let ?amount = Delivery.deliverableCycles(locked, fee) else { assert false; return };
      assert amount == locked - fee;
      // THE INVARIANT the replay path depends on.
      assert locked - amount == fee;
    };
  });

  test("a fee that swallows the order yields no amount, so nothing is derivable", func() {
    // Guarded rather than trapped: the replay path escalates on an
    // unrecoverable fee instead of guessing one on a money path.
    assert Delivery.deliverableCycles(100, 100) == null;
    assert Delivery.deliverableCycles(100, 101) == null;
    assert Delivery.deliverableCycles(0, 1) == null;
  });

  test("the intent carries the amount, not the fee — so the args are reproducible", func() {
    // `TransferIntent` has no fee field on purpose: a second copy of the fee
    // could disagree with the amount, and then neither would be authoritative.
    let intent = Delivery.buildDeliveryIntent(
      "aabbccddeeff00112233445566778899",
      { owner = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"); subaccount = null },
      3_499_900_000_000,
      42,
    );
    assert intent.amountCycles == 3_499_900_000_000;
    // Two projections of the same intent at the same fee are identical — which is
    // the whole meaning of "byte-identical replay".
    assert Delivery.deliveryArgs(intent, 100_000_000) == Delivery.deliveryArgs(intent, 100_000_000);
    // And a different fee produces DIFFERENT args, which is exactly why the
    // caller must not re-read it.
    assert Delivery.deliveryArgs(intent, 100_000_000) != Delivery.deliveryArgs(intent, 200_000_000);
  });
});

suite("interpretTransfer (§5.1)", func() {
  test("Ok and Duplicate both recover the block index — the replay payoff", func() {
    // ⚠️ These are DISTINCT outcomes since #30 PR-B, and the reserve floor is why:
    // a fresh block means this call debited the ledger, a duplicate means an earlier
    // one did. The floor is decremented when a transfer is issued, so a duplicate
    // must credit that decrement back while a fresh block must keep it. Collapsing
    // them refunds real debits (optimistic) or under-counts healed replays.
    assert Delivery.interpretTransfer(#Ok(7)) == #delivered(7);
    assert Delivery.interpretTransfer(#Err(#Duplicate({ duplicate_of = 9 }))) == #deduplicated(9);
  });

  test("nothing-recorded errors are retriable with identical args", func() {
    func retriable(r : Delivery.TransferResult) : Bool {
      switch (Delivery.interpretTransfer(r)) {
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
    func escalates(r : Delivery.TransferResult) : Bool {
      switch (Delivery.interpretTransfer(r)) {
        case (#escalate(_)) true;
        case (_) false;
      };
    };
    assert escalates(#Err(#TooOld));
    assert escalates(#Err(#BadBurn({ min_burn_amount = 1 })));
  });

  test("a fee change is its OWN outcome, not an escalation", func() {
    // #30 split `#BadFee` out of `#escalate` because the two callers answer it
    // differently and both are right: the ICP mint path escalates (a
    // protocol-wide fee change is a protocol event), while reserve delivery
    // re-reads `icrc1_fee` and retries, so a risen fee is absorbed by the
    // reserve rather than shorting the buyer. Folding them back together forces
    // one of the two to be wrong.
    switch (Delivery.interpretTransfer(#Err(#BadFee({ expected_fee = 200_000_000 })))) {
      case (#badFee(expected)) assert expected == 200_000_000;
      case (_) assert false;
    };
  });
});


suite("journal", func() {
  func order() : Types.Order {
    {
      id = "aabbccddeeff00112233445566778899";
      owner = #ii(Principal.fromText("2ibo7-dia"));
      rail = #card;
      destination = #cyclesLedgerAccount({ owner = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai"); subaccount = null });
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
  // Deliberately EARLIER than any order's createdAtNs in these fixtures: the
  // rate pair is read before the order exists, which is the whole reason #34
  // records it separately.
  ratesFetchedAtNs = 1;
};
      paidUsdCents = null;
      expiredBy = null;
      expiresAtNs = null;
      stripeSessionId = null;
      stripeSessionUrl = null;
      status = #paid;
      createdAtNs = 1;
      updatedAtNs = 2;
    };
  };

  test("⚠️ openEntry records the ORDER's status, not a hardcoded #minting", func() {
    // This assertion is inverted from what it was, and the inversion IS the bug fix.
    // `openEntry` wrote `status = #minting` unconditionally — a leftover from when
    // money-out meant the ICP mint path — and nothing read the field back, so the lie
    // was free. The legacy caller transitions the order to `#minting` before opening
    // the entry, so the two agreed there by coincidence.
    //
    // ⚠️ **Then #30 PR-B started reading it.** `Main.unsettledDeliveries` tests this
    // field for `#paid` to decide whether a reserve observation may be adopted, so a
    // hardcoded `#minting` made the predicate match NOTHING: the quiet window was
    // always satisfied, and a reconcile could overwrite the floor while a transfer it
    // could not see was still in flight. That is the exact failure the quiet window
    // exists to prevent, reintroduced by a stale literal in a different file.
    //
    // So this test is the coupling's guard: the fixture order is `#paid`, which is
    // what a delivery entry must record.
    let journal = Delivery.emptyJournal();
    let intent = intentAt(42);
    let entry = Delivery.openEntry(journal, order(), intent, 100);
    assert journal.get(order().id) == ?entry;
    assert entry.status == #paid;
    assert entry.status == order().status;
    assert entry.transferIntent == ?intent;
    assert entry.blockIndex == null;
    assert entry.cyclesDelivered == null;
    assert entry.retries == 0;
    assert entry.createdAtNs == 100 and entry.updatedAtNs == 100;
  });


  test("patch updates only the requested fields and bumps updatedAt", func() {
    let journal = Delivery.emptyJournal();
    let entry = Delivery.openEntry(journal, order(), intentAt(42), 100);
    Delivery.patch(journal, entry.orderId, { status = ?#delivered; blockIndex = ?77; cyclesDelivered = null; bumpRetries = false }, 200);
    let ?after = journal.get(entry.orderId) else { assert false; return };
    assert after.status == #delivered;
    assert after.blockIndex == ?77;
    assert after.cyclesDelivered == null;
    assert after.retries == 0;
    assert after.transferIntent == entry.transferIntent; // untouched
    assert after.updatedAtNs == 200 and after.createdAtNs == 100;
  });

  test("bumpRetries accumulates", func() {
    let journal = Delivery.emptyJournal();
    let entry = Delivery.openEntry(journal, order(), intentAt(42), 100);
    Delivery.patch(journal, entry.orderId, { status = null; blockIndex = null; cyclesDelivered = null; bumpRetries = true }, 200);
    Delivery.patch(journal, entry.orderId, { status = null; blockIndex = null; cyclesDelivered = null; bumpRetries = true }, 300);
    let ?after = journal.get(entry.orderId) else { assert false; return };
    assert after.retries == 2;
  });

  test("patch on a missing id is a no-op, never a trap", func() {
    let journal = Delivery.emptyJournal();
    Delivery.patch(journal, "nope", { status = ?#delivered; blockIndex = null; cyclesDelivered = null; bumpRetries = true }, 200);
    assert journal.get("nope") == null;
  });
});

suite("stageOf (§5.1/§5.2 resume decision)", func() {
  test("#paid with no journal begins a DELIVERY, not a mint", func() {
    // Inverted by #30 PR-A. `#paid` used to open the CMC mint chain; it is now
    // the whole money-out path — one transfer out of the reserve.
    assert Delivery.stageOf(#paid, null, 0, window) == #beginDelivery;
  });

  test("#paid with an entry but no intent begins too — the retry state is the JOURNAL", func() {
    // Delivery has no status of its own (the order stays `#paid` throughout), so
    // "have we sent yet?" is answered by the journal. An entry without an intent
    // means nothing was ever frozen, so there is nothing to replay.
    assert Delivery.stageOf(#paid, ?entryWith(null, null, null, 0), 0, window) == #beginDelivery;
  });

  test("#paid with a fresh delivery intent REPLAYS the stored args", func() {
    // ⚠️ The stored ones. Two drivers legitimately reach one order at once (the
    // webhook's detached kick and the recovery sweep); a rebuilt intent carries
    // a fresh `created_at_time`, the ledger does not dedup it, and the buyer is
    // paid twice. Dedup only works on byte-identical args.
    let intent = intentAt(1_000);
    let entry = entryWith(?intent, null, null, 0);
    assert Delivery.stageOf(#paid, ?entry, 1_000 + window - 1, window) == #replayDelivery(intent);
  });

  test("#paid past the dedup window escalates rather than replaying — the ONE ambiguous case", func() {
    // Past the window a replay is no longer protected, so a blind retry could
    // pay twice. This is the only thing on the delivery path that escalates.
    let intent = intentAt(1_000);
    let entry = entryWith(?intent, null, null, 0);
    assert Delivery.stageOf(#paid, ?entry, 1_000 + window, window) == #escalate(#staleIntent);
  });

  test("#paid with a block recorded finishes the delivery instead of re-sending", func() {
    // Unreachable today — the block and the `#delivered` transition commit in
    // one sync block — and handled so a future regression degrades to something
    // resumable rather than to a paid order whose buyer already holds the cycles.
    let entry = entryWith(?intentAt(1_000), ?77, null, 0);
    assert Delivery.stageOf(#paid, ?entry, 1_000, window) == #finishDelivery(77);
  });

  test("⚠️ #paid keeps replaying FOREVER — the retry cap does not apply to delivery", func() {
    // #30 PR-B deleted the cap on this path, and the inverted assertion is the
    // record of it: a replay here is provably safe (byte-identical args, the ledger
    // deduplicates, `#Duplicate` recovers the block), so exhausting a counter turned
    // a recoverable state into a manual one for no safety gain.
    //
    // "Forever" is bounded by TIME rather than by a count, twice over: the dedup
    // window escalates the intent (the test above), and §5.3's 72 h max-wait gets a
    // human involved long before. Ten times the old cap still replays.
    let intent = intentAt(1_000);
    let entry = entryWith(?intent, null, null, 20_000); // far past any budget that ever existed
    assert Delivery.stageOf(#paid, ?entry, 1_000, window) == #replayDelivery(intent);
  });



  test("§5.1 boundary: at exactly the dedup window the intent is stale — never auto-replayed", func() {
    let intent = intentAt(1_000);
    let entry = entryWith(?intent, null, null, 0);
    assert Delivery.stageOf(#paid, ?entry, 1_000 + window, window) == #escalate(#staleIntent);
  });









  test("no money-out work for the remaining statuses", func() {
    for (status in [#created, #cancelled, #expired, #delivered, #needsReview, #abandoned].values()) {
      assert Delivery.stageOf(status, null, 0, window) == #none;
    };
  });
});

suite("terminationFor — the money position, not the status", func() {
  // This is the function three consecutive defects came from getting wrong when
  // the decision was inlined off `status` alone. Every arm is pinned here so a
  // fourth round has to break a test rather than a production instruction.





  test("the staleIntent instruction carries the values needed to match the ledger", func() {
    let intent = intentAt(5_000);
    let t = Delivery.terminationFor(#paid, ?entryWith(?intent, null, null, 0));
    assert t.stage == "staleIntent";
    let createdText = Nat64.toText(intent.createdAtTimeNs);
    assert Text.contains(t.detail, #text createdText);
    let amountText = Nat.toText(intent.amountCycles);
    assert Text.contains(t.detail, #text amountText);
  });





  test("#paid: whether a refund is the answer depends on the JOURNAL, not the status", func() {
    // #30 PR-A moved delivery onto `#paid`, so the status alone stopped being a
    // money position. The dangerous cell is the middle one: telling an operator
    // to refund a buyer who may already hold their cycles.
    let never = Delivery.terminationFor(#paid, null);
    assert never.stage == "deliveryWaitExceeded";
    assert Text.contains(never.detail, #text "no transfer attempted");

    let unconfirmed = Delivery.terminationFor(#paid, ?entryWith(?intentAt(0), null, null, 0));
    assert unconfirmed.stage == Delivery.escalateReasonToText(#staleIntent);
    assert Text.contains(unconfirmed.detail, #text "NEVER rebuild");
    // It must NOT read as a settled refund case.
    assert not Text.contains(unconfirmed.detail, #text "no transfer attempted");

    let landed = Delivery.terminationFor(#paid, ?entryWith(?intentAt(0), ?42, null, 0));
    assert Text.contains(landed.detail, #text "buyer HAS their cycles");
    assert Text.contains(landed.detail, #text "do NOT re-send");
  });

  test("⚠️ a missing journal is a KNOWN position for #paid, and that is the point", func() {
    // ⚠️ **This replaced a test asserting the opposite (#36).** It read "a missing
    // journal is never silently treated as a known position" and walked `#minting`
    // and `#icpAtCmc`, where an absent journal really was an invariant breach — the
    // order could not have reached those states without one.
    //
    // `#paid` is different, and the difference is load-bearing: an order can sit
    // `#paid` with nothing ever sent, which is the **certain** position. Reporting
    // `missingJournal` there would tell an operator to establish a fate that is
    // already known, instead of "fiat in, nothing moved, refund".
    let t = Delivery.terminationFor(#paid, null);
    assert t.stage == "deliveryWaitExceeded";
    assert Text.contains(t.detail, #text "refund");
  });

  test("the journal decides, so the same status yields different instructions", func() {
    // The whole point of the extraction: status alone cannot answer this.
    let withBlock = Delivery.terminationFor(#paid, ?entryWith(?intentAt(0), ?42, null, 0));
    let without = Delivery.terminationFor(#paid, ?entryWith(?intentAt(0), null, null, 0));
    assert withBlock.stage != without.stage;
  });

  test("every stage it can produce is non-empty and recognisable to the runbook", func() {
    // ⚠️ **The mint positions are gone (#36)**, so the vocabulary this test walks is
    // the delivery one. `#paid` covers all four shapes a journal can have.
    let cases : [(Types.OrderStatus, ?Types.JournalEntry)] = [
      (#paid, ?entryWith(?intentAt(0), ?1, ?1, 0)),
      (#paid, ?entryWith(?intentAt(0), ?1, null, 0)),
      (#paid, ?entryWith(?intentAt(0), null, null, 0)),
      (#paid, ?entryWith(null, null, null, 0)),
      (#paid, null),
    ];
    let known = ["ambiguousForward", "retriesExhausted", "staleIntent", "missingJournal", "treasuryWaitExceeded", "mintWaitExceeded", "deliveryWaitExceeded"];
    for ((status, entry) in cases.values()) {
      let t = Delivery.terminationFor(status, entry);
      assert t.detail != "";
      var recognised = false;
      for (k in known.values()) { if (k == t.stage) recognised := true };
      assert recognised;
    };
  });
});


let hour : Int = 3_600_000_000_000;

/// The same two thresholds the shared fixture used: alert at 2 h, terminate at 72 h.
let waitConfig : Delivery.Config = {
  alertAfterNs = 2 * hour;
  maxHoldNs = 72 * hour;
};

suite("waitStage — the §5.3 timeline for money in, nothing delivered", func() {
  // Three outcomes, not two. Splitting the alert from the terminal bound is what
  // lets the operator be told early WITHOUT giving up on the sale early.
  test("quiet retry before the alert threshold", func() {
    assert Delivery.waitStage(0, 1 * hour, waitConfig) == #retry;
    assert Delivery.waitStage(0, 2 * hour - 1, waitConfig) == #retry;
  });

  test("alert from alertAfterNs, and keep retrying — not terminal", func() {
    assert Delivery.waitStage(0, 2 * hour, waitConfig) == #alert;
    assert Delivery.waitStage(0, 71 * hour, waitConfig) == #alert;
  });

  test("terminate at maxHoldNs — the spec's max-wait bound", func() {
    // A buyer left waiting files a chargeback, which costs the operator more
    // than a refund; and by 72h the cause is structural, not transient.
    assert Delivery.waitStage(0, 72 * hour, waitConfig) == #terminate;
    assert Delivery.waitStage(0, 1_000 * hour, waitConfig) == #terminate;
  });

  test("a clock that has not advanced never alerts", func() {
    assert Delivery.waitStage(5 * hour, 5 * hour, waitConfig) == #retry;
  });
});
