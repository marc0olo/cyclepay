/// PocketIC integration suite — the Card-rail go-live bar (spec §9).
///
/// Scenarios run **sequentially against one instance**: the on-chain state
/// accumulates the way a live gateway's would (orders, dedup sets, burn-cap
/// consumption, audit trail), and several scenarios deliberately build on
/// earlier ones. Coverage demanded by §9: happy path, duplicate/replay,
/// delivery replay and escalation, the error queue,
/// forex fail-closed, upgrade-mid-flight, postupgrade timer re-arm.
import { afterAll, afterEach, beforeAll, expect, test } from 'vitest';
import {
  CYCLES_LEDGER_FEE, ICP_USD_RATE,
  TIER_LOCKED_CYCLES, TIER_USD_CENTS, WEBHOOK_SECRET, XDR_PERMYRIAD_PER_ICP, admin, user,
  bigIntReplacer, partialRefundBody, stopNns, startNns,
  CYCLES_LEDGER_ID, clientReferenceFor, createOrderWithSession, cancelOrderWithExpire,
  awaitPendingOutcall, answerOutcall, outcallHeader, outcallBody, sessionExpiredBody,
  sessionCreatedBody, maybePendingOutcall, drainSweepRetrieves, isSweepRetrieve,
  answerSweepRetrieveOpen,
  Gateway, setupGateway, teardownGateway, upgradeBackendMidFlight,
  setCmcRate, fundReserve, reserveBalance,
  checkoutSessionBody, chargeRefundedBody, deliverWebhook, stripeSignature,
  nowSeconds, setXrcRate, setXrcResponse, warmRates, ensureRates, tickRateTimer,
  orderStatus, statusKey, tickUntilStatus, expectOk, expectErr,
  allErrorEntries, openErrorEntries,
} from './harness';
import type { Destination, ErrorEntry, Order } from './types';

let gw: Gateway;

/// The only destination `create_order` accepts (#29): the caller's own
/// cycles-ledger account, default subaccount.
///
/// Every order below is addressed here, which is also why the delivered figure is
/// exact rather than bounded: delivery goes through `cyclesLedger.deposit`, whose
/// 100 M deposit fee is a constant, where `deposit_cycles` to a canister lost an
/// unpredictable slice to execution. (Delivery becomes `icrc1_transfer` in #30;
/// the fee stays deterministic, so these assertions carry over.)
const USER_ACCOUNT: Destination = {
  cyclesLedgerAccount: { owner: user.getPrincipal(), subaccount: [] },
};

/// ⚠️ **THE FLOOR'S BOUND, after every single scenario.**
///
/// `reserveFloor` must never exceed the real ledger balance, because the gate sells
/// against it — an optimistic floor admits orders the reserve cannot cover, and it does
/// so silently.
///
/// This started as one assertion inside scenario 73. That was enough to catch a
/// mutation (crediting the floor back on a real debit) and **not** enough to be the
/// safety net it was described as: it checked history up to 73 and nothing after, so
/// anything first reachable in a later scenario walked past it. Widening it to three
/// scenarios fixed those three; a hook fixes the **class** — every scenario anyone adds
/// from here is born checkpointed, including ones written by someone who never reads
/// this comment.
///
/// Costs one query and one ledger read per scenario. A read failure is skipped rather
/// than asserted: a scenario that fails with the ledger stopped would otherwise get a
/// confusing secondary error on top of its real one.
afterEach(async () => {
  // ⚠️ **Backstop for the sweep's background retrieves (#52), before the floor check.**
  // `awaitPendingOutcall` answers strays as it meets them, so this should normally find
  // none; it exists so a scenario that never calls that helper cannot leave a parked
  // outcall for the next one to trip over. A parked outcall is an in-flight message, and
  // one leaking across a scenario boundary would look exactly like the order-coupling
  // failures the README warns about.
  try { await drainSweepRetrieves(gw) } catch (_e) { /* teardown has begun */ }
  try {
    const floor = (await gw.asAnon.reserve_status()).reserveFloor;
    expect(floor, 'reserveFloor exceeded the real reserve balance').toBeLessThanOrEqual(
      await reserveBalance(gw),
    );
  } catch (e) {
    if (e instanceof Error && /exceeded the real reserve/.test(e.message)) throw e;
    // Ledger unreadable (a scenario left it stopped, or teardown has begun) — let the
    // scenario's own failure be the one that is reported.
  }
});

/// What the buyer actually holds, on the cycles ledger.
async function userCycles(): Promise<bigint> {
  return gw.cyclesLedger.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] });
}

// Orders created along the way (suite-global on purpose — later scenarios
// replay and re-attack earlier ones).
let orderA: Order; let refA: string; // the happy path order
let orderB: Order; let refB: string; // cycles-ledger delivery
let orderC: Order; let refC: string; // a delivery through a ledger outage
let orderE: Order; let refE: string; // upgrade-mid-transfer replay
/// The escalated order scenario 35 leaves in `needsReview` with a transfer intent
/// and no block. 76 uses it as the freeze case the reserve reconcile has to survive,
/// and 77 resolves it — so it is suite-global rather than local to 35.
let orderEscalated: Order;

/// #30 PR-A: delivery is a transfer OUT of the gateway's own cycles-ledger
/// account, so the suite has to fund that account or every order retries
/// forever. Sized generously — an unfunded reserve is PR-B's subject, and a
/// scenario that runs short here fails as a hang rather than as an assertion.
const RESERVE_CYCLES = 500_000_000_000_000n; // 500 T

beforeAll(async () => {
  gw = await setupGateway();
  await setCmcRate(gw);
  await fundReserve(gw, RESERVE_CYCLES);
  // ⚠️ The gate refuses to quote against an **unobserved** reserve, and a funded reserve
  // is not a sellable one until `fundReserve` makes the gateway look (scenario 73 is the
  // guard on that). Every scenario below that creates an order needs both calls above.
  //
  // ⚠️ **The open-order cap is pinned here, and the shipped default is 1, not 20.** A
  // test that depends on a limit should state the limit rather than inherit it — and this
  // file's 55 order-creations against one principal would all refuse under the shipped
  // value. Scenario 88 is where the cap of 1 is actually exercised, by setting it and
  // restoring it. Do NOT "fix" a scenario that trips this by making it create fewer
  // orders: scenario 07 needs two in the same round for a reason spelled out there.
  const gateDefaults = (await gw.asAnon.lifecycle_config()).gate;
  expectOk(await gw.asAdmin.set_gate_config({ ...gateDefaults, maxOpenOrdersPerPrincipal: 20n }));
});



afterAll(async () => {
  if (gw) await teardownGateway(gw);
});

test('01 — deploy, fail-closed before provisioning, admin authz', async () => {
  expect(await gw.asAnon.health()).toBe(true);

  // §6.1: an unprovisioned secret answers 503 so Stripe keeps retrying.
  const before = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_pre', paymentIntent: 'pi_pre', clientReferenceId: null,
    amountCents: TIER_USD_CENTS,
  }));
  expect(before.status_code).toBe(503);

  // §7: only controllers may provision; the user and anonymous callers trap.
  await expect(gw.asUser.set_webhook_secret(WEBHOOK_SECRET)).rejects.toThrow(/not a controller/);
  await expect(gw.asAnon.set_webhook_secret(WEBHOOK_SECRET)).rejects.toThrow(/anonymous/);

  expectOk(await gw.asAdmin.set_webhook_secret(WEBHOOK_SECRET));
  const status = await gw.asAdmin.webhook_secret_status();
  expect(status.isSet).toBe(true);
  expect(status.generation).toBe(1n);

  // ── #33: an unprovisioned rail refuses BEFORE committing an order ───────────
  //
  // Asserted here because there is deliberately no way to UNSET a secret, so
  // this is the only point in the suite where the unprovisioned state exists —
  // and it is the state a fresh deployment is in, and the one RUNBOOK §1
  // prescribes during go-live, since provisioning the secrets last is what opens
  // the rail.
  //
  // ⚠️ **`totalOrders` is the assertion that matters.** Both config checks
  // short-circuit before the outcall, so if the order were committed first every
  // call would create a permanent `#expired` record for FREE: no cycles spent, so
  // `minCanisterCycles` never bounds the loop, and the record is not `#created`,
  // so the open-order cap does not either. Unbounded storage at zero cost.
  expect((await gw.asAdmin.stripe_api_key_status()).isSet).toBe(false);
  expect(await gw.asAdmin.stripe_origin()).toHaveLength(0);
  const ordersBefore = (await gw.asAdmin.reserve_status()).totalOrders;
  const linesBefore = (await gw.asAdmin.audit_log()).length;
  const closedBefore = (await gw.asAnon.refusal_counts()).counts.railClosed;
  const noKey = expectErr(
    await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []),
  ) as { sessionUnavailable: string };
  expect(noKey.sessionUnavailable).toContain('API key');
  expect((await gw.asAdmin.reserve_status()).totalOrders).toBe(ordersBefore);

  // ⚠️ **#61: the rail closing is ONE line, however many buyers hit it.** This is
  // the second free-to-drive path — no order, no payment, no prior state — and it
  // refuses BEFORE the gate, so while the rail is closed 100% of attempts take
  // this branch and never reach `admit`. Three more attempts must add nothing to
  // the log.
  for (let i = 0; i < 3; i += 1) {
    expectErr(await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []));
  }
  const afterClosed = await gw.asAdmin.audit_log();
  // Exactly one new line: the transition in.
  expect(afterClosed.length).toBe(linesBefore + 1);
  expect(afterClosed[afterClosed.length - 1].tag).toBe('gate.startedRefusing');
  // Four refusals, all tallied — the volume survives even though the lines do not.
  const closedAfter = (await gw.asAnon.refusal_counts()).counts.railClosed;
  expect(closedAfter).toBe(closedBefore + 4n);
  expect((await gw.asAnon.refusal_counts()).refusingNow.railClosed).toBe(true);
  // And it did not leak into a gate counter: these refusals never reached `admit`.
  const counts = (await gw.asAnon.refusal_counts()).counts;
  expect(counts.canisterCyclesLow).toBe(0n);
  expect(counts.reserveShort).toBe(0n);

  // The key alone is not enough: without a return origin there is no URL to send
  // the buyer back to, and the same no-record rule applies.
  expectOk(await gw.asAdmin.set_stripe_api_key('rk_test_integration_suite_key'));
  const noOrigin = expectErr(
    await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []),
  ) as { sessionUnavailable: string };
  expect(noOrigin.sessionUnavailable).toContain('origin');
  expect((await gw.asAdmin.reserve_status()).totalOrders).toBe(ordersBefore);

  // Validated at set time, so a bad value fails in front of the operator who
  // typed it rather than breaking every purchase later.
  expect(expectErr(await gw.asAdmin.set_stripe_origin('http://insecure.example'))).toEqual({ notHttps: null });
  expect(expectErr(await gw.asAdmin.set_stripe_origin('https://x.example/?a=1'))).toEqual({ hasQueryOrFragment: null });
  expect(expectErr(await gw.asAdmin.set_stripe_origin(''))).toEqual({ empty: null });
  expectOk(await gw.asAdmin.set_stripe_origin('https://integration.example'));
  expect(await gw.asAdmin.stripe_origin()).toEqual(['https://integration.example']);

  // ── #33's amount bounds, and why this suite lowers the floor ───────────────
  //
  // The shipped defaults are a $10 floor and a $100 ceiling, asserted here.
  expect((await gw.asAnon.lifecycle_config()).gate.minPurchaseUsdCents).toBe(1_000n);
  expect((await gw.asAnon.lifecycle_config()).gate.maxPurchaseUsdCents).toBe(10_000n);

  // But every exact assertion in this suite rests on the §3 vector: 500¢ gross
  // − 45¢ fee = 455¢ net = **exactly one ICP** at $4.55, which is worth exactly
  // 3.5 T cycles. That is what makes `TIER_LOCKED_CYCLES` exact rather than
  // approximate, across dozens of assertions. A $10 floor would
  // refuse it, and re-deriving the vector at $10 would trade exactness for
  // matching a default — so the floor is lowered HERE and the shipped value is
  // asserted above and exercised in scenario 71.
  const { gate: defaults } = await gw.asAnon.lifecycle_config();
  expectOk(await gw.asAdmin.set_gate_config({ ...defaults, minPurchaseUsdCents: 100n }));
});

test('01b — a dark gateway spends nothing on rates (#33: the switch is both secrets)', async () => {
  // The other half of scenario 29, and it has to live here: `railsLive` gates the
  // rate-refresh timer, and the only point where the rail is genuinely OFF is
  // before both secrets are provisioned — there is deliberately no way to unset
  // one.
  //
  // This also fixes a real waste rather than just moving a check: a gateway with
  // presets but no API key used to pay for XRC calls it could never use, because
  // the switch was the tier list.
  //
  // ⚠️ Ordering note: scenario 01 provisions BOTH secrets, so by the time this
  // runs the rail is live and the timer ticks. The dark case is asserted through
  // the audit log, which records what happened while it was dark: nothing.
  const log = await gw.asAdmin.audit_log();
  const beforeProvisioning = log.filter((e) => e.tag === 'rates.refreshFailed');
  // No refresh was even attempted before the secrets landed, so no failure was
  // recorded from that window.
  expect(beforeProvisioning.length).toBe(0);

  // Nothing has been attempted at all yet, which is the whole claim: no rates
  // cached and no attempt recorded from the window before the secrets landed.
  const pricing = await gw.asAnon.pricing_status();
  expect(pricing.rates).toHaveLength(0);
  expect(pricing.lastAttempt).toHaveLength(0);

  // ⚠️ **Deliberately does not tick the rate timer.** A failed refresh arms the
  // backoff (`rateTicksToSkip`), so an extra failing attempt here makes a LATER
  // scenario's tick get skipped and its `lastAttempt` read as this one's. That
  // cost scenario 03 a confusing failure once. The positive — a live rail does
  // refresh — is asserted in scenario 29, which has rates installed and can
  // observe it without side effects.
});

test('02 — tier config is admin-gated and public to read', async () => {
  await expect(gw.asUser.set_card_tiers([])).rejects.toThrow(/not a controller/);
  expectOk(await gw.asAdmin.set_card_tiers([
    { id: 'tier5', usdCents: TIER_USD_CENTS },
  ]));
  const tiers = await gw.asAnon.card_tiers();
  expect(tiers).toHaveLength(1);
  expect(tiers[0].id).toBe('tier5');
});

test('03 — pricing fails closed: an XRC error leaves no rate and blocks orders (§3.1)', async () => {
  // Anonymous callers can never own orders.
  const anonResult = await gw.asAnon.create_order({ tier: 'tier5' }, USER_ACCOUNT, []);
  expect(expectErr(anonResult)).toEqual({ anonymous: null });

  // The XRC declining to answer is the realistic outage: it refuses rather than
  // guessing. Nothing may be priced off it, and no order may be created.
  await setXrcResponse(gw, { kind: 'error', error: 'InconsistentRatesReceived' });
  await tickRateTimer(gw);

  const status = await gw.asAnon.pricing_status();
  expect(status.rates).toEqual([]);
  // Which XRC are we pricing from? This suite installs the mock AT the mainnet id,
  // so no `PUBLIC_CANISTER_ID:xrc` is injected and the resolver takes its FALLBACK
  // branch. Pinning it here means a changed default — or a broken lookup — fails a
  // test instead of silently pricing a mainnet deploy off the wrong canister, which
  // is the one failure mode that would otherwise be invisible.
  //
  // The override branch is only reachable on a local `icp network`; see issue #7.
  // Null would mean no refresh has resolved the id yet, which is not a pass —
  // the whole point of the field is that a mainnet deploy pointed at a mock must
  // not be able to look clean.
  expect(status.xrcCanisterId).toHaveLength(1);
  expect(status.xrcCanisterId[0]).toBe('uf6dk-hyaaa-aaaaq-qaaaq-cai');
  // The failure is diagnosable — "timer dead" and "XRC erroring" must not look
  // the same to an operator.
  expect(status.lastAttempt[0]!.ok).toBe(false);
  expect(status.lastAttempt[0]!.detail).toContain('InconsistentRatesReceived');

  expect(expectErr(await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, [])))
    .toEqual({ rateUnavailable: null });
});

test('04 — a healthy XRC + CMC pair prices the §3 vector exactly', async () => {
  await setXrcRate(gw);
  await warmRates(gw);

  const rates = (await gw.asAnon.pricing_status()).rates[0]!;
  // $4.55 at XRC's 9 decimals → 4_550_000 micro-USD per ICP.
  expect(rates.usdPerIcpMicros).toBe(4_550_000n);
  expect(rates.xdrPermyriadPerIcp).toBe(XDR_PERMYRIAD_PER_ICP);
  // The quality signal the mock was installed with, recorded for the receipt.
  expect(rates.quality.receivedRates).toBe(5n);
  expect(rates.quality.queriedSources).toBe(6n);

  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  orderA = created.order;
  refA = clientReferenceFor(created.order.id);

  // THE VECTOR: 500¢ gross − 45¢ fee = 455¢ net; at $4.55/ICP that is exactly
  // one ICP, worth 35_000 · 10⁸ = 3.5 T cycles at the protocol rate.
  expect(orderA.lockedCycles).toBe(TIER_LOCKED_CYCLES);
  expect(statusKey(orderA)).toBe('created');
  expect(refA).toBe(`${user.getPrincipal().toText()}_${orderA.id}`);

  // Both rate inputs are on the order, so the quote is reproducible from the
  // record alone rather than only checkable against a stored result.
  expect(orderA.pricing.usdPerIcpMicros).toBe(4_550_000n);
  expect(orderA.pricing.xdrPermyriadPerIcp).toBe(XDR_PERMYRIAD_PER_ICP);
  const net = TIER_USD_CENTS - (TIER_USD_CENTS * 290n + 9_999n) / 10_000n - 30n;
  expect(net * orderA.pricing.xdrPermyriadPerIcp * 10n ** 12n / orderA.pricing.usdPerIcpMicros)
    .toBe(orderA.lockedCycles);

  // §2 authz: non-owners (including admins) see nothing, not even existence.
  expect(await gw.asUser.get_order(orderA.id)).toHaveLength(1);
  expect(await gw.asAdmin.get_order(orderA.id)).toHaveLength(0);
  expect((await gw.asUser.list_orders()).map((o) => o.id)).toContain(orderA.id);

  // Orders read the cache; nothing user-facing calls the XRC.
  const again = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(again.order.lockedCycles).toBe(TIER_LOCKED_CYCLES);
});

test('05 — HTTP ingress guards on the live route table (§6.0/§6.1)', async () => {
  const body = checkoutSessionBody({
    eventId: 'evt_guard', paymentIntent: 'pi_guard', clientReferenceId: refA,
    amountCents: TIER_USD_CENTS,
  });

  // Query half: the matched upgrade route defers to consensus.
  const query = await gw.asAnon.http_request({
    method: 'POST', url: '/webhook/stripe', headers: [],
    body: new TextEncoder().encode(body),
  });
  expect(query.upgrade).toEqual([true]);

  // Tampered MAC → 400, and the order is untouched.
  const badSig = await deliverWebhook(gw, body, {
    signature: stripeSignature('whsec_wrong_secret_entirely', await nowSeconds(gw.pic), body),
  });
  expect(badSig.status_code).toBe(400);

  // Replayed timestamp outside the ±300 s tolerance → 400.
  const staleT = await deliverWebhook(gw, body, {
    signature: stripeSignature(WEBHOOK_SECRET, (await nowSeconds(gw.pic)) - 301n, body),
  });
  expect(staleT.status_code).toBe(400);

  // Unknown path / wrong method / oversized body.
  const notFound = await gw.asAnon.http_request_update({
    method: 'POST', url: '/webhook/other', headers: [], body: new Uint8Array(),
  });
  expect(notFound.status_code).toBe(404);
  const wrongMethod = await gw.asAnon.http_request_update({
    method: 'GET', url: '/webhook/stripe', headers: [], body: new Uint8Array(),
  });
  expect(wrongMethod.status_code).toBe(405);
  // Http.mo emits header *names* lowercased (`allow`) — RFC 9110 §5.1 makes
  // them case-insensitive on the wire, so this asserts the actual bytes.
  expect(wrongMethod.headers).toContainEqual(['allow', 'POST']);
  const oversize = await gw.asAnon.http_request_update({
    method: 'POST', url: '/webhook/stripe', headers: [], body: new Uint8Array(65_537),
  });
  expect(oversize.status_code).toBe(413);

  expect(await orderStatus(gw, orderA.id)).toBe('created');
});

test('06 — the money-out path is ONE transfer out of the reserve (#30 PR-A)', async () => {
  // Replaces two scenarios, because #30 PR-A replaced the mechanism they were
  // about. 06 asserted that a burn cap of 0 held the mint at `#awaitingTreasury`;
  // 07 asserted the held order then resumed and the CMC mint landed. Delivery no
  // longer mints and no longer consults the burn cap or the float — it transfers
  // cycles the reserve already holds — so **`#awaitingTreasury` has no entrance
  // any more**. #30 lists that status under #36's deletions and does not mention
  // that PR-A already strands it; it does.
  //
  // Gating a cycles transfer on an ICP burn cap would have kept the old
  // scenarios passing and been nonsense: the cap bounds ICP burn, and delivery
  // burns no ICP.
  //
  // What that leaves worth asserting is the arithmetic, and it is exact in both
  // directions — which is the whole point of the fee being charged on top:

  const reserveBefore = await reserveBalance(gw);
  const creditedBefore = await userCycles();
  const feeNow = await gw.cyclesLedger.icrc1_fee();
  expect(feeNow).toBe(CYCLES_LEDGER_FEE);

  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_a1', paymentIntent: 'pi_a', clientReferenceId: refA,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);
  expect(await tickUntilStatus(gw, orderA.id, ['delivered'])).toBe('delivered');

  // The buyer receives the locked quantity LESS the fee.
  expect((await userCycles()) - creditedBefore).toBe(TIER_LOCKED_CYCLES - feeNow);
  // And the reserve falls by EXACTLY the locked quantity — the fee is charged on
  // top of the amount, so sending `locked - fee` debits `locked`. That is why
  // #30's promise tally is `Σ lockedCycles` with no separate fee term; an earlier
  // draft wrote `Σ (lockedCycles + fee)` and double-counted.
  expect(reserveBefore - (await reserveBalance(gw))).toBe(TIER_LOCKED_CYCLES);

  // §4.2 journal: the ledger block, the delivered quantity, terminal status.
  const journal = (await gw.asAdmin.delivery_journal(orderA.id))[0]!;
  expect(journal.blockIndex.length).toBe(1);
  expect(journal.cyclesDelivered).toEqual([TIER_LOCKED_CYCLES - feeNow]);
  expect(statusKey(journal)).toBe('delivered');

  // ⚠️ Delivery moves cycles out of the reserve and nothing else: the gateway holds
  // no ICP and has no way to convert any. Asserted through the reserve, which is the
  // only pot a delivery can touch.
  expect(await reserveBalance(gw)).toBeLessThan(RESERVE_CYCLES);
});

