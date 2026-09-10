import { test; suite } "mo:test";
import Nat "mo:core/Nat";
import AuditLog "../src/backend/AuditLog";

// Unit suite for the §4.2 audit log: append-only with a monotonic, never-reused `seq`,
// and the two paging views over it.
//
// ⚠️ This header described a "bounded ring buffer with hard cap and oldest-first drop"
// until 2026-09-10, three lines above a test asserting nothing is ever dropped. #37
// removed the ring; the comment outlived it.

suite("audit log ring buffer", func() {
  test("append returns the event and retains oldest -> newest", func() {
    let log = AuditLog.emptyLog();
    let a = AuditLog.append(log, 100, "delivery.sent", "3.5 T to the buyer");
    let b = AuditLog.append(log, 200, "dedup.drop", "evt_1 redelivered");
    assert a.seq == 0;
    assert b.seq == 1;
    let events = AuditLog.events(log);
    assert events.size() == 2;
    assert events[0] == a;
    assert events[1] == b;
  });

  // ── Deleted by #37, with their heirs named ────────────────────────────────
  //
  // ~~"hard cap drops oldest first"~~ and ~~"seq stays monotonic across drops (gap
  // detection)"~~ both asserted about a bound that no longer exists. The `capacity`
  // parameter is gone from `append`, so neither claim is expressible — which is
  // stronger than a test asserting the cap is large.
  //
  // ⚠️ **Their heirs, because a deleted test needs one named:**
  //   - "nothing is ever dropped" below is the direct replacement: it is the same
  //     property inverted, and it is the one that would fail if a cap came back.
  //   - `seq` monotonicity survives as a claim in its own right, tested below without
  //     reference to drops. Readers used gaps in `seq` to DETECT drops; with no drops
  //     there are no gaps, so what is left to pin is that `seq` never repeats.

  test("nothing is ever dropped, however many events arrive (#37)", func() {
    let log = AuditLog.emptyLog();
    for (i in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].values()) {
      ignore AuditLog.append(log, i, "tag", "e" # debug_show(i));
    };
    assert AuditLog.size(log) == 10;
    let events = AuditLog.events(log);
    // Oldest still first, newest still last: retention is total, not a larger window.
    assert events[0].seq == 0;
    assert events[9].seq == 9;
  });

  test("seq never repeats, which is what readers actually rely on", func() {
    let log = AuditLog.emptyLog();
    for (i in [0, 1, 2, 3].values()) {
      ignore AuditLog.append(log, i, "tag", "");
    };
    let e = AuditLog.append(log, 99, "tag", "");
    assert e.seq == 4;
    // ⚠️ **No gap, and that is the point.** Gaps in `seq` used to be how a reader
    // detected drops; with nothing dropped there is nothing to detect, and the only
    // remaining property is that a seq is never reused.
    assert AuditLog.events(log)[0].seq == 0;
    assert AuditLog.size(log) == 5;
  });
});

/// ⚠️ **Neither paging view had a unit test before 2026-09-10.** `page` shipped with #38
/// and was covered only through integration scenarios, which read it to exhaustion and so
/// could not distinguish "the cursor works" from "one page held everything".
suite("audit log paging", func() {

  /// `n` events, seq 0 .. n-1.
  func filled(n : Nat) : AuditLog.Log {
    let log = AuditLog.emptyLog();
    for (i in Nat.range(0, n)) ignore AuditLog.append(log, i, "tag" # i.toText(), "d" # i.toText());
    log;
  };

  test("page walks OLDEST first, and the cursor is the newest seq returned", func() {
    let log = filled(5);
    let first = AuditLog.page(log, null, 2);
    assert first.events.size() == 2;
    assert first.events[0].seq == 0;
    assert first.events[1].seq == 1;
    // Pass it back as `afterSeq` to continue forward.
    assert first.nextCursor == ?1;

    let second = AuditLog.page(log, first.nextCursor, 2);
    assert second.events[0].seq == 2;
    assert second.nextCursor == ?3;

    // The last page carries no cursor, which is how a caller stops.
    let third = AuditLog.page(log, second.nextCursor, 2);
    assert third.events.size() == 1;
    assert third.events[0].seq == 4;
    assert third.nextCursor == null;
  });

  test("⚠️ recentPage walks NEWEST first, which is what the console shows", func() {
    let log = filled(5);
    let first = AuditLog.recentPage(log, null, 2);
    assert first.events.size() == 2;
    assert first.events[0].seq == 4;
    assert first.events[1].seq == 3;
  });

  test("⚠️ recentPage's cursor is the OLDEST seq returned — the mirror of page's", func() {
    // The one trap in having both: the same `Page` type carries opposite cursor
    // meanings. Swapping them pages the wrong way and looks like a stuck first page.
    let log = filled(5);
    let first = AuditLog.recentPage(log, null, 2);
    assert first.nextCursor == ?3;

    let second = AuditLog.recentPage(log, first.nextCursor, 2);
    assert second.events[0].seq == 2;
    assert second.events[1].seq == 1;
    assert second.nextCursor == ?1;

    let third = AuditLog.recentPage(log, second.nextCursor, 2);
    assert third.events.size() == 1;
    assert third.events[0].seq == 0;
    assert third.nextCursor == null;
  });

  test("the two views cover the same events, in opposite order", func() {
    // Neither view may drop or invent an event: a reader choosing by direction must not
    // also be choosing a different population.
    let log = filled(7);
    let forward = AuditLog.page(log, null, 200);
    let backward = AuditLog.recentPage(log, null, 200);
    assert forward.events.size() == 7;
    assert backward.events.size() == 7;
    for (i in Nat.range(0, 7)) {
      assert forward.events[i].seq == backward.events[6 - i].seq;
    };
  });

  test("`seq` starts at 0, so a cursor of ?0 yields nothing older", func() {
    // Not a corner case to shrug at: `0` is a real seq here, so a sentinel-zero cursor
    // would silently hide the first event ever written.
    let log = filled(3);
    let page = AuditLog.recentPage(log, ?0, 5);
    assert page.events.size() == 0;
    assert page.nextCursor == null;
  });

  test("an empty log pages to nothing, both ways", func() {
    let log = AuditLog.emptyLog();
    assert AuditLog.page(log, null, 10).events.size() == 0;
    assert AuditLog.recentPage(log, null, 10).events.size() == 0;
    assert AuditLog.recentPage(log, null, 10).nextCursor == null;
  });

  test("a zero or oversized limit is capped rather than refused", func() {
    let log = filled(3);
    assert AuditLog.recentPage(log, null, 0).events.size() == 3;
    assert AuditLog.recentPage(log, null, 10_000).events.size() == 3;
  });
});
