import {
  test,
  expect,
  openFixtureOrder,
  signInAsFixtureBuyer,
  useFixtureBackend,
} from "./fixtures";

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
/// ⚠️ **Baselines are LINUX-ONLY, and these tests skip on any other platform.**
/// Playwright suffixes per platform because font rasterisation differs, so a
/// darwin set was committed alongside — and it bought a signal for a rasteriser
/// nothing ships on, at a second set to regenerate on every deliberate change.
/// Worse, a Mac cannot repair the `-linux` half that CI actually compares against
/// (see below), so the darwin half could never substitute for it. Linux-only makes
/// every failure reproducible where it is checked.
///
/// **The `-linux` set has to come from the CI runner itself.** Generating it in
/// `mcr.microsoft.com/playwright:v1.62.1-noble` at `--platform linux/amd64` —
/// the same image and architecture CI uses — was tried first and produced ~2,400
/// differing pixels against the runner, all of it text antialiasing. Same image is
/// not the same rasteriser.
///
/// So the procedure is: push, let CI fail, and take its own renders. The
/// `browser-failures` artifact (uploaded on failure by the workflow) contains
/// `*-actual.png` for every mismatch. **Look at them**, then copy them over the
/// `-linux` baselines and push again. Two consecutive attempts in one CI run were
/// byte-identical, so the runner is deterministic enough for this to be stable
/// until the runner image itself changes.
///
/// Tolerance stays at Playwright's default (zero differing pixels above the 0.2
/// colour threshold) on purpose. The defect these baselines found — a 5px dot and
/// a 1px hairline painted over four digits — is about a hundred pixels, so any
/// tolerance loose enough to absorb cross-environment noise would also have hidden
/// it. Regenerating on a runner-image bump is the price of that.
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
  // ⚠️ Linux-only: the committed baselines come from the CI runner, and comparing a
  // macOS rasteriser against them produced ~2,400 differing pixels of pure antialiasing.
  // Skipping is honest about where this coverage lives; a local run reporting green
  // against a baseline it cannot reproduce would not be.
  test.skip(process.platform !== "linux", "baselines are generated on the CI runner");

  test("the landing view, light", async ({ page }) => {
    await page.goto("/");
    await settleForShot(page);
    await expect(page.locator("#start-buy")).toBeVisible();
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
    await page.locator("#start-buy").click();
    await expect(page.locator("#buy-flow")).toBeVisible();
    // Wait for the priced tiles rather than the empty grid.
    await expect(page.locator("#tiers button.tier")).toHaveCount(3);
    await settleForShot(page);
    await expect(page).toHaveScreenshot("buy-light.png", shot);
  });

  test("the delivered view, with the tour leading", async ({ page }) => {
    // The surface with the worst history in this repo: it shipped broken twice,
    // both times because nothing could reach it. It is also the one where paint
    // matters most — two shell commands the buyer has to read and copy exactly.
    // Deterministic by construction: the order id, the credited principal, the
    // receipt figures and the `--app` domain are all fixed by the fixture.
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "delivered" });
    await expect(page.locator("#cmd-link")).toBeVisible();
    await settleForShot(page);
    await expect(page).toHaveScreenshot("delivered-light.png", shot);
  });

  test("the buy view with real amounts, dark", async ({ page }) => {
    await page.goto("/");
    await page.locator("#theme-toggle").click();
    await useFixtureBackend(page);
    await page.locator("#start-buy").click();
    await expect(page.locator("#tiers button.tier")).toHaveCount(3);
    await settleForShot(page);
    await expect(page).toHaveScreenshot("buy-dark.png", shot);
  });
});
