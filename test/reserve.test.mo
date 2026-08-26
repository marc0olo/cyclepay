// Unit suite for reserve solvency (#30). All pure, so all of it is pinned here —
// the `create_order` half needs a ledger and lives in the PocketIC suite.
import { suite; test } "mo:test";
import Principal "mo:core/Principal";
import Reserve "../src/backend/Reserve";
import Types "../src/backend/Types";

let alice = Principal.fromText("aaaaa-aa");

let pricing : Types.Pricing = {
  usdCents = 500;
  usdPerIcpMicros = 4_550_000;
  xdrPermyriadPerIcp = 35_000;
  rateStandardDeviation = 0;
  rateReceivedRates = 5;
  rateQueriedSources = 5;
  feeBps = 290;
  feeFixedCents = 30;
  ratesFetchedAtNs = 1;
};

func orderAt(id : Text, status : Types.OrderStatus, lockedCycles : Nat) : Types.Order {
  {
    id;
    owner = #ii(alice);
    rail = #card;
    destination = #cyclesLedgerAccount({ owner = alice; subaccount = null });
    lockedCycles;
    pricing;
    status;
    paidUsdCents = null;
    expiredBy = null;
    expiresAtNs = null;
    stripeSessionId = null;
    stripeSessionUrl = null;
    createdAtNs = 0;
    updatedAtNs = 0;
  };
};

