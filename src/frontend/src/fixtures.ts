/// Test-only fixtures: drive the post-purchase surfaces without a backend.
///
/// **Why this exists.** The delivered view is the flagship surface of the
/// two-audience flow, and it shipped broken twice. Both times the reason was the
/// same: nothing outside jsdom could reach it. Getting there for real needs a
/// signed-in Internet Identity, a funded local network, a Stripe payment link and
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
import type { Backend, Order } from "./actor";
import { cyclesForCents } from "./format";

/// The seams main.ts hands over. Deliberately narrow: fixtures may choose what
/// the backend says and who is signed in, and must go through the app's own
/// functions for everything else.
export type FixtureHost = {
  /// Replace backend construction. Called for every actor the app builds after
  /// this point, including the one `setIdentity` rebuilds on sign-in.
  useBackend(factory: (identity: Identity | null) => Backend): void;
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
  /// `account` is the newcomer shape and the only one that earns a tour;
  /// `canister` is the already-live shape, which needs none.
  destination?: "account" | "canister";
  /// Credit someone else's account. The tour's printed commands cannot reach a
  /// balance that is not the buyer's, so this is a distinct surface.
  thirdParty?: boolean;
};

/// A buyer and a stranger, both real self-authenticating principals so they are
/// the length and shape a visitor actually sees. Derived from fixed bytes rather
/// than typed out, because a hand-written principal fails its own checksum.
const BUYER = Principal.selfAuthenticating(new Uint8Array(32).fill(7));
const STRANGER = Principal.selfAuthenticating(new Uint8Array(32).fill(9));

const USD_CENTS = 500n;
const NET_CENTS = 455n;
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

function cannedOrder(spec: OrderSpec): Order {
  const status = spec.status ?? "delivered";
  const toAccount = (spec.destination ?? "account") === "account";
  const owner = spec.thirdParty ? STRANGER : BUYER;
  return {
    id: ORDER_ID,
    status: status as Order["status"],
    rail: "card" as Order["rail"],
    owner: { __kind__: "ii", ii: BUYER },
    destination: toAccount
      ? { __kind__: "cyclesLedgerAccount", cyclesLedgerAccount: { owner } }
      : { __kind__: "canister", canister: STRANGER },
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
    },
    paidUsdCents: status === "created" || status === "expired" ? undefined : USD_CENTS,
    createdAtNs: CREATED_AT_NS,
    updatedAtNs: CREATED_AT_NS,
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
  const backend = {
    card_tiers: async () => [
      { id: "t5", usdCents: 500n, paymentLinkUrl: "https://buy.stripe.com/test_fixture" },
      { id: "t20", usdCents: 2_000n, paymentLinkUrl: "https://buy.stripe.com/test_fixture" },
      { id: "t50", usdCents: 5_000n, paymentLinkUrl: "https://buy.stripe.com/test_fixture" },
    ],
    treasury_status: async () => ({ lowFloat: false }),
    pricing_status: async () => ({
      config: { feeBps: 290n, feeFixedCents: 30n },
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
      cyclesLedgerDepositFee: DEPOSIT_FEE,
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
    list_orders: async () => (order ? [order] : []),
    receipt: async () =>
      order === null || order.status !== "delivered"
        ? null
        : {
            order,
            paidUsdCents: USD_CENTS,
            cyclesMinted: LOCKED_CYCLES,
            mintBlockIndex: 4_812n,
            verification: {
              netCents: NET_CENTS,
              usdPerIcpMicros: USD_PER_ICP_MICROS,
              xdrPermyriadPerIcp: XDR_PERMYRIAD_PER_ICP,
              rateReceivedRates: 5n,
              rateQueriedSources: 6n,
            },
          },
  } as unknown as Backend;

  // NOT installed here. Most specs are about what renders while the gateway is
  // unreachable, which is the app's error path and worth keeping as the default;
  // a fixture that took over at load would quietly delete that coverage.
  const api: FixtureApi = {
    async useBackend() {
      host.useBackend(() => backend);
      await host.reloadMarket();
    },
    async signIn() {
      host.useBackend(() => backend);
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
