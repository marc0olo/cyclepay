/// Test-only fixtures: drive the post-purchase surfaces without a backend.
///
/// **Why this exists.** The delivered view is the flagship surface of this app,
/// and it shipped broken twice. Both times the reason was the same: nothing
/// outside jsdom could reach it. Getting there for real needs a
/// signed-in Internet Identity, a funded local network, a Stripe API key and
/// a signed webhook, so the only pictures anyone ever had of that screen were
/// produced by injecting DOM state directly. A test can pass that way while a
/// visitor sees nothing, which is exactly what happened.
///
/// So this replaces the *backend*, and nothing else. Sign-in, routing, the view
/// machine, the poll and every render run as they do in production; the only thing
/// standing in is what `get_order` answers. That is what makes a spec written
/// against these fixtures evidence about the app rather than about the fixture.
///
/// **Absent from a production build.** The single call site sits behind
/// `if (__FIXTURES__)` in main.ts, which Vite replaces with the literal `false`
/// unless the build sets `CYCLEPAY_FIXTURES=1`, so Rollup drops the branch and
/// this module's dynamic import with it. `scripts/test-all.sh` greps the shipping
/// bundle for the hook's name to keep that claim true rather than assumed.
import { Principal } from "@icp-sdk/core/principal";
import type { Identity } from "@icp-sdk/core/agent";
import type { Backend, CyclesIndex, CyclesLedger, Order } from "./actor";
import { cyclesForCents } from "./format";

/// The seams main.ts hands over. Deliberately narrow: fixtures may choose what
/// the backend says and who is signed in, and must go through the app's own
/// functions for everything else.
export type FixtureHost = {
  /// Replace backend construction. Called for every actor the app builds after
  /// this point, including the one `setIdentity` rebuilds on sign-in.
  useBackend(factory: (identity: Identity | null) => Backend): void;
  useCyclesLedger(factory: () => CyclesLedger): void;
  /// The cycles-ledger INDEX, for the dashboard's transaction list.
  useCyclesIndex(factory: () => CyclesIndex): void;
  /// Which principal counts as the gateway. Needed because the ledger list's order
  /// cross-reference is gated on the sender, so this is the one seam that decides
  /// whether that column renders anything.
  useGatewayPrincipal(id: string): void;
  /// The app's own `setIdentity`.
  signIn(identity: Identity | null): void;
  /// The app's own `openOrder` — routes, renders and starts the poll.
  openOrder(order: Order): void;
  /// The app's own market load, so tiers and rates come from the canned backend.
  reloadMarket(): Promise<void>;
  /// The app's own history load. Needed because the orders link, and therefore
  /// every route reachable through it, appears only once an order exists.
  reloadHistory(): Promise<void>;
};

export type OrderSpec = {
  /// An `OrderStatus` label. `delivered` is the interesting one.
  status?: string;
};

/// One destination shape and one owner, so `status` is the only thing worth
/// parameterising: `create_order` accepts only the caller's own account (#29), so
/// a fixture for any other would depict a screen no buyer can reach.
///
/// A real self-authenticating principal, so it is the length and shape a visitor
/// actually sees. Derived from fixed bytes rather than typed out, because a
/// hand-written principal fails its own checksum.
const BUYER = Principal.selfAuthenticating(new Uint8Array(32).fill(7));

