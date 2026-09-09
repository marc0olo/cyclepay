import { test; suite } "mo:test";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Result "mo:core/Result";
import Purchase "../src/backend/Purchase";
import Types "../src/backend/Types";

/// ⚠️ **These tests exist because the ORDER of `Purchase.plan`'s four steps is
/// behaviour, and it was previously observable only through PocketIC.** Which refusal a
/// buyer sees when several conditions apply at once is decided entirely by the sequence,
/// so every adjacent pair is pinned here: make both conditions true, and assert which one
/// is reported. Reorder any two steps in `Purchase.plan` and one of these fails.
///
/// The stubs are what make it possible: `admit` and `quote` come in as functions, so a
/// refusing gate and a stale rate cache are two lines rather than a replica.

let alice = Principal.fromText("aaaaa-aa");

let tiers : [{ id : Text; usdCents : Nat }] = [
  { id = "tier5"; usdCents = 500 },
  { id = "tier50"; usdCents = 5_000 },
];

let admits : Purchase.Admitter = func(_) = #ok;
let refuses : Purchase.Admitter = func(_) = #err(#buyerNotAllowed);

/// 455¢ net at the §3 vector — the same arithmetic the integration suite uses, so a
/// figure here means the same thing there.
let priced : Purchase.Quoter = func(cents) = #ok((
  cents * 7_000_000_000,
  {
    usdCents = cents;
    usdPerIcpMicros = 4_550_000; // $4.55 per ICP, the §3 vector
    xdrPermyriadPerIcp = 35_000; // 3.5 XDR per ICP
    rateStandardDeviation = 0;
    rateReceivedRates = 5;
    rateQueriedSources = 5;
    feeBps = 290;
    feeFixedCents = 30;
    ratesFetchedAtNs = 1;
  },
));
let stale : Purchase.Quoter = func(_) = #stale;
let belowFees : Purchase.Quoter = func(_) = #unpriceable(#stripeFee);

func planWith(
  amount : Types.Amount,
  minCycles : ?Nat,
  admit : Purchase.Admitter,
  quote : Purchase.Quoter,
) : Result.Result<Purchase.Plan, Purchase.PlanError> {
  Purchase.plan(alice, amount, minCycles, tiers, admit, quote);
};

suite("Purchase.plan — the happy path carries what the commit needs", func() {
  test("a preset resolves to its cents, and the label names the tier", func() {
    let #ok(plan) = planWith(#tier("tier5"), null, admits, priced) else Runtime.trap("expected #ok");
    assert plan.usdCents == 500;
    assert plan.quoteLabel == "tier5";
    assert plan.lockedCycles == 500 * 7_000_000_000;
    assert plan.owner == #ii(alice);
  });

  test("a custom amount is taken as given, and labels itself in cents", func() {
    // ⚠️ NOT validated against the tier list — the gate is the only bound. A custom
    // amount that matches no preset is the normal case, not an error.
    let #ok(plan) = planWith(#custom(1_234), null, admits, priced) else Runtime.trap("expected #ok");
    assert plan.usdCents == 1_234;
    assert plan.quoteLabel == "1234 cents";
  });

  test("⚠️ lockedCycles comes from the quote, so the commit and the delivery agree", func() {
    // The one field a later re-quote would change. `Plan` carries it precisely so
    // nothing downstream has to ask again — see the note on `Purchase.Plan`.
    let #ok(a) = planWith(#tier("tier50"), null, admits, priced) else Runtime.trap("expected #ok");
    assert a.lockedCycles == 5_000 * 7_000_000_000;
    assert a.pricing.usdCents == 5_000;
  });
});

suite("Purchase.plan — each adjacent pair of steps, in order", func() {
  test("1 before 2: an unknown tier beats a refusing gate", func() {
    // Resolving the amount comes first, so a bad tier id is reported even though
    // admission would also have refused. The gate never sees this call.
    assert planWith(#tier("nope"), null, refuses, priced) == #err(#unknownTier("nope"));
  });

  test("2 before 3: a refused buyer beats an unpriceable amount", func() {
    // ⚠️ This is the pair with a REASON beyond precedence: admission is the cheap
    // pre-refusal, so a spamming principal must be turned away before this does pricing
    // work. Swap them and the refusal still happens, but only after the work.
    assert planWith(#tier("tier5"), null, refuses, stale) == #err(#notAdmitted(#buyerNotAllowed));
    assert planWith(#tier("tier5"), null, refuses, belowFees) == #err(#notAdmitted(#buyerNotAllowed));
  });

  test("3 before 4: a stale rate beats the caller's floor", func() {
    // `minCycles` compares against the quote, so with no quote there is nothing to
    // compare — `#quoteChanged` would be a lie about a figure that was never computed.
    assert planWith(#tier("tier5"), ?(999 ** 3), admits, stale) == #err(#rateUnavailable);
  });

  test("4 last: the floor is checked against the quote that was actually produced", func() {
    let quoted = 500 * 7_000_000_000;
    assert planWith(#tier("tier5"), ?(quoted + 1), admits, priced)
      == #err(#quoteChanged({ quoted; minimum = quoted + 1 }));
    // Exactly at the floor is admitted: the caller asked for "at least".
    let #ok(_) = planWith(#tier("tier5"), ?quoted, admits, priced) else Runtime.trap("expected #ok");
  });
});

suite("Purchase.plan — the two unpriceable causes stay distinct", func() {
  test("a fee-swallowed amount names the amount, not the gateway's divisor", func() {
    // ⚠️ #99 review finding 2: telling a buyer "payment processing is too large" when the
    // cause is this gateway's simulation divisor names the wrong party and prescribes a
    // fix that may not work. The two causes are separate arms for that reason.
    assert planWith(#tier("tier5"), null, admits, belowFees) == #err(#tierBelowFees("tier5"));
    assert planWith(#custom(7), null, admits, belowFees) == #err(#tierBelowFees("7 cents"));
  });

  test("a too-small simulation scale carries both figures", func() {
    let scaled : Purchase.Quoter = func(_) = #unpriceable(
      #simulationScale({ scaledCycles = 10; ledgerFee = 100_000_000 })
    );
    assert planWith(#tier("tier5"), null, admits, scaled)
      == #err(#simulationScaleTooSmall({ scaledCycles = 10; ledgerFee = 100_000_000 }));
  });
});
