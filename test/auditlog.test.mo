import { test; suite } "mo:test";
import AuditLog "../src/backend/AuditLog";

// Unit suite for the §4.2 bounded audit-log ring buffer: hard cap with
// oldest-first drop and a monotonic, never-reused seq.

suite("audit log ring buffer", func() {
  test("append returns the event and retains oldest -> newest", func() {
    let log = AuditLog.emptyLog();
    let a = AuditLog.append(log, 10, 100, "delivery.sent", "3.5 T to the buyer");
    let b = AuditLog.append(log, 10, 200, "dedup.drop", "evt_1 redelivered");
    assert a.seq == 0;
    assert b.seq == 1;
    let events = AuditLog.events(log);
    assert events.size() == 2;
    assert events[0] == a;
    assert events[1] == b;
  });

  test("hard cap drops oldest first", func() {
    let log = AuditLog.emptyLog();
    for (i in [0, 1, 2, 3, 4].values()) {
      ignore AuditLog.append(log, 3, i, "tag", "e" # debug_show(i));
    };
    assert AuditLog.size(log) == 3;
    let events = AuditLog.events(log);
    assert events[0].seq == 2;
    assert events[2].seq == 4;
  });

  test("seq stays monotonic across drops (gap detection)", func() {
    let log = AuditLog.emptyLog();
    for (i in [0, 1, 2, 3].values()) {
      ignore AuditLog.append(log, 2, i, "tag", "");
    };
    // seqs 0 and 1 were dropped; next append continues at 4, never reusing
    let e = AuditLog.append(log, 2, 99, "tag", "");
    assert e.seq == 4;
    assert AuditLog.events(log)[0].seq == 3;
  });
});
