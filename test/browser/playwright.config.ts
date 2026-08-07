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
/// Serves the **built** `dist/` over a plain static server, not `vite dev`.
/// Two reasons, both load-bearing:
///   - `vite.config.ts` shells out to `icp network status` at config load, so dev
///     mode cannot start without a running local network. These specs must not
///     need one, or they will not run in CI and will rot.
///   - `dist/` is the artifact that actually ships. A bundler transform that only
///     breaks in production is exactly the sort of thing a dev-server spec misses.
///
/// The backend is unreachable on purpose (see fixtures.ts): what renders must not
/// depend on the gateway answering.
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
      "npm --prefix ../../src/frontend run build" +
      " && python3 -m http.server 5178 --bind 127.0.0.1 --directory ../../src/frontend/dist",
    url: "http://localhost:5178",
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
  },
});
