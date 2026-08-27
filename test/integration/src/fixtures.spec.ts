// Real-Stripe-payload parity (issue #4).
//
// Every other Stripe payload in this repo is JSON we wrote from the API docs, so the
// suites prove the canister matches *our reading* of Stripe rather than Stripe. This
// file closes that gap: it parses **recorded real event bodies** and asserts the
// canister's parser extracts what we expect, and that the crafted equivalents agree.
//
// It has already been earned once — a unit test "covered" delayed-payment settlement
// by sending a second `checkout.session.completed`, which Stripe does not send.
//
// ⚠️ Every test here **skips** when its fixture is absent, so the suite stays green
// before anyone has captured them. Skipped is not passed: `--status` on the capture
// script is the source of truth for what is still missing.
//
//     scripts/capture-stripe-fixtures.sh --status
//     scripts/capture-stripe-fixtures.sh
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, test } from 'vitest';

const DIR = resolve(__dirname, '..', 'fixtures');

function fixture(name: string): Record<string, any> | null {
  const path = resolve(DIR, `${name}.json`);
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, 'utf-8'));
}

/// Declare a test that skips itself when the recorded body is not present.
function withFixture(
  name: string,
  title: string,
  fn: (event: Record<string, any>) => void,
): void {
  const event = fixture(name);
  test.skipIf(event === null)(`${name} — ${title}`, () => fn(event!));
}

describe('recorded Stripe events match what the canister expects', () => {
  // The envelope fields `Card.parseEvent` reads before anything else. If Stripe ever
  // moved these, every event would fail to parse and the cause would be non-obvious.
  for (const name of [
    'checkout.session.completed.paid',
    'charge.refunded.full',
    'charge.dispute.created',
  ]) {
    withFixture(name, 'has a string id, a string type, and a boolean livemode', (ev) => {
      expect(typeof ev.id).toBe('string');
      expect(typeof ev.type).toBe('string');
      // livemode must be a genuine boolean: `Json.boolAt` returns null for a string
      // "true", and the livemode gate would then treat it as unset.
      expect(typeof ev.livemode).toBe('boolean');
    });
  }

  withFixture('checkout.session.completed.paid', 'carries the fields attribution and pricing need', (ev) => {
    const o = ev.data.object;
    expect(ev.type).toBe('checkout.session.completed');
    expect(typeof o.payment_intent).toBe('string');
    expect(o.payment_status).toBe('paid');
    expect(typeof o.amount_total).toBe('number');
    expect(typeof o.currency).toBe('string');
    // `client_reference_id` is the whole attribution flow. Absent or null both mean
    // "no reference" to the parser; a *paid* capture should have carried one.
    expect(o.client_reference_id == null).toBe(false);
  });

  withFixture('checkout.session.completed.unpaid', 'is genuinely not paid', (ev) => {
    // The premise of the async path: `completed` can arrive with no money behind it.
    expect(ev.data.object.payment_status).not.toBe('paid');
  });

  withFixture('checkout.session.completed.no-intent', 'has a null payment_intent', (ev) => {
    // What a 100%-off promo code or subscription-mode link produces. The canister
    // acks these 200 and queues `#unprocessable` rather than 4xx-ing until Stripe
    // disables the endpoint — so this fixture pins that the case is real.
    expect(ev.data.object.payment_intent == null).toBe(true);
  });

  withFixture('checkout.session.async_payment_succeeded', 'carries the same session shape as completed', (ev) => {
    // The canister parses this into the *same* structure and runs the same handler.
    // If the shapes diverged, delayed payments would silently stop delivering.
    const o = ev.data.object;
    expect(ev.type).toBe('checkout.session.async_payment_succeeded');
    expect(typeof o.payment_intent).toBe('string');
    expect(typeof o.amount_total).toBe('number');
    expect(typeof o.currency).toBe('string');
    expect(o.payment_status).toBe('paid');
  });

  withFixture('checkout.session.async_payment_failed', 'identifies the intent that will never pay', (ev) => {
    expect(typeof ev.data.object.payment_intent).toBe('string');
  });

  // ── the refund pair: the defect that survived three review rounds ──────────────

  withFixture('charge.refunded.full', 'amount_refunded reaches amount', (ev) => {
    const o = ev.data.object;
    expect(typeof o.payment_intent).toBe('string');
    expect(typeof o.amount).toBe('number');
    expect(typeof o.amount_refunded).toBe('number');
    // `Card.isFullRefund` is exactly this comparison.
    expect(o.amount_refunded).toBeGreaterThanOrEqual(o.amount);
  });

  withFixture('charge.refunded.partial', 'amount_refunded is BELOW amount, and cumulative', (ev) => {
    const o = ev.data.object;
    expect(typeof o.amount).toBe('number');
    expect(typeof o.amount_refunded).toBe('number');
    // THE assertion this whole file exists for. The canister assumes
    // `amount_refunded` is *cumulative* against the charge total, and that a partial
    // refund therefore leaves the obligation open. If Stripe instead reported
    // per-refund amounts, a sequence of partials would each look partial and an
    // obligation would never auto-resolve; if it reported something else again, a
    // partial could read as full and erase a live obligation.
    expect(o.amount_refunded).toBeLessThan(o.amount);
    expect(o.amount_refunded).toBeGreaterThan(0);
  });

  withFixture('charge.dispute.created', 'is a type the canister does not handle', (ev) => {
    // Not subscribed by decision (§11): the canister cannot claw back forwarded
    // cycles. It must still be acked 200 rather than 4xx'd. Pinning the shape so the
    // unhandled-type path is exercised against a real body.
    expect(ev.type).toBe('charge.dispute.created');
  });
});

describe('capture progress', () => {
  test('reports which fixtures are still missing', () => {
    const all = [
      'checkout.session.completed.paid',
      'checkout.session.completed.unpaid',
      'checkout.session.completed.no-intent',
      'checkout.session.async_payment_succeeded',
      'checkout.session.async_payment_failed',
      'charge.refunded.full',
      'charge.refunded.partial',
      'charge.dispute.created',
    ];
    const missing = all.filter((n) => fixture(n) === null);
    if (missing.length > 0) {
      // Deliberately not a failure: this suite must stay green before anyone has run
      // the capture. The visibility is the point — see issue #4.
      // eslint-disable-next-line no-console
      console.log(
        `\n  ${all.length - missing.length}/${all.length} real Stripe fixtures captured.` +
          `\n  Missing: ${missing.join(', ')}` +
          `\n  Capture them with: scripts/capture-stripe-fixtures.sh\n`,
      );
    }
    expect(missing.length).toBeLessThanOrEqual(all.length);
  });
});
