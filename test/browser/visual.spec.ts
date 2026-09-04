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
/// Baselines are per-platform (Playwright suffixes the file with `darwin`/`linux`)
/// because font rasterisation differs. CI runs ubuntu-latest x86_64, so the
/// `-linux` files are the ones it compares against and both sets are committed.
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

/// ── SUSPENDED for the UX phase (#107) ──────────────────────────────────────
///
/// Not disabled because they were wrong — they are the only thing in this repo that
/// can see PAINT, and they have already caught a 5px dot and a 1px hairline painted
/// over four digits. Disabled because a flow rewrite changes these pixels on purpose,
/// on every commit, and each refresh needs a full CI round-trip: the `-linux` half of
/// every baseline can only come from the runner (see the procedure above), so a Mac
/// cannot repair them locally. That is a round-trip per iteration for information we
/// already have — the pixels changed, that was the work.
///
/// ⚠️ **What is NOT covered while this is skipped**, and nothing else reaches it:
/// text the same colour as its background, an element covering another, an opacity
/// that renders something technically visible and practically not. Each of those
/// passes `toBeVisible()` and passes whichever `getComputedStyle` property someone
/// thought to check. Reviewing screenshots by hand is the stand-in, and it is a
/// weaker one.
///
/// ⚠️ **Re-enable via #107, not from memory.** Delete this `.skip`, regenerate BOTH
/// platforms (darwin locally, linux from a CI run's `browser-failures` artifact), and
/// LOOK at every PNG before committing — a baseline is only evidence if a human
/// looked at it, and one adopted blind pins whatever the page happened to render.
/// The issue exists because a code comment is the weakest possible reminder, and this
/// suite going quietly stale is exactly the failure it would produce.
test.describe.skip("visual baselines", () => {
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
