import { test; suite } "mo:test";
import AuditLog "../src/backend/AuditLog";

// Unit suite for the §4.2 bounded audit-log ring buffer: hard cap with
// oldest-first drop and a monotonic, never-reused seq.

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