test('07 — the transfer memo is the ORDER id, so two identical orders both deliver', async () => {
  // The subtlest money bug #30 names, and it is unreachable only because of the
  // memo. The ledger dedups on `(created_at_time, from, to, amount, memo)` —
  // NOT on the order. Two `#paid` orders from one buyer for the same amount are
  // reachable (the open-order cap counts only `#created`, so pay → create → pay
  // produces exactly that), and if both intents are built in the same round they
  // share the timestamp, the destination and the amount. Without the order id in
  // the memo the second transfer is falsely deduplicated: order B is marked
  // delivered against order A's block and the buyer is shorted a whole purchase.
  await ensureRates(gw);
  const creditedBefore = await userCycles();

  // ⚠️ **Two orders open at once, and the cap must be RAISED for this rather than the
  // scenario reduced to one.** Both intents have to be built in the *same round* to share
  // a `created_at_time`; that is what makes the ledger's
  // `(created_at_time, from, to, amount, memo)` key collide, which is the entire bug being
  // guarded. Serialising it to pay → create → pay puts the intents in different rounds,
  // removes the collision, and the test still passes — testing nothing. The suite's
  // `beforeAll` pins the cap at 20 for exactly this.
  const first = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const second = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));

  for (const [i, o] of [first, second].entries()) {
    expect(await deliverWebhook(gw, checkoutSessionBody({
      eventId: `evt_memo_${i}`, paymentIntent: `pi_memo_${i}`,
      clientReferenceId: clientReferenceFor(o.order.id), amountCents: TIER_USD_CENTS,
    }))).toMatchObject({ status_code: 200 });
  }
  expect(await tickUntilStatus(gw, first.order.id, ['delivered'])).toBe('delivered');
  expect(await tickUntilStatus(gw, second.order.id, ['delivered'])).toBe('delivered');

  // TWO purchases arrived, not one. This is the assertion that fails if the memo
  // ever stops being per-order.
  const fee = await gw.cyclesLedger.icrc1_fee();
  expect((await userCycles()) - creditedBefore).toBe((TIER_LOCKED_CYCLES - fee) * 2n);

  // Distinct ledger blocks, which is the same fact from the ledger's side.
  const blockA = (await gw.asAdmin.delivery_journal(first.order.id))[0]!.blockIndex[0]!;
  const blockB = (await gw.asAdmin.delivery_journal(second.order.id))[0]!.blockIndex[0]!;
  expect(blockA).not.toBe(blockB);
});

test('08 — duplicate/replay: every dedup layer holds through real ingress (§4.1/§4.2)', async () => {
  const reserveBefore = await reserveBalance(gw);
  const errorsBefore = (await allErrorEntries(gw)).length;

  // Replay 1: identical event redelivered (Stripe retry) → ack-and-drop.
  const sameEvent = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_a1', paymentIntent: 'pi_a', clientReferenceId: refA,
    amountCents: TIER_USD_CENTS,
  }));
  expect(sameEvent.status_code).toBe(200);

  // Replay 2: fresh event id, same payment_intent → one-delivery-per-payment.
  const sameIntent = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_a2', paymentIntent: 'pi_a', clientReferenceId: refA,
    amountCents: TIER_USD_CENTS,
  }));
  expect(sameIntent.status_code).toBe(200);

  await gw.pic.tick(10);
  expect(await orderStatus(gw, orderA.id)).toBe('delivered');
  expect(await reserveBalance(gw)).toBe(reserveBefore);
  expect((await allErrorEntries(gw)).length).toBe(errorsBefore);

  // Genuine double-pay: a *new* payment intent against the handled order →
  // #duplicate, acked 200 (the money is handled — by the operator).
  const doublePay = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_a3', paymentIntent: 'pi_a_double', clientReferenceId: refA,
    amountCents: TIER_USD_CENTS,
  }));
  expect(doublePay.status_code).toBe(200);
  const dupEntry = (await allErrorEntries(gw)).find(
    (e) => 'duplicate' in e.kind && e.kind.duplicate.paymentRef === 'pi_a_double',
  ) as ErrorEntry;
  expect(dupEntry).toBeDefined();
  expect(dupEntry.resolvedAtNs).toEqual([]);

  // charge.refunded auto-resolves the entry by payment_intent.
  const refund = await deliverWebhook(gw, chargeRefundedBody('evt_a4', 'pi_a_double'));
  expect(refund.status_code).toBe(200);
  const resolved = (await allErrorEntries(gw)).find((e) => e.id === dupEntry.id) as ErrorEntry;
  expect(resolved.resolvedAtNs.length).toBe(1);

  await gw.pic.tick(5);
  expect(await reserveBalance(gw)).toBe(reserveBefore);
});

test('09 — unattributed: claimed-not-trusted reference resolution (§6.1)', async () => {
  // Valid-shaped client_reference_id pointing at a nonexistent order.
  const bogusRef = `${user.getPrincipal().toText()}_00000000000000000000000000000000`;
  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_u1', paymentIntent: 'pi_u', clientReferenceId: bogusRef,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);

  const entry = (await allErrorEntries(gw)).find(
    (e) => 'unattributed' in e.kind && e.kind.unattributed.paymentRef === 'pi_u',
  ) as ErrorEntry;
  expect(entry).toBeDefined();

  // Manual operator resolution (§4.1) — admin-gated.
  await expect(gw.asUser.resolve_error(entry.id)).rejects.toThrow(/not a controller/);
  const resolved = expectOk(await gw.asAdmin.resolve_error(entry.id));
  expect(resolved.resolvedAtNs.length).toBe(1);
});

test('10 — the ledger\'s deposit fee lands on the buyer, and is not grossed up (§5 forward)', async () => {
  const creditedBefore = await userCycles();
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  orderB = created.order;
  refB = clientReferenceFor(created.order.id);

  const response = await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_b1', paymentIntent: 'pi_b', clientReferenceId: refB,
    amountCents: TIER_USD_CENTS,
  }));
  expect(response.status_code).toBe(200);

  expect(await tickUntilStatus(gw, orderB.id, ['delivered'])).toBe('delivered');

  // The buyer receives `lockedCycles - CYCLES_LEDGER_FEE` (documented in
  // docs/STRIPE.md and disclosed in the UI). This used to be described as an
  // asymmetry between two forward arms; #29 deleted the canister arm, so it is
  // simply what every delivery does.
  //
  // The fee is deliberately NOT grossed up by the canister: paying it out of the
  // app's own cycle balance would make every order a 100M subsidy, i.e. a
  // griefable gas-drain vector (canister-security: cycle drain protection). It is
  // disclosed to the buyer instead.
  //
  // On the delta, not the balance: every scenario in this suite delivers to this
  // one account now, so an absolute figure would encode how many ran before this.
  expect((await userCycles()) - creditedBefore)
    .toBe(TIER_LOCKED_CYCLES - CYCLES_LEDGER_FEE);
});

test('11 — a cycles-ledger outage strands NOTHING: the order stays payable-out and retries (#30 PR-A)', async () => {
  // INVERTED BY #30 PR-A, and the inversion is the improvement.
  //
  // This asserted Type 2 `#undeliverable`: the canister had already MINTED the
  // cycles into its own balance, so a failed `deposit` left real value stranded
  // in the app canister with a queue entry telling an operator to re-deliver it
  // by hand. #29's own comment predicted this case would "die in #30/#36 when
  // delivery stops being deposit-based". It has.
  //
  // Nothing is minted now. The cycles sit in the reserve until a transfer
  // succeeds, so a ledger outage is simply a call that failed: the order stays
  // `#paid`, the recovery sweep replays the identical intent, and it delivers
  // when the ledger comes back. **There is no stranded-value state to enter.**
  //
  // The outage is real rather than mocked: PocketIC accepts NNS root as an
  // impersonated sender, so the cycles ledger can genuinely be stopped, which is
  // what an outage looks like to the backend.
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  orderC = created.order;
  refC = clientReferenceFor(created.order.id);

  const reserveBefore = await reserveBalance(gw);
  const creditedBefore = await userCycles();

  await stopNns(gw, CYCLES_LEDGER_ID);
  try {
    expect(await deliverWebhook(gw, checkoutSessionBody({
      eventId: 'evt_c1', paymentIntent: 'pi_c', clientReferenceId: refC,
      amountCents: TIER_USD_CENTS,
    }))).toMatchObject({ status_code: 200 });
    await gw.pic.tick(5);

    // Still #paid — retrying, not escalated, not delivered.
    expect(await orderStatus(gw, orderC.id)).toBe('paid');
    // No queue entry: an outage is not an obligation.
    expect((await allErrorEntries(gw)).some(
      (e) => 'deliveryStuck' in e.kind && e.kind.deliveryStuck.orderId === orderC.id,
    )).toBe(false);
    // ⚠️ Do NOT read the ledger here. It is stopped, so a balance query is
    // rejected — the first version of this scenario asserted the balances inside
    // the outage and failed on the assertion rather than on the behaviour.
  } finally {
    await startNns(gw, CYCLES_LEDGER_ID);
  }

  // Now that it answers again: nothing moved during the outage.
  expect(await reserveBalance(gw)).toBe(reserveBefore);
  expect(await userCycles()).toBe(creditedBefore);

  // The ledger is back, but nothing re-drives the order on its own: the webhook's
  // detached kick already ran and failed, and the recovery sweep is hourly. So
  // advance to the sweep — which is also the real-world shape of this incident.
  // Ticking alone would sit here forever and read as a delivery bug.
  await gw.pic.advanceTime(3_601_000);
  await gw.pic.tick(3);
  expect(await tickUntilStatus(gw, orderC.id, ['delivered'])).toBe('delivered');
  const fee = await gw.cyclesLedger.icrc1_fee();
  expect((await userCycles()) - creditedBefore).toBe(TIER_LOCKED_CYCLES - fee);
  expect(reserveBefore - (await reserveBalance(gw))).toBe(TIER_LOCKED_CYCLES);
  // Exactly one block, so the retry did not pay twice.
  expect((await gw.asAdmin.delivery_journal(orderC.id))[0]!.blockIndex.length).toBe(1);
});

test('12 — an upgrade concurrent with delivery pays exactly once, and the timer re-arms', async () => {
  // ⚠️ **The interruption point this scenario used to catch no longer exists.**
  // It waited for status `#minting` — a persisted marker meaning "the intent is
  // journaled and the ledger call is in flight". Delivery is now ONE message: the
  // intent is written and the transfer issued inside the same `drive` loop pass,
  // with the order `#paid` throughout. The first version of this rewrite tried to
  // hold the order in that state by stopping the ledger, and learned something
  // worth keeping: `#beginDelivery` reads `icrc1_fee` BEFORE writing the intent,
  // so a ledger outage produces no intent at all. There is nothing to freeze.
  //
  // The replay DECISION is pinned where it is deterministic — `Cmc.stageOf` in
  // test/cmc.test.mo asserts intent-and-no-block → `#replayDelivery(intent)`, the
  // stale-intent boundary, and that the STORED args are what get replayed. What
  // this scenario can still prove, and what actually protects a buyer, is the
  // outcome: an upgrade landing on a delivery pays exactly once.
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  orderE = created.order;
  refE = clientReferenceFor(created.order.id);

  const reserveBefore = await reserveBalance(gw);
  const creditedBefore = await userCycles();
  const sweepBefore = await gw.asAnon.recovery_status();

  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_e1', paymentIntent: 'pi_e', clientReferenceId: refE,
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });

  // Upgrade immediately, without ticking: the webhook's detached kick is either
  // still queued or mid-delivery. `stop_canister` drains outstanding callbacks
  // before the canister reaches `Stopped`, so the stop → upgrade → start
  // procedure cannot strand a transfer — it can only land either side of one.
  await upgradeBackendMidFlight(gw);

  // The timer re-armed on upgrade (transient initializer): advancing past the
  // sweep interval delivers with no manual kick.
  await gw.pic.advanceTime(3_601_000);
  await gw.pic.tick(3);
  expect(await tickUntilStatus(gw, orderE.id, ['delivered'])).toBe('delivered');

  // EXACTLY once, and "exactly" is literal: a second transfer would show as a
  // second `locked - fee` credit, not as a figure inside a tolerance band.
  const fee = await gw.cyclesLedger.icrc1_fee();
  expect((await userCycles()) - creditedBefore).toBe(TIER_LOCKED_CYCLES - fee);
  expect(reserveBefore - (await reserveBalance(gw))).toBe(TIER_LOCKED_CYCLES);
  expect((await gw.asAdmin.delivery_journal(orderE.id))[0]!.blockIndex.length).toBe(1);

  // Liveness observability: the post-upgrade timer completed a sweep.
  const sweepAfter = await gw.asAnon.recovery_status();
  expect(sweepAfter.lastSweep.length).toBe(1);
  expect(sweepAfter.lastSweep[0]!.atNs).toBeGreaterThan(sweepBefore.lastSweep[0]?.atNs ?? -1n);
});

// ── 13 and 14 were deleted by #30 PR-A, and the reasons differ ──────────────
//
// **13 (upgrade mid-forward)** exercised the pre-forward window: the mint set
// `cyclesDelivered` before a SEPARATE forward await, so an interruption between them
// left the forward's fate unknown (`#ambiguousForward`). Delivery is now one
// call — mint-then-forward does not exist — so there is no window to catch. Its
// surviving property, "delivered exactly once across an upgrade", is asserted in
// 12 above.
//
// **14 (a treasury hold alerts, waits, then delivers)** exercised the mint
// pre-gate. `#awaitingTreasury` had exactly one entrance, `Treasury.gate` inside
// the mint path, so PR-A strands it: delivery consults neither the burn cap nor
// the float, because it transfers cycles the reserve already holds and burns no
// ICP. #30 lists that status under #36's deletions without noting that PR-A
// already makes it unreachable — it does, and keeping the scenario would have
// meant gating a cycles transfer on an ICP burn cap.
//
// Both are recorded on #36 so the deletion is not discovered as a gap.

test('15 — operational trail is coherent end-to-end (§4.2)', async () => {
  const audit = await gw.asAdmin.audit_log();
  expect(audit.length).toBeGreaterThan(0);
  for (let i = 1; i < audit.length; i++) {
    expect(audit[i].seq).toBeGreaterThan(audit[i - 1].seq);
  }
  const tags = audit.map((e) => e.tag);

  // ── The delivery path's TAG CONTRACT ─────────────────────────────────────
  //
  // ⚠️ **The whole vocabulary, deliberately**, because an audit tag is the only trace
  // of a money-out event that leaves no state change — and RUNBOOK §9 alerts on
  // specific tag strings, so a rename that misses this line silently breaks an
  // operator's alerting rather than a test.
  //
  // ⚠️ Only what has happened BY HERE. `delivery.delayed` is asserted in 47, where a
  // delay actually exists; asserting it here failed for the most ordinary reason in an
  // order-coupled suite — the event had not happened yet. See the README's coupling
  // note.
  expect(tags).toContain('delivery.sent');
  // ⚠️ **No `mint.*` tag exists**, because nothing mints — the audit
  // trail should never again contain a word for a mechanism this gateway does not
  // have. A regression that reintroduced one would show up here first.
  expect(tags.filter((t) => t.startsWith('mint.'))).toEqual([]);

  // The server-side worklist, which is what an operator actually reads.
  const open = await openErrorEntries(gw);
  // ⚠️ **Only fiat can be stranded, never cycles**, and this list is where that shows.
  // A failed delivery leaves the cycles in the reserve and the order retrying, so it
  // files no obligation at all. Everything open here is money we took and have not
  // delivered against — which is what makes `error_queue_depth` a real alarm rather
  // than a gauge that always reads non-zero.
  const kinds = open.map((e) => Object.keys(e.kind)[0]);
  expect(kinds).not.toContain('deliveryStuck');
  // Depth agrees with the paged content — the number ops monitors.
  expect((await gw.asAnon.error_queue_depth()).unresolved).toBe(BigInt(open.length));

  // Admin gates on the trail itself.
  await expect(gw.asUser.audit_log()).rejects.toThrow(/not a controller/);
  await expect(gw.asUser.error_queue([], 10n)).rejects.toThrow(/not a controller/);
  await expect(gw.asUser.error_queue_unresolved([], 10n)).rejects.toThrow(/not a controller/);
  // Depth is public — it is the monitoring signal, not the payment references.
  expect((await gw.asAnon.error_queue_depth()).retained).toBeGreaterThan(0n);
});

test('16 — admission gate: the gas floor refuses the quote before any money moves', async () => {
  // ⚠️ **The burn-cap axis this scenario was written for is gone** (#30 PR-B
  // deleted `#burnCapExhausted` with the ICP it bounded). The property survives —
  // the gate refuses to *quote* rather than taking money it cannot fulfil — so the
  // scenario keeps that and exercises it on the axis that is still live and still
  // reachable from a query: the canister's own gas floor.
  //
  // ⚠️ The reserve axis (`#reserveShort`) is deliberately NOT asserted here. It
  // needs a balance read, so it cannot live in `Gate.admit` or answer from
  // `can_purchase` — it is checked inside `create_order`, and its scenario arrives
  // with that wiring. Which is also this scenario's remaining point: **`admit` and
  // `can_purchase` agree exactly**, and they can only keep agreeing because
  // solvency is not one of the questions they answer.
  const { gate } = await gw.asAnon.lifecycle_config();
  const floor = gate.minCanisterCycles;

  // Raise the floor above the canister's own balance: fulfilment is impossible
  // because the gateway cannot pay for its own execution.
  const balance = (await gw.asAnon.cycles_status()).balance;
  expectOk(await gw.asAdmin.set_gate_config({ ...gate, minCanisterCycles: balance + 1_000_000_000_000n }));

  const refused = expectErr(await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []));
  expect(refused).toHaveProperty('notAdmitted');
  expect((refused as { notAdmitted: Record<string, unknown> }).notAdmitted)
    .toHaveProperty('canisterCyclesLow');

  // can_purchase reports the SAME refusal, so the frontend can disable the button
  // with a real reason instead of failing at submit.
  expect(expectErr(await gw.asAnon.can_purchase(TIER_USD_CENTS)))
    .toHaveProperty('canisterCyclesLow');

  // Restoring the floor re-opens the rail with no other intervention.
  expectOk(await gw.asAdmin.set_gate_config({ ...gate, minCanisterCycles: floor }));
  await ensureRates(gw);
  expectOk(await gw.asAnon.can_purchase(TIER_USD_CENTS));
  const admitted = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(statusKey(admitted.order)).toBe('created');
});

test('17 — admission gate: the per-purchase ceiling bounds tiers and amounts', async () => {
  const { gate } = await gw.asAnon.lifecycle_config();

  // A tier above the ceiling cannot be registered at all — the operator-typo
  // guard. Rejection is atomic, so the live tier list is untouched.
  const tooBig = gate.maxPurchaseUsdCents + 1n;
  expectErr(await gw.asAdmin.set_card_tiers([
    { id: 'tier5', usdCents: TIER_USD_CENTS },
    { id: 'fat', usdCents: tooBig },
  ]));
  expect((await gw.asAnon.card_tiers()).map((t) => t.id)).toEqual(['tier5']);

  // And an amount above it is refused at admission.
  expect(expectErr(await gw.asAnon.can_purchase(tooBig))).toEqual({
    amountAboveMax: { usdCents: tooBig, maxUsdCents: gate.maxPurchaseUsdCents },
  });

  // ⚠️ Lowering the ceiling under a live tier is now REFUSED, and this assertion
  // used to say the opposite — it described the old behaviour as a convenience
  // ("pause a tier without rewriting the tier list"). It was a footgun dressed as a
  // feature: order creation stopped, but a buyer already on the Stripe page could
  // still pay, and the webhook would then file an obligation rather than deliver. Since
  // there is no rescue lever either, so the buyer is refunded.
  //
  // ⚠️ **The pause lever is NOT the tier list.** This comment said it was, and
  // PR-B (#48) falsified that: with custom amounts a buyer can order without any
  // preset, so an empty vector only hides the tiles. The rail is live iff **both
  // Stripe secrets are provisioned** — scenario 29 in this file asserts exactly
  // that, and asserted the opposite before #48.
  expectErr(await gw.asAdmin.set_gate_config({ ...gate, maxPurchaseUsdCents: TIER_USD_CENTS - 1n }));
  expect((await gw.asAnon.lifecycle_config()).gate.maxPurchaseUsdCents)
    .toBe(gate.maxPurchaseUsdCents);
  // The tier stays sellable, which is the point: the config change did not half-apply.
  expectOk(await gw.asAdmin.set_gate_config(gate));
});

