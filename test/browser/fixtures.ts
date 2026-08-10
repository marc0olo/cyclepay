import { test as base, type Page } from "@playwright/test";

/// A syntactically valid `ic_env` cookie, in the **exact** shape the asset
/// canister and the Vite dev server emit.
///
/// The encoding is fussier than it looks: every reserved character is
/// percent-encoded, `_` included (`%5F`), which `encodeURIComponent` leaves
/// alone. A cookie that merely looks right parses to nothing, `makeBackend()`
/// throws at module load, and the whole page is dead JS while still rendering
/// its initial markup — which is exactly how a first attempt at these specs
/// "passed" four assertions.
///
/// The canister id is a real, well-formed principal that answers nowhere, and the
/// root key is a local test network's. Every backend call therefore fails and
/// `init()` takes its error path. That is deliberate: these specs are about what
/// RENDERS, and the render must not depend on a deployed backend, a local
/// network, or mainnet Internet Identity. A page that only lays out correctly
/// while the gateway answers is a page that looks broken during an outage.
const ROOT_KEY =
  "308182301d060d2b0601040182dc7c0503010201060c2b0601040182dc7c05030201036100" +
  "a587ac27884f235a91ddd86927eec11e09872417231b41ab8fb95605c633af9702849c0ad6" +
  "929613392b39c715fc232c0a0d8eb00a1ea91985b3e440bc9d0b78a5872f96dae753f395cd" +
  "6602516ad58748d698958976c6c25b86c55aa30a3af9";

function icEnvCookie(entries: Record<string, string>): string {
  const enc = (s: string) =>
    s.replace(/_/g, "%5F").replace(/:/g, "%3A").replace(/=/g, "%3D").replace(/&/g, "%26");
  return Object.entries(entries)
    .map(([k, v]) => `${enc(k)}%3D${enc(v)}`)
    .join("%26");
}

const IC_ENV = icEnvCookie({
  ic_root_key: ROOT_KEY,
  "PUBLIC_CANISTER_ID:backend": "aaaaa-aa",
  "PUBLIC_CANISTER_ID:frontend": "aaaaa-aa",
});

export const test = base.extend({
  page: async ({ page, baseURL }, use) => {
    await page.context().addCookies([{ name: "ic_env", value: IC_ENV, url: baseURL! }]);
    // A fresh chooser on every spec: the "live" arm persists by design, and a
    // leaked preference would skip the very gate under test. Only that key —
    // clearing all of localStorage also wipes the theme choice, which runs on
    // every navigation and so makes "survives a reload" unpassable.
    await page.addInitScript(() => window.localStorage.removeItem("icp.audience"));
    // The page must be alive for any of these assertions to mean anything. A
    // module-load throw leaves the initial markup on screen, so assertions about
    // things that start hidden would pass against a dead page.
    page.on("pageerror", (error) => {
      throw new Error(`uncaught page error, the app never initialised: ${error.message}`);
    });
    await use(page);
  },
});

export { expect } from "@playwright/test";

// ── the app's own test hook ───────────────────────────────────────────────────
//
// `window.__cyclepayFixtures`, installed by src/frontend/src/fixtures.ts and
// present only in a CYCLEPAY_FIXTURES=1 build. It replaces the BACKEND and
// nothing else, so everything these helpers drive — sign-in, routing, the view
// machine, the 3 s poll — is the app's own code on its own path.
//
// This is what makes the post-purchase surfaces testable at all. Reaching the
// delivered view for real needs an Internet Identity session, a funded local
// network, a Stripe payment and a signed webhook, none of which a browser spec
// can have; so before this existed the only pictures of that screen came from
// injecting DOM state, and a spec could pass while a visitor saw nothing.

export type OrderSpec = {
  status?: string;
  destination?: "account" | "canister";
  thirdParty?: boolean;
};

type FixtureApi = {
  useBackend(): Promise<void>;
  signIn(): Promise<void>;
  openOrder(spec?: OrderSpec): Promise<void>;
  setStatus(status: string): void;
  principal(): string;
};

declare global {
  interface Window {
    __cyclepayFixtures: FixtureApi;
  }
}

/// Wait for `init()` to have installed the hook. It is installed inside an async
/// init, so a spec that reaches for it immediately after `goto` races it.
async function api(page: Page): Promise<void> {
  await page.waitForFunction(() => window.__cyclepayFixtures !== undefined);
}

/// Canned backend, no session. For the priced buy view a signed-out visitor sees.
export async function useFixtureBackend(page: Page): Promise<void> {
  await api(page);
  await page.evaluate(() => window.__cyclepayFixtures.useBackend());
}

/// Canned backend and a signed-in buyer.
export async function signInAsFixtureBuyer(page: Page): Promise<void> {
  await api(page);
  await page.evaluate(() => window.__cyclepayFixtures.signIn());
}

/// Put an order on screen through the app's own `openOrder`.
export async function openFixtureOrder(page: Page, spec: OrderSpec = {}): Promise<void> {
  await api(page);
  await page.evaluate((s) => window.__cyclepayFixtures.openOrder(s), spec);
}

/// Change what the backend answers, and leave the app to DISCOVER it on its next
/// poll tick. Deliberately not a render call: the defect this exists to catch was
/// precisely that the poll's discovery skipped the view machine.
export async function setFixtureStatus(page: Page, status: string): Promise<void> {
  await api(page);
  await page.evaluate((s) => window.__cyclepayFixtures.setStatus(s), status);
}

export async function fixturePrincipal(page: Page): Promise<string> {
  await api(page);
  return page.evaluate(() => window.__cyclepayFixtures.principal());
}
