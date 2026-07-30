import { test; suite } "mo:test";
import Retention "../src/backend/Retention";
import Types "../src/backend/Types";

// Unit suite for §4 expiry policy. `bandOf` is pure over status and age, so
// every boundary is pinned here. Nothing deletes orders — the only transition
// this drives is #created → #expired, and expiry is advisory (an expired order
// stays payable).

let config = Retention.defaultConfig();
let created : Int = 1_000_000;

/// `now` for an order of exactly this age.
func at(age : Nat) : Int = created + age;

suite("config", func() {
  test("defaults validate", func() {
    assert Retention.validateConfig(config) == #ok;
  });

  test("the TTL must outlive a Stripe Checkout Session (24 h)", func() {
    // A session that outlives its order would let a user watch their order
    // expire while they are still on the Stripe payment page.
    assert config.orderTtlNs >= 86_400_000_000_000;
  });

  test("a zero TTL is refused", func() {
    assert Retention.validateConfig({ config with orderTtlNs = 0 }) == #err(#zeroTtl);
  });

});

suite("band boundaries", func() {
  test("#created: one ns short of the TTL keeps, exactly at it expires", func() {
    assert Retention.bandOf(#created, created, at(config.orderTtlNs - 1), config) == #keep;
    assert Retention.bandOf(#created, created, at(config.orderTtlNs), config) == #expire;
  });

  test("a brand-new order keeps", func() {
    assert Retention.bandOf(#created, created, created, config) == #keep;
  });

  test("an expired order is kept forever, however long past the TTL", func() {
    // It stays payable (§4 advisory expiry) and it is a record of an attempt
    // either way. Nothing deletes orders.
    assert Retention.bandOf(#expired, created, at(config.orderTtlNs), config) == #keep;
    assert Retention.bandOf(#expired, created, at(config.orderTtlNs * 1_000), config) == #keep;
  });

});

suite("statuses the sweep must never touch", func() {
  test("money-bearing and terminal statuses always keep, at any age", func() {
    // #paid/#minting/#icpAtCmc/#awaitingTreasury are in flight; #delivered and
    // #errorQueue are financial records kept forever. Their volume is bounded
    // by the burn cap, so they can never be a growth vector.
    let untouchable : [Types.OrderStatus] = [
      #paid,
      #minting,
      #icpAtCmc,
      #awaitingTreasury,
      #delivered,
      #errorQueue,
    ];
    for (status in untouchable.values()) {
      assert Retention.bandOf(status, created, at(config.orderTtlNs * 10_000), config) == #keep;
    };
  });

  test("all eight statuses are covered — a new status defaults to keep", func() {
    // Guards against a future status silently becoming sweepable.
    let all : [Types.OrderStatus] = [
      #created, #expired, #paid, #minting,
      #icpAtCmc, #delivered, #awaitingTreasury, #errorQueue,
    ];
    var expiring = 0;
    for (status in all.values()) {
      switch (Retention.bandOf(status, created, at(config.orderTtlNs * 1_000), config)) {
        case (#expire) expiring += 1;
        case (#keep) {};
      };
    };
    // Exactly one status is ever touched: #created → #expired. Nothing else.
    assert expiring == 1;
  });
});

suite("clock safety", func() {
  test("a backwards clock never acts", func() {
    // Time going backwards must not be read as "infinitely old".
    assert Retention.bandOf(#created, created, created - 1, config) == #keep;
    assert Retention.bandOf(#expired, created, created - 1_000_000, config) == #keep;
  });
});