test('18 — an expired order is never deleted, and a late payment is refunded not converted', async () => {
  // Rewritten by #33, which deleted `Retention.mo`: there is no TTL and no
  // sweep, so the ONLY thing that expires an order is Stripe telling us the
  // session did. The scenario keeps its real subject — what survives, and what a
  // payment arriving afterwards does — and drops the mechanism that is gone.
  await ensureRates(gw);
  const created = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_lapsed' }),
  );
  const lapsed = created.order;
  const lapsedRef = clientReferenceFor(created.order.id);

  // Time alone does nothing now. Past its own deadline the order is still
  // `#created` — which is the point: a missed webhook is VISIBLE as an order
  // sitting past `expiresAtNs`, and that is #30's detection predicate. A sweep
  // would have hidden it by flipping the status while the reserve stayed held.
  await gw.pic.advanceTime(3 * 3_600_000);
  await gw.pic.tick(3);
  expect(await orderStatus(gw, lapsed.id)).toBe('created');

  expect(await deliverWebhook(gw, sessionExpiredBody({
    eventId: 'evt_lapsed', sessionId: 'cs_lapsed', clientReferenceId: lapsedRef,
  }))).toMatchObject({ status_code: 200 });
  await gw.pic.tick(3);
  expect(await orderStatus(gw, lapsed.id)).toBe('expired');

  // Nothing deletes it. Age it enormously and it is still there — a deleted
  // financial record would orphan the paidIntents entry a later payment creates,
  // and would make an unattributable payment unrefundable.
  await gw.pic.advanceTime(365 * 86_400_000);
  await gw.pic.tick();
  expect(await gw.asUser.get_order(lapsed.id)).toHaveLength(1);
  expect((await gw.asUser.list_orders()).map((o) => o.id)).toContain(lapsed.id);

  // §4's late-payment promise is GONE as of #34, which deleted `#expired →
  // #paid`. A payment arriving now is real money against an order that cannot
  // accept it, so it becomes an operator obligation rather than cycles.
  //
  // ⚠️ This is the money-in path's most dangerous edge, because `Orders.markPaid`
  // TRAPS on an illegal transition and `Card.mo` relies on its status guard to
  // make that unreachable — and a trap here is a 5xx Stripe retries for ~3 days.
  // So: 200, status unmoved, obligation filed.
  //
  // #33 removed the second half this scenario used to assert: `attach_payment`
  // refusing the same order. There is no rescue lever at all now, so the ONLY
  // remedy for the payment below is a refund in Stripe — which is why the
  // obligation being filed, rather than the payment being silently dropped, is
  // the whole safety property here.
  await ensureRates(gw);
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_late', paymentIntent: 'pi_late', clientReferenceId: lapsedRef,
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  await gw.pic.tick(5);
  expect(await orderStatus(gw, lapsed.id)).toBe('expired');
  const obligation = (await openErrorEntries(gw)).find(
    (e) => 'unattributed' in e.kind && e.kind.unattributed.paymentRef === 'pi_late',
  );
  expect(obligation).toBeDefined();
  expect(obligation!.detail).toContain('cannot be paid');
  // Nothing was delivered for it.
  expect((await gw.asUser.get_order(lapsed.id))[0]!.paidUsdCents).toHaveLength(0);
});

test('19 — a buyer can verify their own purchase from the receipt', async () => {
  // Everything needed to check us, scoped to the owner. The order already held
  // the inputs; nothing surfaced them, and the delivery proof was admin-only.
  await ensureRates(gw);
  const receipt = (await gw.asUser.receipt(orderA.id))[0]!;

  // Authz: only the owner. Not even an admin.
  expect(await gw.asAdmin.receipt(orderA.id)).toHaveLength(0);
  expect(await gw.asAnon.receipt(orderA.id)).toHaveLength(0);

  expect(receipt.paidUsdCents).toEqual([TIER_USD_CENTS]);
  // The on-chain delivery proof: a real cycles-ledger block anyone can look up.
  expect(receipt.deliveryBlockIndex).toHaveLength(1);
  // ⚠️ What the buyer RECEIVED, which is the locked quantity less the ledger's
  // transfer fee. It equalled `lockedCycles` while the canister created cycles and then
  // deposited (the deposit fee came off separately); since #30 PR-A the transfer
  // IS the delivery, so the fee is inside this figure. A receipt that reported
  // the locked quantity here would overstate what arrived.
  expect(receipt.cyclesDelivered).toEqual([TIER_LOCKED_CYCLES - CYCLES_LEDGER_FEE]);

  // THE POINT: recompute the price from the two recorded rate inputs and it must
  // equal what was locked. Both are queryable from the XRC and the CMC, so this
  // is reproducible rather than merely asserted by us.
  const v = receipt.verification;
  const net = v.netCents[0]!;
  expect(net * v.xdrPermyriadPerIcp * 10n ** 12n / v.usdPerIcpMicros)
    .toBe(receipt.order.lockedCycles);
  // And the quality of the rate that priced it is visible.
  expect(v.rateQueriedSources).toBeGreaterThanOrEqual(v.rateReceivedRates);
});

test('20 — an unauthenticated webhook that pays nothing triggers no sweep (DoS)', async () => {
  // The webhook route cannot be authenticated (Stripe can't sign in), so
  // anything it triggers is free for anyone on the internet to invoke. A sweep
  // over every order — which makes paid inter-canister calls per sweepable
  // order — must be reachable only from an actual payment.
  //
  // ⚠️ **The observable is the order's own status, deliberately.** There is no
  // pre-gate observation to watch — delivery reads nothing before transferring — so
  // the only evidence a sweep ran is an order that moved.
  //
  // Park an undelivered
  // `#paid` order with the ledger down, bring the ledger BACK, then send junk
  // traffic. A sweep triggered by that traffic would deliver the order. If nothing
  // sweeps, it stays `#paid` until the hourly timer fires -- and ten ticks do not
  // advance an hour.
  // Scenario 19 advanced 30 days, which staled both rates. Re-arm the CMC rate
  // and force a refresh through the admin lever.
  await setCmcRate(gw);
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const held = created.order;

  await stopNns(gw, CYCLES_LEDGER_ID);
  try {
    expect(await deliverWebhook(gw, checkoutSessionBody({
      eventId: 'evt_dos', paymentIntent: 'pi_dos', clientReferenceId: clientReferenceFor(created.order.id),
      amountCents: TIER_USD_CENTS,
    }))).toMatchObject({ status_code: 200 });
    await gw.pic.tick(5);
    expect(await orderStatus(gw, held.id)).toBe('paid');
  } finally {
    await startNns(gw, CYCLES_LEDGER_ID);
  }

  // Four ways to reach the canister without paying anything.
  const body = checkoutSessionBody({
    eventId: 'evt_junk', paymentIntent: 'pi_junk', clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
  });
  await deliverWebhook(gw, body, { signature: 't=1,v1=deadbeef' });          // malformed
  await deliverWebhook(gw, body, {
    signature: stripeSignature('whsec_wrong', await nowSeconds(gw.pic), body), // bad MAC
  });
  await gw.asAnon.http_request_update({
    method: 'POST', url: '/webhook/nonexistent', headers: [], body: new Uint8Array(),
  });                                                                          // 404
  await deliverWebhook(gw, chargeRefundedBody('evt_junk2', 'pi_nothing'));     // valid, pays nothing
  await gw.pic.tick(10);

  // The order is deliverable now -- the ledger is back and the reserve is funded.
  // It stays `#paid` anyway, because none of the junk above is allowed to start a
  // sweep. THIS is the DoS property: a sweep makes a paid inter-canister call per
  // sweepable order, so anyone on the internet triggering one is a cost attack.
  expect(await orderStatus(gw, held.id)).toBe('paid');

  // And the control: the timer's own sweep DOES deliver it, so the assertion
  // above is about the trigger and not about a broken delivery path.
  await gw.pic.advanceTime(3_601_000);
  await gw.pic.tick(3);
  expect(await tickUntilStatus(gw, held.id, ['delivered'])).toBe('delivered');
});

test('21 — status counters are O(1) and reconcile against a full recount', async () => {
  // The public status queries read maintained tallies rather than scanning the
  // order store, so a drift would silently misreport operational state.
  const before = await gw.asAnon.reserve_status();
  const rebuilt = await gw.asAdmin.recount_orders();
  const asMap = new Map(rebuilt);

  expect(asMap.get('Created')).toBe(before.openOrders);
  expect(asMap.get('Expired')).toBe(before.expiredOrders);
  // ⚠️ **`Paid` is the tally the sweep depends on, so it is the one asserted here.**
  //
  // There is deliberately no assertion that a deleted status is *absent* from this
  // map. The keys are `Text`, so such a check would read as a guard, but it can only
  // fail if someone re-adds the status — which the `OrderStatus` variant already makes
  // impossible. Scenario 79 was deleted for making exactly that claim: unreachability
  // became unrepresentability, and asserting the absence of an unrepresentable thing
  // tests nothing.
  expect(asMap.has('Paid')).toBe(true);
  expect(asMap.size).toBe(4);

  // Recount is admin-only: it is the expensive O(n) path.
  await expect(gw.asUser.recount_orders()).rejects.toThrow(/not a controller/);

  // And the canister's own gas is observable, distinct from the cycles it sells.
  const cycles = await gw.asAnon.cycles_status();
  expect(cycles.balance).toBeGreaterThan(0n);
  expect(cycles.floor).toBeGreaterThan(0n);
});

test('22 — a rate change between order and delivery does not move the locked quantity', async () => {
  // The §3 promise: the cycle QUANTITY is locked at creation and the operator
  // absorbs rate movement. This is the operator's actual exposure, and it was
  // untested — every earlier scenario used one unchanging rate.
  await ensureRates(gw);

  // A 2× move exceeds the default 50% delta guard, which scenario 23 covers on
  // purpose. Here the subject is drift, not the guard, so widen it for the
  // duration and restore it at the end.
  const defaultPricing = (await gw.asAnon.pricing_status()).config;
  expectOk(await gw.asAdmin.set_pricing_config({ ...defaultPricing, maxRateDeltaBps: 20_000n }));

  // Both rates must move together. ICP getting dearer in USD without the CMC's
  // XDR/ICP following is not a market move — it is two sources disagreeing, and
  // the cross-check rejects it (scenario 30). Here ICP doubles in USD while the
  // CMC rate rises 1.6×, so the implied XDR/USD shifts 0.769 → 0.615: a real
  // change in what a dollar buys, still inside the plausible band.
  const movedPermyriad = (XDR_PERMYRIAD_PER_ICP * 16n) / 10n;

  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const order = created.order;
  expect(order.lockedCycles).toBe(TIER_LOCKED_CYCLES);
  expect(order.pricing.usdPerIcpMicros).toBe(4_550_000n);

  // The market moves before the payment lands. A fresh quote would now buy 80%
  // as many cycles — this order must not care.
  await setXrcRate(gw, ICP_USD_RATE * 2n);
  await ensureRates(gw, movedPermyriad);
  const moved = (await gw.asAnon.pricing_status()).rates[0]!;
  expect(moved.usdPerIcpMicros).toBe(9_100_000n);
  expect(moved.xdrPermyriadPerIcp).toBe(movedPermyriad);

  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_move', paymentIntent: 'pi_move', clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  const creditedBefore = await userCycles();
  expect(await tickUntilStatus(gw, order.id, ['delivered'])).toBe('delivered');

  // Delivered at the ORIGINAL locked quantity, and the snapshot still records
  // the rate it was quoted at — not the rate at delivery time.
  expect((await userCycles()) - creditedBefore)
    .toBe(TIER_LOCKED_CYCLES - CYCLES_LEDGER_FEE);
  const stored = (await gw.asUser.get_order(order.id))[0]!;
  expect(stored.lockedCycles).toBe(TIER_LOCKED_CYCLES);
  expect(stored.pricing.usdPerIcpMicros).toBe(4_550_000n);

  // A NEW order at the moved rates buys 80% as much: cycles scale by
  // (P′/P)/(U′/U) = 1.6/2. The locked quantity above is unaffected — only new
  // quotes move, which is the §3 promise.
  const after = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(after.order.lockedCycles).toBe((TIER_LOCKED_CYCLES * 8n) / 10n);

  await setXrcRate(gw, ICP_USD_RATE);
  expectOk(await gw.asAdmin.set_pricing_config(defaultPricing));
  await ensureRates(gw);
});

