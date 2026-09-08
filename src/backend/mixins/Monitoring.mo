import Cycles "mo:core/Cycles";
import Map "mo:core/Map";
import Time "mo:core/Time";
import Delivery "../Delivery";
import Gate "../Gate";
import Idempotency "../Idempotency";
import Orders "../Orders";
import Orphans "../Orphans";
import Pricing "../Pricing";
import Reserve "../Reserve";
import Types "../Types";
import Card "../rails/Card";

/// Every read-only operational surface: is anything wrong right now, and what the
/// counters say (§8).
///
/// ⚠️ **Public and unauthenticated except where noted, deliberately.** Operational state
/// is public by design here — the reserve is an account on a public ledger, and a monitor
/// should not need a controller key. The one admin read carries `requireAdmin` for the
/// reason stated at it.
///
/// ⚠️ **Nothing in this mixin writes**, which is exactly why the state records are passed
/// rather than accessor pairs (`docs/DESIGN.md` §9.1): a `var` passed by value would
/// answer its install-time value forever, and for a monitoring surface that is worse than
/// an error — it looks like a healthy system.
///
/// ⚠️ **Each state parameter declares only the FIELDS these reads touch**, not the whole
/// record. Motoko's width subtyping accepts the fuller record, so the signature is the
/// A6 "pass only the slice it uses" rule enforced by the compiler rather than asserted in
/// a comment — adding a field elsewhere cannot silently widen what this mixin can reach.
mixin (
  orderStore : Orders.Store,
  dedup : Idempotency.Store,
  orphanStore : Orphans.Store,
  paidIntents : Map.Map<Text, Types.OrderId>,
  rateCache : Pricing.Cache,
  reserveState : { var floor : Nat; var observedAtNs : ?Int; var cyclesLedgerFee : Nat },
  gateState : {
    var config : Gate.Config;
    var refusals : Gate.RefusalCounts;
    var latch : Gate.RailStateLatch;
  },
  pricingState : {
    var config : Pricing.Config;
    var lastAttempt : ?{ atNs : Int; ok : Bool; detail : Text };
  },
  stripeState : { var expectLivemode : ?Bool },
  recoveryState : {
    var sweepIntervalNs : Nat;
    var lastSweep : ?{ atNs : Int; pending : Nat };
    var lastCountReconcile : ?{
      atNs : Int;
      drift : [Orders.Drift];
      refused : [Orders.Drift];
      ordersRead : Nat;
    };
    var lastReserveReconcileAttemptNs : Int;
    var lastCountReconcileAttemptNs : Int;
    var indexScanCycle : { startedAtNs : Int; ordersRead : Nat; repairs : Nat };
    var lastIndexScanCycle : ?{
      startedAtNs : Int;
      completedAtNs : Int;
      ordersRead : Nat;
      repairs : Nat;
    };
  },
  /// The private helpers these reads share with the sweeps that maintain them, passed as
  /// closures: each is actor-bound — they read several stores at once, and one needs the
  /// canister's own principal.
  ops : {
    requireAdmin : (Principal) -> ();
    selfPrincipal : () -> Principal;
    unsettledDeliveries : () -> Nat;
    delayedDeliveryCount : (Int) -> Nat;
    expectedIndexScanCycleNs : () -> Nat;
    /// ⚠️ Two TRANSIENT vars, read through getters. Transient state is rebuilt on every
    /// start, so passing the field would hand this mixin a value frozen at include time
    /// — and both exist precisely to say "has this run since the canister started",
    /// which a frozen copy answers wrongly and confidently.
    lastXrcCanisterId : () -> ?Text;
    recoverySweepInFlight : () -> Bool;
  },
) {

  /// Rates + params + refresh liveness, public: both rates are market data any
  /// third party can query for themselves, and the fee formula is what users
  /// are charged. Nothing here is secret, and reproducibility is the point.
  public query func pricing_status() : async {
    rates : ?Pricing.Rates;
    config : Pricing.Config;
    lastAttempt : ?{ atNs : Int; ok : Bool; detail : Text };
    /// Which Exchange Rate Canister the last refresh actually priced from. On
    /// mainnet this MUST read `uf6dk-hyaaa-aaaaq-qaaaq-cai`; anything else means
    /// the deploy injected `PUBLIC_CANISTER_ID:xrc` and prices are coming from
    /// somewhere else. Alert on it (RUNBOOK §8).
    ///
    /// **Null means no refresh has resolved it yet** — not that it is the mainnet
    /// canister. Null is the expected reading for the first seconds after an
    /// install or upgrade, and it is a "check again", never a pass.
    xrcCanisterId : ?Text;
  } {
    {
      rates = Pricing.lastRates(rateCache);
      config = pricingState.config;
      lastAttempt = pricingState.lastAttempt;
      xrcCanisterId = ops.lastXrcCanisterId();
    };
  };

  /// Which Stripe mode this gateway declares it serves, or null while unset.
  ///
  /// Public because the page reads it: a sandbox deployment says so on every view, and
  /// a mismatch against the mode a webhook arrives in is what `Card.handleWebhook`
  /// refuses on. `set_expected_livemode` is the controller-only setter.
  public query func expected_livemode() : async ?Bool {
    stripeState.expectLivemode;
  };

  /// How much is outstanding, as two numbers rather than a collection (#38).
  ///
  /// ⚠️ **The shape to poll, and the reason it exists separately from the list.** A
  /// paginated detail query needs a cheap total beside it or a monitor pages through
  /// everything to learn one number — the same split `orphan_depth` already has, and
  /// the same reason RUNBOOK says to alert on the depth and fetch details only when it
  /// fires.
  ///
  /// ⚠️ **`unresolved` is NOT `orders`.** One order can carry several problems, so a
  /// caller reading the order count undercounts the work.
  public query func problem_depth() : async { unresolved : Nat; orders : Nat } {
    {
      unresolved = Orders.unresolvedProblemCount(orderStore);
      // ⚠️ O(1) — the index's size. This built the whole worklist as an array to read its
      // length, on a query anyone can call.
      orders = Orders.unresolvedProblemOrderCount(orderStore);
    };
  };

  /// Refusal tallies, and whether the gate is refusing right now (#61).
  ///
  /// ⚠️ **Public, like every other monitoring surface here** — operational state
  /// is public by design; the webhook secret is the only secret in the system.
  ///
  /// ⚠️ **This query is the point of the counters.** A tally nobody reads is the
  /// `Orders.tallySaturations` failure over again, so RUNBOOK §8 carries a row
  /// per counter with the response — the counters mean different things:
  /// `amountBelowMin` climbing is a UI bug or an attacker probing, while
  /// `reserveShort` climbing is a refill. Same shape, opposite actions.
  public query func refusal_counts() : async {
    counts : Gate.RefusalCounts;
    /// True while that rail-state condition is refusing. Each flips to true with
    /// exactly one `gate.startedRefusing` audit line and clears on the next
    /// successful admission.
    refusingNow : Gate.RailStateLatch;
  } {
    { counts = gateState.refusals; refusingNow = gateState.latch };
  };

  /// Open-obligation depth, public.
  ///
  /// Nothing is evicted, so this only comes down by the operator working it. A climbing
  /// value means dollars are arriving that nobody has dealt with — the most important
  /// operational number on the money path, and public because operational state is not
  /// secret (§8).
  public query func orphan_depth() : async { unresolved : Nat; retained : Nat } {
    {
      unresolved = Orphans.unresolvedCount(orphanStore);
      retained = Orphans.size(orphanStore);
    };
  };

  /// The operator worklist: open obligations only, paged. Filtered server-side
  /// so a large body of resolved history never stands between the operator and
  /// the dollars that still need an answer.
  public shared query ({ caller }) func orphans_unresolved(
    afterId : ?Nat,
    limit : Nat,
  ) : async Orphans.Page {
    ops.requireAdmin(caller);
    Orphans.unresolvedPage(orphanStore, afterId, limit);
  };

  /// Reserve solvency and order counters, public (#30 PR-B).
  ///
  /// `reserveFloor` − `promisedTotal` = `availableToSell`, in one answer, so "the ledger
  /// says 100 T and the gateway will sell 0" is diagnosable at a glance (§3.2).
  ///
  /// ⚠️ **`reserveFloor` is a maintained lower BOUND, not the balance, and must not cache
  /// one.** Caching invents a staleness class over a number the caller can read from the
  /// source. A floor far below the ledger's balance means nothing has reconciled since the
  /// last top-up — `reserveObservedAtNs` says when it last did, `refresh_reserve` is the
  /// lever.
  ///
  /// ⚠️ **Uncertified query answers, and nothing may be wired to decide on them.**
  /// `create_order` decides solvency from the same state *synchronously*, inside the
  /// order-creating message; that is what stops the decision being raced into an
  /// over-sale.
  public query func reserve_status() : async {
    reserveFloor : Nat;
    promisedTotal : Nat;
    /// How many orders still hold a promise — `promiseHolders.size()`, O(1).
    ///
    /// ⚠️ **This is what `withdraw_reserve` guards on, so it must be readable before
    /// calling it** (#103): the refusal names a count an operator then has to go and
    /// find, and a decommissioning lever that cannot tell you what is blocking it is a
    /// dead end.
    ///
    /// ⚠️ **It is also the direct read on a saturated tally.** `promisedTotal` clamps to
    /// zero on release when it has diverged low, so `promisedTotal == 0` with
    /// `promiseHolders > 0` is exactly the state `tallySaturations` counts — visible here
    /// side by side rather than inferred from a counter.
    promiseHolders : Nat;
    availableToSell : Nat;
    reserveObservedAtNs : ?Int;
    cyclesLedgerFee : Nat;
    tallySaturations : Nat;
    reserveAccount : Types.Account;
    canisterCycles : Nat;
    minCanisterCycles : Nat;
    openOrders : Nat;
    expiredOrders : Nat;
    totalOrders : Nat;
    paidIntentsIndexed : Nat;
  } {
    {
      reserveFloor = reserveState.floor;
      promiseHolders = Orders.promiseHolderCount(orderStore);
      /// Null means **no reconcile has ever run**, which is also why a freshly
      /// installed canister sells nothing until the operator refreshes: the floor
      /// starts at zero and only a look at the ledger can raise it.
      reserveObservedAtNs = reserveState.observedAtNs;
      /// Exactly what the gate computes, from the same two numbers, so a refused
      /// sale and this figure can never tell different stories.
      availableToSell = Reserve.available(reserveState.floor, Orders.promised(orderStore));
      /// The fee the NEXT delivery will use, and the only way to see that `#BadFee`
      /// self-correction actually happened (#30 PR-B). ⚠️ Nothing but the ledger
      /// writes it — there is deliberately no admin lever — so a value at or above an
      /// order's locked quantity stalls delivery loudly and the answer is a redeploy;
      /// at that fee the rail cannot sell anyway.
      cyclesLedgerFee = reserveState.cyclesLedgerFee;
      // O(1): maintained counters, not a scan of the order store.
      openOrders = Orders.countOf(orderStore, #created);
      expiredOrders = Orders.countOf(orderStore, #expired);
      totalOrders = orderStore.orders.size();
      paidIntentsIndexed = paidIntents.size();
      promisedTotal = Orders.promised(orderStore);
      /// ⚠️ **Any non-zero value means the tally has diverged.** A saturation is a
      /// release asking to remove more than was held, so it says the tally was
      /// already wrong *before* that order got there — strictly worse than a fault
      /// in the order being released. The daily recount reports drift's SIZE; this
      /// reports its EXISTENCE, same day. RUNBOOK §8 alerts on any increment.
      tallySaturations = orderStore.tallySaturations;
      // Named so an operator (or the frontend) can point a ledger query at the
      // right account without reconstructing it.
      reserveAccount = Delivery.reserveAccount(ops.selfPrincipal());
      // The gas half, which is a different pot from the reserve: what the canister
      // spends to run, gated by `minCanisterCycles`.
      canisterCycles = Cycles.balance();
      minCanisterCycles = gateState.config.minCanisterCycles;
    };
  };

  /// §5.2 liveness observability, public (operational transparency, same stance as
  /// `reserve_status`): cadence + last completed timer sweep. A null or stale
  /// `lastSweep` means recovery is not running.
  /// This canister's OWN cycle balance and the floor the admission gate holds it
  /// against (public — the same operational-transparency stance as `reserve_status`;
  /// it is visible via `canister_status` regardless).
  ///
  /// ⚠️ **Gas, not stock.** This is what the canister spends to run; the cycles it
  /// sells live in its cycles-ledger account and are reported by `reserve_status`.
  /// Below the freezing threshold the canister stops accepting updates; at zero it is
  /// uninstalled and the order store, journals, and dedup sets go with it. Monitor it
  /// separately, and alert well above `minCanisterCycles` — that gate stops *sales*,
  /// it does not stop the burn. A sudden acceleration here is the
  /// signature of a cycle-drain attempt.
  public query func cycles_status() : async { balance : Nat; floor : Nat } {
    { balance = Cycles.balance(); floor = gateState.config.minCanisterCycles };
  };

  /// The public trust figures (#39) — anonymous, safe on a landing page.
  ///
  /// ⚠️ **The admission test is "what does a POLLER learn from the deltas?", not "does this
  /// field name a buyer?"** Cumulative counters are differentiable: anyone sampling this
  /// query recovers each delivery's cycles, USD and timing from the increments. That is
  /// accepted here because it is not new — `reserve_status` is already public and its
  /// `promisedTotal` leaks per-order amounts the same way, and USD is near-derivable from
  /// the public `card_tiers`/`quote_previews` — but the field-level reading of the test is
  /// what will wave through the field that *does* add something. Do not add a
  /// most-recent-order field, a largest-purchase field, or anything per-principal.
  ///
  /// ⚠️ **`refusingNow` is REUSED, not re-derived.** It is the same `gateState.latch`
  /// `refusal_counts` reports, so "is the rail accepting orders" has one definition and
  /// cannot come out differently on two surfaces.
  ///
  /// ⚠️ **The counters read zero on a fresh install and that is correct, not a bug.**
  /// Orders are never deleted, but a reinstall replaces the state, so a launch-day figure
  /// starts at zero whichever way it is built.
  ///
  /// ⚠️ **The renderer must show that zero — do NOT add a threshold.** #39 first said "0
  /// orders delivered is worse than no badge" and that was rejected: an absent number is
  /// indistinguishable from a withheld one, and a rule that hides the figure exactly when
  /// the news is bad is a misleading presentation rather than a neutral one. This comment
  /// used to instruct the opposite, which would have had a future implementer build the
  /// thing the decision removed.
  ///
  /// `nullPaid` should always be 0. It counts delivered orders whose `paidUsdCents` was
  /// unset, which `markPaid` makes unreachable — a non-zero value means the USD total is
  /// understated and the reason is a bug in this canister, not in the display.
  /// ⚠️ **One call, because it is the landing page's whole backend.** `availableToSell`
  /// and `refusingNow` also appear on `reserve_status` and `refusal_counts` — that is
  /// duplication of the READER, not of the definition: both are read here from the same
  /// state those queries read, never recomputed. Folding them in keeps a first paint to a
  /// single round trip and a single mock in the test harness.
  ///
  /// ⚠️ **`availableToSell` leads, and it is a different KIND of number from the
  /// others.** It is derived from a balance on the cycles ledger that anyone can query
  /// without this canister's cooperation, so a visitor can check it rather than believe
  /// it. The delivered totals are ours to report. Do not present them as equivalent.
  public query func delivery_stats() : async {
    availableToSell : Nat;
    deliveredOrders : Nat;
    deliveredCycles : Nat;
    deliveredUsdCents : Nat;
    nullPaid : Nat;
    refusingNow : Gate.RailStateLatch;
  } {
    let totals = Orders.deliveryTotals(orderStore);
    {
      availableToSell = Reserve.available(reserveState.floor, Orders.promised(orderStore));
      deliveredOrders = totals.orders;
      deliveredCycles = totals.cycles;
      deliveredUsdCents = totals.usdCents;
      nullPaid = totals.nullPaid;
      refusingNow = gateState.latch;
    };
  };

  /// "Is anything wrong right now" in ONE call (#68).
  ///
  /// ⚠️ **Public is a decision, not a default: #3's alerting needs no credentials.** What
  /// reaches a human at 03:00 is a cron on the public queries, and an admin-gated summary
  /// would put that back on a credentialed cron. Everything here is a COUNT, never an
  /// entry, and `reserve_status` already publishes `totalOrders`, `openOrders`,
  /// `expiredOrders`, `promisedTotal` and `availableToSell` — so there is no new exposure
  /// class, only one fewer round trip.
  ///
  /// ⚠️ **The two delivery numbers are measured over DIFFERENT populations, and neither
  /// contains the other.** `deliveriesOutstanding` means a transfer has been ISSUED, so it
  /// needs the journal entry that records the intent. `deliveriesDelayed` reads the
  /// ORDER's own clock and needs neither.
  ///
  /// Both directions are reachable, so `deliveriesDelayed` is **not** a subset:
  ///   - outstanding, not delayed: a transfer issued seconds ago.
  ///   - delayed, not outstanding: a delivery that bailed before issuing — short reserve,
  ///     stale rate, gas floor — so there is no intent to be outstanding about.
  ///   - both: a transfer issued long enough ago that the clock ran out, including one that
  ///     landed without its block recorded.
  ///
  /// ⚠️ That last case is the CANONICAL outstanding shape (`intent` set, `blockIndex`
  /// null), not a delayed-only one — it is what `unsettledDeliveries` exists to detect and
  /// what freezes the reconcile's quiet window. Filing it under "delayed, not outstanding"
  /// would tell an operator that `outstanding = 0` means no transfer is in flight, when a
  /// transfer of unknown fate is exactly what it means.
  ///
  /// ⚠️ So `outstanding = 0, delayed = 1` is a real state, not the summary contradicting
  /// itself — and a UI that presented one as a subset of the other would be wrong exactly
  /// where it matters.
  ///
  /// They also differ in what they ask of a human: `deliveriesOutstanding` self-clears —
  /// it is money-out in flight and the answer is wait — while `ordersNeedingReview`,
  /// `orphansUnresolved` and `problemsUnresolved` are the three that mean a human is
  /// needed. A summary that flattened those would make waiting look like work.
  ///
  /// ⚠️ **`deliveriesOutstanding` is exactly the reserve reconcile's quiet-window
  /// predicate**, deliberately: it is also the answer to "why does the reconcile keep
  /// skipping", and sharing the definition means the number an operator reads cannot
  /// disagree with the number the reconcile acted on.
  ///
  /// **What bounds each number, stated because "bounded" alone would hide a difference:**
  /// `ordersNeedingReview`, `ordersWithProblems` and `availableToSell` are O(1) tallies.
  /// `deliveriesOutstanding` and `deliveriesDelayed` are bounded by `promiseHolders`, i.e.
  /// by flow (§5.4). ⚠️ `problemsUnresolved` is bounded by the unresolved-problem index and
  /// `orphansUnresolved` walks retained orphan history — both grow only while obligations
  /// go uncleared, and an orphan costs a real payment or the signing secret to create
  /// (`Orphans.add`), so neither is attacker-inflatable. Not O(1), and not the
  /// grows-with-successful-business shape #69 and #70 removed.
  public query func operator_summary() : async {
    deliveriesOutstanding : Nat;
    deliveriesDelayed : Nat;
    ordersNeedingReview : Nat;
    orphansUnresolved : Nat;
    problemsUnresolved : Nat;
    ordersWithProblems : Nat;
    refusingNow : Gate.RailStateLatch;
    availableToSell : Nat;
    reserveObservedAtNs : ?Int;
  } {
    {
      deliveriesOutstanding = ops.unsettledDeliveries();
      deliveriesDelayed = ops.delayedDeliveryCount(Time.now());
      ordersNeedingReview = Orders.countOf(orderStore, #needsReview);
      orphansUnresolved = Orphans.unresolvedCount(orphanStore);
      problemsUnresolved = Orders.unresolvedProblemCount(orderStore);
      ordersWithProblems = Orders.unresolvedProblemOrderCount(orderStore);
      refusingNow = gateState.latch;
      availableToSell = Reserve.available(reserveState.floor, Orders.promised(orderStore));
      reserveObservedAtNs = reserveState.observedAtNs;
    };
  };

  /// The recovery machinery's own clocks and its last findings, public.
  ///
  /// Four independent passes report here — the stranded sweep, the tally reconcile, the
  /// reserve reconcile and the rotating index scan — because each can stop running
  /// without any of the others noticing. RUNBOOK §8 alerts on the gaps between them.
  public query func recovery_status() : async {
    intervalNs : Nat;
    lastSweep : ?{ atNs : Int; pending : Nat };
    sweepInFlight : Bool;
    /// Last **successful** tally reconciliation. A non-empty `drift` means the
    /// incremental counts had diverged and were **raised** to the recount — the tallies
    /// are correct again, but the bug that moved them is not fixed. A non-empty
    /// `refused` means the recount came out **lower** and the pass would not adopt it,
    /// so those tallies are still suspect (#63). `recount_orders` is the on-demand form
    /// of the same pass, with the same rule.
    lastCountReconcile : ?{
      atNs : Int;
      drift : [Orders.Drift];
      refused : [Orders.Drift];
      ordersRead : Nat;
    };
    /// When one was last *attempted*. Reported alongside the success timestamp so
    /// "due tomorrow" and "attempted today and failed" are distinguishable without
    /// correlating against the sweep clock: an attempt materially newer than the
    /// success means the reconcile is trapping (RUNBOOK §8).
    lastCountReconcileAttemptNs : Int;
    /// When the RESERVE reconcile was last attempted (#30 PR-B). Its success clock
    /// is `reserve_status.reserveObservedAtNs`, and the two diverging is the one
    /// signal that says "the floor is stale on purpose": either the ledger read is
    /// failing, or every attempt has landed on a non-quiet window. Both under-sell
    /// rather than over-sell, so this is a P3 that explains refusals — not an
    /// incident.
    lastReserveReconcileAttemptNs : Int;
    /// The rotating index scan's **coverage** (#63) — the reader without which a clean
    /// scan says nothing.
    ///
    /// ⚠️ **Read `lastCompletedCycle` before reading the absence of an audit line as
    /// "no drift".** The scan verifies the one property that needs every order — that
    /// nothing *outside* an index satisfies the index's predicate — so it can only
    /// speak for what it has visited. Silence plus a recent `completedAtNs` means
    /// verified clean; silence with no completed cycle, or one much older than the
    /// window below, means **unverified**, which is not the same thing and carries the
    /// opposite response: wait for the pass rather than hunt for a writer.
    ///
    /// `inFlightCycle.ordersRead` against `storedOrders` is how far the current cycle
    /// has walked. `chunkSize` and the sweep interval give the expected window:
    /// `storedOrders ÷ (chunkSize × sweeps per day)` days per full cycle.
    indexScan : {
      chunkSize : Nat;
      storedOrders : Nat;
      /// How long a full coverage cycle is **expected** to take at the current store
      /// size and the current sweep cadence.
      ///
      /// ⚠️ **Computed, not configured, so it moves when either input does** — and the
      /// sweep cadence is one `set_recovery_interval` away from 24× the default. This is
      /// the detection latency for `orders.unindexedHolders`, which is a money finding,
      /// so it is reported rather than left as arithmetic an operator has to know to do.
      /// Compare `lastCompletedCycle.completedAtNs` against this: much older means the
      /// scan is behind its own expectation, not merely mid-cycle.
      expectedFullCycleNs : Nat;
      inFlightCycle : { startedAtNs : Int; ordersRead : Nat; repairs : Nat };
      lastCompletedCycle : ?{
        startedAtNs : Int;
        completedAtNs : Int;
        ordersRead : Nat;
        repairs : Nat;
      };
    };
  } {
    {
      intervalNs = recoveryState.sweepIntervalNs;
      lastSweep = recoveryState.lastSweep;
      sweepInFlight = ops.recoverySweepInFlight();
      lastCountReconcile = recoveryState.lastCountReconcile;
      lastCountReconcileAttemptNs = recoveryState.lastCountReconcileAttemptNs;
      lastReserveReconcileAttemptNs = recoveryState.lastReserveReconcileAttemptNs;
      indexScan = {
        chunkSize = Orders.scanChunkSize;
        storedOrders = Orders.storedCount(orderStore);
        expectedFullCycleNs = ops.expectedIndexScanCycleNs();
        inFlightCycle = recoveryState.indexScanCycle;
        lastCompletedCycle = recoveryState.lastIndexScanCycle;
      };
    };
  };

  /// Liveness probe; also used by the scaffold smoke test path.
  public query func health() : async Bool {
    true;
  };
};
