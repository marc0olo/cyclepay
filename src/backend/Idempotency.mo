/// Per-rail dedup sets with retention/pruning (§4.2).
///
/// Dedup gates delivery (§4.1 invariant): a key that fails `record*` here is
/// the *same* payment seen again (Stripe at-least-once redelivery,
/// block replay) and must be silently acked — never delivered, never queued.
/// A genuine second payment carries a fresh `event.id`/`payment_intent`,
/// passes dedup, and is the rail's business to queue as a refundable obligation.
///
/// Retention (§4.2): Stripe keys are timestamped at first sight and pruned
/// after ~7 days (Stripe redelivers ≤3 days); crypto `block_index` dedup is
/// small, financial, and kept for years — never pruned.
import Map "mo:core/Map";
import Set "mo:core/Set";
import Iter "mo:core/Iter";
import Text "mo:core/Text";
import Nat "mo:core/Nat";

module {

  /// ~7 days in ns (§4.2) — comfortably past Stripe's ≤3-day redelivery
  /// horizon. (Module-level lets must be static, hence the spelled-out value.)
  public let stripeRetentionNs : Int = 604_800_000_000_000;

  public type Store = {
    /// Stripe `event.id` → first-seen ns. Catches event redelivery.
    stripeEvents : Map.Map<Text, Int>;
    /// Stripe `payment_intent` → first-seen ns. One delivery per payment, even
    /// across distinct event deliveries for the same intent.
    stripeIntents : Map.Map<Text, Int>;
  };

  public func emptyStore() : Store {
    {
      stripeEvents = Map.empty<Text, Int>();
      stripeIntents = Map.empty<Text, Int>();
    };
  };

  /// True = first sight, recorded; false = duplicate (ack and drop).
  public func recordStripeEvent(store : Store, eventId : Text, nowNs : Int) : Bool {
    recordTimestamped(store.stripeEvents, eventId, nowNs);
  };

  /// True = first sight, recorded; false = duplicate (ack and drop).
  public func recordStripeIntent(store : Store, paymentIntent : Text, nowNs : Int) : Bool {
    recordTimestamped(store.stripeIntents, paymentIntent, nowNs);
  };

  /// Drop Stripe keys first seen ≥ `stripeRetentionNs` ago. Returns the count
  /// pruned. Cheap enough to call opportunistically from the webhook path or
  /// the recovery timer; the first-seen timestamp never refreshes, so a key
  /// redelivered on day 6 still prunes on day 7.
  public func pruneStripe(store : Store, nowNs : Int) : Nat {
    pruneTimestamped(store.stripeEvents, nowNs) + pruneTimestamped(store.stripeIntents, nowNs);
  };

  func recordTimestamped(map : Map.Map<Text, Int>, key : Text, nowNs : Int) : Bool {
    if (map.containsKey(key)) return false;
    map.add(key, nowNs);
    true;
  };

  func pruneTimestamped(map : Map.Map<Text, Int>, nowNs : Int) : Nat {
    let cutoff = nowNs - stripeRetentionNs;
    let expired = map.entries().filterMap(
      func((key, firstSeenNs)) = if (firstSeenNs <= cutoff) ?key else null
    ).toArray();
    for (key in expired.values()) { map.remove(key) };
    expired.size();
  };

};