test('23 — the delta guard rejects an implausible move and keeps serving the old rate', async () => {
  await ensureRates(gw);
  const before = (await gw.asAnon.pricing_status()).rates[0]!;

  // A 10× jump is inside the plausibility band but far beyond the delta bound,
  // so it is refused — and critically, the PREVIOUS rate keeps pricing orders
  // rather than pricing stopping dead.
  await setXrcRate(gw, ICP_USD_RATE * 10n);
  await gw.asAdmin.refresh_rates();

  const status = await gw.asAnon.pricing_status();
  expect(status.lastAttempt[0]!.ok).toBe(false);
  expect(status.lastAttempt[0]!.detail).toContain('delta guard');
  expect(status.rates[0]!.usdPerIcpMicros).toBe(before.usdPerIcpMicros);
  expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));

  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('24 — an implausible rate is refused outright', async () => {
  await ensureRates(gw);
  const before = (await gw.asAnon.pricing_status()).rates[0]!;

  // Below the band floor ($0.10): a decimal-point disaster, not a market move.
  await setXrcResponse(gw, { kind: 'rate', rate: 1_000n, decimals: 9 }); // $0.000001
  await gw.asAdmin.refresh_rates();
  let status = await gw.asAnon.pricing_status();
  expect(status.lastAttempt[0]!.detail).toContain('implausible');
  expect(status.rates[0]!.usdPerIcpMicros).toBe(before.usdPerIcpMicros);

  // A rate that rescales to zero micros is unusable rather than zero-priced.
  await setXrcResponse(gw, { kind: 'rate', rate: 1n, decimals: 12 });
  await gw.asAdmin.refresh_rates();
  status = await gw.asAnon.pricing_status();
  expect(status.lastAttempt[0]!.ok).toBe(false);
  expect(status.rates[0]!.usdPerIcpMicros).toBe(before.usdPerIcpMicros);

  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('25 — every XRC failure mode fails closed with a distinguishable reason', async () => {
  // An operator has to tell "XRC is rate-limiting us" from "we are out of
  // cycles" from "the sources disagreed" — the responses differ.
  for (const error of ['Pending', 'RateLimited', 'NotEnoughCycles', 'CryptoBaseAssetNotFound']) {
    await setXrcResponse(gw, { kind: 'error', error });
    await gw.asAdmin.refresh_rates();
    const status = await gw.asAnon.pricing_status();
    expect(status.lastAttempt[0]!.ok).toBe(false);
    expect(status.lastAttempt[0]!.detail).toContain(error);
  }

  // A prior good rate keeps serving until it goes stale, then orders refuse.
  await gw.pic.advanceTime(3_700_000); // past any allowed staleness window
  await gw.pic.tick(3);
  expect(expectErr(await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, [])))
    .toEqual({ rateUnavailable: null });

  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
  expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
});

test('26 — a rate reported with different decimals prices identically', async () => {
  // The mock reports 9 decimals, so the other toMicros branches would never run
  // against a real canister otherwise. Same price, different encoding, same quote.
  await setXrcResponse(gw, { kind: 'rate', rate: 4_550_000n, decimals: 6 });
  await ensureRates(gw);
  expect((await gw.asAnon.pricing_status()).rates[0]!.usdPerIcpMicros).toBe(4_550_000n);
  const sixDecimals = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(sixDecimals.order.lockedCycles).toBe(TIER_LOCKED_CYCLES);

  await setXrcResponse(gw, { kind: 'rate', rate: 4_550_000_000_000n, decimals: 12 });
  await ensureRates(gw);
  const twelveDecimals = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(twelveDecimals.order.lockedCycles).toBe(TIER_LOCKED_CYCLES);

  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('27 — the rate timer re-arms across an upgrade with no manual kick', async () => {
  // Timers are deactivated when the Wasm module changes, so a canister that
  // does not re-arm them silently stops refreshing. Pricing depends on that
  // timer, so this is the regression test for it — the mirror of scenario 12's
  // recovery-timer assertion.
  await ensureRates(gw);
  const before = (await gw.asAnon.pricing_status()).rates[0]!.fetchedAtNs;

  await upgradeBackendMidFlight(gw);

  // The cache is persistent, so the price survives the upgrade itself.
  expect((await gw.asAnon.pricing_status()).rates[0]!.fetchedAtNs).toBe(before);

  // And the timer is alive again: advancing past one interval refreshes with no
  // admin call. The CMC rate is re-armed first because it carries its own guard.
  await setCmcRate(gw);
  await tickRateTimer(gw);
  const after = (await gw.asAnon.pricing_status()).rates[0]!.fetchedAtNs;
  expect(after).toBeGreaterThan(before);

  // Orders work off the timer-refreshed rate, with nothing manual in between.
  expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
});

test('28 — the own-cycles floor refuses orders against a real balance', async () => {
  // The gate's canister-cycles check guards the resource whose exhaustion
  // uninstalls the canister and takes the order store with it. PocketIC can add
  // cycles but not remove them, so the floor is raised above the live balance
  // instead — the same code path, reading a real `Cycles.balance()`.
  await ensureRates(gw);
  const { balance, floor } = await gw.asAnon.cycles_status();
  expect(balance).toBeGreaterThan(0n);

  const gate = (await gw.asAnon.lifecycle_config()).gate;
  expectOk(await gw.asAdmin.set_gate_config({ ...gate, minCanisterCycles: balance * 2n }));

  const refused = expectErr(await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []));
  expect(refused).toHaveProperty('notAdmitted');
  const reason = (refused as { notAdmitted: Record<string, { balance: bigint; min: bigint }> }).notAdmitted;
  expect(reason).toHaveProperty('canisterCyclesLow');
  // The refusal carries both numbers, so an operator sees how far short it is.
  expect(reason.canisterCyclesLow.min).toBe(balance * 2n);
  expect(reason.canisterCyclesLow.balance).toBeGreaterThan(0n);

  // Both rails are gated, not just the card one — they share the float.
  expect(expectErr(await gw.asAnon.can_purchase(TIER_USD_CENTS)))
    .toHaveProperty('canisterCyclesLow');

  expectOk(await gw.asAdmin.set_gate_config({ ...gate, minCanisterCycles: floor }));
  expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
});

test('29 — an empty preset list does NOT pause the rail any more (#33)', async () => {
  // INVERTED BY #33, and this is the assertion that proves the switch moved.
  //
  // Emptying the tier list used to be the documented pause lever, and it also
  // stopped the rate timer. With custom amounts it stops nothing: a buyer can
  // order any amount between the floor and the ceiling without any preset, so an
  // empty list means only "no tiles shown". The switch is both Stripe secrets
  // being provisioned — see scenario 01 for the timer going quiet when it is off.
  //
  // A paid order must still deliver either way, because money-out reads the CMC
  // directly and never touches the rate cache.
  await ensureRates(gw);

  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const inFlight = created.order;
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_pause', paymentIntent: 'pi_pause', clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });

  // Empty the presets. A `#tier` order for a preset that no longer exists is
  // still refused — that part is unchanged.
  const tiers = await gw.asAnon.card_tiers();
  expectOk(await gw.asAdmin.set_card_tiers([]));
  expect(expectErr(await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, [])))
    .toEqual({ unknownTier: 'tier5' });

  // ⚠️ But a CUSTOM amount goes through, which is why an empty list is no longer
  // a pause: it never stopped the thing it claimed to.
  const custom = expectOk(
    await createOrderWithSession(gw, { custom: TIER_USD_CENTS }, USER_ACCOUNT, []),
  );
  expect(custom.order.pricing.usdCents).toBe(TIER_USD_CENTS);
  expectOk(await cancelOrderWithExpire(gw, custom.order.id));

  // And the refresh timer KEEPS RUNNING, because the rail is live: both secrets
  // are provisioned. It used to go quiet here.
  const attemptBefore = (await gw.asAnon.pricing_status()).lastAttempt[0]!.atNs;
  await tickRateTimer(gw);
  expect((await gw.asAnon.pricing_status()).lastAttempt[0]!.atNs).not.toBe(attemptBefore);

  // But the already-paid order still delivers: money-out uses the CMC, not the
  // rate cache, so a paused rail cannot strand money already taken.
  await setCmcRate(gw);
  const driven = expectOk(await gw.asAdmin.process_order(inFlight.id));
  expect(statusKey(driven)).toBe('delivered');

  expectOk(await gw.asAdmin.set_card_tiers(tiers));
  await ensureRates(gw);
});

test('30 — the rate pair is cross-checked: a plausible-but-wrong ICP price is refused', async () => {
  // The guard that stops us trusting one provider. $45.50/ICP is inside the wide
  // ICP-price band, so nothing else catches it — but against the CMC's
  // 3.5 XDR/ICP it implies 0.077 XDR/USD, which is absurd for an IMF basket.
  await ensureRates(gw);
  const before = (await gw.asAnon.pricing_status()).rates[0]!;

  // The delta guard would catch a 10× jump first, so widen it to isolate the
  // cross-check. That is not artificial: the cross-check's real job is the case
  // where there is no delta baseline — a fresh canister whose very FIRST XRC
  // reading is wrong by a factor — and when the CMC rate is the one that moved.
  const defaults = (await gw.asAnon.pricing_status()).config;
  expectOk(await gw.asAdmin.set_pricing_config({ ...defaults, maxRateDeltaBps: 100_000n }));

  await setXrcResponse(gw, { kind: 'rate', rate: ICP_USD_RATE * 10n, decimals: 9 });
  await gw.asAdmin.refresh_rates();

  const status = await gw.asAnon.pricing_status();
  expect(status.lastAttempt[0]!.ok).toBe(false);
  expect(status.lastAttempt[0]!.detail).toContain('rate pair disagrees');
  // The previous good pair keeps serving rather than pricing stopping dead.
  expect(status.rates[0]!.usdPerIcpMicros).toBe(before.usdPerIcpMicros);
  expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));

  // Symmetric: 10x too low implies 7.69 XDR/USD, equally absurd.
  await setXrcResponse(gw, { kind: 'rate', rate: ICP_USD_RATE / 10n, decimals: 9 });
  await gw.asAdmin.refresh_rates();
  expect((await gw.asAnon.pricing_status()).lastAttempt[0]!.detail).toContain('rate pair disagrees');

  expectOk(await gw.asAdmin.set_pricing_config(defaults));
  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('31 — a single-source rate is refused, because XRC cannot flag it itself', async () => {
  // XRC returns Ok for a one-exchange rate: a single rate cannot disagree with
  // itself, so InconsistentRatesReceived never fires. This is the only guard
  // that sees the degenerate case.
  await ensureRates(gw);
  const before = (await gw.asAnon.pricing_status()).rates[0]!;

  await setXrcResponse(gw, {
    kind: 'rate', rate: ICP_USD_RATE, decimals: 9,
    receivedRates: 1n, queriedSources: 6n,
  });
  await gw.asAdmin.refresh_rates();

  const status = await gw.asAnon.pricing_status();
  expect(status.lastAttempt[0]!.ok).toBe(false);
  expect(status.lastAttempt[0]!.detail).toContain('too few rate sources');
  expect(status.lastAttempt[0]!.detail).toContain('1 of 6');
  expect(status.rates[0]!.fetchedAtNs).toBe(before.fetchedAtNs);

  // Two sources clears the default threshold.
  await setXrcResponse(gw, {
    kind: 'rate', rate: ICP_USD_RATE, decimals: 9,
    receivedRates: 2n, queriedSources: 6n,
  });
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  // The quality signal reaches the order, so a buyer can see how thin it was.
  expect(created.order.pricing.rateReceivedRates).toBe(2n);
  expect(created.order.pricing.rateQueriedSources).toBe(6n);

  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('32 — rates going bad after payment cannot affect an order already #paid', async () => {
  // The question this answers: what happens if rates go bad while an order is
  // #paid? Nothing. Money-out reads the CMC directly and never touches the rate
  // cache, so the locked quantity is delivered regardless.
  await ensureRates(gw);

  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const order = created.order;
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_ratebad', paymentIntent: 'pi_ratebad', clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });

  // Break the XRC completely while the order is in flight.
  await setXrcResponse(gw, { kind: 'error', error: 'InconsistentRatesReceived' });
  await gw.asAdmin.refresh_rates();
  expect((await gw.asAnon.pricing_status()).lastAttempt[0]!.ok).toBe(false);

  // The order still delivers its locked quantity — no dependency on the XRC.
  // The webhook's own detached kick drives it, so let that finish rather than
  // racing it with process_order (which would answer #inFlight).
  expect(await tickUntilStatus(gw, order.id, ['delivered'])).toBe('delivered');
  const settled = (await gw.asUser.get_order(order.id))[0]!;
  // The LOCKED quantity is untouched by a rate move — that is the guarantee.
  expect(settled.lockedCycles).toBe(TIER_LOCKED_CYCLES);
  // What was delivered is that quantity less the ledger fee (#30 PR-A).
  expect((await gw.asAdmin.delivery_journal(order.id))[0]!.cyclesDelivered)
    .toEqual([TIER_LOCKED_CYCLES - CYCLES_LEDGER_FEE]);

  // New orders are refused once the cached rate lapses — the fail-closed half.
  await setXrcRate(gw, ICP_USD_RATE);
  await ensureRates(gw);
});

test('33 — an UNDELIVERED order alerts and waits, then delivers when the cause clears', async () => {
  await ensureRates(gw);

  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const stuck = created.order;

  // ⚠️ The PARKING MECHANISM changed with #30 PR-A; the property did not.
  //
  // It used to let the CMC rate go stale before payment, because the delivery kick
  // read a rate and refused on a stale one. Delivery reads no rate — it moves
  // cycles the reserve already holds — so the way to hold an order undelivered is
  // a real cycles-ledger outage. That is also a more honest incident: a stale
  // rate was a self-inflicted pause, an outage is the thing operators actually
  // page on.
  await stopNns(gw, CYCLES_LEDGER_ID);
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_stuck', paymentIntent: 'pi_stuck', clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  await gw.pic.tick(10);
  expect(await orderStatus(gw, stuck.id)).toBe('paid');

  // Past the alert threshold but short of the terminal bound: SOMEONE IS TOLD,
  // and the order keeps its money and keeps retrying. That split is the point —
  // an alert that only fired at the give-up would be useless.
  await gw.pic.advanceTime(3 * 3_600 * 1_000);
  await gw.pic.tick(5);
  const alert = (await openErrorEntries(gw)).find(
    (e) => 'deliveryDelayed' in e.kind && e.kind.deliveryDelayed.orderId === stuck.id,
  ) as ErrorEntry;
  expect(alert).toBeDefined();
  expect(await orderStatus(gw, stuck.id)).toBe('paid');

  // ── Salvaged from scenario 60, which #30 PR-A deleted ────────────────────
  // Repeated sweeps at the SAME stall must stay silent. 60's subject was a stall
  // moving between stages, and there is only one stage now — but this direction
  // has nothing to do with stages and a live failure mode: an alert re-filed on
  // every tick would flood the worklist and push real obligations out of the ring
  // buffer.
  await gw.pic.advanceTime(3 * 3_600 * 1_000);
  await gw.pic.tick(5);
  const stillOne = (await openErrorEntries(gw)).filter(
    (e) => 'deliveryDelayed' in e.kind && e.kind.deliveryDelayed.orderId === stuck.id,
  );
  expect(stillOne).toHaveLength(1);
  expect(stillOne[0]!.id).toBe(alert.id);

  // Fixing the cause delivers it, automatically, on the next sweep — no operator
  // action on the order itself.
  await startNns(gw, CYCLES_LEDGER_ID);
  expectOk(await gw.asAdmin.set_recovery_interval(60_000_000_000n));
  await gw.pic.advanceTime(90_000);
  await gw.pic.tick(5);
  expect(await tickUntilStatus(gw, stuck.id, ['delivered'])).toBe('delivered');
});

test('34 — abandon_order is the only terminal give-up, and it demands a reason', async () => {
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const doomed = created.order;

  // Not abandonable before money is involved — nothing to decide about.
  expectErr(await gw.asAdmin.abandon_order(doomed.id, 'too early'));

  // Park it in `#paid` with a real outage — a stopped cycles ledger is the only way to
  // hold an order undelivered, since delivery reads no rate and asks no other canister.
  // `#paid` is the state that matters here: money in, nothing delivered.
  await stopNns(gw, CYCLES_LEDGER_ID);
  try {
    expect(await deliverWebhook(gw, checkoutSessionBody({
      eventId: 'evt_aband', paymentIntent: 'pi_aband', clientReferenceId: clientReferenceFor(created.order.id),
      amountCents: TIER_USD_CENTS,
    }))).toMatchObject({ status_code: 200 });
    await gw.pic.tick(5);
    expect(await orderStatus(gw, doomed.id)).toBe('paid');

    // Admin-gated, and a reason is mandatory so the trail records why.
    await expect(gw.asUser.abandon_order(doomed.id, 'nope')).rejects.toThrow(/not a controller/);
    expectErr(await gw.asAdmin.abandon_order(doomed.id, ''));

    // ⚠️ **This scenario used to abandon the order HERE, and that was the unsafe
    // procedure (#30 PR-B).** A `#paid` order with a transfer issued and no block
    // recorded has an UNKNOWN money position: abandoning releases the promise and
    // files a refund-by-hand obligation while the transfer may already have landed,
    // and after `#abandoned` nothing sweeps the order, so nothing ever discovers
    // which. The buyer would keep the cycles and get the refund.
    //
    // A reviewer found the hole; **this test and 47 were codifying it**, which is
    // how we know it was reachable rather than theoretical. Scenario 78 owns the
    // guard itself; here it is asserted only to show the ordering — authz first,
    // then the reason, then the money position.
    expect(expectErr(await gw.asAdmin.abandon_order(doomed.id, 'buyer asked to cancel')))
      .toMatch(/delivery outstanding/);
    expect(await orderStatus(gw, doomed.id)).toBe('paid');

    // The legitimate route: let the 72 h bound escalate it, where the position can be
    // established from the ledger and abandonment is the documented exit.
    await gw.pic.advanceTime(80 * 3_600 * 1_000);
    await gw.pic.tick(5);
    expect(await tickUntilStatus(gw, doomed.id, ['needsReview'])).toBe('needsReview');

    const abandoned = expectOk(await gw.asAdmin.abandon_order(doomed.id, 'buyer asked to cancel'));
    // `#abandoned`, the released half of the old `#errorQueue` (#34): the operator
    // ended it, so nothing is owed. ⚠️ #30 depends on this releasing the promise —
    // an abandoned order must not keep reserving cycles nobody will receive.
    expect(statusKey(abandoned)).toBe('abandoned');
  } finally {
    await startNns(gw, CYCLES_LEDGER_ID);
  }

  const entry = (await openErrorEntries(gw)).find(
    (e) => 'abandoned' in e.kind && e.kind.abandoned.orderId === doomed.id,
  ) as ErrorEntry;
  expect(entry).toBeDefined();
  if ('abandoned' in entry.kind) {
    expect(entry.kind.abandoned.reason).toBe('buyer asked to cancel');
  }

  // The audit trail names WHO decided, not just that it happened.
  const audit = await gw.asAdmin.audit_log();
  const line = audit.find((e) => e.tag === 'order.abandoned' && e.detail.includes(doomed.id));
  expect(line).toBeDefined();
  expect(line!.detail).toContain('by ');
  expect(line!.detail).toContain('buyer asked to cancel');

  // Terminal: a second abandon is refused.
  expectErr(await gw.asAdmin.abandon_order(doomed.id, 'again'));

  // ⚠️ This scenario now advances ~80 h, which stales BOTH rates. `ensureRates` alone
  // is not enough — the CMC rate needs governance to re-arm it — and skipping that
  // fails whatever runs next on rates it never touched (see the README).
  await setCmcRate(gw);
  await ensureRates(gw);
});

test('35 — past the max-wait bound the order terminates so the operator refunds (§5.3)', async () => {
  // The spec's max-wait bound, and the reason it exists: a buyer left waiting
  // indefinitely files a chargeback, which costs the operator more than a refund
  // (dispute fees, dispute process, Stripe account health). By 72 h the cause is
  // structural, not transient, so refunding proactively is the protective act.
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const doomed = created.order;
  // Scenarios 76 and 77 need an order in exactly the state this one produces —
  // `needsReview`, intent journalled, no block — and reproducing it costs another
  // 72 h of clock advance plus the two rate re-arms that follow. They assert the
  // shape they depend on rather than assuming it.
  orderEscalated = doomed;

  // Parked with a real cycles-ledger outage — the one injectable cause of an
  // undelivered order.
  // ⚠️ Balance first, THEN stop. Reading it after the stop throws, and a throw
  // between `stopNns` and the `try` skips the `finally` — which leaves the ledger
  // stopped for every scenario after this one. That is how one mistake here
  // became nine failures elsewhere; see the coupling note in the README.
  const reserveBefore = await reserveBalance(gw);
  await stopNns(gw, CYCLES_LEDGER_ID);
  try {
    expect(await deliverWebhook(gw, checkoutSessionBody({
      eventId: 'evt_maxwait', paymentIntent: 'pi_maxwait', clientReferenceId: clientReferenceFor(created.order.id),
      amountCents: TIER_USD_CENTS,
    }))).toMatchObject({ status_code: 200 });
    await gw.pic.tick(5);
    expect(await orderStatus(gw, doomed.id)).toBe('paid');

    // Alert first (2 h), then terminate (72 h) — two tiers, one timeline. The
    // order stays payable-out through the alert: that split is the whole point.
    await gw.pic.advanceTime(3 * 3_600 * 1_000);
    await gw.pic.tick(5);
    expect(await orderStatus(gw, doomed.id)).toBe('paid');

    await gw.pic.advanceTime(70 * 3_600 * 1_000);
    await gw.pic.tick(5);
    expect(await tickUntilStatus(gw, doomed.id, ['needsReview'])).toBe('needsReview');
  } finally {
    await startNns(gw, CYCLES_LEDGER_ID);
  }

  const entry = (await openErrorEntries(gw)).find(
    (e) => 'deliveryStuck' in e.kind && e.kind.deliveryStuck.orderId === doomed.id,
  ) as ErrorEntry;
  expect(entry).toBeDefined();
  // ⚠️ The money position must say NOTHING WAS DELIVERED, because the action it
  // implies is a refund. Emitting a position that hedged here is what put an
  // operator in front of a buyer who may or may not hold their cycles.
  expect(entry.detail).toContain('refund');
  // Nothing moved out of the reserve — the position is certain, not merely likely.
  expect(await reserveBalance(gw)).toBe(reserveBefore);

  // The superseded delay alert was closed, not left orphaned alongside it.
  expect((await openErrorEntries(gw)).filter(
    (e) => 'deliveryDelayed' in e.kind && e.kind.deliveryDelayed.orderId === doomed.id,
  )).toHaveLength(0);

  // ── Salvaged from scenario 48, which #30 PR-A deleted ────────────────────
  // 48's subject was "the NOTIFY stage is bounded by time, not only by the retry
  // count", and there is no notify stage — delivery's time bound is this
  // scenario's job. But it carried a second assertion that is not about notify at
  // all: **the alert/terminate timeline never fires on an order that already
  // delivered.** A false alert promising action on a settled order is the orphan
  // class scenario 47 exists to prevent, so the guard outlives the mechanism.
  await ensureRates(gw);
  const settled = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_settled', paymentIntent: 'pi_settled',
    clientReferenceId: clientReferenceFor(settled.order.id), amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, settled.order.id, ['delivered'])).toBe('delivered');
  // Well past BOTH bounds. A delivered order must attract neither tier.
  await gw.pic.advanceTime(100 * 3_600 * 1_000);
  await gw.pic.tick(5);
  expect(await orderStatus(gw, settled.order.id)).toBe('delivered');
  expect((await openErrorEntries(gw)).filter(
    (e) => ('deliveryDelayed' in e.kind && e.kind.deliveryDelayed.orderId === settled.order.id)
      || ('deliveryStuck' in e.kind && e.kind.deliveryStuck.orderId === settled.order.id),
  )).toHaveLength(0);
  // ⚠️ This scenario advanced the clock by ~170 h in total, which stales BOTH
  // rates. `ensureRates` alone is not enough — the CMC rate needs governance to
  // re-arm — and skipping it fails the next nine scenarios on rates they never
  // touched. `advanceTime` is global and irreversible; see the README.
  await setCmcRate(gw);
  await ensureRates(gw);
});

test('39 — a payment against a CANCELLED order is refunded, never a trap', async () => {
  // What survives of scenarios 36–39, which #33 deleted with `attach_payment`.
  //
  // Those four covered the operator's manual rescue: the lost-webhook recovery,
  // its dedup against the webhook route, its obligation-closing, and its amount
  // rules. All four are gone — under per-order sessions WE set
  // `client_reference_id` through the API, so the attribution failure the lever
  // existed for cannot happen, and an unattributable payment is refunded rather
  // than converted.
  //
  // One half had to be kept, and it is the dangerous one. `Orders.markPaid` TRAPS
  // on an illegal transition; `Card.handleWebhook`'s status guard is what makes
  // that unreachable, and `-Werror` checks neither against the matrix. That guard
  // had a sibling in `attach_payment` — #34 fixed the webhook's and missed the
  // other one. With one caller left, this is the whole coupling, and a trap here
  // is a 5xx Stripe retries for ~3 days.
  //
  // Cancelled rather than expired, because it needs no clock: advancing time here
  // would leak into every scenario after this one (scenario 18 holds the expired
  // half, where an aged order already exists).
  await ensureRates(gw);
  const doomed = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expectOk(await cancelOrderWithExpire(gw, doomed.order.id));

  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_pay_cancelled', paymentIntent: 'pi_pay_cancelled',
    clientReferenceId: clientReferenceFor(doomed.order.id), amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  await gw.pic.tick(5);

  expect(await orderStatus(gw, doomed.order.id)).toBe('cancelled');
  expect((await gw.asUser.get_order(doomed.order.id))[0]!.paidUsdCents).toHaveLength(0);
  const filed = (await openErrorEntries(gw)).find(
    (e) => 'unattributed' in e.kind && e.kind.unattributed.paymentRef === 'pi_pay_cancelled',
  );
  expect(filed).toBeDefined();
  expect(filed!.detail).toContain('cannot be paid');
});

test('40 — the price a buyer is shown comes from the same code that locks it', async () => {
  // quote_previews exists so no client has to reimplement the §3 formula. If it
  // could drift from create_order, a buyer would be shown one number and charged
  // for another, with no way to tell which was wrong.
  await setCmcRate(gw);
  await ensureRates(gw);

  const preview = await gw.asAnon.quote_previews([TIER_USD_CENTS]);
  const quoted = preview.quotes[0]!;

  // The fee split accounts for every cent, and net is exactly gross minus fee.
  expect(quoted.usdCents).toBe(TIER_USD_CENTS);
  expect(quoted.netCents[0]! + quoted.feeCents).toBe(TIER_USD_CENTS);
  // The §3 vector, from the public query.
  expect(quoted.cycles).toEqual([TIER_LOCKED_CYCLES]);
  // ⚠️ The ledger's fee is NOT here any more (#30 PR-A). A query cannot await
  // `icrc1_fee`, so disclosing it meant the backend storing a copy and
  // correcting it on `#BadFee`. The frontend asks the ledger instead — asserted
  // below to be the same number this suite uses, so the two cannot drift.
  expect('cyclesLedgerDepositFee' in preview).toBe(false);
  expect(await gw.cyclesLedger.icrc1_fee()).toBe(CYCLES_LEDGER_FEE);
  // Reproducible from the returned inputs alone.
  const rates = preview.rates[0]!;
  expect(quoted.netCents[0]! * rates.xdrPermyriadPerIcp * 10n ** 12n / rates.usdPerIcpMicros)
    .toBe(TIER_LOCKED_CYCLES);

  // And an order created now locks exactly the previewed figure.
  const created = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [quoted.cycles[0]!]),
  );
  expect(created.order.lockedCycles).toBe(quoted.cycles[0]!);
  expectOk(await cancelOrderWithExpire(gw, created.order.id));

  // Public: it is market data plus the fee formula, nothing secret.

  // An empty request is answered, not rejected — no cap, so nothing is ever
  // silently truncated.
  expect((await gw.asAnon.quote_previews([])).quotes).toHaveLength(0);
  const many = Array.from({ length: 64 }, (_, i) => TIER_USD_CENTS + BigInt(i));
  expect((await gw.asAnon.quote_previews(many)).quotes).toHaveLength(64);
});

test('41 — an order can never lock fewer cycles than the buyer was shown', async () => {
  // The rate refresh is timer-driven, so a figure quoted to a buyer can move
  // before they commit. A client-side re-check cannot close that window (a query
  // and an update are separate messages), so the expectation is pinned inside
  // the same update that locks the price.
  await setCmcRate(gw);
  await ensureRates(gw);

  const shown = (await gw.asAnon.quote_previews([TIER_USD_CENTS]))
    .quotes[0]!.cycles[0]!;
  const ordersBefore = (await gw.asUser.list_orders()).length;

  // ICP appreciates 40%, so the same dollars buy ~28.6% fewer cycles.
  //
  // 40% and not 100%: the move has to clear every §3.1 guard, or the refresh is
  // rejected and the quote never changes at all. maxRateDeltaBps caps a single
  // move at 50%, and the implied XDR/USD cross-check (P × 10⁸ / U) has a 0.5
  // floor — $4.55 → $6.37 against an unchanged 3.5 XDR/ICP implies 0.549, which
  // is inside it. This is the widest single move the guards permit.
  const APPRECIATED = ICP_USD_RATE * 14n / 10n;
  await setXrcRate(gw, APPRECIATED);
  // ⚠️ `ensureRates`, not `tickRateTimer`. The timer honours the §3.1 backoff
  // (`rateTicksToSkip`), so a single earlier FAILED refresh makes the next tick a
  // no-op — and this scenario then reads the stale quote and fails on arithmetic
  // that was never recomputed. Scenario 35's time advances can arm that backoff.
  // The admin lever refreshes unconditionally, so the rate move is deterministic
  // and the subject here stays "the quote a buyer was shown is honoured", not
  // "the timer fired".
  await ensureRates(gw);
  const dearer = (await gw.asAnon.quote_previews([TIER_USD_CENTS]))
    .quotes[0]!.cycles[0]!;
  // 455¢ net × 35_000 × 10¹² / 6_370_000 — checked against the arithmetic, not
  // just "smaller than before", so a guard silently rejecting the refresh (which
  // would leave the old quote serving) fails here instead of passing vacuously.
  expect(dearer).toBe(2_500_000_000_000n);
  expect(dearer).toBeLessThan(shown);

  // Pinning the old figure refuses, and says what the amount buys NOW — so the
  // caller can show the buyer a real number rather than a bare failure.
  const refused = expectErr(
    await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, [shown]),
  ) as { quoteChanged: { quoted: bigint; minimum: bigint } };
  expect(refused.quoteChanged.quoted).toBe(dearer);
  expect(refused.quoteChanged.minimum).toBe(shown);

  // Nothing was created: a refused quote leaves no half-finished order behind,
  // so a buyer who declines the new rate has nothing to clean up.
  expect(await gw.asUser.list_orders()).toHaveLength(ordersBefore);

  // Accepting the current figure goes through.
  const atNewRate = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [dearer]),
  );
  expect(atNewRate.order.lockedCycles).toBe(dearer);
  expectOk(await cancelOrderWithExpire(gw, atNewRate.order.id));

  // A move in the buyer's FAVOUR must never refuse — the guard is a floor, not
  // an equality, so it can only ever protect the buyer.
  await setXrcRate(gw, ICP_USD_RATE);
  // Same reason as the appreciation above: the timer honours the §3.1 backoff, so
  // a tick can be a no-op and this reads the unchanged quote — which fails as
  // "2500000000000 is not greater than 2500000000000", a diff that says nothing
  // about the real cause.
  await ensureRates(gw);
  const better = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [dearer]),
  );
  expect(better.order.lockedCycles).toBeGreaterThan(dearer);
  expectOk(await cancelOrderWithExpire(gw, better.order.id));

  // Omitting the pin opts out of the check entirely.
  const unpinned = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []),
  );
  expectOk(await cancelOrderWithExpire(gw, unpinned.order.id));
});

