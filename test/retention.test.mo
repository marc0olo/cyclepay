import { test; suite } "mo:test";
import Retention "../src/backend/Retention";
import Types "../src/backend/Types";

// Unit suite for the three retention bands. `bandOf` is pure over status and
// age, so every boundary is pinned here; the other half of the band-3 contract
// (never delete an order that has touched money) lives in Main.mo's sweep and
// is asserted by the "money-bearing statuses" case below plus the integration
// suite.

let config = Retention.defaultConfig();
let created : Int = 1_000_000;

/// `now` for an order of exactly this age.
func at(age : Nat) : Int = created + age;

suite("config", func() {
  test("defaults validate and leave a wide band 2", func() {
    assert Retention.validateConfig(config) == #ok;
    // Band 2 is where a late payment is still honoured, so it must be large.
    assert config.retentionHorizonNs > config.orderTtlNs * 10;
  });

  test("the TTL must outlive a Stripe Checkout Session (24 h)", func() {
    // A session that outlives its order would let a user watch their order
    // expire while they are still on the Stripe payment page.
    assert config.orderTtlNs >= 86_400_000_000_000;
  });

  test("a zero TTL is refused", func() {
    assert Retention.validateConfig({ config with orderTtlNs = 0 }) == #err(#zeroTtl);
  });

  test("a horizon at or below the TTL is refused — band 2 must exist", func() {
    // Equal would delete orders the instant they expired, destroying the §4
    // late-payment guarantee.
    assert Retention.validateConfig({ config with retentionHorizonNs = config.orderTtlNs })
      == #err(#horizonNotAfterTtl({
        orderTtlNs = config.orderTtlNs;
        retentionHorizonNs = config.orderTtlNs;
      }));
    assert Retention.validateConfig({ config with retentionHorizonNs = config.orderTtlNs - 1 })
      == #err(#horizonNotAfterTtl({
        orderTtlNs = config.orderTtlNs;
        retentionHorizonNs = config.orderTtlNs - 1;
      }));
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

  test("#expired: one ns short of the horizon keeps, exactly at it sweeps", func() {
    assert Retention.bandOf(#expired, created, at(config.retentionHorizonNs - 1), config) == #keep;
    assert Retention.bandOf(#expired, created, at(config.retentionHorizonNs), config) == #sweep;
  });

  test("#expired inside band 2 is never swept, however long past the TTL", func() {
    // The whole point of band 2: still fully payable, record intact.
    assert Retention.bandOf(#expired, created, at(config.orderTtlNs), config) == #keep;
    assert Retention.bandOf(#expired, created, at(config.orderTtlNs * 2), config) == #keep;
  });

  test("the horizon is measured from creation, not from expiry", func() {
    // Absolute and monotonic: an order created at T is sweepable at
    // T + horizon regardless of when it happened to flip to #expired.
    assert Retention.bandOf(#expired, created, at(config.retentionHorizonNs), config) == #sweep;
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
      assert Retention.bandOf(status, created, at(config.retentionHorizonNs * 100), config) == #keep;
    };
  });

  test("all eight statuses are covered — a new status defaults to keep", func() {
    // Guards against a future status silently becoming sweepable.
    let all : [Types.OrderStatus] = [
      #created, #expired, #paid, #minting,
      #icpAtCmc, #delivered, #awaitingTreasury, #errorQueue,
    ];
    var expiring = 0;
    var sweeping = 0;
    for (status in all.values()) {
      switch (Retention.bandOf(status, created, at(config.retentionHorizonNs), config)) {
        case (#expire) expiring += 1;
        case (#sweep) sweeping += 1;
        case (#keep) {};
      };
    };
    // Exactly one status expires (#created) and exactly one sweeps (#expired).
    assert expiring == 1;
    assert sweeping == 1;
  });
});

suite("clock safety", func() {
  test("a backwards clock never acts", func() {
    // Time going backwards must not be read as "infinitely old".
    assert Retention.bandOf(#created, created, created - 1, config) == #keep;
    assert Retention.bandOf(#expired, created, created - 1_000_000, config) == #keep;
  });
});
