/// Order lifecycle retention — the three bands (§4 expiry, §4.2 retention).
///
/// Owns the policy that drives `#created → #expired` and, past a longer
/// horizon, deletes abandoned orders so the store cannot grow without bound.
///
/// **The hazard to design against.** A Stripe Payment Link is permanent and
/// always live, and `client_reference_id` is just a URL parameter — so a
/// payment can arrive for any order at any time, including one abandoned months
/// ago from a bookmarked URL. Deleting an order therefore risks a payment we
/// cannot attribute.
///
/// **Why that is survivable.** It degrades to a refund, never to lost money.
/// The §4.1 invariant is that every verified dollar resolves to delivery,
/// Type 1, or Type 2; a payment referencing a deleted order resolves to nothing
/// and becomes Type 1 `#unattributed`, acked 200, sitting in the error queue
/// with its `payment_intent` for the operator to refund — which
/// `charge.refunded` then auto-resolves. The `sweptOrders` tombstone set makes
/// that diagnosis *certain* rather than ambiguous: 32 bytes per id says "we
/// swept this, deliberately, on this date", instead of the generic "no such
/// order" that is indistinguishable from a forged reference.
///
/// **Sweeping is cleanup, not protection.** The bound that actually stops state
/// growth is `Gate.Config.maxOpenOrdersPerPrincipal`, because legitimate order
/// volume is already bounded by the burn cap. This module keeps the tail tidy.
import Result "mo:core/Result";
import Types "Types";

module {

  public type Config = {
    /// Band 1 → 2. Age past which a `#created` order flips to `#expired`.
    /// Advisory only, per §4: an expired order is still fully payable and a
    /// late genuine payment is still honoured at the locked quantity. The flip
    /// exists to make state legible and to define what becomes sweepable.
    /// Size it past the Stripe Checkout Session lifetime (24 h) plus delivery
    /// slack, so a user who is mid-checkout never sees their order expire.
    orderTtlNs : Nat;
    /// Band 2 → 3. Age past which an `#expired`, never-paid order is deleted
    /// and tombstoned. Measured from **creation**, not from expiry, so the
    /// horizon is absolute and monotonic. Size it well past any plausible
    /// bookmarked-link payment; past this point a payment nobody expected
    /// becoming a refund is correct behaviour.
    retentionHorizonNs : Nat;
  };

  public func defaultConfig() : Config {
    {
      orderTtlNs = 172_800_000_000_000; // 48 h — 2× the Stripe session lifetime
      retentionHorizonNs = 7_776_000_000_000_000; // 90 days
    };
  };

  public type ConfigError = {
    #zeroTtl;
    /// The horizon must strictly exceed the TTL, or band 2 would not exist and
    /// orders would be deleted the moment they expired — destroying the
    /// late-payment guarantee §4 promises.
    #horizonNotAfterTtl : { orderTtlNs : Nat; retentionHorizonNs : Nat };
  };

  public func validateConfig(config : Config) : Result.Result<(), ConfigError> {
    if (config.orderTtlNs == 0) return #err(#zeroTtl);
    if (config.retentionHorizonNs <= config.orderTtlNs) {
      return #err(#horizonNotAfterTtl({
        orderTtlNs = config.orderTtlNs;
        retentionHorizonNs = config.retentionHorizonNs;
      }));
    };
    #ok;
  };

  /// What the retention sweep should do with one order.
  public type Band = {
    /// Band 1 — inside the TTL, or in a money-bearing state. Leave alone.
    #keep;
    /// Band 1 → 2 — flip `#created` to `#expired`. Still payable.
    #expire;
    /// Band 2 → 3 — delete the record and tombstone the id. The caller MUST
    /// additionally confirm there is no mint journal entry and no ck-USDC pull
    /// entry for this order; this function only knows status and age.
    #sweep;
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
      case (#expired) {
        if (age >= config.retentionHorizonNs) #sweep else #keep;
      };
      case (#paid or #minting or #icpAtCmc or #awaitingTreasury or #delivered or #errorQueue) #keep;
    };
  };

};