test('42 — a buyer can give up on their own unpaid order and is never locked out', async () => {
  // maxOpenOrdersPerPrincipal counts #created orders, and the gate's refusal
  // tells the user to pay or abandon one. Without a buyer-facing cancel that is
  // advice they cannot follow: abandon_order is admin-only and only accepts a
  // *paid* order, so someone who opened the cap's worth of checkouts and
  // completed none would be locked out until their sessions' own deadlines passed —
  // which since #52 PR-B is what frees the slot, there being no TTL of ours since #33.
  await setCmcRate(gw);
  await ensureRates(gw);

  const mine = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const openBefore = (await gw.asAdmin.reserve_status()).openOrders;

  // Owner-scoped: nobody else can cancel your order, including an admin.
  expect(expectErr(await gw.asAdmin.cancel_order(mine.order.id))).toContain('no order');
  expect(expectErr(await gw.asAnon.cancel_order(mine.order.id))).toContain('no order');

  const cancelled = expectOk(await cancelOrderWithExpire(gw, mine.order.id));
  // `#cancelled`, its own status as of #34 — not `#expired`, which told a buyer
  // who had cancelled that their order had expired.
  expect(statusKey(cancelled)).toBe('cancelled');
  // The slot is freed, which is the point.
  expect((await gw.asAdmin.reserve_status()).openOrders).toBe(openBefore - 1n);
  // Idempotent — a double-click is not an error.
  expect(statusKey(expectOk(await cancelOrderWithExpire(gw, mine.order.id)))).toBe('cancelled');

  // THE SAFETY PROPERTY, INVERTED BY #34 and stated as it now is.
  //
  // A cancelled order can never be paid: `#cancelled → #paid` is absent from the
  // matrix, and that absence is the guarantee. So a payment that was already in
  // flight when the buyer clicked cancel does NOT deliver — it lands as an
  // operator obligation carrying the payment intent, which a Stripe refund
  // resolves. Money is recorded and refundable, never silently kept and never
  // converted against the buyer's decision.
  //
  // The window itself is what #33 closes: `cancel_order` will expire the Stripe
  // session first, so the race stops being possible rather than merely recorded.
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_cancel_race',
    paymentIntent: 'pi_cancel_race',
    clientReferenceId: clientReferenceFor(mine.order.id),
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  await gw.pic.tick(5);
  expect(await orderStatus(gw, mine.order.id)).toBe('cancelled');
  const raced = (await openErrorEntries(gw)).find(
    (e) => 'unattributed' in e.kind && e.kind.unattributed.paymentRef === 'pi_cancel_race',
  );
  expect(raced).toBeDefined();
  expect(raced!.detail).toContain('cannot be paid');

  // A PAID order cannot be cancelled — it is going to deliver, and pretending
  // otherwise would be the actual way to strand a buyer. Needs its own order,
  // since the one above never becomes paid now.
  const payable = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_cancel_paid',
    paymentIntent: 'pi_cancel_paid',
    clientReferenceId: clientReferenceFor(payable.order.id),
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, payable.order.id, ['delivered'])).toBe('delivered');
  expect(expectErr(await gw.asUser.cancel_order(payable.order.id)))
    .toContain('cannot be cancelled');

  // The cancel is on the audit trail.
  const log = await gw.asAdmin.audit_log();
  expect(log.some((e) => e.tag === 'order.cancelled' && e.detail.includes(mine.order.id))).toBe(true);

  // And CANCELLING ITSELF owes nothing: the only obligation against this order is
  // the raced payment above, which carries real money. An entry with nothing owed
  // is exactly the orphan the queue must not accumulate, so the count matters —
  // asserting "none" would now be wrong, and asserting "some" would hide a
  // spurious second one.
  const againstMine = (await openErrorEntries(gw)).filter(
    (e) => JSON.stringify(e.kind, bigIntReplacer).includes(mine.order.id),
  );
  expect(againstMine).toHaveLength(1);
  expect(JSON.stringify(againstMine[0]!.kind)).toContain('pi_cancel_race');
});

test('43 — a partial refund never settles a full obligation', async () => {
  // Stripe fires charge.refunded for ANY refund, so reading it as "settled"
  // means a $5 courtesy refund would auto-resolve a $500 obligation and the
  // unrefunded remainder would exist nowhere but the droppable audit ring.
  await setCmcRate(gw);
  await ensureRates(gw);

  // An unattributable payment: fiat in, nothing delivered, an obligation open.
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_partial_in',
    paymentIntent: 'pi_partial',
    clientReferenceId: 'not-a-real-reference',
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  const entry = (await openErrorEntries(gw)).find(
    (e) => JSON.stringify(e.kind, bigIntReplacer).includes('pi_partial'),
  )!;
  expect(entry).toBeDefined();

  // A small refund against the same charge must leave it open.
  expect(await deliverWebhook(
    gw, partialRefundBody('evt_partial_1', 'pi_partial', 100n, TIER_USD_CENTS),
  )).toMatchObject({ status_code: 200 });
  const stillOpen = (await allErrorEntries(gw)).find((e) => e.id === entry.id)!;
  expect(stillOpen.resolvedAtNs).toHaveLength(0);

  // Completing the refund settles it — the auto-resolve still works, it is just
  // conditioned on the amount now.
  expect(await deliverWebhook(
    gw, partialRefundBody('evt_partial_2', 'pi_partial', TIER_USD_CENTS, TIER_USD_CENTS),
  )).toMatchObject({ status_code: 200 });
  const settled = (await allErrorEntries(gw)).find((e) => e.id === entry.id)!;
  expect(settled.resolvedAtNs).toHaveLength(1);
});

test('44 — a verified event we cannot process is acked, not retried forever', async () => {
  // A checkout session with no payment_intent is reachable in production via a
  // subscription-mode link or a 100%-off promo code. Answering non-2xx would
  // fail identically on every Stripe retry for ~3 days, and Stripe can DISABLE
  // an endpoint that keeps failing — which would then lose every legitimate
  // webhook after it. The obligation goes on the worklist instead.
  const body = JSON.stringify({
    id: 'evt_nopi',
    type: 'checkout.session.completed',
    livemode: true,
    data: {
      object: {
        payment_intent: null,
        client_reference_id: null,
        amount_total: Number(TIER_USD_CENTS),
        currency: 'usd',
        payment_status: 'paid',
      },
    },
  });
  expect(await deliverWebhook(gw, body)).toMatchObject({ status_code: 200 });
  const queued = (await openErrorEntries(gw)).filter(
    (e) => JSON.stringify(e.kind, bigIntReplacer).includes('evt_nopi'),
  );
  expect(queued).toHaveLength(1);
  expect(queued[0]!.kind).toMatchObject({ unprocessable: { eventId: 'evt_nopi' } });

  // Stripe retries the identical event; the obligation must not duplicate.
  expect(await deliverWebhook(gw, body)).toMatchObject({ status_code: 200 });
  expect((await openErrorEntries(gw)).filter(
    (e) => JSON.stringify(e.kind, bigIntReplacer).includes('evt_nopi'),
  )).toHaveLength(1);

  // Unverifiable input still gets a non-2xx: there, retrying is exactly right.
  const unsigned = await gw.asAnon.http_request_update({
    method: 'POST',
    url: '/webhook/stripe',
    headers: [],
    body: new TextEncoder().encode(body),
  });
  expect(unsigned.status_code).toBe(400);
});

test('45 — a delayed async payment still delivers when it settles', async () => {
  // The `completed` event for a delayed method carries payment_status != paid and
  // no money. Settlement arrives later as async_payment_succeeded. Handling only
  // `completed` means fiat in, nothing delivered, nothing on the worklist.
  await setCmcRate(gw);
  await ensureRates(gw);

  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));

  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_async_pending',
    paymentIntent: 'pi_async',
    clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
    paymentStatus: 'unpaid',
  }))).toMatchObject({ status_code: 200 });
  expect(await orderStatus(gw, created.order.id)).toBe('created');

  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_async_settled',
    paymentIntent: 'pi_async',
    clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
    eventType: 'checkout.session.async_payment_succeeded',
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, created.order.id, ['delivered'])).toBe('delivered');
});

test('46 — a test-mode payment cannot deliver on a gateway declared live', async () => {
  // The slip this catches: a test-mode signing secret pasted into a canister
  // with a funded reserve. The secret is the only thing separating the two.
  expect(await gw.asAdmin.expected_livemode()).toHaveLength(0);
  await gw.asAdmin.set_expected_livemode([true]);
  expect(await gw.asAdmin.expected_livemode()).toEqual([true]);

  // ⚠️ The session must be LIVE-mode too, and that is #33 working rather than a
  // test detail: there are now TWO mode-bearing secrets — the webhook secret and
  // the API key — and they can disagree. `create_order` checks the session's
  // `livemode` against `expectLivemode` and refuses a mismatch, which is before
  // any money moves and much cheaper than catching it at webhook time. Scenario 63
  // asserts that refusal directly.
  const created = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { livemode: true }),
  );
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_testmode',
    paymentIntent: 'pi_testmode',
    clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
    livemode: false,
  }))).toMatchObject({ status_code: 200 });
  // Nothing delivered, and no obligation — a test payment owes nobody anything.
  expect(await orderStatus(gw, created.order.id)).toBe('created');

  // A live payment for the same order goes through normally.
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_livemode',
    paymentIntent: 'pi_livemode',
    clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, created.order.id, ['delivered'])).toBe('delivered');

  await gw.asAdmin.set_expected_livemode([]);
});

test('47 — a delay alert never outlives the delay, even when the order escalates', async () => {
  // The invariant the code states for itself: an open worklist entry must
  // describe a live problem. A #deliveryDelayed alert says "it delivers on the
  // next sweep" — the moment the order escalates instead, that becomes a false
  // promise sitting next to the real entry, plus a leaked delayedAlerts mapping
  // that nothing can ever clear.
  //
  // Scenario 33 covers the happy exit (fixed → delivered → alert resolved). This
  // is the unhappy one: alerted, then terminated.
  await setCmcRate(gw);
  await ensureRates(gw);

  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const doomed = created.order;

  // Park it in #paid with a real cycles-ledger outage. It used to be a stale CMC
  // rate, which stopped delivery before it started — delivery reads no rate, so
  // the outage is what holds an order undelivered now (#30 PR-A).
  await stopNns(gw, CYCLES_LEDGER_ID);
  let alert;
  try {
    expect(await deliverWebhook(gw, checkoutSessionBody({
      eventId: 'evt_orphan', paymentIntent: 'pi_orphan', clientReferenceId: clientReferenceFor(created.order.id),
      amountCents: TIER_USD_CENTS,
    }))).toMatchObject({ status_code: 200 });
    await gw.pic.tick(10);
    expect(await orderStatus(gw, doomed.id)).toBe('paid');

    // Past the 2 h alert threshold: the delay alert opens.
    await gw.pic.advanceTime(3 * 3_600 * 1_000);
    await gw.pic.tick(5);
    alert = (await openErrorEntries(gw)).find(
      (e) => 'deliveryDelayed' in e.kind && e.kind.deliveryDelayed.orderId === doomed.id,
    )!;
    expect(alert).toBeDefined();
  } finally {
    await startNns(gw, CYCLES_LEDGER_ID);
  }

  // Now let it terminate instead of being fixed — the 72 h bound escalates it.
  //
  // ⚠️ **This used to call `abandon_order` on the `#paid` order, and that was the
  // unsafe procedure #30 PR-B closed**: the order has a transfer issued and no block
  // recorded, so abandoning it would release the promise and file a refund while the
  // transfer's fate was unknown. This test was codifying the hole a reviewer found —
  // which is how we know it was reachable. The escalation is the honest terminator,
  // and it is also this scenario's actual subject: the title says "even when the
  // order escalates".
  await stopNns(gw, CYCLES_LEDGER_ID);
  try {
    await gw.pic.advanceTime(80 * 3_600 * 1_000);
    await gw.pic.tick(5);
    expect(await tickUntilStatus(gw, doomed.id, ['needsReview'])).toBe('needsReview');
  } finally {
    await startNns(gw, CYCLES_LEDGER_ID);
  }

  // The delay alert's own audit tag exists — moved here from 15, which runs before
  // any delay has happened. The tag names what it reports: a delivery delay.
  expect((await gw.asAdmin.audit_log()).map((e) => e.tag)).toContain('delivery.delayed');

  // THE ASSERTION: the delay alert is **resolved**, not merely absent — an entry that
  // promised "it delivers on the next sweep" must not sit on the worklist next to the
  // real problem, and its `delayedAlerts` mapping must not leak.
  const after = (await allErrorEntries(gw)).find((e) => e.id === alert.id)!;
  expect(after.resolvedAtNs).toHaveLength(1);
  // And exactly one entry for this order remains open — the escalation itself.
  const openForOrder = (await openErrorEntries(gw)).filter(
    (e) => JSON.stringify(e.kind, bigIntReplacer).includes(doomed.id),
  );
  expect(openForOrder).toHaveLength(1);
  expect(openForOrder[0]!.kind).toMatchObject({ deliveryStuck: { orderId: doomed.id } });
  // ⚠️ ~80 h of clock advance stales both rates; see the README.
  await setCmcRate(gw);
  await ensureRates(gw);
});

// -- 48 was deleted by #30 PR-A, and one assertion was salvaged into 35 -------
//
// Its subject was "**the notify stage** is bounded by time, not only by the retry
// count" — a real regression at the time: `#icpAtCmc` (ICP transferred, block
// recorded, `notify_top_up` answering retriable) was bounded ONLY by
// `maxMintRetries`, so raising the retry budget silently stretched the
// silently-stuck window from ~25 h to ~21 days.
//
// There is no notify stage. Delivery is one transfer, and "paid and undelivered
// is bounded by TIME, not just by retries" is scenario 35's property now.
//
// ⚠️ **Salvaged, because it outlives the mechanism:** 48 also asserted that the
// alert/terminate timeline never fires on an order that already **delivered**. A
// false alert promising action on a settled order is the orphan class 47 exists to
// prevent, and it has nothing to do with notify. That assertion is folded into the
// end of 35 rather than deleted with the rest — the same disposal 39 got in #49:
// delete the mechanism's test, keep the guard that survives it.

test('49 — an out-of-order async settlement still delivers exactly once', async () => {
  // Stripe does not guarantee ordering. If async_payment_succeeded arrives BEFORE
  // the completed event (or the completed event never arrives), the money is real
  // and must still deliver — and the later completed event must not double-credit.
  await setCmcRate(gw);
  await ensureRates(gw);

  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));

  // Settlement first.
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_oo_settled',
    paymentIntent: 'pi_oo',
    clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
    eventType: 'checkout.session.async_payment_succeeded',
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, created.order.id, ['delivered'])).toBe('delivered');

  // The completed event arrives afterwards, same intent: deduped, no obligation.
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_oo_completed',
    paymentIntent: 'pi_oo',
    clientReferenceId: clientReferenceFor(created.order.id),
    amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  const spurious = (await openErrorEntries(gw)).filter(
    (e) => JSON.stringify(e.kind, bigIntReplacer).includes('pi_oo'),
  );
  expect(spurious).toHaveLength(0);
  expect(await orderStatus(gw, created.order.id)).toBe('delivered');
});

// -- 51-54 were deleted by #30 PR-A, with their subjects recorded ------------
//
// Four scenarios about a settlement path this app no longer has. Delivery is one
// `icrc1_transfer` out of the reserve: there is no CMC to notify, no ICP to move,
// and no rate between payment and delivery. What each one PROVED still matters,
// so the heir is named rather than left to be re-derived — and where there is no
// heir, that is stated too. #36 carries the same list.
//
// **51 (a CMC outage stalls the mint, alerts, never invents a money position)**
// and **53 (an outage after the transfer parks the order at `#icpAtCmc`, alerts,
// then terminates carrying the block)**. The mechanism is gone; the property —
// *an order paid and undelivered past a bound alerts, then terminates so the
// operator can refund* — is alive and lands in 33/35/47/48, re-expressed against
// a stopped cycles ledger.
//
// **52 (an ICP ledger outage cannot move money or fabricate a block)**. The §5.1
// replay contract it guarded survives as delivery's write-intent replay, and
// scenarios 11 and 12 own it: an outage strands nothing and a retry pays exactly
// once, evidenced by one ledger block.
//
// **54 (a rate move between transfer and notify escalates instead of subsidising
// the buyer)** has **no heir, because the reserve model deletes the exposure
// rather than handling it.** That scenario existed because the CMC minted at
// whatever rate applied when `notify_top_up` landed, which could be days after
// the ICP left — so the minted quantity could fall short of what was locked, and
// covering the gap would have been an invisible subsidy out of the canister's own
// gas. Now `lockedCycles` is fixed at creation, delivery moves exactly
// `locked - fee`, and **no rate is read between payment and delivery at all**.
// There is nothing to escalate. Reserve-flavoured versions of these would assert
// nothing, which is the vacuous-assertion class this project has already buried
// once.

test('56 — the purchase ceiling cannot be lowered under a live tier', async () => {
  // `set_card_tiers` already refuses a tier priced above the ceiling. Without the
  // inverse check, lowering the ceiling left the tier SELLABLE BUT UNPAYABLE: a
  // buyer completes checkout and the webhook files an obligation instead of delivering.
  // Since #33 deleted `attach_payment` the only remedy is a refund, so the buyer
  // pays and is repaid over a config change made earlier — exactly the kind of
  // link nobody makes under pressure.
  //
  // ⚠️ This is also the ceiling's ONE remaining reachable case on the money path:
  // with the paid amount required to equal the quote, an order that matches its
  // own quote after the ceiling moved beneath it is the only thing `#aboveCeiling`
  // still catches (webhook.test.mo pins it directly).
  const gate = (await gw.asAnon.lifecycle_config()).gate;

  const refused = expectErr(await gw.asAdmin.set_gate_config({
    ...gate,
    maxPurchaseUsdCents: TIER_USD_CENTS - 1n,
  })) as { tierAboveCeiling: { tierId: string; usdCents: bigint; maxUsdCents: bigint } };
  // It names the offending tier and both numbers — "ceiling too low" without saying
  // which tier collides is a message someone has to go and investigate.
  expect(refused.tierAboveCeiling.tierId).toBe('tier5');
  expect(refused.tierAboveCeiling.usdCents).toBe(TIER_USD_CENTS);

  // Refused means unchanged, not partially applied.
  expect((await gw.asAnon.lifecycle_config()).gate.maxPurchaseUsdCents)
    .toBe(gate.maxPurchaseUsdCents);

  // Exactly equal to the tier price is allowed: the gate refuses `amount > ceiling`,
  // so equality has to pass or the most expensive tier could never be sold.
  expectOk(await gw.asAdmin.set_gate_config({ ...gate, maxPurchaseUsdCents: TIER_USD_CENTS }));
  expectOk(await gw.asAdmin.set_gate_config(gate));
});

test('57 — an already-credited intent is caught before attribution, not after', async () => {
  // The gap this closes: the already-credited check used to run AFTER the reference
  // resolved. So an intent already credited elsewhere, arriving with an unusable
  // reference, fell through to the unattributed path and filed an obligation for
  // money that was already spent.
  //
  // Reaching it requires the ~7-day dedup retention to have lapsed — inside that
  // window `recordStripeEvent` catches the replay first, which is why this needs a
  // time jump rather than an immediate redelivery.
  //
  // This models the HARSHER case on purpose: a new event id carrying an intent
  // that was already credited, plus a reference that cannot resolve. Scenario 59
  // covers the literal same-id Dashboard resend.
  await setCmcRate(gw);
  await ensureRates(gw);

  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_credit_a', paymentIntent: 'pi_credited',
    clientReferenceId: clientReferenceFor(created.order.id), amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, created.order.id, ['delivered'])).toBe('delivered');

  // Past the dedup retention. Pruning is opportunistic on the next verified
  // delivery, so the event below both triggers the prune and then hits the check.
  await gw.pic.advanceTime(9 * 24 * 3_600 * 1_000);
  await gw.pic.tick(5);

  const auditBefore = (await gw.asAdmin.audit_log()).length;

  // The same intent, a NEW event id, and a reference that cannot resolve — both
  // things wrong at once, which is the combination that used to slip through.
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_credit_resend', paymentIntent: 'pi_credited',
    clientReferenceId: 'total-garbage-not-a-reference', amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });

  const fresh = (await gw.asAdmin.audit_log()).slice(auditBefore);
  // Recognised as already credited, and it names the order that actually holds the
  // money rather than the unusable reference.
  const elsewhere = fresh.find((e) => e.tag === 'stripe.creditedElsewhere');
  expect(elsewhere).toBeDefined();
  expect(elsewhere!.detail).toContain(created.order.id);

  // NOT filed as unattributed: that would claim money is owed when it is spent.
  expect(fresh.some((e) => e.tag === 'stripe.type1' && e.detail.includes('total-garbage')))
    .toBe(false);
  // And nothing was delivered a second time.
  expect(await orderStatus(gw, created.order.id)).toBe('delivered');
});

