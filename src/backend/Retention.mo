/// Order lifecycle retention — expiry policy (§4).
///
/// Owns the one transition nothing else performed: `#created → #expired` past a
/// TTL. The flip exists so abandoned attempts are visibly stale rather than
/// indistinguishable from live ones, and so an abandoned attempt stops holding an
/// open-order slot.
///
/// ⚠️ **Expiry is TERMINAL as of #34**, which deleted `#expired → #paid`. It used
/// to be advisory — an expired order stayed payable and a late payment was
/// honoured at the locked quantity. It is not: a payment arriving now becomes a
/// Type 1 obligation for the operator to refund. #33 deletes this module
/// entirely and takes the deadline from Stripe.
///
/// **Orders are never deleted.** Every order is a financial record and is kept
/// for the life of the canister, which is what keeps `paidIntents` entries
/// pointing at records that still exist.
///
/// **What actually bounds growth**, since retention does not:
///
/// - Legitimate volume is bounded by the burn cap.
/// - `Gate.Config.maxOpenOrdersPerPrincipal` bounds *concurrent* unpaid orders
///   per principal — but **not** the lifetime total, because `cancel_order`
///   frees a slot immediately and self-authenticating principals are free to
///   mint. A create→cancel loop can therefore accrete `#expired` records without
///   any per-principal ceiling, and a per-principal cap would not help: the
///   attacker rotates keys.
/// - What genuinely bounds it is the **cycles cost of the update calls**. Every
///   record costs the canister two update calls to create and cancel, and
///   `Gate.Config.minCanisterCycles` fails the whole rail closed once the balance
///   falls below the floor. That trips long before an order store of a few
///   hundred bytes per record threatens memory: adding a GB takes millions of
///   orders, and the calls to create them cost far more cycles than the floor
///   allows to be spent.
///
/// So the exposure is **availability, not memory** — a funded attacker can stop
/// the rail selling, which is the same exposure `create_order` has on its own and
/// is why `cycles_status` is monitored (RUNBOOK §9). It is not a path to
/// unbounded state or an unupgradeable canister.
///
/// The sweep is nevertheless bounded per tick (`maxRetentionScanPerSweep`), so a
/// large store cannot make each tick progressively more expensive and compound
/// the drain.
///
/// If retention ever genuinely binds, archival to a separate canister preserves
/// the record; deletion does not.
import Result "mo:core/Result";
import Types "Types";

module {

  public type Config = {
    /// Age past which a `#created` order flips to `#expired`. Terminal since
    /// #34, so this is a real deadline rather than a label.
    ///
    /// Size it past the Stripe Checkout Session lifetime (24 h) plus delivery
    /// slack, so a user who is mid-checkout never sees their order expire — and
    /// note that now costs them a refund cycle rather than a wait. Stripe also
    /// retries a lost webhook for ~3 days, so a TTL below that can expire an
    /// order whose payment is still being delivered.
    orderTtlNs : Nat;
  };

  public func defaultConfig() : Config {
    {
      orderTtlNs = 172_800_000_000_000; // 48 h — 2× the Stripe session lifetime
    };
  };

  public type ConfigError = {
    #zeroTtl;
  };

  public func validateConfig(config : Config) : Result.Result<(), ConfigError> {
    if (config.orderTtlNs == 0) return #err(#zeroTtl);
    #ok;
  };

  /// What the retention sweep should do with one order.
  public type Band = {
    /// Inside the TTL, or in a state that must not be touched. Leave alone.
    #keep;
    /// Flip `#created` to `#expired`, which is terminal since #34: a payment
    /// arriving afterwards is refunded, not converted.
    #expire;
  };

  /// Pure band decision from status and age.
  ///
  /// `#created` is the only status this ever *acts* on, and expiry is the only
  /// action: nothing here deletes. Every other status is a record kept forever —
  /// `#paid`/`#minting`/`#icpAtCmc`/`#awaitingTreasury` because money is in
  /// flight, the rest because money was. Their volume is bounded by the burn cap,
  /// so they can never be a growth vector.
  public func bandOf(
    status : Types.OrderStatus,
    createdAtNs : Int,
    nowNs : Int,
    config : Config,
  ) : Band {
    let age = nowNs - createdAtNs;
    if (age < 0) return #keep; // clock went backwards; never act on that
    switch (status) {
      case (#created) {
        if (age >= config.orderTtlNs) #expire else #keep;
      };
      // Kept indefinitely: an order is a record of an attempt whatever became
      // of it, and nothing here is deleted on age.
      //
      // `#expired` used to be kept on the grounds that it "remains payable".
      // That stopped being true when #34 deleted `#expired → #paid`; it is kept
      // as a record now, which is the same answer for an honest reason.
      case (#cancelled or #expired or #paid or #minting or #icpAtCmc or #awaitingTreasury or #delivered or #needsReview or #abandoned) #keep;
    };
  };

};
