import { test, expect } from "./fixtures";

/// One view owns the screen, and Back works. Both are layout facts, so they
/// belong here rather than in jsdom.
test.describe("view routing", () => {
  test("the landing view is the only thing on screen at the start", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("#view-landing")).toBeVisible();
    await expect(page.locator("#buy-flow")).toBeHidden();
    await expect(page.locator("#active-order")).toBeHidden();
    await expect(page.locator("#history")).toBeHidden();
    // The explainers stay on the landing view, below the fold.
    await expect(page.locator(".explainer").first()).toBeVisible();
  });

  test("choosing an arm replaces the landing view rather than appending to it", async ({ page }) => {
    // The old page stacked hero, chooser, form and explainers in one column.
    await page.goto("/");
    await page.locator("#choose-live").click();
    await expect(page.locator("#buy-flow")).toBeVisible();
    await expect(page.locator("#view-landing")).toBeHidden();
    await expect(page.locator(".explainer").first()).toBeHidden();
  });

  test("Back returns to the landing view", async ({ page }) => {
    await page.goto("/");
    await page.locator("#choose-live").click();
    await expect(page).toHaveURL(/#\/buy$/);
    await page.goBack();
    await expect(page.locator("#view-landing")).toBeVisible();
    await expect(page.locator("#buy-flow")).toBeHidden();
  });

  test("a mangled hash lands on the product, not an error", async ({ page }) => {
    await page.goto("/#/nonsense");
    await expect(page.locator("#view-landing")).toBeVisible();
  });

  test("the orders link is absent with no orders", async ({ page }) => {
    // Signed out and with no history, a "Your orders" link leads nowhere.
    await page.goto("/");
    await expect(page.locator("#history-link")).toBeHidden();
  });
});

test.describe("the stepper", () => {
  test("is absent on the landing view and present once buying", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("#stepper")).toBeHidden();
    await page.locator("#choose-new").click();
    await expect(page.locator("#stepper")).toBeVisible();
    await expect(page.locator("#stepper .step")).toHaveCount(4);
  });

  test("step 1 is the current step while signed out", async ({ page }) => {
    await page.goto("/");
    await page.locator("#choose-new").click();
    await expect(page.locator("#stepper .step").nth(0)).toHaveClass(/current/);
    await expect(page.locator("#stepper .step").nth(3)).toHaveClass(/todo/);
  });

  test("the hero still states the four steps, and the stepper repeats them", async ({ page }) => {
    // The headline promises four steps; the strip has to agree with it or one of
    // the two is lying.
    await page.goto("/");
    const hero = await page.locator(".steps li").allInnerTexts();
    expect(hero).toHaveLength(4);
    await page.locator("#choose-new").click();
    const strip = await page.locator("#stepper .step").allInnerTexts();
    expect(strip).toHaveLength(4);
  });
});
