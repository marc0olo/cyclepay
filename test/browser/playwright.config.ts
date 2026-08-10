import { defineConfig, devices } from "@playwright/test";

/// Browser specs for the frontend (issue #6).
///
/// These exist because the jsdom suite is structurally blind to a whole class of
/// bug, and that blindness shipped: `.chooser { display: grid }` outranks the UA
/// stylesheet's `[hidden] { display: none }`, so the chooser stayed on screen and
/// the disabled ck-USDC rail nav was always visible — while every DOM test passed,
/// because `el.hidden` was true and jsdom has no cascade and no layout.
///
/// Anything asserted here must be about **rendering and reachability**. Backend
/// behaviour belongs in the PocketIC suite; UI state transitions belong in
/// main.test.ts, which is far faster.
///
/// Serves a **production build** over a plain static server, not `vite dev`.
/// Two reasons, both load-bearing:
///   - `vite.config.ts` shells out to `icp network status` at config load, so dev
///     mode cannot start without a running local network. These specs must not
///     need one, or they will not run in CI and will rot.
///   - the bundle is the artifact that actually ships. A bundler transform that
///     only breaks in production is exactly the sort of thing a dev-server spec
///     misses.
///
/// `dist-fixtures/` rather than `dist/`: the same `vite build`, with
/// CYCLEPAY_FIXTURES=1 adding the test-only hook that makes the post-purchase
/// surfaces reachable (src/frontend/src/fixtures.ts). A separate outDir because
/// `dist/` is what a deploy uploads, and a bundle carrying the hook must never be
/// sitting there waiting to be shipped. `scripts/test-all.sh` asserts the shipping
/// bundle has no hook in it.
///
/// The backend is unreachable on purpose (see fixtures.ts): what renders must not
/// depend on the gateway answering, and the specs that DO need answers install the
/// canned backend explicitly.
export default defineConfig({
  testDir: ".",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "line" : "list",
  use: {
    baseURL: "http://localhost:5178",
    trace: "on-first-retry",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: {
    command:
      "npm --prefix ../../src/frontend run build:fixtures" +
      " && python3 -m http.server 5178 --bind 127.0.0.1 --directory ../../src/frontend/dist-fixtures",
    url: "http://localhost:5178",
    // NEVER reuse. The command here is "build, then serve", so a reused server is
    // serving whatever bundle the last run happened to leave on disk: edit the
    // CSS, re-run, and the suite reports green against the code you just changed
    // without ever having loaded it. That happened twice while these specs were
    // being written, and both times the wrong conclusion was drawn from it before
    // the cause was found. The cost of not reusing is one rebuild, a few seconds.
    reuseExistingServer: false,
    timeout: 180_000,
  },
});