test('58 — the sweep reconciles the status tallies on its own cadence and reports no drift', async () => {
  // The tallies feed the admission gate and are maintained incrementally, so a
  // bookkeeping bug would quietly refuse or admit the wrong orders. The daily
  // reconcile is what turns that from an unfalsifiable assumption into an
  // observable one; this pins that it re-runs on cadence and that its verdict is
  // visible to an operator without an admin call.
  await setCmcRate(gw);
  await ensureRates(gw);

  // Orders across several tracked statuses, so a reconcile has something to
  // disagree with if `bump` were wrong.
  const paid = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_reconcile', paymentIntent: 'pi_reconcile',
    clientReferenceId: clientReferenceFor(paid.order.id), amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  expect(await tickUntilStatus(gw, paid.order.id, ['delivered'])).toBe('delivered');
  expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));

  const before = (await gw.asAnon.recovery_status()).lastCountReconcile[0]?.atNs ?? -1n;
  const auditBefore = (await gw.asAdmin.audit_log()).length;

  // Past the 24-hour cadence, so this proves the periodic path rather than a
  // one-off at boot (earlier scenarios in this file have already swept).
  await gw.pic.advanceTime(25 * 3_600 * 1_000);
  await gw.pic.tick(6);

  const status = await gw.asAnon.recovery_status();
  expect(status.lastCountReconcile.length).toBe(1);
  expect(status.lastCountReconcile[0]!.atNs).toBeGreaterThan(before);
  // Empty drift is the pass condition: the incremental counts agreed with the
  // order store. A non-empty list here would mean the tallies had been wrong.
  expect(status.lastCountReconcile[0]!.drift).toEqual([]);
  // And nothing was audited, because a clean reconcile every day would bury the
  // one line that matters.
  const fresh = (await gw.asAdmin.audit_log()).slice(auditBefore);
  expect(fresh.some((e) => e.tag === 'orders.countDrift')).toBe(false);

  // The cadence holds in the other direction too: an hour of sweeps must not
  // re-scan the store. The reconcile is detached into its own message, so a gate
  // that failed open would spawn one per sweep — invisible except as cycles.
  const settled = status.lastCountReconcile[0]!.atNs;
  await gw.pic.advanceTime(3_600 * 1_000);
  await gw.pic.tick(6);
  expect((await gw.asAnon.recovery_status()).lastCountReconcile[0]!.atNs).toBe(settled);
});

test('59 — a Stripe resend past the dedup window does not file a second unprocessable', async () => {
  // Ingestion dedups on the event id, but that set is pruned at ~7 days. A
  // Dashboard resend after that is a new event to the dedup set, so without a
  // second check one unreadable event becomes two worklist items an operator has
  // to recognise as the same thing.
  await setCmcRate(gw);
  await ensureRates(gw);

  const body = JSON.stringify({
    id: 'evt_nopi_resend',
    type: 'checkout.session.completed',
    livemode: true,
    data: {
      object: {
        payment_intent: null,
        client_reference_id: null,
        amount_total: Number(TIER_USD_CENTS),
        currency: 'usd',
        payment_status: 'paid',
      },
    },
  });
  const matching = async () => (await openErrorEntries(gw)).filter(
    (e) => JSON.stringify(e.kind, bigIntReplacer).includes('evt_nopi_resend'),
  );

  expect(await deliverWebhook(gw, body)).toMatchObject({ status_code: 200 });
  expect(await matching()).toHaveLength(1);

  // Past the dedup retention. Pruning is opportunistic on the next verified
  // delivery, so this same call both prunes and hits the worklist check.
  await gw.pic.advanceTime(9 * 24 * 3_600 * 1_000);
  await gw.pic.tick(5);

  expect(await deliverWebhook(gw, body)).toMatchObject({ status_code: 200 });
  expect(await matching()).toHaveLength(1);
  const log = await gw.asAdmin.audit_log();
  expect(log.some((e) => e.tag === 'stripe.unprocessableResend')).toBe(true);

  // Once an operator closes it, a genuine re-report is allowed through: resolved
  // history must not suppress a real event forever.
  const entry = (await matching())[0]!;
  expectOk(await gw.asAdmin.resolve_error(entry.id));
  await gw.pic.advanceTime(9 * 24 * 3_600 * 1_000);
  await gw.pic.tick(5);
  expect(await deliverWebhook(gw, body)).toMatchObject({ status_code: 200 });
  expect(await matching()).toHaveLength(1);
});

// -- 60 was deleted by #30 PR-A, with its dedup half salvaged into 33 ---------
//
// Its subject was "**a stall that MOVES TO A DIFFERENT STAGE** re-raises the
// alert instead of leaving stale wording" — an order stuck at `#paid` on a stale
// rate, then stuck at `#awaitingTreasury` on a zero burn cap, with the first
// alert closed and a second raised carrying the new stage's wording.
//
// There are no longer two stages to move between. Money-out runs from `#paid`
// alone, so `mint.delayedStageChanged` was unreachable — and #30 PR-C **deleted it**,
// along with the branch that raised it and the stage half of the `delayedAlerts`
// pair, which existed only to detect a change that cannot happen. That
// is a simplification, not a coverage loss: the confusion the scenario guarded
// against — two open alerts for one order, or wording describing a state the
// order has left — cannot arise from one stage.
//
// ⚠️ **Salvaged: the dedup direction.** "Repeated sweeps at the same stall stay
// silent" is not about stage changes at all, and its failure mode is alive — a
// sweep that re-filed on every tick would flood the worklist and push real
// obligations out of the ring buffer. That assertion moved into 33, where a
// stalled order already sits across multiple sweeps.

test('61 — cycles go to the caller and nowhere else, enforced by the canister (#29)', async () => {
  // The property this asserts is the WHOLE point of #29: "the cycles come to
  // you" used to be a fact about the frontend, not about the gateway. The
  // backend accepted whatever `Destination` it was handed, so a hand-crafted
  // call could send a purchase to any account. This is that hand-crafted call.
  //
  // Deliberately here rather than in a browser spec: the browser cannot make a
  // call the app does not offer, so a UI test can only ever show that the app
  // does not ask — never that the canister refuses.
  await ensureRates(gw);

  const ordersBefore = (await gw.asUser.list_orders()).length;

  // Someone else's account.
  expect(expectErr(await gw.asUser.create_order({ tier: 'tier5' }, {
    cyclesLedgerAccount: { owner: admin.getPrincipal(), subaccount: [] },
  }, []))).toEqual({ destinationNotOwned: null });

  // The caller's own account, but not the default subaccount. Refused too: it is
  // theirs, but it is not the balance the app shows them or the one
  // `icp cycles balance` reads, so an order there strands cycles somewhere the
  // buyer cannot see.
  const subaccount = new Uint8Array(32);
  subaccount[31] = 1;
  expect(expectErr(await gw.asUser.create_order({ tier: 'tier5' }, {
    cyclesLedgerAccount: { owner: user.getPrincipal(), subaccount: [subaccount] },
  }, []))).toEqual({ destinationNotOwned: null });

  // No order is left behind. An earlier version of this checked that every
  // stored order had a `cyclesLedgerAccount` destination, which is true of every
  // order BY TYPE now that the variant has one case — it asserted nothing.
  expect((await gw.asUser.list_orders()).length).toBe(ordersBefore);

  // And the refusal comes FIRST, pinned against the next check in the method: an
  // unknown tier *and* a bad destination returns the destination error, so
  // nothing after the caller comparison has run. Moving the check below the tier
  // lookup or the admission gate flips this to `unknownTier`.
  expect(expectErr(await gw.asUser.create_order({ tier: 'no-such-tier' }, {
    cyclesLedgerAccount: { owner: admin.getPrincipal(), subaccount: [] },
  }, []))).toEqual({ destinationNotOwned: null });

  // And the anonymous check still wins over this one: an anonymous caller gets
  // told about the session rather than about the destination.
  expect(expectErr(await gw.asAnon.create_order({ tier: 'tier5' }, {
    cyclesLedgerAccount: { owner: admin.getPrincipal(), subaccount: [] },
  }, []))).toEqual({ anonymous: null });
});

test('62 — the durable order record survives a real stop → upgrade → start (#34)', async () => {
  // #34's acceptance criterion. The fields exist to make a support ticket or a
  // reconciliation answerable from the record itself rather than from a 4,096-
  // entry ring buffer that drops — which is worth nothing if an upgrade loses
  // them. Enhanced orthogonal persistence keeps stable state without serialising
  // it, and this is the assertion of that rather than the assumption.
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const before = created.order;

  // ── ratesFetchedAtNs is the one new field with a producer TODAY, so it is the
  // one this scenario can assert on its merits rather than just for durability.
  expect(before.pricing.ratesFetchedAtNs).toBeGreaterThan(0n);
  // STRICTLY EARLIER than the order: quotes come from a cache the timer
  // refreshes, so the rates that priced this order were read before it existed.
  // That gap is the entire reason the field is not `createdAtNs` — an auditor
  // comparing the stored rates against XRC/CMC history at `createdAtNs` would
  // otherwise be checking the wrong instant.
  expect(before.pricing.ratesFetchedAtNs).toBeLessThan(before.createdAtNs);

  // ── The session fields are POPULATED as of #33, and this assertion inverting
  // is the test doing its job. #34 pinned them as null-and-durable precisely so
  // that the transition to populated-and-durable would be a deliberate edit
  // rather than a silent one.
  expect(before.stripeSessionId).toHaveLength(1);
  expect(before.stripeSessionUrl).toHaveLength(1);
  expect(before.stripeSessionUrl[0]!).toMatch(/^https:\/\/checkout\.stripe\.com\//);
  // Stripe's own deadline, in NANOSECONDS. ⚠️ The single most likely bug in #33:
  // `expires_at` is Unix seconds, so a raw store puts every order in 1970 — the
  // open-order cap frees instantly and the UI shows everything expired. Asserted
  // as an era check rather than an exact value, because that is what catches a
  // mistyped factor.
  expect(before.expiresAtNs).toHaveLength(1);
  expect(before.expiresAtNs[0]!).toBeGreaterThan(1_000_000_000_000_000_000n);
  expect(before.expiresAtNs[0]!).toBeGreaterThan(before.createdAtNs);
  // Still null: nothing has expired this order.
  expect(before.expiredBy).toHaveLength(0);

  // ── A cancelled order, so a non-default status and a terminal one both cross
  // the upgrade.
  const doomed = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(statusKey(expectOk(await cancelOrderWithExpire(gw, doomed.order.id)))).toBe('cancelled');

  await upgradeBackendMidFlight(gw);

  const after = (await gw.asUser.get_order(before.id))[0]!;
  expect(after.pricing).toEqual(before.pricing);
  expect(after.expiresAtNs).toEqual(before.expiresAtNs);
  expect(after.stripeSessionId).toEqual(before.stripeSessionId);
  expect(after.stripeSessionUrl).toEqual(before.stripeSessionUrl);
  expect(after.expiredBy).toEqual(before.expiredBy);
  expect(statusKey(after)).toBe('created');

  // The new status survives as itself — not decoded as some neighbouring tag,
  // which is the failure a variant reorder would produce.
  expect(statusKey((await gw.asUser.get_order(doomed.order.id))[0]!)).toBe('cancelled');

  // And it is still unpayable on the other side of the upgrade.
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_62', paymentIntent: 'pi_62',
    clientReferenceId: clientReferenceFor(doomed.order.id), amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });
  await gw.pic.tick(5);
  expect(await orderStatus(gw, doomed.order.id)).toBe('cancelled');
});

test('63 — the session request is exactly what Stripe needs, asserted byte by byte (#33)', async () => {
  // Nothing pinned the request shape before this. PocketIC parks each outcall
  // instead of performing it, which for THIS property is better coverage than a
  // live call: the exact bytes the canister built can be read back.
  await ensureRates(gw);

  const settle = await gw.deferredUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []);
  const outcall = await awaitPendingOutcall(gw);

  expect(outcall.url).toBe('https://api.stripe.com/v1/checkout/sessions');
  expect(outcall.httpMethod).toBe('POST');
  // ⚠️ Never null. The `ic` package substitutes 2,000,000 and the call costs
  // ~20.85 B cycles instead of ~220 M.
  expect(outcall.maxResponseBytes).toBe(16_384);

  expect(outcallHeader(outcall, 'Authorization')).toBe('Bearer rk_test_integration_suite_key');
  expect(outcallHeader(outcall, 'Content-Type')).toBe('application/x-www-form-urlencoded');

  const body = outcallBody(outcall);
  // The order id is not knowable before the call, so it is recovered from the
  // body and then used to check the idempotency key — which must BE the order id.
  const refMatch = /client_reference_id=([^&]+)/.exec(body);
  expect(refMatch).not.toBeNull();
  const orderId = decodeURIComponent(refMatch![1]!).split('_').pop()!;
  // ⚠️ THE key assertion. Every replica performs this outcall. Without the key
  // each one creates a DISTINCT session — so one order spawns many, and consensus
  // can never be reached, which no transform can repair.
  expect(outcallHeader(outcall, 'Idempotency-Key')).toBe(orderId);

  // Inline price_data, one fixed-amount line item, card only. The
  // `amount_total == usdCents` guarantee is a property of exactly this shape.
  expect(body).toContain('mode=payment');
  expect(body).toContain('payment_method_types%5B%5D=card');
  expect(body).toContain('line_items%5B0%5D%5Bprice_data%5D%5Bunit_amount%5D=500');
  expect(body).toContain('line_items%5B0%5D%5Bquantity%5D=1');
  expect(body).toContain('adaptive_pricing%5Benabled%5D=false');
  // Nothing that could move amount_total. Each is one Stripe parameter away.
  for (const forbidden of ['automatic_tax', 'adjustable_quantity', 'allow_promotion_codes', 'after_expiration']) {
    expect(body).not.toContain(forbidden);
  }

  // Both return URLs point at the buyer's own order on the configured origin —
  // admin config, never a caller parameter, because a caller-supplied success_url
  // is an open redirect Stripe renders after a real payment.
  const expectedReturn = encodeURIComponent(`https://integration.example/#/order/${orderId}`)
    .replace(/!/g, '%21');
  expect(body).toContain(`success_url=${expectedReturn}`);
  expect(body).toContain(`cancel_url=${expectedReturn}`);

  // `expires_at` asks for Stripe's 30-minute floor PLUS SLACK. Asking for exactly
  // 30 puts the value on the floor as Stripe's clock evaluates it, so a few
  // seconds of skew rejects it — and that fails every session creation, taking
  // the rail down rather than one order.
  const expiresMatch = /expires_at=(\d+)/.exec(body);
  expect(expiresMatch).not.toBeNull();
  const requested = Number(expiresMatch![1]!);
  const now = Number(await nowSeconds(gw.pic));
  expect(requested - now).toBeGreaterThan(30 * 60);
  expect(requested - now).toBeLessThanOrEqual(35 * 60);

  const stripeDeadline = now + 40 * 60;
  await answerOutcall(gw, outcall, 200, sessionCreatedBody({ expiresAtSeconds: stripeDeadline }));
  const created = expectOk(await settle());

  // `expiresAtNs` is STRIPE's deadline, not the one we asked for — Stripe owns
  // when the session dies, and a second copy only creates something to disagree
  // with.
  expect(created.order.expiresAtNs).toEqual([BigInt(stripeDeadline) * 1_000_000_000n]);
  expect(created.order.stripeSessionUrl[0]!).toContain('checkout.stripe.com');
  expectOk(await cancelOrderWithExpire(gw, created.order.id));
});

test('65 — a session that cannot be created fails the order in the same call (#33)', async () => {
  // There is no retry method, deliberately: `payment_session(orderId)` was the
  // only thing that created orders in a sessionless state, and every downstream
  // complication chained off that. The buyer's slot frees immediately and they
  // start over.
  await ensureRates(gw);
  const openBefore = (await gw.asAdmin.reserve_status()).openOrders;

  const settle = await gw.deferredUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []);
  const outcall = await awaitPendingOutcall(gw);
  await answerOutcall(gw, outcall, 400, JSON.stringify({ error: { message: 'no such price' } }));
  const failed = expectErr(await settle());
  expect(failed).toHaveProperty('sessionUnavailable');

  // The order exists, is #expired, and records WHY — so a support ticket is
  // answerable from the record rather than from the audit ring.
  const mine = await gw.asUser.list_orders();
  const theOrder = mine.find((o) => statusKey(o) === 'expired' && 'sessionFailed' in (o.expiredBy[0] ?? {}));
  expect(theOrder).toBeDefined();
  expect(theOrder!.stripeSessionUrl).toHaveLength(0);
  // The slot is free again: openOrders is back where it started.
  expect((await gw.asAdmin.reserve_status()).openOrders).toBe(openBefore);

  // And a livemode mismatch is refused at CREATION, before any money moves —
  // cheaper than catching it at webhook time, and the reason the check lives here.
  await gw.asAdmin.set_expected_livemode([true]);
  const mismatched = expectErr(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { livemode: false }),
  ) as { sessionUnavailable: string };
  expect(mismatched.sessionUnavailable).toContain('livemode mismatch');
  await gw.asAdmin.set_expected_livemode([]);
});

test('66 — cancelling is ATOMIC with Stripe: never half-cancelled (#33)', async () => {
  await ensureRates(gw);

  // ── A failed expire leaves the order payable and UNCANCELLED. This is the
  // whole reason the outcall is fatal rather than best-effort: an earlier draft
  // audited the failure and returned success, which recreates the state
  // `#cancelled` exists to eliminate — order says cancelled, session still
  // charges the buyer.
  const stubborn = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const failedCancel = expectErr(
    await cancelOrderWithExpire(gw, stubborn.order.id, { expireStatus: 500, expireBody: '{"error":{"message":"internal"}}' }),
  );
  expect(failedCancel).toContain('try again');
  expect(await orderStatus(gw, stubborn.order.id)).toBe('created');
  // Still payable, which is the safe side of the failure.
  const still = (await gw.asUser.get_order(stubborn.order.id))[0]!;
  expect(still.stripeSessionUrl).toHaveLength(1);

  // ── "Not open" is its own outcome, not a failure. Two causes — the session
  // completed, or it expired already — and we must not guess between them from
  // our clock. Change nothing; let the webhook resolve it.
  const raced = expectErr(
    await cancelOrderWithExpire(gw, stubborn.order.id, {
      expireStatus: 400,
      expireBody: '{"error":{"message":"You cannot expire a Checkout Session in a status of complete."}}',
    }),
  );
  expect(raced).toContain('already settled');
  expect(await orderStatus(gw, stubborn.order.id)).toBe('created');

  // ── A successful expire cancels. Only now.
  expect(statusKey(expectOk(await cancelOrderWithExpire(gw, stubborn.order.id)))).toBe('cancelled');
});

test('67 — checkout.session.expired is the only thing that expires an order (#33)', async () => {
  await ensureRates(gw);
  const live = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_expire_me' }),
  );

  expect(await deliverWebhook(gw, sessionExpiredBody({
    eventId: 'evt_exp_1',
    sessionId: 'cs_expire_me',
    clientReferenceId: clientReferenceFor(live.order.id),
  }))).toMatchObject({ status_code: 200 });
  await gw.pic.tick(3);

  const expired = (await gw.asUser.get_order(live.order.id))[0]!;
  expect(statusKey(expired)).toBe('expired');
  expect(expired.expiredBy[0]).toEqual({ sessionExpired: null });

  // A REDELIVERY is a no-op, not a second anything. Stripe retries for ~3 days.
  expect(await deliverWebhook(gw, sessionExpiredBody({
    eventId: 'evt_exp_1',
    sessionId: 'cs_expire_me',
    clientReferenceId: clientReferenceFor(live.order.id),
  }))).toMatchObject({ status_code: 200 });
  expect(await orderStatus(gw, live.order.id)).toBe('expired');

  // ── The NORMAL path: cancelling expires the session, so Stripe fires this for
  // every cancel. "Mark it expired" is illegal on a #cancelled order, and it must
  // degrade to a no-op rather than trap — a trap here is a 5xx that Stripe
  // retries for three days.
  const cancelled = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_cancelled_one' }),
  );
  expectOk(await cancelOrderWithExpire(gw, cancelled.order.id));
  expect(await deliverWebhook(gw, sessionExpiredBody({
    eventId: 'evt_exp_2',
    sessionId: 'cs_cancelled_one',
    clientReferenceId: clientReferenceFor(cancelled.order.id),
  }))).toMatchObject({ status_code: 200 });
  await gw.pic.tick(3);
  // Still cancelled, not expired: the buyer's own decision is what the record says.
  expect(await orderStatus(gw, cancelled.order.id)).toBe('cancelled');

  // ── The event names a DIFFERENT session than the order holds. Audited and
  // treated as unattributed rather than trusted: `client_reference_id` is an
  // attacker-editable URL parameter, so a reference that resolves to one of our
  // orders is not on its own permission to expire it. The order must not move.
  const bound = expectOk(
    await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_the_real_one' }),
  );
  expect(await deliverWebhook(gw, sessionExpiredBody({
    eventId: 'evt_exp_mismatch',
    sessionId: 'cs_some_other_session',
    clientReferenceId: clientReferenceFor(bound.order.id),
  }))).toMatchObject({ status_code: 200 });
  await gw.pic.tick(3);
  expect(await orderStatus(gw, bound.order.id)).toBe('created');
  const mismatchLog = await gw.asAdmin.audit_log();
  expect(mismatchLog.some((e) => e.tag === 'stripe.expiredSessionMismatch'
    && e.detail.includes('cs_the_real_one')
    && e.detail.includes('cs_some_other_session'))).toBe(true);
  // Still payable, because nothing legitimate happened to it.
  expect((await gw.asUser.get_order(bound.order.id))[0]!.stripeSessionUrl).toHaveLength(1);
  expectOk(await cancelOrderWithExpire(gw, bound.order.id));

  // ── An event for a session nobody holds is acked, not an error.
  expect(await deliverWebhook(gw, sessionExpiredBody({
    eventId: 'evt_exp_3',
    sessionId: 'cs_never_existed',
    clientReferenceId: `${user.getPrincipal().toText()}_00000000000000000000000000000000`,
  }))).toMatchObject({ status_code: 200 });

  // ── A dispute is recorded and nothing else. Cycles are gone and the network
  // pulls the funds; there is nothing to react to, but it must be visible.
  expect(await deliverWebhook(gw, JSON.stringify({
    id: 'evt_dispute_1',
    type: 'charge.dispute.created',
    livemode: false,
    data: { object: { id: 'dp_1', payment_intent: 'pi_disputed', amount: 500 } },
  }))).toMatchObject({ status_code: 200 });
  const log = await gw.asAdmin.audit_log();
  expect(log.some((e) => e.tag === 'stripe.disputeCreated' && e.detail.includes('pi_disputed'))).toBe(true);
});

