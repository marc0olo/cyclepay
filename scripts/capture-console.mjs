// Capture the operator console for review (#68). NOT part of the gate.
//
// Committed so the screenshots in docs/screenshots/ are reproducible rather than
// artifacts nobody can regenerate. Run it as:
//
//   npm --prefix src/frontend run build:fixtures
//   (cd src/frontend && python3 -m http.server 5178 --bind 127.0.0.1 --directory dist-fixtures &)
//   node scripts/capture-console.mjs
//
// It drives the FIXTURE backend, so the figures are the ones in src/frontend/src/fixtures.ts.
// An empty console shows the layout and none of the judgement the design is about, which is
// why those fixtures are populated and now-relative.
import { chromium } from "../test/browser/node_modules/playwright-core/index.mjs";
import { mkdirSync } from "node:fs";

const ROOT_KEY =
  "308182301d060d2b0601040182dc7c0503010201060c2b0601040182dc7c05030201036100" +
  "a587ac27884f235a91ddd86927eec11e09872417231b41ab8fb95605c633af9702849c0ad6" +
  "929613392b39c715fc232c0a0d8eb00a1ea91985b3e440bc9d0b78a5872f96dae753f395cd" +
  "6602516ad58748d698958976c6c25b86c55aa30a3af9";
const enc = (s) => s.replace(/_/g, "%5F").replace(/:/g, "%3A").replace(/=/g, "%3D").replace(/&/g, "%26");
const cookie = Object.entries({
  "PUBLIC_CANISTER_ID:backend": "aaaaa-aa",
  IC_ROOT_KEY: ROOT_KEY,
}).map(([k, v]) => `${enc(k)}%3D${enc(v)}`).join("%26");

const out = new URL("../docs/screenshots/", import.meta.url).pathname;
mkdirSync(out, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1100, height: 1400 } });
await page.context().addCookies([
  { name: "ic_env", value: cookie, url: "http://localhost:5178" },
]);

// 1. Ungranted: what an operator sees before a controller grants them.
await page.goto("http://localhost:5178/#/admin");
await page.waitForTimeout(900);
await page.screenshot({ path: `${out}/admin-ungranted.png`, fullPage: true });

// 2. Granted and populated, via the fixture backend.
await page.waitForFunction(() => window.__cyclepayFixtures !== undefined);
await page.evaluate(() => window.__cyclepayFixtures.useBackend());
await page.evaluate(() => { window.location.hash = "#/"; });
await page.waitForTimeout(200);
await page.evaluate(() => { window.location.hash = "#/admin"; });
await page.waitForTimeout(1200);
await page.screenshot({ path: `${out}/admin-populated.png`, fullPage: true });

await browser.close();
console.log("captured");
