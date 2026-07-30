/// Order lifecycle retention — expiry policy (§4).
///
/// Owns the one transition nothing else performed: `#created → #expired` past a
/// TTL. **Advisory only**, per §4 — an expired order is still fully payable and
/// a late genuine payment is honoured at the locked quantity. The flip exists so
/// abandoned attempts are visibly stale rather than indistinguishable from live
/// ones.
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
    /// Age past which a `#created` order flips to `#expired`.
    /// Advisory only, per §4: an expired order is still fully payable and a
    /// late genuine payment is still honoured at the locked quantity. The flip
    /// makes an abandoned attempt visibly stale rather than indistinguishable
    /// from a live one.
    /// Size it past the Stripe Checkout Session lifetime (24 h) plus delivery
    /// slack, so a user who is mid-checkout never sees their order expire.
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
    /// Flip `#created` to `#expired`. Still fully payable.
    #expire;
  };

  /// Pure band decision from status and age.
  ///
  /// Only `#created` and `#expired` are ever touched. Every other status means
  /// money is or was in play: `#paid`/`#minting`/`#icpAtCmc`/
  /// `#awaitingTreasury` are in flight, and `#delivered`/`#errorQueue` are
  /// **financial records kept forever** — they are bounded by real volume,
  /// which the burn cap bounds, so they can never be a growth vector.
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
      // An expired order is kept indefinitely: it remains payable, and it is a
      // record of an attempt either way.
      case (#expired) #keep;
      case (#paid or #minting or #icpAtCmc or #awaitingTreasury or #delivered or #errorQueue) #keep;
    };
  };

};