test('68 — a cancel racing session creation cannot leave a payable URL behind (#33)', async () => {
  // THE INTERLEAVING the continuation re-check exists for, and it had no test —
  // the same shape as #46's untested `attach_payment` guard, so it gets one now.
  //
  // `create_order` commits the order and THEN awaits the outcall, so another
  // ingress message runs in between. `cancel_order` from a second tab takes its
  // sessionless branch (no session id yet, so no outcall) and cancels
  // immediately. If the continuation then stored the URL, the buyer would hold a
  // **payable link for an order they were told was cancelled** — money-safe,
  // because the matrix rejects `#cancelled → #paid`, but exactly the "told
  // cancelled, tab still charges" wart atomic cancellation exists to eliminate.
  await ensureRates(gw);

  const settle = await gw.deferredUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []);
  const outcall = await awaitPendingOutcall(gw);

  // The order is committed and `#created` at this point, with no session id — so
  // cancelling takes the branch that needs no outcall.
  const orderId = decodeURIComponent(
    /client_reference_id=([^&]+)/.exec(outcallBody(outcall))![1]!,
  ).split('_').pop()!;
  expect(await orderStatus(gw, orderId)).toBe('created');
  expect(statusKey(expectOk(await gw.asUser.cancel_order(orderId)))).toBe('cancelled');

  // Now Stripe answers the create. The session is real at Stripe, but its URL
  // must never reach the buyer.
  await answerOutcall(gw, outcall, 200, sessionCreatedBody({
    id: 'cs_raced_creation',
    expiresAtSeconds: Number(await nowSeconds(gw.pic)) + 2_100,
  }));
  expect(expectErr(await settle())).toEqual({ cancelledDuringCreation: null });

  const raced = (await gw.asUser.get_order(orderId))[0]!;
  expect(statusKey(raced)).toBe('cancelled');
  // Nothing stored: no URL to hand out, and no session id to bind an event to.
  expect(raced.stripeSessionUrl).toHaveLength(0);
  expect(raced.stripeSessionId).toHaveLength(0);
  // Audited, because a real session now exists at Stripe that nobody can reach.
  // It dies at its own `expires_at`; the URL never left the canister.
  const log = await gw.asAdmin.audit_log();
  expect(log.some((e) => e.tag === 'stripe.sessionOrphaned' && e.detail.includes('cs_raced_creation'))).toBe(true);
});

test('69 — a FAILED session creation racing a cancel does not double-release (#33)', async () => {
  // The other half of the same gap. The failure path routes through
  // `expireWithCause` rather than writing the status directly, so when the order
  // is already `#cancelled` the matrix no-ops `#cancelled → #expired` for free.
  // A direct write would move a terminal order back to `#expired` — and once #30
  // lands, release a promise that cancellation already released.
  await ensureRates(gw);

  const settle = await gw.deferredUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []);
  const outcall = await awaitPendingOutcall(gw);
  const orderId = decodeURIComponent(
    /client_reference_id=([^&]+)/.exec(outcallBody(outcall))![1]!,
  ).split('_').pop()!;
  expectOk(await gw.asUser.cancel_order(orderId));

  // Stripe refuses. The in-call failure handler runs against a cancelled order.
  await answerOutcall(gw, outcall, 400, JSON.stringify({ error: { message: 'nope' } }));
  expect(expectErr(await settle())).toHaveProperty('sessionUnavailable');

  // Still #cancelled, NOT #expired: the buyer's own decision is what the record
  // says, and the status did not move twice.
  const stayed = (await gw.asUser.get_order(orderId))[0]!;
  expect(statusKey(stayed)).toBe('cancelled');
  expect(stayed.expiredBy).toHaveLength(0);
});

test('88 — refusals tally and never write a line per attempt (#61)', async () => {
  // ⚠️ **This is the leak #61 exists to close, and it is the assertion the
  // per-attempt line would fail.** `#amountBelowMin` needs no prior state: one
  // cent from any principal reaches it with no order, no payment and no setup.
  // While the audit log was a 4,096-entry ring that was harmless churn — #37
  // removes the ring, and an unbounded log fed by a free caller is permanent
  // stable-state growth at zero attacker cost.
  //
  // Mutation check: restore `audit("order.notAdmitted", …)` in `Main.mo`'s
  // `admit` and this scenario fails on the line count while everything else
  // stays green.
  await ensureRates(gw);
  const { gate } = await gw.asAnon.lifecycle_config();

  const before = (await gw.asAdmin.audit_log()).length;
  const tallyBefore = (await gw.asAnon.refusal_counts()).counts.amountBelowMin;

  const ATTEMPTS = 5;
  for (let i = 0; i < ATTEMPTS; i += 1) {
    const refused = expectErr(
      await gw.asUser.create_order({ custom: gate.minPurchaseUsdCents - 1n }, USER_ACCOUNT, []),
    ) as { notAdmitted: { amountBelowMin: { minUsdCents: bigint } } };
    // Still a real, distinguishable refusal — the buyer's answer is unchanged.
    expect(refused.notAdmitted.amountBelowMin.minUsdCents).toBe(gate.minPurchaseUsdCents);
  }

  // The whole point: five refusals, zero new audit lines.
  const after = await gw.asAdmin.audit_log();
  expect(after.length).toBe(before);

  // And nothing was lost that the old line carried. It was
  // `audit("order.notAdmitted", reasonToText(reason))` — no principal, no amount
  // — so its entire content was "a refusal of this kind happened", which the
  // counter keeps in full.
  const tallyAfter = (await gw.asAnon.refusal_counts()).counts.amountBelowMin;
  expect(tallyAfter).toBe(tallyBefore + BigInt(ATTEMPTS));

  // A per-request reason is not the rail refusing, so nothing latched — which is
  // what keeps a later genuine rail-state refusal announceable.
  const { refusingNow } = await gw.asAnon.refusal_counts();
  expect(refusingNow.reserveShort).toBe(false);
  expect(refusingNow.canisterCyclesLow).toBe(false);
});

test('71 — a custom amount is bounded by the gate, in both directions (#33)', async () => {
  // The bounds are the ONLY thing standing between a buyer and an arbitrary
  // charge now: with custom amounts there is no tier to pin the figure. So both
  // ends are asserted against the canister, not the UI — a frontend-only bound is
  // not a bound.
  await ensureRates(gw);
  const { gate } = await gw.asAnon.lifecycle_config();

  // A typed amount with no matching preset works — that is the point.
  const odd = expectOk(await createOrderWithSession(gw, { custom: 3_333n }, USER_ACCOUNT, []));
  expect(odd.order.pricing.usdCents).toBe(3_333n);
  // Priced by the same code a preset uses, so the receipt arithmetic is identical.
  expect(odd.order.lockedCycles).toBeGreaterThan(0n);
  expectOk(await cancelOrderWithExpire(gw, odd.order.id));

  // Below the floor: refused, and distinguishably from the ceiling case, because
  // the buyer acts on them differently.
  const under = expectErr(
    await gw.asUser.create_order({ custom: gate.minPurchaseUsdCents - 1n }, USER_ACCOUNT, []),
  ) as { notAdmitted: { amountBelowMin: { usdCents: bigint; minUsdCents: bigint } } };
  expect(under.notAdmitted.amountBelowMin.minUsdCents).toBe(gate.minPurchaseUsdCents);

  // Above the ceiling: refused. The ceiling IS the per-order reserve exposure
  // (#30), so this is the bound that matters most.
  const over = expectErr(
    await gw.asUser.create_order({ custom: gate.maxPurchaseUsdCents + 1n }, USER_ACCOUNT, []),
  ) as { notAdmitted: { amountAboveMax: { usdCents: bigint; maxUsdCents: bigint } } };
  expect(over.notAdmitted.amountAboveMax.maxUsdCents).toBe(gate.maxPurchaseUsdCents);

  // Both bounds inclusive, so the extremes are sellable.
  for (const at of [gate.minPurchaseUsdCents, gate.maxPurchaseUsdCents]) {
    const edge = expectOk(await createOrderWithSession(gw, { custom: at }, USER_ACCOUNT, []));
    expect(edge.order.pricing.usdCents).toBe(at);
    expectOk(await cancelOrderWithExpire(gw, edge.order.id));
  }

  // ⚠️ ONE ceiling for presets AND custom amounts. Registering a preset outside
  // either bound is refused, so a tile can never appear that `Gate.admit` then
  // rejects — sellable but unpayable, at both ends.
  const live = await gw.asAnon.card_tiers();
  expect(expectErr(await gw.asAdmin.set_card_tiers([
    { id: 'toobig', usdCents: gate.maxPurchaseUsdCents + 1n },
  ]))).toHaveProperty('aboveCeiling');
  expect(expectErr(await gw.asAdmin.set_card_tiers([
    { id: 'toosmall', usdCents: gate.minPurchaseUsdCents - 1n },
  ]))).toHaveProperty('belowFloor');
  // And the live list is untouched by a refused batch.
  expect(await gw.asAnon.card_tiers()).toEqual(live);

  // The inverse guard: moving a bound across a registered preset is refused, so
  // the operator cannot strand one by editing config later.
  expect(expectErr(await gw.asAdmin.set_gate_config({
    ...gate,
    minPurchaseUsdCents: TIER_USD_CENTS + 1n,
  }))).toHaveProperty('tierBelowFloor');
  expect(expectErr(await gw.asAdmin.set_gate_config({
    ...gate,
    minPurchaseUsdCents: gate.maxPurchaseUsdCents + 1n,
  }))).toHaveProperty('floorAboveCeiling');
});

test('72 — a delivery completing DURING a create cannot manufacture capacity (#30 PR-B)', async () => {
  // ⚠️ **The interleaving that broke an earlier version of this PR's own
  // correctness proof.** It is worth keeping the shape on record even though the
  // design no longer has the gap: `create_order` USED to await the reserve balance,
  // and a delivery continuation landing in that gap moved both numbers at once — it
  // debited the ledger and released the order's promise — so pairing the stale
  // balance with a live tally double-counted the release and `available` came out
  // high by a whole order.
  //
  // The fix was not a fresher read (any awaited value is historical by the time it is
  // used); it was removing the read from the decision. `admitOrder` is now
  // synchronous against `reserveFloor`, a maintained lower bound moved only by our own
  // outflows, so there are no two values to pair and no gap to land in. What this
  // scenario now guards is the INVARIANT rather than that mechanism — see below.
  //
  // Staged so the harm would be visible rather than theoretical: the reserve holds
  // **exactly one order's worth**. An optimistic admission here is an order the
  // gateway provably cannot deliver, and it leaves `promised > balance`.
  await ensureRates(gw);

  // A dedicated tight reserve. `reserveBalance` is whatever earlier scenarios
  // left, so the figure is computed rather than assumed.
  const before = await reserveBalance(gw);
  const fee = await gw.cyclesLedger.icrc1_fee();

  const paid = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(await deliverWebhook(gw, checkoutSessionBody({
    eventId: 'evt_race', paymentIntent: 'pi_race',
    clientReferenceId: clientReferenceFor(paid.order.id), amountCents: TIER_USD_CENTS,
  }))).toMatchObject({ status_code: 200 });

  // Submit a second create WITHOUT awaiting it, then let the paid order's delivery
  // continuation run.
  //
  // ⚠️ **VERIFIED BY MUTATION THAT THIS SCENARIO DOES NOT CATCH THE BUG IT
  // DESCRIBED.** With the stale-balance design still in place, replacing
  // `Reserve.promisedForDecision` (since deleted with that design) by a live-only
  // read — the exact defect — left all 58 scenarios passing: PocketIC's scheduling
  // does not put the delivery continuation inside the create's await gap, and nothing
  // here can force it to. The arithmetic is pinned in `test/reserve.test.mo` instead,
  // and `docs/TEST-COVERAGE.md` carries the gap so its absence is not read as
  // coverage.
  //
  // Kept anyway for what it DOES assert: the invariant below holds however the
  // messages interleave, so an over-promise arriving by any other route is caught.
  // A guard, not a proof.
  const settle = await gw.deferredUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []);
  // Let the paid order's delivery continuation run inside the create's await gap.
  await gw.pic.tick(6);
  // ⚠️ `maybePendingOutcall`, not `awaitPendingOutcall`: a create refused at the
  // gate never reaches the session call, so demanding an outcall here would hang
  // on exactly the outcome this scenario is looking for.
  const outcall = await maybePendingOutcall(gw);
  if (outcall !== undefined) {
    await answerOutcall(gw, outcall, 200, sessionCreatedBody({
      expiresAtSeconds: Number(await nowSeconds(gw.pic)) + 2_100,
    }));
  }
  const second = await settle();

  // THE INVARIANT, whichever way it went: the gateway never promises more than it
  // holds. An order admitted into phantom capacity would break this, and the
  // eventual `#InsufficientFunds` would send an operator hunting a fee delta for a
  // cause that is a whole over-promise.
  const promisedAfter = (await gw.asAnon.reserve_status()).promisedTotal;
  expect(promisedAfter).toBeLessThanOrEqual(await reserveBalance(gw));

  // And the first order delivered for real, out of the reserve.
  expect(await tickUntilStatus(gw, paid.order.id, ['delivered'])).toBe('delivered');
  expect(before - (await reserveBalance(gw))).toBeGreaterThanOrEqual(TIER_LOCKED_CYCLES);
  if ('ok' in second) {
    // If it was admitted, it must be genuinely coverable — not phantom capacity.
    expectOk(await cancelOrderWithExpire(gw, second.ok.order.id));
  }
  expect(fee).toBe(CYCLES_LEDGER_FEE);
});

test('73 — a funded reserve is not a SELLABLE reserve until the gateway looks (#30 PR-B)', async () => {
  // Rule 1, and the trap the whole design accepts in exchange for a synchronous
  // admission decision: solvency is decided against `reserveFloor`, a maintained
  // lower bound that moves DOWN when we transfer out and UP only when the canister
  // reads the ledger. A top-up is therefore real money the gateway will not sell
  // until someone tells it to look.
  //
  // ⚠️ This is why `fundReserve` observes by default and why the seed script and the
  // RUNBOOK's top-up step both call `refresh_reserve`. Getting it wrong produces the
  // single most confusing failure in this system: `#reserveShort{available = 0}`
  // against a ledger account holding the full amount, with nothing anywhere saying
  // why.
  const TOP_UP = 7_000_000_000_000n; // 7 T — two tier5 orders' worth

  const before = await gw.asAnon.reserve_status();
  // ⚠️ **THE BOUND, and it is the load-bearing line of this scenario** — asserted
  // before anything else, against whatever every earlier scenario left behind. The
  // floor must never exceed the real balance, because the gate sells against it.
  //
  // **Verified by mutation that this catches the optimistic direction:** crediting the
  // floor back on a `#delivered` (a REAL debit — breaking rule 2/3's asymmetry, the
  // "fix" the code comments warn against) makes the floor exceed the balance and fails
  // here. So the floor's bound property is test-enforced across the suite's whole
  // accumulated history, not merely argued in `Reserve.mo`.
  expect(before.reserveFloor).toBeLessThanOrEqual(await reserveBalance(gw));

  // Fund WITHOUT observing — the state an operator produces by running
  // `icp cycles transfer` and stopping there.
  await fundReserve(gw, TOP_UP, false);
  const unobserved = await gw.asAnon.reserve_status();
  expect(unobserved.reserveFloor).toBe(before.reserveFloor);
  expect(unobserved.reserveObservedAtNs).toEqual(before.reserveObservedAtNs);
  // The money is unambiguously there. Only the gateway's view of it has not moved.
  expect(await reserveBalance(gw)).toBeGreaterThanOrEqual(before.reserveFloor + TOP_UP);

  // Now look. Adoption takes the ledger's truth outright rather than adding the
  // top-up to the floor, which is what makes it self-healing: earlier scenarios
  // left the floor BELOW the balance (scenario 35 parked a transfer against a
  // stopped ledger, and rule 2's decrement correctly stands when a call gets no
  // reply), and one quiet observation repairs that too.
  const observedBalance = await gw.asAdmin.refresh_reserve();
  const after = await gw.asAnon.reserve_status();
  expect(after.reserveFloor).toBe(observedBalance);
  expect(after.reserveFloor).toBe(await reserveBalance(gw));
  expect(after.reserveFloor).toBeGreaterThan(before.reserveFloor);
  expect(after.reserveObservedAtNs).toHaveLength(1);
  // `availableToSell` is the gate's own arithmetic, not a second derivation.
  expect(after.availableToSell).toBe(
    after.reserveFloor > after.promisedTotal ? after.reserveFloor - after.promisedTotal : 0n,
  );
});

// -- 74 was deleted with the lever it depended on (#30 PR-B) ------------------
//
// Its subject was "a deliberately wrong stored ledger fee still delivers, and
// `#BadFee` persists the correction". Staging that needed `set_cycles_ledger_fee` to
// make the stored fee wrong — and that lever has been deleted as self-justifying: the
// only state it fixed was one that it, or a ~70,000× ledger fee rise, could create,
// and its own typo silently shorted buyers.
//
// ⚠️ **So the lever was also this test's only seam, and deleting it deletes the
// scenario.** The alternative — shipping an admin money lever to production so a test
// can stage a state — is the wrong trade. What covers the mechanism now:
//
//   - `test/cmc.test.mo` pins `interpretTransfer(#Err(#BadFee))` → `#badFee(expected)`,
//     so the ledger's report is still read correctly.
//   - The one thing left untested is the persistence itself (`cyclesLedgerFee :=
//     expected`, one line). Its failure mode is loud rather than silent: the fee does
//     not stick, so `delivery.feeChanged` fires on EVERY delivery instead of once,
//     which RUNBOOK §9 carries as a P3 row. `docs/TEST-COVERAGE.md` records the gap.
//   - Its other half — the buyer receives `locked - fee` and the reserve moves by
//     exactly `locked` — is scenario 06's and 10's, and always was.

test('75 — a buyer can heal their OWN stuck delivery, and only their own (#30 PR-B)', async () => {
  // `process_order` was admin-only. It is now admin **or** the order's owner, because
  // it already did exactly the right thing for a stuck delivery — replay the stored
  // intent, `#Duplicate` recovers the block — and making the buyer wait for a sweep
  // interval to get that was a latency choice, not a safety one.
  //
  // ⚠️ It does NOT replace the sweep, and nothing here should be read as saying so:
  // the sweep is the guarantee (we took the money, so we deliver whether or not the
  // buyer ever comes back), this is the latency fix for the buyer who did come back.
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const stuck = created.order;

  // Park it in #paid with a real ledger outage, then end the outage without letting
  // the sweep run — the exact moment a buyer refreshes their page.
  // ⚠️ Balance read BEFORE the stop: reading after throws, and a throw between
  // `stopNns` and the `try` skips the `finally` and leaves the ledger stopped for
  // every scenario after this one (see the README's coupling note).
  await stopNns(gw, CYCLES_LEDGER_ID);
  try {
    expect(await deliverWebhook(gw, checkoutSessionBody({
      eventId: 'evt_ownerkick', paymentIntent: 'pi_ownerkick',
      clientReferenceId: clientReferenceFor(stuck.id), amountCents: TIER_USD_CENTS,
    }))).toMatchObject({ status_code: 200 });
    await gw.pic.tick(5);
    expect(await orderStatus(gw, stuck.id)).toBe('paid');

    // ⚠️ **Correction to what this comment used to say.** It claimed the webhook's
    // detached kick "does not reliably get as far as journalling an intent", offered
    // as the reason for the advance. That was wrong: the intent was there all along,
    // and the empty set that made the first version of this scenario fail was the
    // `openEntry` bug (it recorded a literal status, so the predicate matched nothing).
    // The advance is kept because it makes the precondition robust rather than
    // dependent on how many rounds one `tick(5)` happens to run — 20 min clears the
    // 15 min sweep cadence and is well inside every staleness window — but it is
    // belt-and-braces, not the fix, and reading it as the fix would hide the bug.
    await gw.pic.advanceTime(20 * 60 * 1_000);
    await gw.pic.tick(10);
    const journalled = (await gw.asAdmin.delivery_journal(stuck.id))[0];
    expect(journalled?.transferIntent).toHaveLength(1);
    expect(journalled?.blockIndex).toHaveLength(0);
  } finally {
    await startNns(gw, CYCLES_LEDGER_ID);
  }

  // ⚠️ **The admin can SEE it immediately, with no 2 h wait.** The error queue is the
  // worklist and self-clears correctly, but `#deliveryDelayed` does not open until the
  // alert threshold — and a delivery taking a sweep or two is normal, so lowering that
  // threshold would file entries for orders that deliver themselves. This is the
  // two-hour blind window closed.
  const pendingBefore = await gw.asAdmin.pending_deliveries();
  const mine = pendingBefore.find((e) => e.orderId === stuck.id)!;
  expect(mine).toBeDefined();
  // It has already failed at least once, which is what distinguishes it from an order
  // in its first attempt.
  expect(mine.retries).toBeGreaterThan(0n);
  expect(mine.blockIndex).toHaveLength(0);
  // Not public: it scans the whole journal, so an unauthenticated caller could make
  // the canister walk its entire history for free. That is also why none of it went
  // into `reserve_status`, which is public and O(1).
  await expect(gw.asAnon.pending_deliveries()).rejects.toThrow(/anonymous/);
  await expect(gw.asUser.pending_deliveries()).rejects.toThrow(/not a controller/);

  // A stranger cannot kick it. ⚠️ `notFound`, not a distinct "not yours": whether an
  // order id exists is not a stranger's business, and `getOwned` is what answers.
  expect(expectErr(await gw.asStranger.process_order(stuck.id))).toEqual({ notFound: null });
  // Nor can the anonymous principal — and it needs no check of its own, because
  // `create_order` refuses anonymous callers so it owns no order to kick.
  expect(expectErr(await gw.asAnon.process_order(stuck.id))).toEqual({ notFound: null });
  expect(await orderStatus(gw, stuck.id)).toBe('paid');

  // The owner can, and it delivers.
  const kicked = await gw.asUser.process_order(stuck.id);
  expect('ok' in kicked).toBe(true);
  expect(await tickUntilStatus(gw, stuck.id, ['delivered'])).toBe('delivered');

  // ⚠️ **And it disappears from `pending_deliveries` by itself.** No resolve step to
  // forget: delivery records the block and moves the status, which is what removes it
  // from the set. That is the property that makes this usable as a dashboard rather
  // than as another queue somebody has to tidy.
  expect((await gw.asAdmin.pending_deliveries()).map((e) => e.orderId)).not.toContain(stuck.id);

  // ⚠️ An owner kick is NOT audited and an admin kick is. A buyer refreshing a page
  // must not be able to fill a 4,096-entry ring buffer with lines that say nothing,
  // while an ops action on someone else's order is exactly what the trail is for.
  const kickLines = (log: { tag: string; detail: string }[]) =>
    log.filter((e) => e.tag === 'delivery.manualKick' && e.detail.includes(stuck.id));
  expect(kickLines(await gw.asAdmin.audit_log())).toHaveLength(0);

  // And the admin lever still works — the widening is additive, not a handover.
  // Safe to spam by construction: the order is already delivered, so this is the
  // idempotent path.
  expect('ok' in (await gw.asAdmin.process_order(stuck.id))).toBe(true);
  expect(kickLines(await gw.asAdmin.audit_log()).length).toBeGreaterThan(0);
  expect(await orderStatus(gw, stuck.id)).toBe('delivered');
  // The clock moved, so leave the rates fresh for what follows (see the README).
  await setCmcRate(gw);
  await ensureRates(gw);
});