// $10 — the smallest preset as of #33, and the gate's floor. A $5 fixture would
// match no preset, so "buy again" would select nothing.
const USD_CENTS = 1_000n;
// 1000 − (ceil(1000 × 290/10000) + 30) = 1000 − 59. Derived, not guessed: the
// receipt's own verification recomputes from it, so a wrong value fails visibly.
const NET_CENTS = 941n;
const USD_PER_ICP_MICROS = 4_550_000n;
const XDR_PERMYRIAD_PER_ICP = 35_000n;
/// Recomputed rather than written down, so the receipt's own verification passes
/// for the same reason a real one does: the arithmetic agrees.
const LOCKED_CYCLES = cyclesForCents(NET_CENTS, XDR_PERMYRIAD_PER_ICP, USD_PER_ICP_MICROS)!;
const DEPOSIT_FEE = 100_000_000n;
/// Fixed, because an order id appears on screen and a screenshot baseline cannot
/// tolerate a fresh one per run.
const ORDER_ID = "f1c7ea0b9d2e4a6580b3c1d7e9f20a4b";
/// The gateway's own principal, as this fixture pretends it. The order cross-reference
/// on a ledger transfer is gated on the SENDER being this, so a fixture that could not
/// name it could not exercise the gate at all: every row would read "-" and the browser
/// suite would pass while the column did nothing.
const GATEWAY = Principal.selfAuthenticating(new Uint8Array(32).fill(9));
const CREATED_AT_NS = 1_770_000_000_000_000_000n;
/// Fixed like the order id, and far enough ahead that the order is payable no
/// matter when the suite runs — the order view renders expiry from this rather
/// than from the status.
const EXPIRES_AT_NS = 4_000_000_000_000_000_000n;
const SESSION_ID = "cs_test_a1b2c3d4";
const SESSION_URL = "https://checkout.stripe.com/c/pay/cs_test_a1b2c3d4";
/// The statuses `Reserve.holdsPromise` calls terminal — kept in sync with it by name
/// rather than by comment, since a fixture that disagrees depicts an impossible order.
const TERMINAL = new Set(["delivered", "expired", "cancelled", "abandoned"]);

function cannedOrder(spec: OrderSpec): Order {
  const status = spec.status ?? "delivered";
  return {
    id: ORDER_ID,
    status: status as Order["status"],
    rail: "card" as Order["rail"],
    owner: { __kind__: "ii", ii: BUYER },
    destination: { __kind__: "cyclesLedgerAccount", cyclesLedgerAccount: { owner: BUYER } },
    lockedCycles: LOCKED_CYCLES,
    pricing: {
      usdCents: USD_CENTS,
      usdPerIcpMicros: USD_PER_ICP_MICROS,
      xdrPermyriadPerIcp: XDR_PERMYRIAD_PER_ICP,
      rateStandardDeviation: 0n,
      rateReceivedRates: 5n,
      rateQueriedSources: 6n,
      feeBps: 290n,
      feeFixedCents: 30n,
      // Before the order, deliberately: the rate pair is read from a cache the
      // timer refreshes, so it predates every order it prices (#34).
      ratesFetchedAtNs: CREATED_AT_NS - 60_000_000_000n,
    },
    paidUsdCents: status === "created" || status === "expired" ? undefined : USD_CENTS,
    // ⚠️ Set EXPLICITLY, even though the bindgen makes these optional properties
    // so omitting them typechecks. A forgotten `stripeSessionUrl` is silently
    // `undefined`, which the order view reads as "no session" and renders as no
    // pay button — a fixture that quietly depicts a state no real order is in.
    expiredBy: undefined,
    expiresAtNs: EXPIRES_AT_NS,
    stripeSessionId: SESSION_ID,
    // ⚠️ **Cleared on terminal statuses since #37**, which the rule above demands:
    // `commitTransition` drops the pay link on the way into a terminal state, so a
    // fixture that carries one on a `delivered` order depicts a state no real order
    // can be in — the exact fault the comment above was written about.
    stripeSessionUrl: TERMINAL.has(status) ? undefined : SESSION_URL,
    createdAtNs: CREATED_AT_NS,
    updatedAtNs: CREATED_AT_NS,
    // ⚠️ The three fields #37 added, set explicitly for the reason above — and note
    // that only `problems` (required) failed the typecheck. `delayedAtNs` and
    // `abandonedReason` are optional, so they defaulted to `undefined` silently:
    // the rule exists precisely because the compiler does not enforce it.
    delayedAtNs: undefined,
    abandonedReason: status === "abandoned" ? "operator ended it after refunding" : undefined,
    problems: [],
  };
}

/// The one order the OPERATOR console depicts: the history table, the worklist problem row
/// and the id lookup all answer from this.
///
/// ⚠️ **One object, because three panels disagreeing is the fixture defect this file has
/// already recorded once.** Built from `cannedOrder` rather than hand-written, so the
/// console cannot depict an order shape the app never sees.
function adminOrder(): Order {
  return {
    ...cannedOrder({ status: "needsReview" }),
    id: "9f3a0000000000000000000000000000",
    problems: [
      {
        filedAtNs: BigInt(Date.now() - 40 * 60_000) * 1_000_000n,
        kind: {
          __kind__: "deliveryStuck" as const,
          deliveryStuck: { stage: "transfer issued, no block recorded" },
        },
        detail: "cycles ledger did not answer; money position unknown",
        resolvedAtNs: undefined,
      },
    ],
  };
}

