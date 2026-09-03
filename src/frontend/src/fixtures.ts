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
import type { Backend, CyclesLedger, Order } from "./actor";
import { cyclesForCents } from "./format";

/// The seams main.ts hands over. Deliberately narrow: fixtures may choose what
/// the backend says and who is signed in, and must go through the app's own
/// functions for everything else.
export type FixtureHost = {
  /// Replace backend construction. Called for every actor the app builds after
  /// this point, including the one `setIdentity` rebuilds on sign-in.
  useBackend(factory: (identity: Identity | null) => Backend): void;
  useCyclesLedger(factory: () => CyclesLedger): void;
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
    icrc1_balance_of: async () => 0n,
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

  // ⚠️ **The `unknown` hop is required HERE, and that was measured rather than assumed
  // in either direction.** A one-step `stub as Backend` is what you want, and for a small
  // interface it compiles: a 1-of-3 partial asserts to the full type fine, because the
  // full type is comparable to the stub's inferred type. It does NOT compile against this
  // type. `Backend` is `ActorSubclass<_SERVICE>` with roughly forty members and this stub
  // has eight, which fails TypeScript's comparability heuristic outright:
  //
  //   TS2352: Conversion of type '{ card_tiers: … }' to type 'Backend' may be a mistake
  //   because neither type sufficiently overlaps with the other.
  //
  // So the hop stays, and the reason it is now acceptable is that it no longer does any
  // checking: `satisfies Partial<Backend>` above verifies every stub's signature, and this
  // assertion covers only the partiality. Before, it covered everything, which is how four
  // wrong shapes survived three commits with every suite green.
  const fixtureBackend = stub as unknown as Backend;

  // NOT installed here. Most specs are about what renders while the gateway is
  // unreachable, which is the app's error path and worth keeping as the default;
  // a fixture that took over at load would quietly delete that coverage.
  const api: FixtureApi = {
    async useBackend() {
      host.useBackend(() => fixtureBackend);
      host.useCyclesLedger(() => cyclesLedger);
      await host.reloadMarket();
    },
    async signIn() {
      host.useBackend(() => fixtureBackend);
      host.useCyclesLedger(() => cyclesLedger);
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