test('76 — one escalated order must not freeze the reserve reconcile forever (#30 PR-B)', async () => {
  // ⚠️ **This is a regression test for a bug that was written, shipped into the
  // branch, and found by re-derivation rather than by any test.**
  //
  // A reserve observation is adopted only across a QUIET window — nothing unsettled
  // before the balance read, nothing after, no transfer issued in between — because
  // adopting across an in-flight outflow erases rule 2's decrement while the transfer
  // still debits. The first version of that predicate counted any journal entry with
  // an intent and no block as unsettled.
  //
  // An escalated order keeps exactly that shape FOREVER: escalation patches the
  // status and leaves `blockIndex` null, and resolution happens off-chain on the
  // queue entry. So one escalation made the quiet window unsatisfiable for the life
  // of the canister — every reconcile skipped, every `refresh_reserve` skipped, and
  // top-ups silently stopped registering. The rail closing slowly with no lever.
  //
  // The fix requires the entry to still be `#paid`, which is sound because an
  // escalated order has no outstanding callback: escalation is decided either from
  // `stageOf` at the top of the drive loop or after a response has already arrived,
  // never with a call in the air.
  const escalated = (await gw.asAdmin.delivery_journal(orderEscalated.id))[0]!;
  // The shape this scenario depends on, asserted rather than assumed — scenario 35
  // produced it, and if it ever stops doing so this fails here instead of passing
  // vacuously.
  expect(await orderStatus(gw, orderEscalated.id)).toBe('needsReview');
  expect(escalated.transferIntent).toHaveLength(1);
  expect(escalated.blockIndex).toHaveLength(0);

  // THE ASSERTION: with that order sitting there, an observation is still adopted.
  const before = await gw.asAnon.reserve_status();
  await fundReserve(gw, 3_000_000_000_000n, false);
  const observed = await gw.asAdmin.refresh_reserve();
  const after = await gw.asAnon.reserve_status();
  expect(after.reserveFloor).toBe(observed);
  expect(after.reserveFloor).toBeGreaterThan(before.reserveFloor);
  expect(after.reserveObservedAtNs).not.toEqual(before.reserveObservedAtNs);
  // Its promise is still HELD, which is the other half of the fix being safe: the
  // order is excluded from the in-flight predicate, not forgiven its obligation.
  expect(after.promisedTotal).toBeGreaterThanOrEqual(orderEscalated.lockedCycles);
});

test('77 — an escalated order whose cycles DID arrive can be recorded, not filed as abandoned (#30 PR-B)', async () => {
  // ⚠️ **The record was the bug.** `needsReview`'s only exit was `abandoned`, so an
  // operator who checked the ledger and found the transfer HAD landed had no way to
  // say so: their only lever filed a delivered order as abandoned and audited a
  // refund that never happened. Money-correct, record-wrong — and the record is what
  // this codebase trusts to keep illegal states unrepresentable.
  const target = orderEscalated;
  expect(await orderStatus(gw, target.id)).toBe('needsReview');
  const promisedBefore = (await gw.asAnon.reserve_status()).promisedTotal;

  // Not a buyer's decision, and not a guess: admin-only, and the ledger block is
  // required as the evidence that someone actually looked.
  await expect(gw.asUser.record_delivered(target.id, 12_345n)).rejects.toThrow(/not a controller/);
  expect(await orderStatus(gw, target.id)).toBe('needsReview');

  const LEDGER_BLOCK = 424_242n;
  const recorded = expectOk(await gw.asAdmin.record_delivered(target.id, LEDGER_BLOCK));
  expect(statusKey(recorded)).toBe('delivered');

  // The block lands in the journal, so the receipt shows the same proof any other
  // delivered order shows.
  const journal = (await gw.asAdmin.delivery_journal(target.id))[0]!;
  expect(journal.blockIndex).toEqual([LEDGER_BLOCK]);
  // And the promise is released — the order is settled, so the reserve is no longer
  // holding capacity for it.
  expect((await gw.asAnon.reserve_status()).promisedTotal)
    .toBe(promisedBefore - target.lockedCycles);
  expect((await gw.asAdmin.audit_log()).map((e) => e.tag)).toContain('order.recordedDelivered');

  // Idempotent, because an operator re-running a resolution step must not be a
  // failure — and re-recording cannot move money either way.
  expect(statusKey(expectOk(await gw.asAdmin.record_delivered(target.id, LEDGER_BLOCK)))).toBe('delivered');

  // ⚠️ And it accepts ONLY an escalated order. A live order delivers on its own, so
  // letting an operator declare one delivered would be a lever for skipping the
  // ledger entirely.
  await ensureRates(gw);
  const live = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  expect(expectErr(await gw.asAdmin.record_delivered(live.order.id, 1n)))
    .toMatch(/only an under-review order/);
  expectOk(await cancelOrderWithExpire(gw, live.order.id));
});

test('78 — an order whose delivery is unsettled cannot be abandoned into a double payout (#30 PR-B)', async () => {
  // ⚠️ **Found by a reviewer probing the predicate PR-B built, and it predates PR-B:**
  // `abandon_order` accepted a `#paid` order whose transfer had been issued and whose
  // block was not recorded — a money position that is UNKNOWN. Abandoning released the
  // promise and filed a refund-by-hand obligation, and after `#abandoned` nothing
  // sweeps the order, so nothing ever discovered whether the transfer had landed. The
  // buyer keeps the cycles and gets the refund.
  //
  // Not merely a race with a call in flight: an intent whose transfer executed and
  // whose reply was lost looks exactly like one that never executed, so the lever
  // decided between them by guessing. Deciding an unknown position is what
  // `#needsReview` exists to prevent, and this reached the same outcome from `#paid`.
  await setCmcRate(gw);
  await ensureRates(gw);
  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const target = created.order;
  const reserveBefore = await reserveBalance(gw);

  // ⚠️ Balance read BEFORE the stop (see the README's coupling note).
  await stopNns(gw, CYCLES_LEDGER_ID);
  try {
    expect(await deliverWebhook(gw, checkoutSessionBody({
      eventId: 'evt_abandonrace', paymentIntent: 'pi_abandonrace',
      clientReferenceId: clientReferenceFor(target.id), amountCents: TIER_USD_CENTS,
    }))).toMatchObject({ status_code: 200 });
    // Let a sweep journal the intent against the dead ledger — that is what makes the
    // position unknown, and without it this scenario asserts nothing.
    await gw.pic.advanceTime(20 * 60 * 1_000);
    await gw.pic.tick(10);
    const entry = (await gw.asAdmin.delivery_journal(target.id))[0];
    expect(entry?.transferIntent).toHaveLength(1);
    expect(entry?.blockIndex).toHaveLength(0);
    expect(await orderStatus(gw, target.id)).toBe('paid');

    // THE GUARD: the end-it lever refuses, and says what to look at.
    const refused = expectErr(await gw.asAdmin.abandon_order(target.id, 'operator is impatient'));
    expect(refused).toMatch(/delivery outstanding/);
    expect(refused).toMatch(/pending_deliveries/);
    expect(await orderStatus(gw, target.id)).toBe('paid');
    // The promise is still held, which is the point — releasing it is the harm.
    expect((await gw.asAnon.reserve_status()).promisedTotal)
      .toBeGreaterThanOrEqual(target.lockedCycles);

    // ⚠️ **A wait, not a refusal.** The 72 h bound escalates it to `needsReview`,
    // where the position can be established from the ledger and abandonment is the
    // documented exit. So the operator is never stuck — they are told to establish
    // the fate first, which is exactly the procedure `#needsReview` carries.
    await gw.pic.advanceTime(80 * 3_600 * 1_000);
    await gw.pic.tick(5);
    expect(await tickUntilStatus(gw, target.id, ['needsReview'])).toBe('needsReview');
    const abandoned = expectOk(await gw.asAdmin.abandon_order(target.id, 'established on the ledger: never sent (test)'));
    expect(statusKey(abandoned)).toBe('abandoned');
  } finally {
    await startNns(gw, CYCLES_LEDGER_ID);
  }

  // Nothing moved out of the reserve throughout — the position the operator acted on
  // was certain by the time they were allowed to act.
  expect(await reserveBalance(gw)).toBe(reserveBefore);

  // ⚠️ ~80 h of clock advance stales BOTH rates; skipping this fails whatever runs
  // next on rates it never touched (see the README).
  await setCmcRate(gw);
  await ensureRates(gw);
});

test('80 — an issued intent escalates at the DEDUP window, not at the 72 h max hold', async () => {
  // ⚠️ **Two time bounds terminate a stuck delivery, and which one fires is not a
  // detail — it decides the operator's instruction.** Nothing covered this until now:
  // 35 and 47 both advance ~80 h in a single jump, so no sweep lands between 24 h and
  // 72 h and the max-hold bound is the only one they can reach. In production the sweep
  // runs every 15 min, so for an order whose intent WAS issued the 24 h bound always
  // wins, and the escalation those scenarios exercise is the one that fires least.
  //
  // The division of labour, stated because the sweep reads bottom-up and this is easy
  // to get backwards:
  //
  //   - an intent WAS issued  → `stageOf` escalates `staleIntent` at ~24 h. Past the
  //     dedup window a replay is no longer protected, so retrying could pay twice.
  //     The instruction is *establish its fate from the ledger*, never re-send.
  //   - an intent was NEVER issued (reserve short, stored fee above the order) →
  //     nothing ages, so `stageOf` keeps answering `#beginDelivery` and only the 72 h
  //     max hold stops it. Nothing was sent, so there is nothing to establish.
  //
  // This asserts the first, and asserts it at 25 h — comfortably inside the 72 h bound,
  // so a pass cannot be the max-hold path in disguise.
  await setCmcRate(gw);
  await ensureRates(gw);

  const created = expectOk(await createOrderWithSession(gw, { tier: 'tier5' }, USER_ACCOUNT, []));
  const stale = created.order;
  const reserveBefore = await reserveBalance(gw);

  await stopNns(gw, CYCLES_LEDGER_ID);
  try {
    expect(await deliverWebhook(gw, checkoutSessionBody({
      eventId: 'evt_stale', paymentIntent: 'pi_stale', clientReferenceId: clientReferenceFor(stale.id),
      amountCents: TIER_USD_CENTS,
    }))).toMatchObject({ status_code: 200 });
    await gw.pic.tick(10);
    expect(await orderStatus(gw, stale.id)).toBe('paid');

    // The intent must exist for this scenario to mean anything: `staleIntent` is
    // reachable only through a journalled intent with no block. Without this the test
    // would still go `needsReview` — via `missingJournal` — and assert nothing about
    // the window.
    const issued = (await gw.asAdmin.delivery_journal(stale.id))[0]!;
    expect(issued.transferIntent).toHaveLength(1);
    expect(issued.blockIndex).toHaveLength(0);

    // 25 h: past the ~24 h dedup window, less than a third of the way to the 72 h max
    // hold. A sweep here is what production would do; 35 and 47 skip over it.
    await gw.pic.advanceTime(25 * 3_600 * 1_000);
    await gw.pic.tick(5);
    expect(await tickUntilStatus(gw, stale.id, ['needsReview'])).toBe('needsReview');

    // The stage IS the cause, and the runbook's triage table is keyed by it. A pass
    // here that read `deliveryWaitExceeded` would mean the max-hold bound fired 47 h
    // early; one that read `missingJournal` would mean the intent never got written.
    const filed = (await openErrorEntries(gw)).find(
      (e) => 'deliveryStuck' in e.kind && e.kind.deliveryStuck.orderId === stale.id,
    );
    expect(filed).toBeDefined();
    expect((filed!.kind as { deliveryStuck: { stage: string } }).deliveryStuck.stage).toBe('staleIntent');
    // No block recorded, so the money position is genuinely unknown — the entry must
    // not claim otherwise.
    expect((filed!.kind as { deliveryStuck: { blockIndex: [] | [bigint] } }).deliveryStuck.blockIndex)
      .toHaveLength(0);
  } finally {
    await startNns(gw, CYCLES_LEDGER_ID);
  }

  // ⚠️ **And it must NOT be re-driven.** `#needsReview` is not sweepable precisely
  // because the position is unknown; a sweep that re-issued this intent is the double
  // payment the whole escalation exists to avoid. The reserve is the witness.
  await gw.pic.advanceTime(30 * 60 * 1_000);
  await gw.pic.tick(10);
  expect(await orderStatus(gw, stale.id)).toBe('needsReview');
  expect(await reserveBalance(gw)).toBe(reserveBefore);

  // ~25 h of clock advance stales both rates; see the README.
  await setCmcRate(gw);
  await ensureRates(gw);
});

// -- 79 was deleted by #36, exactly as it was written to be --------------------
//
// It asserted `Minting`, `IcpAtCMC` and `AwaitingTreasury` were tracked and **zero**
// across every order the suite accumulated — the claim that nothing entered the mint
// pipeline during the PR-A → PR-C window, checkable only while the states existed.
//
// ⚠️ **Its heir is this deletion.** `Types.OrderStatus` has seven cases now, so "no
// order is in a mint state" is not a claim anybody can make or fail to make:
// unreachability became **unrepresentability**, which is the upgrade this codebase
// reaches for everywhere else (the transition matrix, the cycles ledger's actor type)
// and strictly stronger than the test that preceded it.
//
// For the record, since it is the only place the measurement survives: routing
// `#beginDelivery` into `#minting` — the one legal entrance — failed scenarios 06,
// 07, 08, 10, 11 and 12, and every other insertion point was refused by the
// transition matrix itself.

test('87 — the stranded scan RESUMES: a crowd of due orders does not starve the tail', async () => {
  // ⚠️ **This scenario stays in the shared instance on purpose, and is the only #52 one
  // that does.** The other six moved to `stranded.spec.ts` for determinism; this one
  // needs the opposite — a *crowd*. By here the suite has left dozens of orders
  // `#created` forever, which is the population the resume cursor exists for and cannot
  // be built cheaply by a scenario.
  //
  // The bug it guards: the scan takes at most `maxRetrievesPerPass` due orders, and a
  // due order that stays due — answered `open`, or a retrieve that keeps failing — is
  // asked again on every pass while orders behind it are never reached at all. A bound
  // without a resume bounds *which* orders get looked at, not how many. That is not
  // hypothetical: two scenarios failed with "the sweep never retrieved session …"
  // because their order sat behind ten permanently-due neighbours, and the deleted
  // retention sweep had already solved it with a keyed cursor before #33 removed the
  // module and the reasoning together.
  await setCmcRate(gw);
  await ensureRates(gw);

  // Past every lingering order's deadline plus the grace, so the whole crowd is due.
  await gw.pic.advanceTime(90 * 60 * 1_000);
  await gw.pic.tick(5);

  // Answer every retrieve with `open` — a no-op, so nothing leaves the due set and the
  // crowd stays exactly as crowded. Then collect which sessions were asked about across
  // several passes.
  const asked = new Set<string>();
  for (let pass = 0; pass < 4; pass += 1) {
    await gw.pic.advanceTime(65 * 60 * 1_000); // clear the hourly cadence gate
    for (let round = 0; round < 30; round += 1) {
      for (const outcall of await gw.pic.getPendingHttpsOutcalls()) {
        if (!isSweepRetrieve(outcall)) continue;
        asked.add(outcall.url.slice(outcall.url.lastIndexOf('/') + 1));
        await answerSweepRetrieveOpen(gw, outcall);
      }
      await gw.pic.tick();
    }
  }

  // THE assertion: more distinct sessions were asked about than one pass can hold. With
  // no resume this is exactly `maxRetrievesPerPass` forever — the same head of the list,
  // pass after pass — so a cursor that does not advance fails here.
  expect(asked.size, 'the scan asked about the same orders every pass — the cursor is not advancing').toBeGreaterThan(10);

  await setCmcRate(gw);
  await ensureRates(gw);
});

test('88 — one open order per principal, and its own deadline is what frees the slot', async () => {
  // The shipped cap (#52 PR-B): **1 per principal**, as a product decision rather than a
  // safety control — a buyer who wants another order cancels the one they have, which is
  // what makes `cancel_order` load-bearing. This file pins 20 in `beforeAll` because 55
  // creations need it, so the shipped value is exercised here and restored at the end.
  await setCmcRate(gw);
  await ensureRates(gw);
  const gate = (await gw.asAnon.lifecycle_config()).gate;

  try {
    expectOk(await gw.asAdmin.set_gate_config({ ...gate, maxOpenOrdersPerPrincipal: 1n }));

    // A fresh order takes the slot; the next one is refused, and the refusal names the
    // cap rather than blaming the reserve or the rate.
    const held = expectOk(await createOrderWithSession(
      gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_cap_88' },
    ));
    const refused = expectErr(await gw.asUser.create_order({ tier: 'tier5' }, USER_ACCOUNT, []));
    // Wrapped in `#notAdmitted`, because the gate's reasons are one variant and the
    // create error is another — the refusal names the cap AND the count, so the message
    // the frontend renders can say "you already have 1 open order" rather than "try
    // later".
    expect(refused).toMatchObject({ notAdmitted: { tooManyOpenOrders: { max: 1n, open: 1n } } });

    // ⚠️ **THE assertion this PR exists for: the slot frees at the order's OWN deadline,
    // with no Stripe call and no state change.** Without it, a cap of 1 plus one missed
    // `checkout.session.expired` locks this buyer out **permanently** — nothing else moves
    // a `#created` order, so "wait 35 minutes" would become "wait forever".
    //
    // A slot is our resource, so we may grant it on our own clock; releasing reserve
    // *capacity* is money and needs Stripe's authority, which is PR-A's sweep. Same
    // input, two resources, two standards of proof.
    await gw.pic.advanceTime(40 * 60 * 1_000); // past the session's 35-minute deadline
    await gw.pic.tick(3);
    // ⚠️ Re-arm the rates: 40 minutes is well past the 15-minute staleness window, so
    // without this the next `create_order` is refused for an unpriceable quote and the
    // failure reads as "no HTTPS outcall was made" — nothing to do with the slot. This is
    // the `advanceTime` coupling the README warns about, and it bit this scenario first.
    await setCmcRate(gw);
    await ensureRates(gw);
    const allowed = expectOk(await createOrderWithSession(
      gw, { tier: 'tier5' }, USER_ACCOUNT, [], { sessionId: 'cs_cap_88b' },
    ));

    // And the first order was NOT touched to make room — it is still `#created`, still
    // holding its reserve promise, waiting for Stripe or the sweep to settle it.
    expect(await orderStatus(gw, held.order.id)).toBe('created');
    expect(await orderStatus(gw, allowed.order.id)).toBe('created');

    // The buyer's own escape hatch still works, which is what makes the cap of 1 a
    // product decision rather than a trap.
    expectOk(await cancelOrderWithExpire(gw, allowed.order.id));
  } finally {
    // Restore, or every later scenario in this order-coupled file refuses.
    expectOk(await gw.asAdmin.set_gate_config({ ...gate, maxOpenOrdersPerPrincipal: 20n }));
  }

  await setCmcRate(gw);
  await ensureRates(gw);
});