/// The window hook. Named on `window` so a spec can find it, and named
/// distinctively so the gate can grep a production bundle for its absence.
export type FixtureApi = {
  /// Answer from the canned backend from here on, and reload the market. Signed
  /// out, so the specs that want a priced buy view without a session can have one.
  useBackend(): Promise<void>;
  /// The same, plus a signed-in buyer. Everything order-shaped assumes this ran.
  signIn(): Promise<void>;
  /// Put an order on screen through the app's own `openOrder`, with history
  /// loaded around it the way a real purchase leaves it.
  openOrder(spec?: OrderSpec): Promise<void>;
  /// Change what `get_order` answers, and let the app's poll find it. This is
  /// the only honest way to test a status transition: the app discovers it the
  /// way it does in production rather than being told.
  setStatus(status: string): void;
  /// The principal the fixture buyer signs in as.
  principal(): string;
};

export function installFixtures(host: FixtureHost): void {
  let order: Order | null = null;

  const identity = { getPrincipal: () => BUYER } as unknown as Identity;

  host.useGatewayPrincipal(GATEWAY.toText());

  // Only the methods the UI actually calls, answering only the fields it reads.
  // Cast once, here, with the reason stated: the generated actor type carries
  // admin methods and config records this surface never touches, and stubbing
  // them would be noise standing in for coverage the PocketIC suite already has.
  // #30 PR-A: the fee comes from the ledger now, not from `quote_previews`. The
  // browser fixture answers it so the buy view still shows what lands, and so a
  // spec can tell "fee not known yet" (0) from "fee is 100 M" — the two render
  // differently and only one of them is a bug.
  const cyclesLedger: CyclesLedger = {
    icrc1_fee: async () => DEPOSIT_FEE,
    // The dashboard reads this from the LEDGER rather than from the gateway. A
    // realistic figure, not zero: a fixture showing "0 cycles" beside a delivered
    // order reads as a bug in the very thing the balance exists to demonstrate.
    icrc1_balance_of: async () => 7_338_461_538_461n,
  };

  /// The account's ledger history, from the INDEX. One row per shape the render has to
  /// tell apart, because a single direction proves nothing: a `transfer` is money in or
  /// out depending on which side the caller is, and every BURN carries the same
  /// `op`/`kind`/`from`, so only the memo separates a canister creation from a top-up.
  ///
  /// The two burn memos are the bytes a real cycles ledger wrote, captured from a local
  /// create and a local withdraw against the same target canister.
  const cyclesIndex: CyclesIndex = {
    get_account_transactions: async () => ({
      Ok: {
        balance: 7_338_461_538_461n,
        transactions: [
          {
            id: 4_812n,
            transaction: {
              kind: "transfer",
              timestamp: 1_760_000_000_000_000_000n,
              transfer: [{
                from: { owner: GATEWAY.toText(), subaccount: [] },
                to: { owner: BUYER, subaccount: [] },
                amount: 7_338_461_538_461n,
                fee: [],
                // Delivery.mo sets the memo to the order id as UTF-8.
                memo: [new TextEncoder().encode(ORDER_ID)],
              }],
              mint: [],
              burn: [],
              approve: [],
            },
          },
          {
            id: 4_901n,
            transaction: {
              kind: "burn",
              timestamp: 1_760_000_600_000_000_000n,
              transfer: [],
              mint: [],
              burn: [{
                from: { owner: BUYER, subaccount: [] },
                amount: 500_000_000_000n,
                // CBOR: 0x81 array(1), 0x4a bytes(10), then the target canister.
                memo: [new Uint8Array([
                  0x81, 0x4a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x70, 0x3d, 0xae, 0x01, 0x01,
                ])],
              }],
              approve: [],
            },
          },
          {
            id: 4_902n,
            transaction: {
              kind: "burn",
              timestamp: 1_760_000_900_000_000_000n,
              transfer: [],
              mint: [],
              burn: [{
                from: { owner: BUYER, subaccount: [] },
                amount: 2_000_000_000_000n,
                // The creation sentinel: 32 bytes of 0xFE, carrying no canister id.
                memo: [new Uint8Array(32).fill(0xfe)],
              }],
              approve: [],
            },
          },
        ],
        oldest_tx_id: [],
      },
    }),
  };

  const stub = {
    card_tiers: async () => [
      // The #33 presets: $10 / $20 / $50. `paymentLinkUrl` went with the links.
      { id: "t10", usdCents: 1_000n },
      { id: "t20", usdCents: 2_000n },
      { id: "t50", usdCents: 5_000n },
    ],
    // The gate's bounds, which the custom-amount field renders its range from.
    // Without this the field stays disabled on "Loading amounts…" — which a
    // screenshot caught and no assertion would have.
    lifecycle_config: async () => ({
      gate: {
        maxOpenOrdersPerPrincipal: 1n,
        minCanisterCycles: 5_000_000_000_000n,
        minPurchaseUsdCents: 1_000n,
        maxPurchaseUsdCents: 10_000n,
      },
      // ⚠️ Added by the `satisfies` below, not by anyone noticing. `lifecycle_config`
      // gained `delivery` earlier in this same PR (#68 step 1) and this fixture kept
      // returning `{gate}` alone: the cast accepted it, so the specs drove the app with
      // a shape the canister no longer returns.
      delivery: { alertAfterNs: 7_200_000_000_000n, maxHoldNs: 259_200_000_000_000n },
    }),
    delivery_stats: async () => ({
    availableToSell: 775_000_000_000_000n,
    deliveredOrders: 0n,
    deliveredCycles: 0n,
    deliveredUsdCents: 0n,
    nullPaid: 0n,
    refusingNow: {
      reserveShort: false,
      canisterCyclesLow: false,
      railClosed: false,
      stripeApiFailing: false,
      unboundedGiveaway: false,
    },
  }),
  pricing_status: async () => ({
      // ⚠️ Five fields, not two. The pricing `Config` carries the staleness window, the
      // delta bound and the minimum rate sources as well as the fee, and this stub had
      // only the fee: another shape the cast accepted.
      config: {
        feeBps: 290n,
        feeFixedCents: 30n,
        maxAgeNs: 900_000_000_000n,
        maxRateDeltaBps: 500n,
        minRateSources: 3n,
        divisor: 1n,
      },
      rates: {
        usdPerIcpMicros: USD_PER_ICP_MICROS,
        xdrPermyriadPerIcp: XDR_PERMYRIAD_PER_ICP,
        fetchedAtNs: CREATED_AT_NS,
        quality: { standardDeviation: 0n, receivedRates: 5n, queriedSources: 6n },
      },
      lastAttempt: { ok: true, atNs: CREATED_AT_NS, detail: "" },
    }),
    // The rail ships disabled, and these fixtures keep it that way: a spec that
    // silently enabled it would be asserting against a product nobody ships.
    quote_previews: async (amounts: bigint[]) => ({
      quotes: amounts.map((usdCents) => {
        const feeCents = (usdCents * 290n) / 10_000n + 30n;
        const netCents = usdCents > feeCents ? usdCents - feeCents : undefined;
        return {
          usdCents,
          feeCents,
          netCents,
          cycles:
            netCents === undefined
              ? undefined
              : (cyclesForCents(netCents, XDR_PERMYRIAD_PER_ICP, USD_PER_ICP_MICROS) ?? undefined),
        };
      }),
    }),
    // ── the operator console (#68) ────────────────────────────────────────────────
    //
    // ⚠️ Timestamps are NOW-relative, unlike the buyer fixtures' fixed `CREATED_AT_NS`.
    // With the fixed value every figure rendered as "213 days ago", which made the console
    // read as a dead deployment: the staleness of the reserve observation and the age of a
    // delayed delivery are exactly the numbers an operator judges, so a screenshot of them
    // frozen in the past shows the layout and none of the judgement.
    //
    // Populated on purpose: a console screenshot with every list empty shows the layout
    // and none of the judgement the design is about. These figures are shaped to show
    // both halves of the wait-versus-work split at once.
    // #97: the configuration surface reads these. A provisioned sandbox gateway, so the
    // console renders as fully configured rather than as a half-set-up one.
    expected_livemode: async () => false,
    stripe_origin: async () => "https://gateway.example",
    stripe_api_key_status: async () => ({ isSet: true, generation: 1n }),
    webhook_secret_status: async () => ({ isSet: true, generation: 1n }),
    admin_status: async () => ({
      caller: BUYER,
      granted: true,
      isController: false,
    }),
    operator_summary: async () => ({
      deliveriesOutstanding: 3n,
      deliveriesDelayed: 1n,
      ordersNeedingReview: 1n,
      orphansUnresolved: 2n,
      problemsUnresolved: 2n,
      ordersWithProblems: 1n,
      refusingNow: {
        stripeApiFailing: false,
        unboundedGiveaway: false,
        canisterCyclesLow: false,
        reserveShort: false,
        railClosed: false,
      },
      availableToSell: 775_000_000_000_000n,
      reserveObservedAtNs: BigInt(Date.now() - 4 * 60_000) * 1_000_000n,
    }),
    refusal_counts: async () => ({
      counts: {
        amountAboveMax: 1n,
        stripeApiFailed: 0n,
        unboundedGiveaway: 0n,
        buyerNotAllowed: 0n,
        canisterCyclesLow: 0n,
        amountBelowMin: 6n,
        reserveShort: 2n,
        railClosed: 0n,
        tooManyOpenOrders: 3n,
      },
      refusingNow: {
        stripeApiFailing: false,
        unboundedGiveaway: false,
        canisterCyclesLow: false,
        reserveShort: false,
        railClosed: false,
      },
    }),
    orphans_unresolved: async () => ({
      entries: [
        {
          id: 12n,
          kind: {
            __kind__: "unattributed" as const,
            unattributed: { claimedRef: "aaaaa-aa_deadbeef", paymentRef: "pi_3Qx1" },
          },
          rail: "card" as Order["rail"],
          createdAtNs: BigInt(Date.now() - 90 * 60_000) * 1_000_000n,
          resolvedAtNs: undefined,
          detail: "client_reference_id resolved to no order",
        },
        {
          id: 13n,
          kind: {
            __kind__: "unprocessable" as const,
            unprocessable: { field: "payment_intent", eventId: "evt_1Qx7" },
          },
          rail: "card" as Order["rail"],
          createdAtNs: BigInt(Date.now() - 20 * 60_000) * 1_000_000n,
          resolvedAtNs: undefined,
          detail: "checkout.session.completed with no payment_intent",
        },
      ],
      nextCursor: undefined,
    }),
    delayed_deliveries: async () => ({
      entries: [
        {
          orderId: "9f3a0000000000000000000000000000",
          status: "paid" as Order["status"],
          heldSinceNs: BigInt(Date.now() - 3 * 3_600_000) * 1_000_000n,
          waitedNs: 10_800_000_000_000n,
          retries: 4n,
          pastMaxHold: false,
          delayedAtNs: CREATED_AT_NS,
        },
      ],
      nextCursor: undefined,
    }),
    pending_deliveries: async () => [
      {
        orderId: "9f3a0000000000000000000000000000",
        status: "paid" as Order["status"],
        updatedAtNs: BigInt(Date.now() - 3 * 3_600_000) * 1_000_000n,
        createdAtNs: BigInt(Date.now() - 3 * 3_600_000) * 1_000_000n,
        destination: { __kind__: "cyclesLedgerAccount" as const, cyclesLedgerAccount: { owner: BUYER, subaccount: undefined } },
        retries: 4n,
        blockIndex: undefined,
        lastError: "cycles ledger did not answer",
        cyclesDelivered: undefined,
        transferIntent: undefined,
      },
    ],
    // ── the diagnostics panel (#68) ──────────────────────────────────────────────
    // ⚠️ **Figures chosen to AGREE with `operator_summary` above**, for the reason the
    // note below this block records: three panels disagreeing in a screenshot meant to
    // show how they agree. `problem_depth` mirrors `problemsUnresolved` and
    // `ordersWithProblems`; `orphan_depth` mirrors `orphansUnresolved`.
    health: async () => true,
    problem_depth: async () => ({ orders: 1n, unresolved: 2n }),
    orphan_depth: async () => ({ retained: 3n, unresolved: 2n }),
    recovery_status: async () => ({
      indexScan: {
        chunkSize: 25n,
        expectedFullCycleNs: 3_600_000_000_000n,
        storedOrders: 12n,
        inFlightCycle: {
          ordersRead: 7n,
          startedAtNs: BigInt(Date.now() - 12 * 60_000) * 1_000_000n,
          repairs: 0n,
        },
        lastCompletedCycle: {
          completedAtNs: BigInt(Date.now() - 70 * 60_000) * 1_000_000n,
          startedAtNs: BigInt(Date.now() - 130 * 60_000) * 1_000_000n,
          ordersRead: 12n,
          repairs: 1n,
        },
      },
      lastCountReconcileAttemptNs: BigInt(Date.now() - 9 * 60_000) * 1_000_000n,
      lastCountReconcile: {
        atNs: BigInt(Date.now() - 9 * 60_000) * 1_000_000n,
        ordersRead: 12n,
        drift: [],
        refused: [],
      },
      lastReserveReconcileAttemptNs: BigInt(Date.now() - 4 * 60_000) * 1_000_000n,
      sweepInFlight: false,
      intervalNs: 600_000_000_000n,
    }),
    // One page with a cursor, so the Load more control is visible rather than hidden by
    // a fixture that happens to fit on one page.
    audit_log: async (afterSeq: bigint | null, _limit: bigint) =>
      afterSeq === undefined || afterSeq === null
        ? {
            events: [
              { seq: 1n, tag: "admin.granted", atNs: BigInt(Date.now() - 86_400_000) * 1_000_000n, detail: "granted to fo76k" },
              { seq: 2n, tag: "secret.set", atNs: BigInt(Date.now() - 82_800_000) * 1_000_000n, detail: "generation 1" },
              { seq: 3n, tag: "order.read", atNs: BigInt(Date.now() - 3_600_000) * 1_000_000n, detail: "9f3a0000000000000000000000000000" },
            ],
            nextCursor: 3n,
          }
        : {
            events: [
              { seq: 4n, tag: "orders.recounted", atNs: BigInt(Date.now() - 600_000) * 1_000_000n, detail: "paid=1, delivered=0" },
            ],
            nextCursor: undefined,
          },
    // ⚠️ Returns an order carrying an UNRESOLVED problem, matching the summary's count.
    // The first version returned the buyer's order or nothing, so the summary said "1
    // order carrying a problem" while the worklist said "None." and the history said "No
    // orders match" — three panels disagreeing in a screenshot meant to show how they
    // agree. In production all three read the same store.
    admin_orders: async () => ({
      orders: [adminOrder()],
      nextCursor: undefined,
    }),
    get_order: async () => order,
    // ⚠️ Two arguments, and `nextCursor` ABSENT rather than null. The wrapper renders a
    // Candid `opt` as `?: T`, so `undefined` means absent and `null` is a value of the
    // wrong shape. This stub had `nextCursor: null` with no parameters at all, which is
    // the inconsistency the cast was hiding: `quote_previews` next to it already used
    // `undefined` for the same thing.
    list_orders: async (_afterId: string | null, _limit: bigint) => ({
      orders: order ? [order] : [],
      nextCursor: undefined,
    }),
    // ── the order lookup (#68) ───────────────────────────────────────────────────
    // ⚠️ **Answered from the SAME object the history table renders**, not from the canned
    // buyer order. Keyed off that one, the lookup said "No order with that id" for the id
    // visible in the row directly above it, because the buyer order is null until one is
    // opened. That is the disagreement the note on `admin_orders` above records, in a new
    // place: a row an operator can see has to be a row they can look up.
    //
    // These are UPDATES in production, so each call writes a line to the audit trail.
    // Refusing every other id keeps the "no order with that id" branch reachable, which is
    // what an operator hits when they paste a payment reference instead of an order id.
    admin_order: async (id: string) => (id === adminOrder().id ? adminOrder() : null),
    // Always null, and that is correct rather than a stub: the fixture order is
    // `needsReview`, and a receipt exists only for a delivered one. The lookup renders
    // "Receipt: none" from this, which is the honest reading for that order.
    admin_receipt: async (_id: string) => null,
    delivery_journal: async (id: string) =>
      id !== adminOrder().id
        ? null
        : {
            orderId: adminOrder().id,
            status: adminOrder().status,
            updatedAtNs: adminOrder().createdAtNs,
            createdAtNs: adminOrder().createdAtNs,
            destination: adminOrder().destination,
            retries: 4n,
            blockIndex: undefined,
            lastError: "cycles ledger did not answer",
            cyclesDelivered: undefined,
            transferIntent: undefined,
          },
    receipt: async () =>
      order === null || order.status !== "delivered"
        ? null
        : {
            order,
            paidUsdCents: USD_CENTS,
            cyclesDelivered: LOCKED_CYCLES,
            deliveryBlockIndex: 4_812n,
            verification: {
              netCents: NET_CENTS,
              usdPerIcpMicros: USD_PER_ICP_MICROS,
              xdrPermyriadPerIcp: XDR_PERMYRIAD_PER_ICP,
              rateReceivedRates: 5n,
              rateQueriedSources: 6n,
            },
          },
    // ⚠️ **`satisfies Partial<Backend>`, then ONE narrow assertion.** This was
    // `as unknown as Backend`, which checked not a single stub signature against the
    // real service: the same hand-written-mirror-with-the-check-laundered-away that
    // #66/#85 removed from the integration suite, where a missing method fails loudly
    // and a CHANGED shape silently feeds the app the old one.
    //
    // `Partial` because the fixture is genuinely partial and must stay so: the specs
    // exercise a handful of paths, and implementing forty methods to satisfy an
    // annotation would be worse than the cast. What `satisfies` buys is that every stub
    // that IS here is checked, and a stub name the service does not have is an error.
    // The one remaining assertion is at the boundary, where the partiality is the point.
    // ⚠️ **`Partial` checks SHAPES, not completeness.** A method the app calls and this
    // object lacks compiles fine and fails at runtime with "not a function". That is the
    // right trade, because that failure is loud, whereas the wrong-shape class this
    // replaced was silent: four wrong shapes sat here through three commits with every
    // suite green. Do not read `satisfies Partial<Backend>` as full coverage.
  } satisfies Partial<Backend>;

  // ⚠️ **The `unknown` hop is required here, and the reason is NEITHER of the two I first
  // wrote.** An assertion is legal when either type is assignable to the other. Here
  // neither is, and three probes pin which:
  //
  //   stub as Pick<Backend, 'card_tiers' | 'get_order'>   compiles
  //   stub as Pick<Backend, keyof Backend>                TS2352
  //   stub as Backend                                     TS2352
  //
  // So it is not member COUNT (a 1-of-40 partial asserts to a plain 40-member interface
  // fine), and not `ActorSubclass`'s own structure (`Pick<..., keyof Backend>` strips index
  // and call signatures and still fails). It is that neither direction holds: the stub is
  // missing about thirty members, so stub to Backend fails; and the stub's members have
  // NARROWER inferred types than the service's (`get_order` returns one specific order
  // object, not `Order | null`), so Backend to stub fails too. Picking only the stubbed
  // keys restores one direction, which is why that probe compiles.
  //
  // ⚠️ **The probe that mattered is the one distinguishing this from a real defect.**
  // `satisfies Partial<Backend>` checks stub against Backend, and TypeScript's method
  // parameters are bivariant, so a stub can satisfy it while the service's member is NOT
  // assignable to the stub's: a fifth wrong shape `satisfies` is structurally unable to
  // catch. The Pick-of-stubbed-keys probe compiling is what rules that out.
  //
  // The hop is acceptable because it no longer does any checking: `satisfies` above
  // verifies every stub's signature, and this covers only the partiality. It used to cover
  // everything, which is how four wrong shapes survived three commits with every suite
  // green.
  const fixtureBackend = stub as unknown as Backend;

  // NOT installed here. Most specs are about what renders while the gateway is
  // unreachable, which is the app's error path and worth keeping as the default;
  // a fixture that took over at load would quietly delete that coverage.
  const api: FixtureApi = {
    async useBackend() {
      host.useBackend(() => fixtureBackend);
      host.useCyclesLedger(() => cyclesLedger);
      host.useCyclesIndex(() => cyclesIndex);
      await host.reloadMarket();
    },
    async signIn() {
      host.useBackend(() => fixtureBackend);
      host.useCyclesLedger(() => cyclesLedger);
      host.useCyclesIndex(() => cyclesIndex);
      host.signIn(identity);
      await host.reloadMarket();
    },
    async openOrder(spec: OrderSpec = {}) {
      order = cannedOrder(spec);
      await host.reloadHistory();
      host.openOrder(order);
    },
    setStatus(status: string) {
      if (order === null) throw new Error("fixture: openOrder before setStatus");
      order = { ...order, status: status as Order["status"] };
    },
    principal: () => BUYER.toText(),
  };

  (window as unknown as { __cyclepayFixtures: FixtureApi }).__cyclepayFixtures = api;
}