suite("holdsPromise — which orders are owed cycles", func() {
  test("created, paid and under-review hold; only the terminal four release", func() {
    // ⚠️ **`#created` HOLDS**, and that changed from an earlier draft of this
    // module. The hold is taken at CREATION — `Orders.create` is an adjustment
    // site in its own right — because the gate admitted the order against
    // capacity, and that capacity is spoken for from the moment the order exists.
    // Holding only from payment would let a buyer stack orders the reserve cannot
    // cover and discover it one webhook at a time.
    assert Reserve.holdsPromise(#created);
    assert Reserve.holdsPromise(#paid);
    // `#needsReview` holding is the point of #34's split: its meaning is "we do
    // not know whether the cycles left the reserve", so releasing it would free
    // cycles that may still have to be delivered — a double-sale.
    assert Reserve.holdsPromise(#needsReview);
    for (released in ([#delivered, #cancelled, #expired, #abandoned] : [Types.OrderStatus]).values()) {
      assert not Reserve.holdsPromise(released);
    };
  });

  test("EVERY status is decided, so a new one cannot default to released", func() {
    // The compiler enforces this (the switch is exhaustive and `-Werror` is on),
    // and the test states WHY it matters: a status added later that silently
    // holds nothing releases cycles that are still owed. #30 rejected
    // enumerating the holding statuses for exactly this reason — the terminal
    // set is the smaller, more stable list.
    let all : [Types.OrderStatus] = [
      #created, #cancelled, #expired, #paid, #delivered, #needsReview, #abandoned,
    ];
    assert all.size() == 7;
    var held = 0;
    for (s in all.values()) { if (Reserve.holdsPromise(s)) held += 1 };
    assert held == 3; // #created, #paid, #needsReview
  });
});

suite("recount — the independent second derivation", func() {
  test("sums the locked quantity of holding orders only", func() {
    let orders = [
      orderAt("a", #paid, 1_000),
      orderAt("b", #delivered, 500_000), // already left the reserve
      orderAt("c", #needsReview, 2_000),
      orderAt("d", #created, 999_999), // HOLDS: the hold is taken at creation
      orderAt("e", #cancelled, 888_888),
    ];
    assert Reserve.recount(orders) == 1_002_999; // 1_000 + 2_000 + 999_999
  });

  test("an empty store promises nothing", func() {
    assert Reserve.recount([]) == 0;
  });

  test("⚠️ it is lockedCycles, with NO fee term", func() {
    // The ledger charges its fee on top of the amount, so delivering
    // `locked - fee` moves the balance by exactly `locked`. An earlier draft of
    // #30 wrote `Σ (locked + fee)` and double-counted — which under-reports
    // `available` and refuses sales that would have worked.
    assert Reserve.recount([orderAt("a", #paid, 3_500_000_000_000)]) == 3_500_000_000_000;
  });
});

suite("tallyDelta — when the tally moves, and when it must not", func() {
  test("entering the counted set adds; leaving releases; moving inside is zero", func() {
    assert Reserve.tallyDelta(#delivered, #paid) == #add; // not reachable, but the rule
    assert Reserve.tallyDelta(#paid, #delivered) == #release;
    assert Reserve.tallyDelta(#created, #paid) == #none;
  });

  test("⚠️ #created → #paid is ZERO: release is at DELIVERY, not at payment", func() {
    // The two-orders-one-reserve failure this prevents: order A holds 72 T, the
    // buyer pays, and if the tally released here order B for 72 T would be
    // admitted against capacity order A still needs — both then paid out of a
    // reserve that only ever covered one.
    assert Reserve.tallyDelta(#created, #paid) == #none;
    assert Reserve.tallyDelta(#paid, #needsReview) == #none;
  });

  test("every terminal status releases, and every non-terminal one holds", func() {
    for (terminal in ([#delivered, #expired, #cancelled, #abandoned] : [Types.OrderStatus]).values()) {
      assert Reserve.tallyDelta(#paid, terminal) == #release;
      assert not Reserve.holdsPromise(terminal);
    };
    for (held in ([#created, #paid, #needsReview] : [Types.OrderStatus]).values()) {
      assert Reserve.holdsPromise(held);
      assert Reserve.tallyDelta(#paid, held) == #none or held == #paid;
    };
  });
});

suite("applyDelta — saturation is reported, not swallowed", func() {
  test("ordinary moves are exact and report no saturation", func() {
    assert Reserve.applyDelta(0, #add, 500) == { total = 500; saturated = false };
    assert Reserve.applyDelta(500, #release, 500) == { total = 0; saturated = false };
    assert Reserve.applyDelta(500, #none, 500) == { total = 500; saturated = false };
  });

  test("releasing more than is held saturates AND says so", func() {
    // The tally was already wrong before this order arrived. A silent zero is
    // indistinguishable from an exact release, which would hide the divergence
    // until the daily recount — up to 24 h of a wrong tally gating real sales.
    let r = Reserve.applyDelta(100, #release, 101);
    assert r.total == 0;
    assert r.saturated;
  });
});

suite("promisedForDecision — a stale balance with a live tally (#30 PR-B)", func() {
  // ⚠️ **This exists because the interleaving trace got case (A) WRONG, and wrong
  // in the optimistic direction.** The decision carries a balance captured before
  // an await and reads the tally live. A delivery whose continuation runs in that
  // gap debits the ledger AND releases its promise — so a live-only read pairs a
  // not-yet-lowered balance with an already-released promise:
  //
  //   available = B − (P − L_X)  =  (B − P) + L_X     while the truth is B − P
  //
  // Phantom capacity of a full order at the ceiling (~72 T), not fractions of a
  // fee. An order admitted into it makes `promised > balance`, and the eventual
  // `#InsufficientFunds` sends an operator hunting a fee delta — what its triage
  // note tells them to check — for a cause that is a whole over-promise.

  test("a delivery releasing in the gap does NOT create capacity", func() {
    // The bug, stated as arithmetic. Snapshot 10_000 (order X's 3_000 included),
    // live 7_000 after X delivered. A live-only read would offer 3_000 of the
    // balance that X's own delivery just spent.
    assert Reserve.promisedForDecision(10_000, 7_000) == 10_000;
    // Which makes `available` the truth at the read, and delivery does not move it.
    assert Reserve.available(12_000, Reserve.promisedForDecision(10_000, 7_000)) == 2_000;
  });

  test("a concurrent hold in the gap IS honoured", func() {
    // The other direction must not be clamped away, or two creates could both be
    // admitted against one balance.
    assert Reserve.promisedForDecision(10_000, 13_000) == 13_000;
    assert Reserve.available(12_000, Reserve.promisedForDecision(10_000, 13_000)) == 0;
  });

  test("no change in the gap is exact", func() {
    assert Reserve.promisedForDecision(10_000, 10_000) == 10_000;
  });

  test("⚠️ the accepted cost: an expiry in the gap understates for one gap", func() {
    // An expiry releases the tally without touching the balance, so keeping the
    // snapshot refuses a sale that would have worked — for the duration of one
    // scheduling gap. Documented as the price of the fix, not as a defect.
    assert Reserve.promisedForDecision(10_000, 6_000) == 10_000;
    // Conservative: strictly less available than the truth.
    let conservative = Reserve.available(12_000, Reserve.promisedForDecision(10_000, 6_000));
    let truth = Reserve.available(12_000, 6_000);
    assert conservative < truth;
  });
});

suite("available and canCover", func() {
  test("available is balance minus promised", func() {
    assert Reserve.available(10_000, 4_000) == 6_000;
    assert Reserve.available(10_000, 0) == 10_000;
  });

  test("an over-promised reserve reads zero rather than trapping", func() {
    // Reachable: a risen ledger fee is absorbed by the reserve, which can put it
    // fractionally under what is promised. The answer there is "sell nothing",
    // not "trap on every order" — a trap would take the whole rail down over
    // fractions of a fee.
    assert Reserve.available(100, 100) == 0;
    assert Reserve.available(100, 101) == 0;
    assert Reserve.available(0, 5_000) == 0;
  });

  test("cover is INCLUSIVE: an order that exactly exhausts the reserve is fine", func() {
    // Because the fee is charged on top of the amount, and the amount is what is
    // promised. An exclusive check here would strand the last order's worth of
    // cycles in the reserve forever.
    assert Reserve.canCover(10_000, 0, 10_000);
    assert not Reserve.canCover(10_000, 0, 10_001);
    assert Reserve.canCover(10_000, 4_000, 6_000);
    assert not Reserve.canCover(10_000, 4_000, 6_001);
  });

  test("a fully promised reserve covers nothing, including zero-size orders", func() {
    assert Reserve.canCover(10_000, 10_000, 0);
    assert not Reserve.canCover(10_000, 10_000, 1);
  });
});
