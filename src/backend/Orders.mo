/// Order store + the §4 state machine.
///
/// The state machine owns *transitions only*. Expiry policy, solvency checks,
/// dedup, and delivery are the callers' business (per-rail money-in, §5
/// money-out) — they ask for a transition and this module answers whether it
/// is legal. Seam §11.1.3: `create` takes the owner as a parameter and never
/// reads a caller itself; owners come from an II Candid call,
/// a future Base owner from a verified EIP-3009 signature.
import Array "mo:core/Array";
import Problems "Problems";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Set "mo:core/Set";
import List "mo:core/List";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Result "mo:core/Result";
import Reserve "Reserve";
import Types "Types";
import Util "Util";

module {

  /// 128 bits of raw_rand entropy per order ID (§2: random, not a counter —
  /// the ID is public inside `client_reference_id`, so it must not leak
  /// order volume or be enumerable; it is NOT a bearer secret).
  public let idEntropyBytes : Nat = 16;

  /// Derive an order ID (32 lowercase hex chars) from the first
  /// `idEntropyBytes` of a raw_rand blob; null if the entropy is too short
  /// (raw_rand returns 32 bytes, so null means a broken caller, not bad luck).
  public func idFromEntropy(entropy : Blob) : ?Types.OrderId {
    if (entropy.size() < idEntropyBytes) return null;
    let prefix = entropy.toArray().sliceToArray(0, idEntropyBytes);
    ?Util.hexEncode(Blob.fromArray(prefix));
  };

  /// §6.1 — the reference the canister sets on the Checkout Session it creates
  /// (#33); it used to be appended to a Payment Link URL by the frontend:
  /// `<principal>_<orderId>`. Unambiguous to split: principal text is
  /// `[a-z0-9-]`, the ID is hex, so the one `_` is the separator. Claimed,
  /// not trusted — webhook ingestion re-resolves and verifies it.
  public func clientReferenceId(owner : Types.Owner, id : Types.OrderId) : Text {
    switch (owner) {
      case (#ii(p)) p.toText() # "_" # id;
    };
  };

  /// Inverse of `clientReferenceId`, claimed-not-trusted (§4.1: it is an
  /// attacker-editable URL param). Returns the *claimed* owner principal
  /// text and order ID — the caller must verify both against the stored
  /// order; null on any shape deviation. Principal text is compared as
  /// text, never `Principal.fromText`-ed: that traps on garbage, and a
  /// trapped webhook is a 5xx Stripe retries forever.
  public func parseClientReferenceId(ref : Text) : ?(Text, Types.OrderId) {
    let parts = ref.split(#char '_').toArray();
    if (parts.size() != 2) return null;
    if (parts[0] == "") return null;
    if (parts[1].size() != idEntropyBytes * 2) return null;
    for (c in parts[1].chars()) {
      if (not ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return null;
    };
    ?(parts[0], parts[1]);
  };

  public type Store = {
    /// §4.2 — `orders : Map<OrderId, Order>`.
    orders : Map.Map<Types.OrderId, Types.Order>;
    /// §4.2 — order history per principal (fixes the lost-receipt problem).
    ///
    /// ⚠️ **A `Set`, so `ownerPage` can seek to a cursor in O(log n).** A `List` holds
    /// insertion order, which has no relation to the `OrderId` order every cursor in this
    /// codebase is expressed in — so paging it meant scanning the whole store instead.
    principalsToOrders : Map.Map<Principal, Set.Set<Types.OrderId>>;
    /// Live per-status tallies, maintained by `create` / `applyTransition` /
    /// `markPaid` — the only three functions that write an order's status.
    ///
    /// These exist so the public status queries are O(1). Counting by scanning
    /// `orders` makes an unauthenticated query cost O(total orders), which is
    /// an operation that is free for anyone to invoke and grows more expensive
    /// forever — the shape of DoS the security guidance warns about.
    ///
    /// Only the statuses the queries report are tracked; `countOf` returns 0
    /// for the rest. `recount` rebuilds them if they are ever suspected wrong.
    counts : Map.Map<Text, Nat>;
    /// #30 PR-B — cycles promised to orders that exist and are not settled.
    ///
    /// ⚠️ **It lives HERE, in the store, deliberately.** `create`,
    /// `applyTransition` and `markPaid` are the only three functions that write an
    /// order's status, and they are all in this module — so the tally sits next to
    /// every site that can move it, and adding a fourth writer means editing this
    /// file and seeing the tally. Holding it in `Main.mo` instead would put the
    /// state and its adjustment sites in different files, which is how per-status
    /// counters drift.
    ///
    /// The value is `Σ lockedCycles` over orders whose status is **not terminal**
    /// (`Reserve.holdsPromise`). See `Reserve.mo` for why it is a rule rather than
    /// a list, and why there is no fee term.
    var promised : Nat;
    /// How many times `promised` had to saturate at zero — i.e. a release asked to
    /// remove more than was held. **Any non-zero value means the tally diverged**,
    /// and it is surfaced by `reserve_status` so it does not wait for a recount.
    var tallySaturations : Nat;
    /// Orders carrying at least one **unresolved** problem (#37).
    ///
    /// ⚠️ **An index, because the alternative is a full scan on the webhook path.**
    /// `resolveByPaymentRef` runs synchronously inside the `charge.refunded` handler,
    /// where a trap is a 5xx Stripe retries for three days. Under indefinite retention
    /// a scan over every order ever created is exactly the hazard this codebase guards
    /// everywhere else.
    ///
    /// ⚠️ **A status index would NOT have bounded it** — `#duplicate` is filed from a
    /// catch-all covering `#delivered` (the *common* case: order delivered, buyer pays
    /// again) as well as terminal statuses, so a non-terminal index narrows nothing.
    /// Establish that a bound narrows the set before writing that it does.
    ///
    /// ⚠️ **Derived state, safe only because the orders can adjudicate it.** Maintained by
    /// the only two functions that write `problems` — `fileProblem` and `resolveProblems`,
    /// both here — and checked from both directions: the inside daily by
    /// `reconcileBounded`, the outside on a coverage window by `scanChunk` (#63). This is
    /// a projection of `orders`, recomputable at any time; a **map pointing at ids in
    /// another structure** would be the unrecoverable version, because the two could
    /// disagree with no way to tell which was right.
    ///
    /// ⚠️ **No wholesale rebuild lever, deliberately.** A pass that clears and refills
    /// this from every order grows with lifetime sales, and "the index was rebuilt" reads
    /// as a fix for what is actually a bug in this file.
    ///
    /// Growth is attacker-priced: every problem needs a real payment event to exist.
    unresolvedProblems : Set.Set<Types.OrderId>;
    /// Orders whose promise is still held — i.e. **the non-terminal set** (#63).
    ///
    /// ⚠️ **Named for the predicate that defines it, not for what it is used for.**
    /// `Reserve.holdsPromise` IS the membership rule, and it is the same predicate the
    /// `promised` tally moves on, so the two cannot drift apart into two definitions of
    /// "still live". ⚠️ Do not read this as `reserve_status.openOrders` — that figure is
    /// the `#created` tally alone, a strict subset.
    ///
    /// ⚠️ **Bounded by the reserve, which is what makes it fit in one message.** Every
    /// member holds its `lockedCycles` in `promised`, and admission refuses once
    /// `promised` would exceed the reserve floor (`Reserve.canCover`), so
    /// `|promiseHolders| ≤ reserveFloor / minimum order`. That bound is set by **flow**,
    /// not by lifetime sales — which is precisely what the order store is not.
    ///
    /// ⚠️ **It is derived state trusted by the reconcile, so read `#63`'s circularity
    /// argument before extending it.** The rule that makes it safe: iterating this and
    /// reading each order's real status yields a tally that is **exact if the index is
    /// complete and too LOW otherwise** — never too high, because a member whose order
    /// turned out terminal is dropped on sight. So the reconcile adopts only
    /// *increases*, and the one error direction this index can hide is the one direction
    /// it refuses to adopt. The completeness half — nothing outside here holds a promise
    /// — is not knowable from the index at all, and that is what the rotating
    /// `scanChunk` is for.
    promiseHolders : Set.Set<Types.OrderId>;
    /// Cumulative deliveries, for the public trust figures (#39).
    ///
    /// ⚠️ **Counted in `commitTransition` on the transition INTO `#delivered`, which is
    /// the only place it can be counted exactly.** Six call sites move an order to
    /// `#delivered`, so a per-site counter would be six chances to forget — and this file
    /// already carries the scar of a comment that named "the only three writers" and was
    /// false in the same file. Here it is structural: writing a status *is* calling that
    /// function.
    ///
    /// ⚠️ **Double-counting is unrepresentable, not merely unlikely.** `#delivered` has no
    /// outbound edge in `isLegalTransition`, so once an order is delivered
    /// `commitTransition` is never called for it again. There is no idempotency guard here
    /// because none is reachable.
    ///
    /// ⚠️ **`cycles` is what was SOLD (`lockedCycles`), not what landed** (`lockedCycles −
    /// the ledger fee, which the reserve absorbs). The difference is one transfer fee per
    /// order — around 0.0014% at the smallest tier — and buying exactness would mean
    /// threading the delivered amount through six sites for a figure that is displayed
    /// rounded to two significant figures. Say "sold" if the wording ever has to be
    /// precise.
    var deliveredOrders : Nat;
    var deliveredCycles : Nat;
    /// ⚠️ Cumulative gross USD cents actually PAID (`paidUsdCents`), not quoted. Null
    /// cannot happen on a delivered order — `markPaid` sets it before any delivery — so a
    /// null contributes zero and `deliveredNullPaid` records that the impossible happened
    /// rather than silently understating the total.
    var deliveredUsdCents : Nat;
    var deliveredNullPaid : Nat;
    /// The highest `#expired` tally seen by a reconcile, for the monotonicity check
    /// that replaces re-summing it (#63).
    ///
    /// ⚠️ **`#expired` is the only tracked status that is terminal**, so it is the only
    /// one `promiseHolders` cannot recount — and it is also the only one that can be
    /// checked without history: `#created → #expired` is its sole inbound edge and the
    /// matrix has no outbound one, so the tally is **monotonically non-decreasing**. A
    /// decrease is a bookkeeping breach.
    ///
    /// ⚠️ **It follows the count back DOWN once a decrease is reported**, so each
    /// decrease is reported exactly once. Holding a true high-water mark would re-report
    /// the same unfixed condition on every daily pass — our own cadence bounding a
    /// *rate* against a persistent state, which is the fault #37 §2c removed from the
    /// audit log.
    var expiredHighWater : Nat;
  };

  public func emptyStore() : Store {
    {
      orders = Map.empty<Types.OrderId, Types.Order>();
      principalsToOrders = Map.empty<Principal, Set.Set<Types.OrderId>>();
      counts = Map.empty<Text, Nat>();
      var promised = 0;
      var tallySaturations = 0;
      unresolvedProblems = Set.empty<Types.OrderId>();
      promiseHolders = Set.empty<Types.OrderId>();
      var deliveredOrders = 0;
      var deliveredCycles = 0;
      var deliveredUsdCents = 0;
      var deliveredNullPaid = 0;
      var expiredHighWater = 0;
    };
  };

  /// Cycles promised to unsettled orders (#30 PR-B). O(1).
  public func promised(store : Store) : Nat {
    store.promised;
  };

  /// How many orders still hold a promise. O(1) — `Set.size` is a stored field.
  public func promiseHolderCount(store : Store) : Nat {
    store.promiseHolders.size();
  };

  /// The ids of every order that still holds a promise, in id order.
  ///
  /// ⚠️ **This is the bounded stand-in for a store walk, and callers owe it two
  /// disciplines.** *One*: look each id up rather than trusting the index for the
  /// order's status — the index is derived state and the order is the record. *Two*:
  /// materialise the ids before doing anything that can `await` or transition an order,
  /// because a transition removes members and mutating a Set under iteration is not
  /// safe. Both are cheap: the set is bounded by the reserve.
  public func promiseHolderIds(store : Store) : Iter.Iter<Types.OrderId> {
    store.promiseHolders.values();
  };

  /// Resume iterating the promise holders at or after `id` — the seek a paginated
  /// admin query needs, in O(log n) rather than by re-walking.
  public func promiseHolderIdsFrom(store : Store, id : Types.OrderId) : Iter.Iter<Types.OrderId> {
    store.promiseHolders.valuesFrom(id);
  };

  /// The cumulative delivery figures (#39). O(1) — maintained, never scanned.
  public func deliveryTotals(store : Store) : {
    orders : Nat;
    cycles : Nat;
    usdCents : Nat;
    nullPaid : Nat;
  } {
    {
      orders = store.deliveredOrders;
      cycles = store.deliveredCycles;
      usdCents = store.deliveredUsdCents;
      nullPaid = store.deliveredNullPaid;
    };
  };

  /// How many orders the store holds in total. O(1), and the only figure derived from
  /// lifetime sales that any reconcile path may read — it costs one field read, not a
  /// walk.
  public func storedCount(store : Store) : Nat {
    store.orders.size();
  };

  /// Statuses whose live counts are maintained. Keyed by `statusToText` so the
  /// map is a shared type and the key set is self-documenting.
  ///
  /// ⚠️ **A status earns an O(1) tally only when something READS it, and the reader is
  /// named here** — a justification citing readers that do not exist is how this list
  /// drifts.
  ///
  ///   - `#paid` → `Main.sweepableCount`, which short-circuits the recovery sweep at 0.
  ///     The only tally on a money path.
  ///   - `#created`, `#expired` → `reserve_status`. Operator metrics, not decisions.
  ///   - `#needsReview` → nothing reads it, and it stays tracked on purpose: being here
  ///     is what puts escalated orders under `reconcileBounded`'s drift detection, and an
  ///     order whose money position a human is establishing is the last one whose
  ///     bookkeeping should go unchecked.
  ///
  /// ⚠️ **The admission gate reads NONE of these**, and must not be "optimised" onto
  /// `countOf`: its cap is per principal, so a global tally cannot answer it, and
  /// switching would silently change the cap's meaning from per-buyer to system-wide.
  ///
  /// `#cancelled`, `#delivered` and `#abandoned` are absent because nothing counts them.
  let trackedStatuses : [Types.OrderStatus] = [#created, #expired, #paid, #needsReview];

  func isTracked(status : Types.OrderStatus) : Bool {
    for (tracked in trackedStatuses.values()) {
      if (tracked == status) return true;
    };
    false;
  };

  func bump(store : Store, status : Types.OrderStatus, delta : Int) {
    if (not isTracked(status)) return;
    let key = Types.statusToText(status);
    let current = switch (store.counts.get(key)) { case (?n) n; case null 0 };
    let next : Int = current + delta;
    // Clamp at zero rather than trapping: a miscount must never be able to
    // break the money path, and `recount` is the repair lever.
    store.counts.add(key, if (next < 0) 0 else Int.abs(next));
  };

  /// Live count for a tracked status; 0 for anything untracked.
  public func countOf(store : Store, status : Types.OrderStatus) : Nat {
    switch (store.counts.get(Types.statusToText(status))) {
      case (?n) n;
      case null 0;
    };
  };

  /// Every tracked status paired with its current tally, in `trackedStatuses`
  /// order — so two snapshots can be compared index-by-index.
  func snapshotCounts(store : Store) : [(Text, Nat)] {
    let out = List.empty<(Text, Nat)>();
    for (status in trackedStatuses.values()) {
      out.add((Types.statusToText(status), countOf(store, status)));
    };
    out.toArray();
  };

  /// A tracked count that did not match the order store: what it said, and what
  /// the orders actually add up to.
  public type Drift = { status : Text; was : Nat; is : Nat };

  /// What one bounded reconcile pass found (#63).
  ///
  /// ⚠️ **Every field is either a repair that was applied or a breach that was
  /// refused, and the caller must be able to tell which.** A report that collapsed the
  /// two would leave an operator unable to answer the only question that matters —
  /// *is the tally I am about to trust correct now?*
  public type Reconciliation = {
    /// Every tracked count as it stands **after** the pass, in `trackedStatuses` order.
    counts : [(Text, Nat)];
    /// Tallies that disagreed and were **raised** to the recount.
    adopted : [Drift];
    /// Tallies that disagreed where the recount was **lower**, so it was refused and
    /// the maintained value stands. See `adoptOnlyIncreases`.
    refused : [Drift];
    /// The promise tally: what it said, what the non-terminal set adds up to, and
    /// whether the recount was adopted. Same one-directional rule.
    promisedWas : Nat;
    promisedIs : Nat;
    promisedAdopted : Bool;
    /// Members of `promiseHolders` whose order is terminal, or absent from the store.
    /// **Dropped by this pass** — reading the order's real status is authoritative, so
    /// this repair is not a guess.
    staleHolders : [Types.OrderId];
    /// Members of `unresolvedProblems` with no unresolved problem. Dropped, same
    /// authority.
    staleProblemIds : [Types.OrderId];
    /// `#expired` monotonicity: the previous high water, and the tally now. `is <
    /// was` is a breach (see `Store.expiredHighWater`).
    expiredWas : Nat;
    expiredIs : Nat;
    /// `countOf(#expired) + |promiseHolders| > |orders|`, which is arithmetically
    /// impossible — the two sets are disjoint subsets of the store. A cheap upper
    /// bound on the one tally monotonicity cannot bound from above.
    expiredOverflow : Bool;
    /// How many orders this pass read. **Bounded by the two index sizes**, never by
    /// lifetime sales — that is the whole point of the pass.
    ordersRead : Nat;
  };

  /// ⚠️ **The rule that makes an index-derived recount safe to adopt, stated once
  /// because three tallies follow it.**
  ///
  /// A recount taken over `promiseHolders` is **exact if the index is complete and too
  /// low otherwise** — never too high, because `reconcileBounded` drops a member whose
  /// order it reads as terminal before counting it. So:
  ///
  ///   - recount **>** tally → the tally lost an adjustment. Adopt: every reader of
  ///     these tallies is safer with the larger value. `promised` higher means
  ///     `available` lower, so fewer sales are admitted. `#created` and `#paid` higher
  ///     means the recovery sweeps *run* — both short-circuit on a zero tally, so an
  ///     under-count is what silently stops money-out and stranded-order recovery.
  ///   - recount **<** tally → indistinguishable from an incomplete index, so it is
  ///     **not** evidence. Refuse it and audit; the maintained value stands.
  ///
  /// ⚠️ **The asymmetry is the safety property, not a convenience.** Adopting a
  /// decrease is the only way an index bug could lower `promised` and oversell the
  /// reserve, and this rule makes that unreachable: the direction the index can be
  /// wrong in is the direction the reconcile will not follow.
  ///
  /// ⚠️ **A refused decrease has two causes and the daily pass cannot separate them** —
  /// either the index is missing a member (the tally is right) or the tally gained an
  /// adjustment it should not have (the index is right). Both are bugs in this file and
  /// both are the same P2 response, *find the writer*; and `scanChunk` distinguishes
  /// them, by naming any order outside the index that holds a promise. Daily detection,
  /// rotating attribution.
  func adoptOnlyIncreases(was : Nat, is_ : Nat) : Bool { is_ > was };

  /// Reconcile every maintained tally **without reading history** (#63).
  ///
  /// ⚠️ **Bounded by the two indexes plus one O(1) size read, so its cost is set by
  /// flow rather than by lifetime sales.** The pass it replaced summed every order ever
  /// created in a single message; under indefinite retention that is on a path to the
  /// instruction limit, and a reconcile that traps leaves the tallies *unverified*
  /// rather than known-good.
  ///
  /// ⚠️ **It still takes no `await`, and that is still load-bearing.** A global sum
  /// cannot be chunked across messages — mutations between chunks manufacture false
  /// drift — so the answer was never "page it". It was to stop the sums needing history
  /// at all. `scanChunk` may be chunked precisely because it evaluates a **per-order
  /// predicate** instead of a sum: what it compares is read atomically within one
  /// message, so a mutation to an order it has not reached yet changes coverage, never
  /// the verdict. That distinction — *sums cannot be chunked, per-order predicates can*
  /// — is what splits this file's two mechanisms.
  ///
  /// Four things are checked, each by the cheapest sound means available:
  ///
  ///   1. `#created`, `#paid`, `#needsReview` and `promised` are **recounted exactly**
  ///      over `promiseHolders`. All three statuses are non-terminal, so the index is
  ///      the whole population.
  ///   2. `#expired` — the one tracked terminal status — is checked by **monotonicity**
  ///      plus a disjointness bound. It is not re-summed, because that needs history.
  ///      ⚠️ Nothing decides anything on it (`reserve_status.expiredOrders` is an
  ///      operator metric), which is what makes a non-exact check acceptable *here* and
  ///      not for the three above.
  ///   3. Both indexes are verified in the **inside** direction: every member really
  ///      satisfies its predicate. Cheap, because the indexes are small.
  ///   4. The **outside** direction of both — nothing beyond a set satisfies its
  ///      predicate — is the only part that genuinely needs every order, and it is
  ///      `scanChunk`'s job, on a coverage window rather than daily.
  public func reconcileBounded(store : Store) : Reconciliation {
    var ordersRead = 0;

    // ---- (3) inside direction, and (1) the recount, in one pass -------------------
    // Collect first, mutate after: removing from a Set while iterating it is not safe.
    let stale = List.empty<Types.OrderId>();
    let rebuilt = Map.empty<Text, Nat>();
    var promisedIs = 0;
    for (id in store.promiseHolders.values()) {
      switch (store.orders.get(id)) {
        case (?order) {
          ordersRead += 1;
          if (Reserve.holdsPromise(order.status)) {
            promisedIs += order.lockedCycles;
            if (isTracked(order.status)) {
              let key = Types.statusToText(order.status);
              let seen = switch (rebuilt.get(key)) { case (?n) n; case null 0 };
              rebuilt.add(key, seen + 1);
            };
          } else {
            // The order's own status is the authority; this member is a leftover.
            stale.add(id);
          };
        };
        // Unreachable: orders are never deleted (#37). Dropping is still the right
        // answer if the impossible happens — an id with no order can contribute
        // nothing to a tally, so keeping it would only under-count forever.
        case null stale.add(id);
      };
    };
    for (id in stale.values()) store.promiseHolders.remove(id);

    let staleProblems = List.empty<Types.OrderId>();
    for (id in store.unresolvedProblems.values()) {
      switch (store.orders.get(id)) {
        case (?order) {
          ordersRead += 1;
          if (Problems.unresolvedCount(order.problems) == 0) staleProblems.add(id);
        };
        case null staleProblems.add(id);
      };
    };
    for (id in staleProblems.values()) store.unresolvedProblems.remove(id);

    // ---- (1) adopt increases only -------------------------------------------------
    let adopted = List.empty<Drift>();
    let refused = List.empty<Drift>();
    for (status in trackedStatuses.values()) {
      // `#expired` is terminal, so `promiseHolders` says nothing about it — case (2).
      if (Reserve.holdsPromise(status)) {
        let key = Types.statusToText(status);
        let was = countOf(store, status);
        let is_ = switch (rebuilt.get(key)) { case (?n) n; case null 0 };
        if (was != is_) {
          let drift = { status = key; was; is = is_ };
          if (adoptOnlyIncreases(was, is_)) {
            store.counts.add(key, is_);
            adopted.add(drift);
          } else { refused.add(drift) };
        };
      };
    };

    let promisedWas = store.promised;
    let promisedAdopted = adoptOnlyIncreases(promisedWas, promisedIs);
    if (promisedAdopted) store.promised := promisedIs;

    // ---- (2) `#expired`: monotonicity and disjointness ----------------------------
    let expiredIs = countOf(store, #expired);
    let expiredWas = store.expiredHighWater;
    // Follows the tally down after a decrease so the breach is reported once, not
    // daily until someone fixes it.
    store.expiredHighWater := expiredIs;
    // `#expired` orders and `promiseHolders` are disjoint by construction — the first
    // is terminal, the second is not — and both are subsets of the store, so their
    // sizes cannot exceed it. `Map.size`/`Set.size` are O(1), so this costs nothing.
    let expiredOverflow = expiredIs + store.promiseHolders.size() > store.orders.size();

    {
      counts = snapshotCounts(store);
      adopted = adopted.toArray();
      refused = refused.toArray();
      promisedWas;
      promisedIs;
      promisedAdopted;
      staleHolders = stale.toArray();
      staleProblemIds = staleProblems.toArray();
      expiredWas;
      expiredIs;
      expiredOverflow;
      ordersRead;
    };
  };

  /// One bounded chunk of the rotating pass that verifies the **outside** direction of
  /// both indexes: that nothing beyond a set satisfies the set's predicate (#63).
  ///
  /// ⚠️ **This is the only check that needs every order, so it is the only one with a
  /// coverage window instead of a daily guarantee.** What it reports must therefore name
  /// that window — a passing check over a subset is not evidence about the rest, which
  /// is the truncated-gate-run fault in a different substrate. The caller owns the
  /// cursor and the reporting; this function owns one chunk.
  ///
  /// ⚠️ **Chunking is sound here and is not for the reconcile, for a reason worth
  /// keeping straight.** Each verdict is a **per-order predicate** — the order's own
  /// status or problems against its membership — read within one message, so it is
  /// evaluated against a consistent view no matter what happens to other orders
  /// between chunks. A mutation to an order this chunk has not reached changes *which
  /// cycle covers it*, never whether a verdict was right. A global sum has no such
  /// property, which is why `reconcileBounded` stays in one message.
  ///
  /// ⚠️ **It repairs, and the repair is authoritative rather than a guess**: it has
  /// read the order, and the order is the record. Adding a missing member also feeds the
  /// fix through to the tallies without this function touching them — the next
  /// `reconcileBounded` recounts a larger index, and a larger recount is exactly what
  /// `adoptOnlyIncreases` adopts.
  public type ScanChunk = {
    /// Orders visited by this chunk.
    visited : Nat;
    /// Orders that hold a promise and were **not** in `promiseHolders` — added here.
    ///
    /// ⚠️ **This is the money-critical finding of the whole scan.** It is the one
    /// inconsistency the daily pass cannot see: a member missing from the index while
    /// `promised` is missing its cycles too, so index and tally agree and are both
    /// low — the reserve reads as more available than it is.
    unindexedHolders : [Types.OrderId];
    /// Orders with an unresolved problem that were **not** in `unresolvedProblems` —
    /// added here. The obligation existed and the worklist did not show it.
    unindexedProblems : [Types.OrderId];
    /// Where the next chunk resumes. **`null` means the cycle completed** — every
    /// order that existed when the cycle began has now been visited.
    nextCursor : ?Types.OrderId;
  };

  /// Orders per chunk. Sized so a chunk is a small fraction of one message's
  /// instruction budget: the work per order is a status read, a problems-array length,
  /// and two O(log n) set lookups.
  public let scanChunkSize : Nat = 2_000;

  public func scanChunk(store : Store, from : ?Types.OrderId, limit : Nat) : ScanChunk {
    let capped = if (limit == 0 or limit > scanChunkSize) scanChunkSize else limit;
    let holders = List.empty<Types.OrderId>();
    let problems = List.empty<Types.OrderId>();
    var visited = 0;
    var last : ?Types.OrderId = null;
    var exhausted = true;
    // `entriesFrom` seeks in O(log n) and is INCLUSIVE of the key, so the cursor — the
    // last id already visited — is skipped explicitly. Seeking by re-walking from the
    // start would make every chunk cost what the whole pass was supposed to stop
    // costing, which is how a "bounded" scan quietly is not one.
    let it = switch (from) {
      case (?cursor) store.orders.entriesFrom(cursor);
      case null store.orders.entries();
    };
    // ⚠️ **`break`, not a flag.** Letting the loop run on after the chunk fills would
    // read every remaining order to do nothing with it — the bound would be on what is
    // reported, not on what is touched, which is the same conflation of *response size*
    // with *work per message* that #63 exists to undo.
    label chunk for ((id, order) in it) {
      let isCursor = switch (from) { case (?cursor) id == cursor; case null false };
      if (not isCursor) {
        if (visited == capped) { exhausted := false; break chunk };
        visited += 1;
        last := ?id;
        if (Reserve.holdsPromise(order.status) and not store.promiseHolders.contains(id)) {
          holders.add(id);
        };
        if (Problems.unresolvedCount(order.problems) > 0 and not store.unresolvedProblems.contains(id)) {
          problems.add(id);
        };
      };
    };
    // ⚠️ **Applied on BOTH exits.** An earlier draft returned from inside the loop when
    // the chunk filled and skipped these two lines — so the one repair the scan exists
    // to perform was silently dropped on every chunk except the last of a cycle.
    for (id in holders.values()) store.promiseHolders.add(id);
    for (id in problems.values()) store.unresolvedProblems.add(id);
    {
      visited;
      unindexedHolders = holders.toArray();
      unindexedProblems = problems.toArray();
      nextCursor = if (exhausted) null else last;
    };
  };

  public type CreateError = {
    /// raw_rand collision (astronomically unlikely) — caller retries with
    /// fresh randomness rather than silently overwriting an order.
    #duplicateId : Types.OrderId;
  };

  public type TransitionError = {
    #notFound : Types.OrderId;
    #illegalTransition : { from : Types.OrderStatus; to : Types.OrderStatus };
  };

  /// The §4 diagram plus the escalation edges it implies, all of which land in
  /// `#needsReview` — the order still owes cycles, so its promise stays held.
  ///
  /// **The terminal set is `#delivered`, `#cancelled`, `#expired`, `#abandoned`.**
  /// Resolving an orphan *entry* is human and off-chain (§4.1) and never
  /// transitions an order; `abandon_order` is the only thing that ends one, and
  /// `#needsReview → #abandoned` is its single outgoing edge.
  ///
  /// ⚠️ **A guard mirrors this matrix and the compiler does not check it**:
  /// `Card.handleWebhook`'s status switch, which feeds `markPaid`, so anything it
  /// admits that this refuses is a bug — and on that path a trap, i.e. a 5xx
  /// Stripe retries for ~3 days. Change this and check the guard. It was two
  /// guards until #33 deleted `attach_payment`; #34 shipped the first fix and
  /// missed the second, so the lesson is to grep for `markPaid`'s CALLERS, not
  /// for the trap.
  public func isLegalTransition(from : Types.OrderStatus, to : Types.OrderStatus) : Bool {
    switch (from, to) {
      case (#created, #cancelled) true; // the buyer gave up before paying (#34)
      case (#created, #expired) true; // never paid (§4)
      case (#created, #paid) true; // webhook verified, deduped, amount honored
      // Delivery is ONE transfer out of the cycles reserve, so this single edge is
      // the whole money-out path. ⚠️ **Deleting it fails silently in the worst
      // direction:** `tryTransition` returns null *after* the transfer has landed, so
      // the buyer holds their cycles and the order sits `#paid` forever, looking
      // undelivered to every sweep that comes past.
      case (#paid, #delivered) true;
      case (#paid, #needsReview) true; // paid, undelivered past max wait (§5)
      // The operator read the ledger and the transfer HAD landed.
      //
      // ⚠️ **Added because its absence made the operator record a lie.** Until this
      // edge existed, `#needsReview`'s only exit was `#abandoned`, so an escalated
      // order whose cycles the buyer demonstrably has could only be filed as
      // abandoned — auditing a refund that never happened. Money-correct,
      // record-wrong, and the record is what this codebase trusts to keep illegal
      // states unrepresentable.
      //
      // Not a routine path: `#needsReview` means the money position is unknown, and
      // reaching it at all takes a ~24 h cycles-ledger outage. Only `record_delivered`
      // drives it, admin-only, and it demands the ledger block as evidence — no
      // automatic route to `#delivered` from an unknown position exists, because that
      // is the double-delivery this status prevents.
      case (#needsReview, #delivered) true;
      // `abandon_order` — the operator ends it, having refunded by hand. The
      // #needsReview edge is what the #37 split made possible: an
      // escalated order could not previously be abandoned, because one status
      // meant both "promise held" and "promise released".
      case (#paid, #abandoned) true;
      case (#needsReview, #abandoned) true;
      case _ false;
    };
  };

  /// Pure transition: legal → updated copy, illegal → error. Callers decide
  /// *when* to ask (expiry timers, solvency checks); this decides *whether*.
  public func transition(
    order : Types.Order,
    to : Types.OrderStatus,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    if (isLegalTransition(order.status, to)) {
      #ok({ order with status = to; updatedAtNs = nowNs });
    } else {
      #err(#illegalTransition({ from = order.status; to }));
    };
  };

  /// Create an order in `#created`, locking the cycle quantity (§3). Owner is
  /// a parameter, never a caller read (seam §11.1.3).
  public func create(
    store : Store,
    id : Types.OrderId,
    owner : Types.Owner,
    rail : Types.Rail,
    destination : Types.Destination,
    lockedCycles : Nat,
    pricing : Types.Pricing,
    nowNs : Int,
  ) : Result.Result<Types.Order, CreateError> {
    if (store.orders.containsKey(id)) {
      return #err(#duplicateId(id));
    };
    let order : Types.Order = {
      id;
      owner;
      rail;
      destination;
      lockedCycles;
      pricing;
      status = #created;
      paidUsdCents = null;
      // All four are the session's, and no session exists yet: #33 stamps them
      // from the Checkout Session it creates. `expiredBy` stays null unless the
      // order reaches `#expired` with a known cause.
      expiredBy = null;
      expiresAtNs = null;
      stripeSessionId = null;
      stripeSessionUrl = null;
      delayedAtNs = null;
      abandonedReason = null;
      problems = [];
      createdAtNs = nowNs;
      updatedAtNs = nowNs;
    };
    store.orders.add(id, order);
    bump(store, #created, 1);
    // #63: the non-terminal index, entered here for the same reason `promised` is —
    // an order APPEARS in the held set rather than transitioning into it. Expressed
    // through `holdsPromise` rather than as "`#created` always holds" so that this
    // site and `commitTransition` share one definition of membership.
    if (Reserve.holdsPromise(order.status)) store.promiseHolders.add(id);
    // #30 PR-B: the hold at creation. ⚠️ **Not a transition** — an order appears in
    // the counted set rather than moving into it — so it lives outside the
    // transition machinery entirely, which is why #30 calls `create` an adjustment
    // site in its own right. Missing this is the one leak the recount could not
    // attribute to a status change.
    store.promised += lockedCycles;
    let principal = switch (owner) { case (#ii(p)) p };
    switch (store.principalsToOrders.get(principal)) {
      case (?ids) ids.add(id);
      case null {
        let ids = Set.empty<Types.OrderId>();
        ids.add(id);
        store.principalsToOrders.add(principal, ids);
      };
    };
    #ok(order);
  };

  /// ⚠️ **The ONLY way a status reaches the store.** Writes the record, both per-status
  /// counters, the promise tally and the non-terminal index, in one place — so a new
  /// writer cannot forget them, because writing a status *is* calling this.
  ///
  /// A comment naming "the only three writers" was once false **in the same file**: two
  /// more wrote status with hand-rolled tally updates, and one of them is the most common
  /// release in the design (every unpaid order expires). Every expired order would have
  /// left its `lockedCycles` in the tally forever, ratcheting `available` down until the
  /// rail closed on a full reserve. Proximity was not enough; the invariant is structural
  /// now. (`attachSession` legitimately does not call this — it changes no status.)
  ///
  /// ⚠️ **Returns the order AS STORED, and callers must hand that back** rather than the
  /// value they passed in: this mutates the order, not just the tallies, so the two can
  /// disagree.
  func commitTransition(store : Store, before : Types.Order, after : Types.Order) : Types.Order {
    // ⚠️ **Clear the pay link on the way into a terminal state (#37), HERE and not at
    // each terminal site.** It is by far the largest field on an order — a Stripe
    // checkout URL runs to a couple of hundred characters — and it is worthless
    // thirty minutes after creation, so dropping it roughly halves the long-term size
    // of an order under indefinite retention.
    //
    // Structural for the same reason the tally is: a future terminal path added
    // elsewhere cannot forget, because writing a status *is* calling this. Doing it at
    // the call sites would work today and silently stop working on the next one.
    //
    // ⚠️ Safe against every reader: the recovery sweep reads `stripeSessionId`, not the
    // url, and the frontend only offers the pay link while the order is `#created`. A
    // terminal order should not be carrying a payable link at all.
    // ⚠️ **`Reserve.holdsPromise` is the authority on terminality, so this reuses it
    // rather than listing the statuses again.** Its own comment reads "terminal, and
    // nothing else is" — a second list here would be a place for the two to disagree,
    // which is how `#needsReview` (promise still held, not terminal) would eventually
    // get its pay link dropped by one of them and not the other.
    let settled = if (Reserve.holdsPromise(after.status)) { after } else {
      { after with stripeSessionUrl = null };
    };
    store.orders.add(settled.id, settled);
    bump(store, before.status, -1);
    bump(store, after.status, 1);
    // #63: the non-terminal index moves with the promise tally, on the same predicate,
    // in the same function — so a seventh status writer cannot update one and forget
    // the other. Unconditional rather than delta-driven: `add` and `remove` are both
    // idempotent, so a within-set transition (`#created → #paid`) is a no-op without
    // needing to ask whether it was one.
    if (Reserve.holdsPromise(after.status)) {
      store.promiseHolders.add(settled.id);
    } else {
      store.promiseHolders.remove(settled.id);
    };
    // Zero when the transition stays inside the counted set — `#created → #paid`
    // is the live example — and called anyway, so no writer is a special case.
    let moved = Reserve.applyDelta(
      store.promised,
      Reserve.tallyDelta(before.status, after.status),
      before.lockedCycles,
    );
    store.promised := moved.total;
    // ⚠️ Surfaced, not swallowed. Saturation means the tally was ALREADY wrong
    // before this order reached here, and a silent zero is indistinguishable from
    // an exact release — the first evidence would otherwise be the daily recount,
    // up to 24 h of a wrong tally gating real sales. `Main` audits this.
    if (moved.saturated) store.tallySaturations += 1;
    // #39 — the cumulative delivery figures, counted HERE for the reason at the fields:
    // six sites move an order to `#delivered`, and `#delivered` has no outbound edge, so
    // this is the only place the count is both unforgettable and unable to double.
    if (after.status == #delivered) {
      store.deliveredOrders += 1;
      store.deliveredCycles += before.lockedCycles;
      switch (before.paidUsdCents) {
        case (?cents) store.deliveredUsdCents += cents;
        // Unreachable: `markPaid` sets this before any delivery. Recorded rather than
        // ignored, so an understated public total has a matching counter to explain it.
        case null store.deliveredNullPaid += 1;
      };
    };
    settled;
  };

  public func applyTransition(
    store : Store,
    id : Types.OrderId,
    to : Types.OrderStatus,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        switch (transition(order, to, nowNs)) {
          case (#ok(updated)) {
            // The tally moves only when a transition ACTUALLY succeeds.
            // That is where idempotency comes from and why no extra guard is
            // needed anywhere — `transition` refuses an illegal edge, so a
            // redelivered `checkout.session.expired` for an already-cancelled
            // order, a sweep racing a webhook, or a delivery retry answering
            // `#Duplicate` after the transition already committed all no-op here
            // rather than double-releasing.
            #ok(commitTransition(store, order, updated));
          };
          case (#err(e)) #err(e);
        };
      };
    };
  };

  /// Attach a created Checkout Session to an order (#33).
  ///
  /// ⚠️ **Refuses unless the order is still `#created`, and that refusal is the
  /// point.** `create_order` commits the order and *then* awaits the outcall, so
  /// another ingress message can interleave — specifically `cancel_order` from a
  /// second tab, whose sessionless branch fires because no session id exists yet.
  /// Storing the URL anyway would hand the buyer a **payable link for an order
  /// they were told was cancelled**. Money-safe (the matrix rejects
  /// `#cancelled → #paid`, so a payment lands as a refundable obligation) but it
  /// recreates the exact "told cancelled, tab still charges" wart that making
  /// cancellation atomic exists to eliminate.
  ///
  /// `expiresAtNs` is Stripe's own deadline and is stamped **once** — there is no
  /// session retry, so nothing ever re-stamps it.
  public func attachSession(
    store : Store,
    id : Types.OrderId,
    sessionId : Text,
    sessionUrl : Text,
    expiresAtNs : Int,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        if (order.status != #created) {
          // Not a transition failure in the matrix sense — the order is fine, it
          // just is not the order this session was created for any more. Reported
          // as an illegal `#created` transition so the caller has one shape to
          // handle and the audit line names the status it actually found.
          return #err(#illegalTransition({ from = order.status; to = #created }));
        };
        let attached = {
          order with
          stripeSessionId = ?sessionId;
          stripeSessionUrl = ?sessionUrl;
          expiresAtNs = ?expiresAtNs;
          updatedAtNs = nowNs;
        };
        store.orders.add(id, attached);
        // No `bump`: the status did not change, so the tallies are untouched.
        #ok(attached);
      };
    };
  };

  /// `#created → #expired` because **Stripe closed the session** (#33), with the
  /// session id backfilled if the order did not have one.
  ///
  /// The backfill is what lets a residue order heal: if the session-create
  /// response was lost (a trap or upgrade between the order commit and the
  /// continuation), the order holds no session id — and this event, arriving ~30
  /// minutes later, is the thing that tells it which session it had.
  public func expireBySession(
    store : Store,
    id : Types.OrderId,
    sessionId : Text,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        switch (transition(order, #expired, nowNs)) {
          case (#ok(updated)) {
            let expired = {
              updated with
              expiredBy = ?(#sessionExpired : Types.ExpiredBy);
              stripeSessionId = ?sessionId;
            };
            // Release point 1 (#30), and the most common one: Stripe says the
            // session died unpaid, so every unpaid order releases here.
            #ok(commitTransition(store, order, expired));
          };
          case (#err(e)) #err(e);
        };
      };
    };
  };

  /// `#created → #expired` **with a recorded cause** (#34's `expiredBy`).
  ///
  /// Routed through `transition`, never a direct status write, for two protections
  /// at once: the matrix no-ops `#cancelled → #expired` (a second tab may have
  /// cancelled while the outcall was in flight), and the tallies stay coupled to
  /// the status change. A direct write would bypass both — and on the reserve path
  /// (#30) it would release an already-released promise.
  /// Record that this order has crossed `alertAfterNs` while waiting to deliver.
  ///
  /// Returns true only on the **first** crossing, so the caller can announce once
  /// without keeping any state of its own — which is what retires the
  /// `delayedAlerts` map rather than relocating it.
  ///
  /// ⚠️ **`updatedAtNs` is deliberately left alone.** It is the held-since clock
  /// `Delivery.waitStage` reads; moving it here would reset the wait being recorded,
  /// and an order that keeps resetting its own clock can never reach `maxHoldNs` —
  /// it would be alerted about forever and escalated never.
  /// Move an order to `#abandoned` AND record why, in one step.
  ///
  /// ⚠️ **One function, so the status and the reason cannot diverge.** They are two
  /// halves of one operator decision; a caller that transitioned and then set the
  /// reason separately could leave an `#abandoned` order with no explanation, which
  /// is precisely the gap the dropped `#abandoned` queue entry used to paper over.
  public func abandonWithReason(
    store : Store,
    id : Types.OrderId,
    reason : Text,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (applyTransition(store, id, #abandoned, nowNs)) {
      case (#err(e)) #err(e);
      case (#ok(order)) {
        let withReason = { order with abandonedReason = ?reason };
        store.orders.add(id, withReason);
        #ok(withReason);
      };
    };
  };

  // ── Problems on the order (#37) ────────────────────────────────────────────

  /// File a problem on an order. Returns false if the order is gone, or if an
  /// unresolved problem of the same shape is already there.
  ///
  /// ⚠️ **Dedup lives in `Problems.file`, and it needs no second structure.** The
  /// order carries its own answer to "have I already filed this", which is what the
  /// `delayedAlerts` map used to do for one kind — badly, because a separate map can
  /// fall out of step with the orders it points at, and leaking one was a real
  /// failure mode.
  public func fileProblem(
    store : Store,
    id : Types.OrderId,
    kind : Types.ProblemKind,
    detail : Text,
    nowNs : Int,
  ) : Bool {
    let ?order = store.orders.get(id) else return false;
    let result = Problems.file(order.problems, kind, detail, nowNs);
    let updated = result.problems;
    // ⚠️ `updatedAtNs` is deliberately untouched: it is the held-since clock
    // `Delivery.waitStage` reads, and filing a problem is not a state transition.
    store.orders.add(id, { order with problems = updated });
    store.unresolvedProblems.add(id);
    // ⚠️ **False on a refresh, and that is what the callers want.** A refreshed
    // problem must not re-audit: the audit line marks the transition into trouble,
    // not every observation of it. The *payload* is still updated, so an operator
    // reading the order sees the current figure — which is why this returns "was it
    // newly filed" rather than "did anything change".
    result.filed;
  };

  /// Resolve every unresolved problem on one order matching `pred`.
  public func resolveProblems(
    store : Store,
    id : Types.OrderId,
    pred : Types.ProblemKind -> Bool,
    nowNs : Int,
  ) : Nat {
    let ?order = store.orders.get(id) else return 0;
    let result = Problems.resolveWhere(order.problems, pred, nowNs);
    if (result.closed == 0) return 0;
    store.orders.add(id, { order with problems = result.problems });
    // Leaves the index the moment nothing is outstanding — the resolved problems
    // stay on the order, because nothing drops; only the worklist shrinks.
    if (Problems.unresolvedCount(result.problems) == 0) {
      store.unresolvedProblems.remove(id);
    };
    result.closed;
  };

  /// Every unresolved problem on this order matching `kindTag`, and their identifying
  /// references — what an operator needs to disambiguate before closing one.
  public func unresolvedOfKind(
    store : Store,
    id : Types.OrderId,
    kindTag : Text,
  ) : [{ kind : Types.ProblemKind; detail : Text; ref : ?Text }] {
    let ?order = store.orders.get(id) else return [];
    let out = List.empty<{ kind : Types.ProblemKind; detail : Text; ref : ?Text }>();
    for (p in order.problems.vals()) {
      if (Problems.isUnresolved(p) and Problems.kindToText(p.kind) == kindTag) {
        out.add({ kind = p.kind; detail = p.detail; ref = Problems.identifyingRef(p.kind) });
      };
    };
    out.toArray();
  };

  /// Close every problem a `charge.refunded` for `paymentRef` settles on its own.
  ///
  /// ⚠️ **Walks `unresolvedProblems`, NOT the order store.** This runs synchronously
  /// inside the `charge.refunded` handler, where a trap is a 5xx Stripe retries for
  /// three days — so it must not be O(every order ever created). The set is small and
  /// attacker-priced: every problem in it required a real payment event.
  ///
  /// ⚠️ **Only kinds where `paymentRefOf` gives a match are touched**, so
  /// `#refundAfterDelivery` and `#paidNotCredited` are never closed here even though
  /// both carry a `paymentRef`.
  public func resolveByPaymentRef(store : Store, paymentRef : Text, nowNs : Int) : Nat {
    var closed = 0;
    // Snapshot the ids: `resolveProblems` mutates the set we would otherwise be
    // iterating.
    let candidates = List.empty<Types.OrderId>();
    for (id in store.unresolvedProblems.values()) candidates.add(id);
    for (id in candidates.values()) {
      closed += resolveProblems(
        store,
        id,
        func(k) {
          Problems.refundResolvable(k) and Problems.paymentRefOf(k) == ?paymentRef;
        },
        nowNs,
      );
    };
    closed;
  };

  // ── Filtered, cursor-paginated reads (#38) ─────────────────────────────────

  /// Cap on one page, matching `Orphans.maxPageSize` so an operator learns one number.
  public let maxPageSize : Nat = 200;

  /// What an operator narrows by. Every field is optional and they AND together.
  ///
  /// ⚠️ **`withUnresolvedProblems` is folded in here rather than living as its own
  /// query.** That is #37's thesis carried through: "everything outstanding" is a
  /// *filter* over orders, so it composes with status and time range instead of being a
  /// parallel list that answers a different question.
  public type Filter = {
    status : ?Types.OrderStatus;
    /// Matches `Owner`'s principal.
    owner : ?Principal;
    createdFromNs : ?Int;
    createdToNs : ?Int;
    withUnresolvedProblems : Bool;
  };

  public func noFilter() : Filter {
    ({
      status = null;
      owner = null;
      createdFromNs = null;
      createdToNs = null;
      withUnresolvedProblems = false;
    });
  };

  /// ⚠️ **Ordered by order ID, which is NOT time order — and that is deliberate.**
  /// Order ids are random hex, so id order is arbitrary. Sorting the filtered set by
  /// `createdAtNs` would mean materialising it first, which is the unbounded scan #63
  /// exists to remove; a secondary time index would be one more piece of derived state
  /// needing adjudication. So the traversal is **stable and complete** rather than
  /// recent-first, and an operator who wants recency narrows with `createdFromNs`
  /// instead. Saying so here is the point: a caller that assumes newest-first gets a
  /// wrong answer silently.
  ///
  /// Cursor-based, like `Orphans.page`, and for a stronger reason: ids are never reused
  /// and orders are never deleted under #37, so a cursor cannot be invalidated at all.
  ///
  /// `nextCursor` is set **only when further matching orders remain**, so a caller
  /// stops the moment it is null and never makes a wasted final request.
  public type Page = { orders : [Types.Order]; nextCursor : ?Types.OrderId };

  public func page(
    store : Store,
    filter : Filter,
    afterId : ?Types.OrderId,
    limit : Nat,
  ) : Page {
    let capped = if (limit == 0 or limit > maxPageSize) maxPageSize else limit;
    let collected = List.empty<Types.Order>();
    var last : ?Types.OrderId = null;
    // O(log n) seek to the cursor rather than re-walking the store to skip past it.
    // `entriesFrom` is inclusive, so the `id > cursor` test below still does the
    // skipping; this only removes the wasted prefix.
    //
    // ⚠️ **This bounds the RESUME, not the page (#70).** A selective `filter` still
    // walks until it fills a page, so a status filter matching few orders out of many is
    // O(store) in one message, and an owner filter walks every principal's orders to
    // find one principal's. #63 bounded the reconcile and the timer scans, not this. Do
    // not read a paged query as a bounded one — the page caps the ~2 MB response, and
    // the limit this hits is instructions per message.
    let it = switch (afterId) {
      case (?cursor) store.orders.entriesFrom(cursor);
      case null store.orders.entries();
    };
    for ((id, order) in it) {
      let past = switch (afterId) { case (?cursor) id > cursor; case null true };
      if (past and matchesFilter(order, filter)) {
        if (collected.size() == capped) return { orders = collected.toArray(); nextCursor = last };
        collected.add(order);
        last := ?id;
      };
    };
    { orders = collected.toArray(); nextCursor = null };
  };

  /// One buyer's own orders, paged, walking **their** index rather than the whole store.
  ///
  /// ⚠️ **`Orders.page` bounds the RESUME, not the work.** Its owner filter seeks to the
  /// cursor in the global store and then walks every principal's orders looking for one
  /// principal's, so a buyer's history page costs O(all orders ever created) in a single
  /// message. A query's instruction budget is well below an update's, so that cliff
  /// arrives sooner than the equivalent on an update path — and when it arrives, an
  /// ordinary buyer's history page traps. The failure is availability on a routine
  /// action, not a drain: both callers are queries, free to the caller and off consensus.
  ///
  /// ⚠️ **Returns `scanned` because there is no instruction counter a query can read.**
  /// "The work does not grow with other principals' orders" is otherwise unassertable,
  /// and the half that stays assertable — that the rows are right — passes for a
  /// function returning nothing. `Main.list_orders` calls THIS and projects the page
  /// out; a separate uninstrumented path would put the bound on code nobody runs.
  ///
  /// ⚠️ Two invariants live in the loop below, and they are what a cursor walk gets
  /// wrong. Neither follows from the key type:
  ///
  ///   1. **The seek is inclusive**, so `id > cursor` still does the skipping.
  ///   2. **`last` is the last id RETURNED, never one merely scanned past.** A cursor
  ///      taken from a scanned id silently skips every id between it and the last row
  ///      actually handed out — a buyer's missing orders, with no error anywhere.
  ///
  /// `scanned <= limit + 2`, and the three terms are: at most one id skipped by the
  /// inclusive seek, `limit` rows collected, and one lookahead that finds the page full.
  /// The lookahead is what makes `nextCursor = null` mean "no more" rather than "ask
  /// again and get nothing", which is the semantics `admin_orders` already has.
  public func ownerPage(
    store : Store,
    owner : Principal,
    afterId : ?Types.OrderId,
    limit : Nat,
  ) : { page : Page; scanned : Nat } {
    let capped = if (limit == 0 or limit > maxPageSize) maxPageSize else limit;
    let ?ids = store.principalsToOrders.get(owner) else {
      return { page = { orders = []; nextCursor = null }; scanned = 0 };
    };
    let collected = List.empty<Types.Order>();
    var scanned = 0;
    let it = switch (afterId) {
      case (?cursor) ids.valuesFrom(cursor);
      case null ids.values();
    };
    for (id in it) {
      // Counted for every id the iterator yields, including the inclusive-seek skip and
      // the lookahead — the honest measure of work, not of rows.
      scanned += 1;
      let past = switch (afterId) { case (?cursor) id > cursor; case null true };
      if (past) {
        if (collected.size() == capped) {
          // ⚠️ **The cursor is read OFF the rows returned**, so "the cursor is an id we
          // actually handed out" is unrepresentable rather than merely true. A separate
          // `var last` assigned inside the loop is the same value in this function —
          // every id in the owner index yields a row — which is exactly why it is the
          // wrong shape: nothing could ever fail if it drifted. `capped >= 1`, since a
          // zero or oversized limit becomes `maxPageSize`.
          // `last()` rather than `get(size - 1)`: no Nat subtraction to trap on, and no
          // index to get wrong.
          let cursor = switch (collected.last()) { case (?row) ?row.id; case null null };
          return { page = { orders = collected.toArray(); nextCursor = cursor }; scanned };
        };
        switch (store.orders.get(id)) {
          case (?order) collected.add(order);
          // Indexed without a record. Nothing removes from either structure, so this is
          // unreachable; skipping rather than trapping keeps a bookkeeping fault off a
          // buyer's read path.
          case null {};
        };
      };
    };
    { page = { orders = collected.toArray(); nextCursor = null }; scanned };
  };

  public func matchesFilter(order : Types.Order, filter : Filter) : Bool {
    switch (filter.status) {
      case (?want) if (order.status != want) return false;
      case null {};
    };
    switch (filter.owner) {
      case (?want) switch (order.owner) {
        case (#ii(p)) if (p != want) return false;
      };
      case null {};
    };
    switch (filter.createdFromNs) {
      case (?from) if (order.createdAtNs < from) return false;
      case null {};
    };
    switch (filter.createdToNs) {
      case (?to) if (order.createdAtNs > to) return false;
      case null {};
    };
    if (filter.withUnresolvedProblems and Problems.unresolvedCount(order.problems) == 0) {
      return false;
    };
    true;
  };

  /// Every order carrying at least one unresolved problem — **the worklist, as a
  /// filter rather than a structure** (#37).
  public func withUnresolvedProblems(store : Store) : [Types.Order] {
    let out = List.empty<Types.Order>();
    for (id in store.unresolvedProblems.values()) {
      switch (store.orders.get(id)) {
        case (?order) out.add(order);
        // An id in the index with no order cannot happen — orders are never deleted
        // under #37 — so this arm is unreachable rather than defensive. Skipping is
        // still the right response if the impossible occurs: the rebuild fixes it.
        case null {};
      };
    };
    out.toArray();
  };

  /// Total unresolved problems across all orders — the number an operator watches.
  public func unresolvedProblemCount(store : Store) : Nat {
    var n = 0;
    for (id in store.unresolvedProblems.values()) {
      switch (store.orders.get(id)) {
        case (?order) n += Problems.unresolvedCount(order.problems);
        case null {};
      };
    };
    n;
  };

  public func markDelayed(store : Store, id : Types.OrderId, nowNs : Int) : Bool {
    let ?order = store.orders.get(id) else return false;
    switch (order.delayedAtNs) {
      case (?_) false; // already recorded; idempotent by construction
      case null {
        store.orders.add(id, { order with delayedAtNs = ?nowNs });
        true;
      };
    };
  };

  public func expireWithCause(
    store : Store,
    id : Types.OrderId,
    cause : Types.ExpiredBy,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        switch (transition(order, #expired, nowNs)) {
          case (#ok(updated)) {
            let expired = { updated with expiredBy = ?cause };
            // Release point 4 (#30): in-call session-creation failure.
            #ok(commitTransition(store, order, expired));
          };
          case (#err(e)) #err(e);
        };
      };
    };
  };

  /// Webhook money-in (§6.1): `#created → #paid`, and only that. #34 deleted the
  /// `#expired` edge, so this REFUSES an order that stopped being payable.
  ///
  /// ⚠️ `Card.handleWebhook` guards the status before reaching here and `-Werror`
  /// does not check that guard against the matrix. It **traps** on this error
  /// rather than swallowing it, so a guard that drifts open is a 5xx Stripe
  /// retries for ~3 days rather than a silent delivery. One caller is not a reason
  /// to relax the trap.
  ///
  /// **`lockedCycles` is not written here.** The webhook honours only the quoted
  /// amount, so the quantity locked at creation is the quantity delivered —
  /// immutable for the order's whole life, which is what makes the outstanding-promise
  /// tally exact rather than conservative. `paidUsdCents` records what arrived,
  /// and it can only equal `pricing.usdCents`; it is stored because "what Stripe
  /// said" and "what we asked for" being the same is worth being able to check.
  public func markPaid(
    store : Store,
    id : Types.OrderId,
    paidUsdCents : Nat,
    nowNs : Int,
  ) : Result.Result<Types.Order, TransitionError> {
    switch (store.orders.get(id)) {
      case null #err(#notFound(id));
      case (?order) {
        switch (transition(order, #paid, nowNs)) {
          case (#ok(updated)) {
            let paid = { updated with paidUsdCents = ?paidUsdCents };
            // ⚠️ Release is at DELIVERY, never at payment, so this delta is ZERO.
            // `Reserve.tallyDelta` carries the two-orders-one-reserve argument.
            #ok(commitTransition(store, order, paid));
          };
          case (#err(e)) #err(e);
        };
      };
    };
  };

  public func get(store : Store, id : Types.OrderId) : ?Types.Order {
    store.orders.get(id);
  };

  /// Count of this principal's still-open orders — the input to the `Gate` admission cap.
  ///
  /// `#created` **and not past its own deadline**. Anything past `#paid` is a record of
  /// money rather than an open slot, and an `#expired` or `#cancelled` order is finished.
  ///
  /// ⚠️ **The deadline check is what makes a cap of 1 safe, and the reason it needs no
  /// Stripe call is the whole distinction.** A slot is **our** resource: we may grant it
  /// on our own clock, because being generous with it cannot lose money — at worst a
  /// buyer gets a second slot a little early, and the order they abandoned is unpayable
  /// anyway once Stripe expires its session. Reserve *capacity* is money, so releasing it
  /// needs Stripe's authority (#52 PR-A's sweep, and the reason option 3 was rejected).
  /// Same input, two resources, two standards of proof.
  ///
  /// Without it, one missed `checkout.session.expired` locks a buyer out **permanently**
  /// at a cap of 1 — not for the 35 minutes the session lasts, because nothing else moves
  /// a `#created` order. That is why the cap and this check land together and why
  /// shipping the cap alone would have been the harmful half.
  ///
  /// ⚠️ **`expiresAtNs` is null until the session-create response lands**, and a null
  /// deadline counts as open: an order with no session is one whose fate we do not know
  /// yet, and the residue case (a lost create response) is a canister-level fault whose
  /// lever is `expire_order`. Counting it as free would hand out a slot on the strength
  /// of an order we cannot even expire.
  public func openOrderCount(store : Store, caller : Principal, nowNs : Int) : Nat {
    switch (store.principalsToOrders.get(caller)) {
      case null 0;
      case (?ids) {
        var open = 0;
        for (id in ids.values()) {
          switch (store.orders.get(id)) {
            case (?order) {
              if (order.status == #created and not pastDeadline(order, nowNs)) open += 1;
            };
            case null {}; // id indexed without a record — cannot happen
          };
        };
        open;
      };
    };
  };

  /// Is this order past the deadline Stripe set for its own session?
  ///
  /// Null answers **false** — see `openOrderCount`. Separate and named so the one
  /// comparison has one home and one test, the way `Session.secondsToNs` does.
  public func pastDeadline(order : Types.Order, nowNs : Int) : Bool {
    switch (order.expiresAtNs) {
      case (?deadline) nowNs > deadline;
      case null false;
    };
  };

  /// Authz-guarded lookup for the user API: `caller == order.owner` (§2).
  public func getOwned(store : Store, id : Types.OrderId, caller : Principal) : ?Types.Order {
    switch (store.orders.get(id)) {
      case (?order) {
        if (Types.isOwnedBy(order.owner, caller)) ?order else null;
      };
      case null null;
    };
  };

  /// Order history for a principal, newest-last (insertion order).
  /// Every order — **the test oracle for the bounded tallies, and nothing else** (#63).
  ///
  /// ⚠️ **No production path may call this.** A full scan in one message is what #63
  /// removed: under indefinite retention it is on a path to the instruction limit, and
  /// `reconcileBounded` recounts the same quantities from `promiseHolders` instead.
  ///
  /// What the full scan is still good for is being the **independent** definition the
  /// bounded pass is checked against — `Reserve.recount(all(store))` derives the promise
  /// total from the orders themselves, with no index in the chain, which is exactly the
  /// property a test needs and a timer cannot afford. Deliberately unpaged for the same
  /// reason: a partial scan under-counts what is owed, so as an oracle it must see
  /// everything or say nothing.
  public func all(store : Store) : [Types.Order] {
    store.orders.values().toArray();
  };

  public func ordersFor(store : Store, caller : Principal) : [Types.Order] {
    switch (store.principalsToOrders.get(caller)) {
      case null [];
      case (?ids) {
        ids.values().filterMap<Types.OrderId, Types.Order>(func(id) = store.orders.get(id)).toArray();
      };
    };
  };

};
