import {
  test,
  expect,
  openFixtureOrder,
  signInAsFixtureBuyer,
  useFixtureBackend,
} from "./fixtures";

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

  test("asking to buy replaces the landing view rather than appending to it", async ({ page }) => {
    // The old page stacked hero, chooser, form and explainers in one column.
    await page.goto("/");
    await page.locator("#start-buy").click();
    await expect(page.locator("#buy-flow")).toBeVisible();
    await expect(page.locator("#view-landing")).toBeHidden();
    await expect(page.locator(".explainer").first()).toBeHidden();
  });

  test("Back returns to the landing view", async ({ page }) => {
    await page.goto("/");
    await page.locator("#start-buy").click();
    await expect(page).toHaveURL(/#\/buy$/);
    await page.goBack();
    await expect(page.locator("#view-landing")).toBeVisible();
    await expect(page.locator("#buy-flow")).toBeHidden();
  });

  test("a mangled hash lands on the product, not an error", async ({ page }) => {
    await page.goto("/#/nonsense");
    await expect(page.locator("#view-landing")).toBeVisible();
  });

  // Two different reasons for the same absence, and the old single spec could not
  // tell them apart: it asserted "hidden while signed out with no orders", which
  // passes if the link is hidden for either reason, or for a third one nobody
  // intended. Each condition now has its own spec.
  test("the orders link is absent while signed OUT", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("#auth-area").getByRole("button")).toHaveText(/sign in/i);
    await expect(page.locator("#history-link")).toBeHidden();
  });

  test("the orders link is absent for a signed-IN buyer with no orders", async ({ page }) => {
    // The condition the previous spec could not reach at all: a session with an
    // empty history. `orderCount > 0 && identity !== null` could have lost either
    // half and stayed green.
    await page.goto("/");
    await useFixtureBackend(page);
    await signInAsFixtureBuyer(page);
    await expect(page.locator("#auth-area .principal")).toBeVisible();
    await expect(page.locator("#history-link")).toBeHidden();
  });

  test("the orders link appears once there is an order behind it", async ({ page }) => {
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "delivered" });
    await expect(page.locator("#history-link")).toBeVisible();
  });
});

test.describe("the stepper", () => {
  test("is absent on the landing view and present once buying", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("#stepper")).toBeHidden();
    await page.locator("#start-buy").click();
    await expect(page.locator("#stepper")).toBeVisible();
    await expect(page.locator("#stepper .step")).toHaveCount(4);
  });

  test("step 1 is the current step while signed out", async ({ page }) => {
    await page.goto("/");
    await page.locator("#start-buy").click();
    await expect(page.locator("#stepper .step").nth(0)).toHaveClass(/current/);
    await expect(page.locator("#stepper .step").nth(3)).toHaveClass(/todo/);
  });

  test("the hero still states the four steps, and the stepper repeats them", async ({ page }) => {
    // The headline promises four steps; the strip has to agree with it or one of
    // the two is lying.
    await page.goto("/");
    const hero = await page.locator(".flow-step").allInnerTexts();
    expect(hero).toHaveLength(4);
    await page.locator("#start-buy").click();
    const strip = await page.locator("#stepper .step").allInnerTexts();
    expect(strip).toHaveLength(4);
  });
});

test.describe("history is a view, not a footer", () => {
  test("the orders table is never on the landing screen", async ({ page }) => {
    // It was: `setIdentity` unhid `#history` directly while `renderView` also
    // owned it, so signing in pinned the table to the bottom of whatever was on
    // screen. Two owners of one decision, the same shape of bug as the chooser
    // that used to stand on the landing view.
    await page.goto("/");
    await expect(page.locator("#history")).toBeHidden();
    await page.locator("#start-buy").click();
    await expect(page.locator("#history")).toBeHidden();
  });

  test("the history route shows the table and nothing else", async ({ page }) => {
    await page.goto("/#/history");
    await expect(page.locator("#history")).toBeVisible();
    await expect(page.locator("#view-landing")).toBeHidden();
    await expect(page.locator("#buy-flow")).toBeHidden();
  });
});
