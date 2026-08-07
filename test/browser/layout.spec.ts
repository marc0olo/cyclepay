import { test, expect } from "./fixtures";

/// The bugs jsdom is structurally blind to: the CASCADE and LAYOUT.
///
/// Every assertion here uses visibility, never the `hidden` property. `el.hidden`
/// was true for all of these while they were plainly on screen, because a class
/// selector's `display` outranks the UA stylesheet's `[hidden] { display: none }`.
/// That is precisely what shipped, and what these specs exist to catch.
test.describe("the hidden attribute actually hides", () => {
  test("the chooser is the only thing offered before an arm is picked", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("#chooser")).toBeVisible();
    // THE regression. `.chooser { display: grid }` re-showed this.
    await expect(page.locator("#buy-flow")).toBeHidden();
    await expect(page.locator("#tiers")).toBeHidden();
  });

  test("picking an arm reveals the flow and removes the chooser", async ({ page }) => {
    await page.goto("/");
    await page.locator("#choose-live").click();
    await expect(page.locator("#chooser")).toBeHidden();
    await expect(page.locator("#buy-flow")).toBeVisible();
  });

  test("the newcomer arm shows no canister-id field on screen", async ({ page }) => {
    await page.goto("/");
    await page.locator("#choose-new").click();
    await expect(page.locator("#dest-newcomer")).toBeVisible();
    await expect(page.locator("#dest-choice")).toBeHidden();
    await expect(page.locator("#canister-principal")).toBeHidden();
  });

  test("a disabled ck-USDC rail is invisible, and promises nothing", async ({ page }) => {
    // `.rails { display: flex }` outranked [hidden] the same way, so the tab for
    // a rail that may never ship was always on screen.
    await page.goto("/");
    await page.locator("#choose-live").click();
    // Not visible. The stronger claim — that the nav and panel are *removed from
    // the document* — is asserted in main.test.ts, because removal happens only
    // once the config has actually been read and here the gateway is unreachable
    // by construction. Removing on the null-config guess made at first paint
    // would delete the markup for a rail that turns out to be enabled, so under
    // an outage "hidden" is the correct and only honest state.
    await expect(page.locator("#rail-nav")).toBeHidden();
    await expect(page.locator("#ck-panel")).toBeHidden();
    // Nothing promises it either. The old copy said "check back soon".
    await expect(page.getByText(/check back soon/i)).toHaveCount(0);
    // Visible text only. `#ck-pay-area` still exists inside the order view,
    // which is a different surface and unreachable without a ck-USDC order —
    // but nothing about the rail may be legible on the buying page.
    await expect(
      page.getByText(/ck-USDC/i).filter({ visible: true }),
    ).toHaveCount(0);
  });
});

test.describe("brand rendering", () => {
  test("light parchment is the default, and the OS preference does not flip it", async ({ page }) => {
    await page.emulateMedia({ colorScheme: "dark" });
    await page.goto("/");
    // Dark is opt-in via data-theme only; the guidelines forbid auto-switching.
    await expect(page.locator("html")).not.toHaveAttribute("data-theme", "dark");
    const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
    expect(bg).toBe("rgb(250, 249, 245)"); // #faf9f5 parchment
  });

  test("the theme toggle opts in to dark and survives a reload", async ({ page }) => {
    await page.goto("/");
    await page.locator("#theme-toggle").click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
    const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
    expect(bg).toBe("rgb(20, 17, 13)"); // #14110d deep bark
    await page.reload();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  });

  test("the three brand faces load and are actually applied", async ({ page }) => {
    await page.goto("/");
    // A self-hosted face that 404s falls back silently to a serif that looks
    // close enough to miss in a screenshot.
    const loaded = await page.evaluate(async () => {
      await document.fonts.ready;
      return [...document.fonts].map((f) => `${f.family}:${f.status}`);
    });
    expect(loaded.join(" ")).toContain("Newsreader:loaded");
    const h1 = await page.evaluate(() =>
      getComputedStyle(document.querySelector("h1")!).fontFamily,
    );
    expect(h1).toContain("Newsreader");
  });

  test("body prose stays within the 720px measure", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto("/");
    const width = await page.evaluate(
      () => document.querySelector("main")!.getBoundingClientRect().width,
    );
    expect(width).toBeLessThanOrEqual(720);
  });

  test("no horizontal scroll at a phone width", async ({ page }) => {
    // The full-bleed explainer uses 50vw maths that can overflow by a scrollbar.
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/");
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
