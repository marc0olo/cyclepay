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
import { checkoutSessionBody, partialRefundBody } from './harness';

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

  withFixture('checkout.session.completed.unpaid', 'is a real delayed-method body, intent and all', (ev) => {
    // ⚠️ **This assertion used to be `payment_status !== 'paid'` — a tautology**: it
    // checked that the file captured for being unpaid contains the field it was captured
    // for. What matters is the rest of the shape, because our code reads it: the guard in
    // `Card.handleWebhook` acks these and waits, and `Session.classify` routes
    // complete+unpaid to `#unknown` so the #52 sweep cannot claim a buyer paid.
    expect(ev.data.object.payment_status).not.toBe('paid');
    // Stripe still sends an intent for an unsettled session, so "unpaid" is NOT
    // detectable by a missing intent — the field we actually branch on is the only one
    // that says so. A parser keying off `payment_intent == null` would read this as paid.
    expect(typeof ev.data.object.payment_intent).toBe('string');
    // And it really is the delayed flow rather than a card session we mislabelled.
    expect(ev.data.object.payment_method_types).toContain('sepa_debit');
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

describe('real vs crafted: the same values, the same shape (#4 the point of the issue)', () => {
  // ⚠️ **This is what #4 was opened for, and it did not exist until now.** Everything
  // above pins the *real* bodies. This compares them against the **crafted** builders the
  // rest of the suite runs on, field by field, because the crafted ones encode our
  // reading of the API docs and that reading is the thing at risk.
  //
  // The precedent, from #4's own text: a unit test "covered" delayed-payment settlement by
  // sending a second `checkout.session.completed`, an event Stripe does not send. Nothing
  // could catch that except a real body.
  //
  // Any disagreement here is a finding, not a failure: either our crafted payload is
  // wrong (and every suite built on it proves the wrong thing) or our parser reads a
  // field Stripe does not send.

  /// Every field path `Card.parseEvent` and `Card.handleWebhook` read, per event type.
  /// Kept as paths rather than a shape so a missing *parent* is reported precisely.
  const REQUIRED: Record<string, string[]> = {
    'checkout.session.completed': [
      'id', 'type', 'livemode',
      'data.object.payment_intent',
      'data.object.amount_total',
      'data.object.currency',
      'data.object.payment_status',
    ],
    // ⚠️ **No `livemode` on these two, and that is not an omission.** The canister reads
    // `livemode` only off a checkout **session** — `#chargeRefunded` carries
    // `{eventId, paymentIntent, amountRefundedCents, chargeAmountCents}` and
    // `#disputeCreated` carries `{eventId, paymentIntent, amountCents}`. Neither has it.
    //
    // The first draft of this list included it, and the parity test failed on its first
    // run: the crafted refund hardcodes `livemode: true` while every real sandbox refund
    // is `false`. That was **my test overreaching**, not a builder bug — asserting parity
    // on a field the path does not consume. Same discipline as "check which guard actually
    // fires": establish that the code reads it before requiring it to match.
    //
    // ⚠️ The latent half is still worth knowing: `partialRefundBody` cannot express a
    // test-mode refund at all. Harmless **only because nothing reads it here** — so if a
    // livemode check is ever added to the refund path, that builder needs a parameter
    // first, or every refund scenario will be testing a body Stripe never sends in test
    // mode.
    'charge.refunded': [
      'id', 'type',
      'data.object.payment_intent',
      'data.object.amount',
      'data.object.amount_refunded',
    ],
    'charge.dispute.created': ['id', 'type', 'data.object.payment_intent'],
  };

  function at(o: any, path: string): unknown {
    return path.split('.').reduce((n, k) => (n == null ? undefined : n[k]), o);
  }

  for (const name of [
    'checkout.session.completed.paid',
    'checkout.session.async_payment_succeeded',
    'checkout.session.async_payment_failed',
    'charge.refunded.full',
    'charge.refunded.partial',
    'charge.dispute.created',
  ]) {
    withFixture(name, 'carries every field the canister reads, at the path it reads it', (ev) => {
      // `async_payment_*` carry the session object, so they answer to the same required
      // set as `completed` — which is the assumption that broke once and is asserted here
      // against Stripe rather than against our belief.
      const key = ev.type.startsWith('checkout.session.') ? 'checkout.session.completed' : ev.type;
      const required = REQUIRED[key];
      expect(required, `no required-field list for ${ev.type}`).toBeDefined();
      for (const path of required!) {
        expect(at(ev, path), `${name}: real body is missing ${path}`).not.toBeUndefined();
      }
    });
  }

  withFixture('checkout.session.completed.paid', 'agrees with the crafted body field for field', (ev) => {
    // Rebuild the crafted payload from the REAL body's own values, then compare the parsed
    // structures. Identical values by construction — so any difference that survives is a
    // difference in *shape*: a field we invent, a field we omit, or a type mismatch.
    const o = ev.data.object;
    const crafted = JSON.parse(
      checkoutSessionBody({
        eventId: ev.id,
        paymentIntent: o.payment_intent,
        clientReferenceId: o.client_reference_id ?? null,
        amountCents: BigInt(o.amount_total),
        currency: o.currency,
        paymentStatus: o.payment_status,
        livemode: ev.livemode,
      }),
    );
    for (const path of REQUIRED['checkout.session.completed']!) {
      expect(at(crafted, path), `crafted body disagrees with Stripe at ${path}`).toEqual(at(ev, path));
    }
    // ⚠️ The crafted builder is a SUBSET of the real body, deliberately — the real one
    // carries dozens of fields the canister never reads. What must not happen is the
    // reverse: a crafted field with no real counterpart, which is an invented assumption.
    const invented = Object.keys(crafted.data.object).filter((k) => !(k in o));
    expect(invented, 'crafted payload has fields Stripe does not send').toEqual([]);
  });

  withFixture('charge.refunded.partial', 'agrees with the crafted refund, and is genuinely partial', (ev) => {
    const o = ev.data.object;
    const crafted = JSON.parse(
      partialRefundBody(ev.id, o.payment_intent, BigInt(o.amount_refunded), BigInt(o.amount)),
    );
    for (const path of REQUIRED['charge.refunded']!) {
      expect(at(crafted, path), `crafted refund disagrees with Stripe at ${path}`).toEqual(at(ev, path));
    }
    const invented = Object.keys(crafted.data.object).filter((k) => !(k in o));
    expect(invented, 'crafted refund has fields Stripe does not send').toEqual([]);
    // The distinction three review rounds argued about, now read off a real body: a
    // partial refund is only distinguishable by comparing the two amounts.
    expect(o.amount_refunded).toBeLessThan(o.amount);
  });

  withFixture('charge.refunded.full', 'a full refund reaches the charge total', (ev) => {
    expect(ev.data.object.amount_refunded).toBe(ev.data.object.amount);
  });
});
