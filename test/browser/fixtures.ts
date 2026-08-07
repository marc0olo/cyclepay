import { test as base } from "@playwright/test";

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
