/// The audit log — an unbounded, append-only operational trail (§4.2, #37).
///
/// **Facts about money live on the objects, not here.** Where an order got to,
/// what the buyer actually paid, why it expired, when its rates were read: all of
/// that is on `Types.Order` (#34). The journal holds the delivery position and the
/// order's own `problems` and the orphan list hold the open obligations. This is the
/// *operational trail* —
/// balance alerts (§5.3) and dedup drops — and the place to
/// look for "what happened around then", never for "what happened to this order".
///
/// That division is about **where a fact belongs**, not about this buffer being
/// lossy. #37 removed the ring; the division survives it, because an order is
/// still the thing an order's facts are attached to.
///
/// ## What may be written here
///
/// ⚠️ **An audit line may be written only where something other than a caller's
/// willingness to call bounds how often it fires** (#61).
///
/// Qualifying bounds, and they are the only three: **our own timer cadence**, **an
/// authenticated event** (the `stripe.*` webhook lines need the signing secret, so
/// growth is bounded by Stripe rather than by a caller — the same argument
/// `Orphans`'s `#unprocessable` rests on), or **a state transition**
/// (`gate.startedRefusing` fires once when the rail starts refusing, not once per
/// refused request).
///
/// ⚠️ **The rule is about frequency, not about what the line describes.** An
/// earlier draft said *"records a state change, not a request"* and it was wrong:
/// it would have excluded `stripe.retrieveUnauthorized`, which is the outcome of
/// our own outbound request and the only detector for a silently non-functioning
/// recovery sweep (RUNBOOK §8 carries it as P1), and `stripe.disputeCreated`,
/// which records an external fact rather than any state change of ours and exists
/// because nothing else records it at all. Both are legitimate; both are bounded
/// by something other than a caller.
///
/// What the rule excludes is the pre-commit refusal line #61 removed: refusals are
/// free to attempt — `#amountBelowMin` needs no prior state, so one cent from any
/// fresh principal reached it — and with the ring gone, a log fed by a free
/// caller is permanent stable-state growth at zero attacker cost. Every other
/// structure here is attacker-priced. This one is not, so admission is the guard.
///
/// **Adding a tag?** Name the bound. If the honest answer is "a caller decides",
/// it is a counter with a monitoring row, not a line.
///
/// A refund is the one money fact deliberately not on the order: it lives in
/// **Stripe**, where it was issued, plus the unresolved `#refundAfterDelivery`
/// entry the queue never evicts. That is the whole record until there is real
/// money to reconcile (#34 dropped a `refundedUsdCents` field as premature).
///
/// ⚠️ **Nothing is dropped since #37, and the `capacity` parameter is gone rather
/// than large.** `seq` is monotonic and never reused; with no drops there are no gaps,
/// so a reader holding the last seq it saw can tell new events from
/// an empty interval.
import Queue "mo:core/Queue";
import List "mo:core/List";
import Iter "mo:core/Iter";

module {

  public type Event = {
    seq : Nat;
    atNs : Int;
    /// Short greppable category, e.g. "delivery.sent", "orphanStore.resolved".
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
  /// Append. **Nothing is evicted** (#37).
  ///
  /// ⚠️ **The `capacity` parameter and the eviction loop are gone, not defaulted to a
  /// large number.** A bound that is never reached still has to be reasoned about at
  /// every call site, and a later "let's lower it for safety" would silently reintroduce
  /// a lossy log under a name that says it is not. Removing the parameter makes the
  /// property structural: there is nowhere left to put a cap.
  ///
  /// ⚠️ **This is only safe because of the admission rule above**, applied to the whole
  /// tag population rather than to the paths someone happened to look at: 71 tags
  /// checked, 2 removed for being caller-bounded. An unbounded log fed by a free caller
  /// is permanent stable-state growth at zero attacker cost; an unbounded log fed by
  /// timer cadence, authenticated events and state transitions grows with real activity.
  public func append(log : Log, atNs : Int, tag : Text, detail : Text) : Event {
    let event : Event = { seq = log.nextSeq; atNs; tag; detail };
    log.nextSeq += 1;
    log.events.pushBack(event);
    event;
  };

  /// Cap on one page. Matches `Orders.maxPageSize` and `Orphans.maxPageSize` so an
  /// operator learns one number rather than three.
  public let maxPageSize : Nat = 200;

  public type Page = { events : [Event]; nextCursor : ?Nat };

  /// One page of events, oldest → newest, after `afterSeq` (#38).
  ///
  /// ⚠️ **This became necessary the moment #37 removed the ring.** The bound used to be
  /// the ring itself, so nobody had to think about the response size; retention is now
  /// total, and a query response is capped at ~2 MB. Removing the ring moved the problem
  /// from *"history is lossy"* to *"the query cannot answer"* — both real, and only one
  /// was fixed by removing the cap.
  ///
  /// Cursor on `seq`, which is monotonic and never reused, and now has **no gaps** since
  /// nothing is dropped. `nextCursor` is set only when further events remain, so a caller
  /// stops the moment it is null.
  public func page(log : Log, afterSeq : ?Nat, limit : Nat) : Page {
    let capped = if (limit == 0 or limit > maxPageSize) maxPageSize else limit;
    let collected = List.empty<Event>();
    var last : ?Nat = null;
    for (event in log.events.values()) {
      let past = switch (afterSeq) { case (?cursor) event.seq > cursor; case null true };
      if (past) {
        if (collected.size() == capped) return { events = collected.toArray(); nextCursor = last };
        collected.add(event);
        last := ?event.seq;
      };
    };
    { events = collected.toArray(); nextCursor = null };
  };

  /// Retained events, oldest → newest.
  public func events(log : Log) : [Event] {
    log.events.values().toArray();
  };

  public func size(log : Log) : Nat {
    log.events.size();
  };

};
