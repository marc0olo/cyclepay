/// Bounded audit-log ring buffer (§4.2).
///
/// Operational trail — balance alerts (§5.3), dedup drops, error-queue
/// evictions — NOT a financial record. Orders, journal, and the error queue
/// are the records of money and are retained; this buffer hard-caps and drops
/// oldest-first. `seq` is monotonic and never reused, so a reader holding the
/// last seq it saw can tell dropped events from an empty interval.
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
