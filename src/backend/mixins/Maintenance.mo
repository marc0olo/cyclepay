// `Array` for the receiver `.map()` over the recount's counts.
import Array "mo:core/Array";
import Error "mo:core/Error";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Set "mo:core/Set";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Auth "../Auth";
import Delivery "../Delivery";
import Gate "../Gate";
import Orders "../Orders";
import Pricing "../Pricing";
import Reserve "../Reserve";
import Types "../Types";

/// The four levers an operator pulls by hand: refresh the rates, refresh the reserve
/// observation, recount the tallies, and return the reserve (§7).
///
/// ⚠️ **Every one does on demand what a timer already does on a cadence**, and that is
/// the design: each shares the sweep's implementation through `ops` rather than carrying
/// its own. A second copy of "reconcile the tallies" or "observe the reserve" would be a
/// second answer to a question that must have exactly one — and `recount_orders` in
/// particular is NOT a stronger repair than the timer's, which an operator has to be able
/// to rely on.
///
/// ⚠️ **`withdraw_reserve` is the one irreversible lever in the system.** Refused while
/// any order still holds a promise, so nothing owed to a buyer can leave; once it runs the
/// gateway sells nothing until the reserve is funded again, and no lever brings the cycles
/// back.
mixin (
  orderStore : Orders.Store,
  rateCache : Pricing.Cache,
  /// ⚠️ The cycles-ledger actor reference passes directly, like `routes` in the webhook
  /// mixin: it is a transient `let` built during initialisation — which is when `include`
  /// evaluates its arguments — and an actor reference is an immutable value. §9.1's rule
  /// is about MUTABLE state.
  cyclesLedger : Delivery.CyclesLedgerService,
  reserveState : { var floor : Nat; var outflowsIssued : Nat; var cyclesLedgerFee : Nat },
  ops : {
    auditAdmin : (Principal, Text, Text) -> ();
    requireAdmin : (Principal) -> ();
    requireController : (Principal) -> ();
    /// The same three passes the timers run. Shared, never reimplemented.
    refreshRates : () -> async* ();
    observeReserve : () -> async* { observed : Nat; quiet : Bool; holdersAfter : Nat };
    reportReconciliation : (Orders.Reconciliation) -> ();
  },
) {

  /// What a withdrawal moved. `debited` is `withdrawn + fee` — the figure the reserve
  /// actually fell by, which is what reconciles against the ledger.
  type Withdrawn = { withdrawn : Nat; debited : Nat; to : Types.Account };
  type WithdrawError = {
    /// Cycles are still owed: at least one order is non-terminal, so a buyer either
    /// holds a payable session or has paid and not been delivered.
    ///
    /// ⚠️ Carries the holder COUNT and the tally so an operator knows what to clear —
    /// a bare refusal on a decommissioning lever is a dead end. The two figures
    /// disagreeing is itself the signal that the tally has saturated.
    #ordersOutstanding : { holders : Nat; promised : Nat };
    /// The observed floor is zero. Not an error state, but distinguishable from a
    /// successful withdrawal of nothing.
    #nothingToWithdraw;
    /// The whole floor would not clear the ledger's flat deposit fee, so there is
    /// nothing recoverable.
    #belowLedgerFee : { floor : Nat; fee : Nat };
    /// The ledger refused or the call failed. ⚠️ The floor has already been decremented
    /// and is deliberately not restored — see the call site.
    #transferFailed : Text;
  };

  /// Force a rate refresh now (admin) — the ops lever after retuning config or
  /// while diagnosing a stale rate, without waiting for the next tick.
  public shared ({ caller }) func refresh_rates() : async ?Pricing.Rates {
    ops.requireAdmin(caller);
    await* ops.refreshRates();
    Pricing.lastRates(rateCache);
  };

  /// Run the reconcile now rather than waiting for the daily one (admin, §7).
  ///
  /// The tallies are maintained incrementally so the public status queries stay O(1);
  /// this is the on-demand lever for the case where they are ever suspected of having
  /// drifted. Returns the counts as they stand after the pass.
  ///
  /// ⚠️ **It is the same bounded pass the timer runs, with the same one-directional
  /// rule — it is NOT a stronger repair, and an operator must not reach for it as one.**
  /// `Orders.adoptOnlyIncreases` refuses a recount lower than the maintained tally,
  /// here exactly as on the timer, because a lower recount is indistinguishable from an
  /// incomplete index and adopting it is the only way an index bug could oversell the
  /// reserve. There is deliberately **no** force flag and no full-scan rebuild: a lever
  /// for adopting the unsafe direction would be a lever for the bug.
  ///
  /// ⚠️ **No longer the expensive path**, and it stays admin-only anyway — it writes
  /// tallies the gate reads.
  public shared ({ caller }) func recount_orders() : async [(Text, Nat)] {
    ops.requireAdmin(caller);
    let report = Orders.reconcileBounded(orderStore);
    ops.reportReconciliation(report);
    let rendered = report.counts.map(func((status, n)) = status # "=" # n.toText());
    ops.auditAdmin(caller, "orders.recounted", rendered.values().join(", "));
    report.counts;
  };

  /// On-demand reserve refresh (admin — a public one would let anyone spend our
  /// cycles on ledger calls). The sweep does this hourly; this is the lever for
  /// right after `icp cycles transfer`, so a top-up is sellable immediately.
  ///
  /// ⚠️ **`scripts/local-dev-seed.sh` and RUNBOOK's top-up step call this**, and
  /// forgetting it is invisible to every typecheck: the floor stays at zero, so the
  /// gateway refuses every sale against a fully funded reserve and nothing anywhere
  /// says why.
  public shared ({ caller }) func refresh_reserve() : async Nat {
    ops.requireAdmin(caller);
    (await* ops.observeReserve()).observed;
  };

  /// Return the reserve to the caller, refusing while anything is owed (#103).
  ///
  /// ⚠️ **Why this exists at all.** #30 recorded no withdraw lever because *"the app is
  /// not in production and an over-funded local reserve costs nothing"* — true then, and
  /// false the moment the reserve is funded on mainnet, where it is real money in a
  /// ledger account with no way back. Decommissioning, or over-funding once, was a
  /// permanent loss.
  ///
  /// ⚠️ **It grants a controller NO new capability, which is what makes it safe.** A
  /// controller can install arbitrary code, so they can already move the reserve
  /// anywhere by upgrading — `Auth.mo`'s tier note says exactly that. There is a cheaper
  /// existing path too: rotate the webhook secret, sign a completed-session event for an
  /// order you created, and take delivery having paid nothing. The trust boundary does
  /// not move; an off-the-books capability becomes **one audited call**, which is more
  /// visible than a wasm deploy and more visible than a run of forged orders.
  ///
  /// ⚠️ **A DECOMMISSIONING lever, not an incident lever, and the guard is why.** During
  /// a forged-webhook drain the forged orders are open, so this refuses. The evacuation
  /// path is three steps, not one: rotate the webhook secret (which closes the rail to
  /// new orders), `abandon_order` the ones in flight (releasing their promises), then
  /// withdraw. RUNBOOK's suspected-leak section carries that sequence.
  public shared ({ caller }) func withdraw_reserve() : async Result.Result<Withdrawn, WithdrawError> {
    ops.requireController(caller);
    // ⚠️ **The INDEX, not the tally.** `Reserve.applyDelta` clamps a release to zero
    // when the tally has diverged low, so `promised` can read 0 while promise-holders
    // still exist — the state `tallySaturations` exists to surface. Guarding on the
    // tally would permit a withdraw with live orders outstanding, which is the one
    // thing this guard is for. `promiseHolderCount` is `Set.size`: O(1), and set
    // emptiness cannot saturate.
    //
    // The index is authoritative here for the same reason `reconcileBounded` treats it
    // that way — a recount over `promiseHolders` is exact if the index is complete and
    // too low otherwise, never too high.
    // ⚠️ **The holders gate ONLY, not the whole ladder.** A withdrawal with live orders
    // outstanding costs no ledger call this way — and the floor arms deliberately wait
    // for the observe below, because an unobserved top-up leaves the floor reading 0 and
    // refusing here would strand it.
    switch (
      Reserve.ordersOutstanding(
        Orders.promiseHolderCount(orderStore),
        Orders.promised(orderStore),
      )
    ) {
      case (?refusal) return #err(refusal);
      case null {};
    };
    // Observe before withdrawing, or an unobserved top-up is stranded — which defeats
    // the lever. ⚠️ **And an empty promise index is exactly what makes the observation
    // adoptable**: `unsettledDeliveries` is a walk over `promiseHolders` (#69), so no
    // holders means no unsettled deliveries means the reconcile's quiet window holds.
    // The withdraw guard and the observation guard are the same structure, so they
    // cannot disagree.
    // ⚠️ **RE-CHECK, because `observeReserve` contains an await and the floor is still
    // FULL across it.** The decrement below is what refuses a concurrent create, and it
    // has not happened yet — so a `create_order` queued during the balance read sees a
    // full reserve, `Gate.solvent` admits it, and the buyer walks away with a payable
    // session against a reserve that is about to leave. If they pay, they have paid for
    // cycles that are gone.
    //
    // ⚠️ **The count comes BACK from the observe rather than being re-read here**, so
    // the guard cannot be forgotten by anyone editing this function: `observeReserve`
    // computes it after its own await, alongside the `quiet` flag it computes for the
    // same reason. A comment saying "re-read this" would be the weakest guard available,
    // and comments are exactly what this codebase keeps finding insufficient.
    let { holdersAfter } = await* ops.observeReserve();
    // ⚠️ **The same ladder again, and that is the guard.** An await just happened with
    // the floor still full, so the holder count is re-tested — and the observe may have
    // moved the floor, so the arithmetic is redone on what it now says. Two call sites,
    // one decision: the previous shape repeated the holder test inline, where the two
    // copies could drift.
    let fee = reserveState.cyclesLedgerFee;
    let { debited; amount } = switch (
      Reserve.withdrawable(holdersAfter, Orders.promised(orderStore), reserveState.floor, fee)
    ) {
      case (#ok(figures)) figures;
      case (#err(e)) return #err(e);
    };
    let to : Types.Account = { owner = caller; subaccount = null };
    // ── Rule 2 (§5.4): the floor drops when the transfer is ISSUED ──────────
    //
    // ⚠️ **Synchronously, before the await, or this is a TOCTOU on the money path.**
    // `create_order` interleaves on the await below: it would check `Gate.solvent`
    // against a reserve being emptied, admit an order, and leave a buyer paying for
    // cycles that are gone. With the floor at zero first, every concurrent create
    // refuses for free — no new lock and no new lever.
    //
    // ⚠️ **By `amount + fee`, not `amount`** — the figure actually debited, the same
    // correction §5.4 carries for delivery. Decrementing by the transferred amount
    // alone would leave the floor overstating the account by exactly the fee, and the
    // next observation would report an unexplained shortfall: the one signal that is
    // supposed to mean an outflow we did not cause.
    reserveState.floor := Reserve.floorAfterOutflow(reserveState.floor, amount + fee);
    reserveState.outflowsIssued += 1;
    let result = try {
      await cyclesLedger.icrc1_transfer(
        Delivery.withdrawArgs(to, amount, fee, Time.now())
      );
    } catch (e) {
      // ⚠️ The floor is NOT credited back. A call that failed without a reply says
      // nothing about whether the ledger acted, and rule 2 exists to be pessimistic
      // about exactly that; a reconcile heals it if the transfer never happened.
      ops.auditAdmin(caller, "reserve.withdrawFailed", "to " # to.owner.toText() # ": " # e.message());
      return #err(#transferFailed(e.message()));
    };
    switch (result) {
      case (#Ok(block)) {
        // ⚠️ The destination is IN the audit line, not just the fact of a withdrawal.
        // A controller destination is the new class in this whole design, so a record
        // that omits it is weaker than it looks.
        ops.auditAdmin(
          caller,
          "reserve.withdrawn",
          amount.toText() # " cycles to " # to.owner.toText()
          # " (debited " # (amount + fee).toText() # " incl. fee " # fee.toText()
          # ", block " # block.toText() # ")",
        );
        #ok({ withdrawn = amount; debited = amount + fee; to });
      };
      case (#Err(e)) {
        // ⚠️ **The floor stays decremented here, and that is safe and self-correcting
        // rather than a bookkeeping hole.** Understating the floor only ever sells
        // *less*, and adoption is increase-only, so the next quiet observation raises it
        // back to the real balance. Crediting it back would be the unsafe direction: a
        // refusal we misread as definitive would leave the floor optimistic with nothing
        // left to re-decrement it.
        let detail = Delivery.transferErrorToText(e);
        ops.auditAdmin(caller, "reserve.withdrawRefused", "to " # to.owner.toText() # ": " # detail);
        #err(#transferFailed(detail));
      };
    };
  };
};
