/// Bounded audit-log ring buffer (§4.2).
///
/// **Facts about money live on the objects, not here.** Where an order got to,
/// what the buyer actually paid, why it expired, when its rates were read: all of
/// that is on `Types.Order` (#34). The journal holds the mint position and the
/// error queue holds the open obligations. This is the *operational trail* —
/// balance alerts (§5.3), dedup drops, error-queue evictions — and the place to
/// look for "what happened around then", never for "what happened to this order".
///
/// That division is about **where a fact belongs**, not about this buffer being
/// lossy. #37 removes the ring; the division survives it, because an order is
/// still the thing an order's facts are attached to.
///
/// A refund is the one money fact deliberately not on the order: it lives in
/// **Stripe**, where it was issued, plus the unresolved `#refundAfterDelivery`
/// entry the queue never evicts. That is the whole record until there is real
/// money to reconcile (#34 dropped a `refundedUsdCents` field as premature).
///
/// This buffer hard-caps and drops oldest-first. `seq` is monotonic and never
/// reused, so a reader holding the last seq it saw can tell dropped events from
/// an empty interval.
import Queue "mo:core/Queue";
import Iter "mo:core/Iter";

module {

  public type Event = {
    seq : Nat;
    atNs : Int;
    /// Short greppable category, e.g. "treasury.lowFloat", "errorQueue.evicted".
    tag : Text;
    detail : Text;
  };

  public type Log = {
    events : Queue.Queue<Event>;
    var nextSeq : Nat;
  };

  public func emptyLog() : Log {
    { events = Queue.empty<Event>(); var nextSeq = 0 };
  };

  /// Append, dropping oldest events past `capacity`.
  public func append(log : Log, capacity : Nat, atNs : Int, tag : Text, detail : Text) : Event {
    let event : Event = { seq = log.nextSeq; atNs; tag; detail };
    log.nextSeq += 1;
    log.events.pushBack(event);
    while (log.events.size() > capacity) {
      ignore log.events.popFront();
    };
    event;
  };

  /// Retained events, oldest → newest.
  public func events(log : Log) : [Event] {
    log.events.values().toArray();
  };

  public func size(log : Log) : Nat {
    log.events.size();
  };

};
