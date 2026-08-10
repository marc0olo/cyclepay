import { test, expect, useFixtureBackend } from "./fixtures";

/// Pixel baselines for the two surfaces a visitor decides on, in both themes.
///
/// These cover the class of bug no assertion in this suite can reach: PAINT.
/// Text the same colour as its background, an element covering another, an
/// opacity that makes something technically visible and practically not — every
/// one of those passes `toBeVisible()`, passes a `getComputedStyle` check on the
/// property somebody thought to check, and is obvious in a picture.
///
/// **A baseline is only evidence if a human looked at it.** These were reviewed
/// when first generated. Update them deliberately:
///
///   npm --prefix test/browser test -- --update-snapshots visual.spec.ts
///
/// and look at the new PNGs before committing them.
///
/// Baselines are per-platform (Playwright suffixes the file with `darwin`/`linux`)
/// because font rasterisation differs. CI runs ubuntu-latest x86_64, so the
/// `-linux` files are the ones it compares against and both sets are committed.
///
/// The linux set is generated in the image CI's own action installs, pinned to the
/// same Playwright version, and forced to amd64 so the rasterisation matches CI
/// rather than the arm64 host. It builds NOTHING inside the container — a macOS
/// `node_modules` cannot run there — and it works on a COPY, because
/// `test/browser/node_modules` is committed in this repo and an `npm ci` inside the
/// container would rewrite it with linux artifacts:
///
///   npm --prefix src/frontend run build:fixtures
///   docker run --rm --platform linux/amd64 -v "$PWD:/w" \
///     mcr.microsoft.com/playwright:v1.62.1-noble bash -lc '
///       mkdir -p /run/b/test/browser /run/b/src/frontend
///       cp /w/test/browser/*.ts /w/test/browser/package*.json /run/b/test/browser/
///       cp -r /w/src/frontend/dist-fixtures /run/b/src/frontend/dist-fixtures
///       cd /run/b/test/browser && npm ci
///       CYCLEPAY_SKIP_BUILD=1 npx playwright test visual.spec.ts --update-snapshots
///       cp visual.spec.ts-snapshots/*linux.png /w/test/browser/visual.spec.ts-snapshots/'
///
/// The market comes from the fixture backend, so the amounts, the rate strip and
/// the fee line are fixed numbers rather than whatever a gateway last said. Under
/// the unreachable-gateway default these shots would be pictures of an error
/// state, which is not the thing worth pinning.

/// Everything that makes a shot reproducible: no motion, fonts settled, one
/// viewport.
async function settleForShot(page: import("@playwright/test").Page): Promise<void> {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.evaluate(() => document.fonts.ready);
}

const shot = { animations: "disabled", fullPage: true } as const;

test.describe("visual baselines", () => {
  test("the landing view, light", async ({ page }) => {
    await page.goto("/");
    await settleForShot(page);
    await expect(page.locator("#chooser")).toBeVisible();
    await expect(page).toHaveScreenshot("landing-light.png", shot);
  });

  test("the landing view, dark", async ({ page }) => {
    // Dark is opt-in, and it is where a missing token shows up as one flat block.
    await page.goto("/");
    await page.locator("#theme-toggle").click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
    await settleForShot(page);
    await expect(page).toHaveScreenshot("landing-dark.png", shot);
  });

  test("the buy view with real amounts, light", async ({ page }) => {
    await page.goto("/");
    await useFixtureBackend(page);
    await page.locator("#choose-new").click();
    await expect(page.locator("#buy-flow")).toBeVisible();
    // Wait for the priced tiles rather than the empty grid.
    await expect(page.locator("#tiers button.tier")).toHaveCount(3);
    await settleForShot(page);
    await expect(page).toHaveScreenshot("buy-light.png", shot);
  });

  test("the buy view with real amounts, dark", async ({ page }) => {
    await page.goto("/");
    await page.locator("#theme-toggle").click();
    await useFixtureBackend(page);
    await page.locator("#choose-new").click();
    await expect(page.locator("#tiers button.tier")).toHaveCount(3);
    await settleForShot(page);
    await expect(page).toHaveScreenshot("buy-dark.png", shot);
  });
});
