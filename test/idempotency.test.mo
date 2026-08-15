import { test; suite } "mo:test";
import Idempotency "../src/backend/Idempotency";

// Unit suite for the §4.2 per-rail dedup sets: record-once semantics per set,
// set independence, and the ~7-day Stripe pruning boundary.

let day : Int = 24 * 60 * 60 * 1_000_000_000;

suite("record-once semantics", func() {
  test("stripe event: first sight true, replay false", func() {
    let store = Idempotency.emptyStore();
    assert Idempotency.recordStripeEvent(store, "evt_1", 100);
    assert not Idempotency.recordStripeEvent(store, "evt_1", 200);
    assert Idempotency.recordStripeEvent(store, "evt_2", 200);
  });

  test("stripe intent: first sight true, replay false", func() {
    let store = Idempotency.emptyStore();
    assert Idempotency.recordStripeIntent(store, "pi_1", 100);
    assert not Idempotency.recordStripeIntent(store, "pi_1", 200);
  });

  test("sets are independent: same key text in events vs intents", func() {
    let store = Idempotency.emptyStore();
    assert Idempotency.recordStripeEvent(store, "shared", 100);
    // an intent with the same text is a different namespace, not a dup
    assert Idempotency.recordStripeIntent(store, "shared", 100);
  });
});

suite("stripe pruning (~7 days, §4.2)", func() {
  test("entry exactly retention-old is pruned, 1ns younger is kept", func() {
    let store = Idempotency.emptyStore();
    assert Idempotency.recordStripeEvent(store, "evt_old", 0);
    assert Idempotency.recordStripeEvent(store, "evt_young", 1);
    let pruned = Idempotency.pruneStripe(store, Idempotency.stripeRetentionNs);
    assert pruned == 1;
    // evt_old is gone → recording it again is "first sight"
    assert Idempotency.recordStripeEvent(store, "evt_old", Idempotency.stripeRetentionNs);
    // evt_young survived → still a duplicate
    assert not Idempotency.recordStripeEvent(store, "evt_young", Idempotency.stripeRetentionNs);
  });

  test("prunes both stripe sets, returns total count", func() {
    let store = Idempotency.emptyStore();
    assert Idempotency.recordStripeEvent(store, "evt_1", 0);
    assert Idempotency.recordStripeEvent(store, "evt_2", 0);
    assert Idempotency.recordStripeIntent(store, "pi_1", 0);
    assert Idempotency.recordStripeIntent(store, "pi_fresh", 5 * day);
    assert Idempotency.pruneStripe(store, 8 * day) == 3;
    assert not Idempotency.recordStripeIntent(store, "pi_fresh", 8 * day);
  });

  test("first-seen timestamp does not refresh on replay", func() {
    let store = Idempotency.emptyStore();
    assert Idempotency.recordStripeEvent(store, "evt_1", 0);
    // redelivery on day 6 must not extend retention
    assert not Idempotency.recordStripeEvent(store, "evt_1", 6 * day);
    assert Idempotency.pruneStripe(store, 7 * day) == 1;
  });

  test("pruning an empty store is a no-op", func() {
    let store = Idempotency.emptyStore();
    assert Idempotency.pruneStripe(store, 100 * day) == 0;
  });

  test("retention constant is 7 days", func() {
    assert Idempotency.stripeRetentionNs == 7 * day;
  });
});
