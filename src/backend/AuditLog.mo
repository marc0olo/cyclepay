/// The audit log — unbounded, append-only operational trail (§4.2).
///
/// **Facts about money live on the objects, not here.** Where an order got to, what the
/// buyer paid, why it expired: all on `Types.Order`. The journal holds the delivery
/// position; the order's `problems` and the orphan list hold open obligations. This is
/// where to look for "what happened around then", never for "what happened to this order".
///
/// A refund is the one money fact deliberately not on the order: it lives in **Stripe**,
/// where it was issued, plus the unresolved `#refundAfterDelivery` problem.
///
/// ## ⚠️ What may be written here — the admission rule
///
/// > **An audit line may be written only where something other than a caller's
/// > willingness to call bounds how often it fires.**
///
/// Qualifying bounds, and they are the only three: **our own timer cadence**, **an
/// authenticated event** (the `stripe.*` lines need the signing secret, so growth is
/// bounded by Stripe rather than by a caller), or **a state transition**
/// (`gate.startedRefusing` fires once when the rail starts refusing, not per refused
/// request).
///
/// **The rule is about frequency, not about what the line describes.** Phrasing it as
/// "records a state change, not a request" excludes legitimate lines — the outcome of our
/// own outbound request is the only detector for a silently non-functioning recovery
/// sweep, and it is bounded by our cadence, not by a caller.
///
/// ⚠️ **Our cadence bounds a RATE, and a rate against an unfixed persistent condition is
/// unbounded over time.** A per-pass line about a condition nobody has fixed is not
/// admissible just because a timer paces it; latch the condition and write once.
///
/// What the rule excludes is a pre-commit refusal line: refusals are free to attempt —
/// one cent from any fresh principal reaches `#amountBelowMin` — so a log fed by a free
/// caller is permanent stable-state growth at zero attacker cost. Every other structure
/// here is attacker-priced. This one is not, so admission is the guard.
///
/// **Adding a tag?** Name the bound. If the honest answer is "a caller decides", it is a
/// counter with a monitoring row, not a line.
///
/// ⚠️ **Nothing is dropped and the `capacity` parameter is gone rather than large**
/// (#37). `seq` is monotonic and never reused; with no drops there are no gaps, so a
/// reader holding the last seq it saw can tell new events from an empty interval.
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

  /// Append. **Nothing is evicted** (#37).
  ///
  /// ⚠️ **The `capacity` parameter is gone, not defaulted to a large number.** A bound
  /// that is never reached still has to be reasoned about at every call site, and a later
  /// "let's lower it for safety" would silently reintroduce a lossy log under a name that
  /// says it is not. There is nowhere left to put a cap.
  ///
  /// ⚠️ **Only safe because of the admission rule above**, and only once that rule has
  /// been run against the WHOLE tag population rather than the paths that prompted it.
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
