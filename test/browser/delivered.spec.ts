import {
  test,
  expect,
  fixturePrincipal,
  openFixtureOrder,
  setFixtureStatus,
  signInAsFixtureBuyer,
} from "./fixtures";

/// The post-purchase surfaces, in a real browser, for the first time.
///
/// Everything here was previously unreachable from any browser: getting to a
/// delivered order needs an Internet Identity session, a funded local network, a
/// Stripe payment and a signed webhook. So the delivered view — the flagship
/// surface of the two-audience flow — shipped broken twice, and both times the
/// only evidence it worked came from injecting DOM state, which a test can pass
/// against while a visitor sees nothing.
///
/// The hook replaces the BACKEND and nothing else (see fixtures.ts), so sign-in,
/// routing, the view machine, the 3 s poll and every render below are the app's.
test.describe("the delivered view", () => {
  test("the tour is on screen and legible, with the real commands", async ({ page }) => {
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "delivered", destination: "account" });

    const tour = page.locator("#tour");
    await expect(tour).toBeVisible();
    // Visible, not merely un-`hidden`. The whole reason this suite exists.
    await expect(page.locator("#cmd-link")).toBeVisible();
    await expect(page.locator("#cmd-link")).toContainText("icp identity link web");
    await expect(page.locator("#cmd-verify")).toContainText("icp identity principal");
    // The command must name THIS origin, or it derives a different principal and
    // the buyer lands on an empty balance.
    await expect(page.locator("#cmd-link")).toContainText(`--app ${new URL(page.url()).host}`);
    await expect(page.locator("#credited-principal")).toHaveText(await fixturePrincipal(page));

    // On delivery the next action leads and the facts collapse beneath it.
    await expect(page.locator("#order-details")).not.toHaveAttribute("open", /.*/);
    await expect(page.locator("#tour-third-party")).toBeHidden();
  });

  test("the POLL brings the tour up, with no navigation at all", async ({ page }) => {
    // What a buyer actually does: create, pay, wait. They never navigate again,
    // so the poll is the only thing that can reach the delivered view — and it
    // did not, because it repainted the order facts without re-running the view
    // machine. Nothing outside a browser could see that.
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "paid", destination: "account" });
    await expect(page.locator("#active-order")).toBeVisible();
    await expect(page.locator("#tour")).toBeHidden();

    await setFixtureStatus(page, "delivered");

    // The poll ticks every 3 s; this waits for the app to notice on its own.
    await expect(page.locator("#tour")).toBeVisible({ timeout: 15_000 });
    await expect(page.locator("#cmd-link")).toBeVisible();
    // Step 3 of 4 is now the current step.
    await expect(page.locator("#stepper .step").nth(2)).toHaveClass(/current/);
    await expect(page.locator("#receipt-verdict")).toContainText(/verified/i);
  });

  test("a canister top-up is offered no commands, because it needs none", async ({ page }) => {
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "delivered", destination: "canister" });
    await expect(page.locator("#active-order")).toBeVisible();
    await expect(page.locator("#tour")).toBeHidden();
    // And no four-step strip promising two steps that never complete.
    await expect(page.locator("#stepper")).toBeHidden();
  });

  test("cycles credited to someone else's account promise the buyer nothing", async ({ page }) => {
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, {
      status: "delivered",
      destination: "account",
      thirdParty: true,
    });
    await expect(page.locator("#tour-third-party")).toBeVisible();
    // The commands would link the BUYER's identity, which is not the funded
    // account, so nothing about them may be on screen.
    await expect(page.locator("#tour-steps")).toBeHidden();
    await expect(page.locator("#cmd-link")).toBeHidden();
    await expect(page.locator("#stepper")).toBeHidden();
  });
});

test.describe("one view owns the screen, under a live poll", () => {
  test("a poll tick does not repaint the order over the orders table", async ({ page }) => {
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "paid", destination: "account" });
    await expect(page.locator("#active-order")).toBeVisible();

    await page.locator("#history-link").click();
    await expect(page.locator("#history")).toBeVisible();
    await expect(page.locator("#active-order")).toBeHidden();

    // Two poll intervals. The order must not come back.
    await page.waitForTimeout(7_000);
    await expect(page.locator("#active-order")).toBeHidden();
    await expect(page.locator("#history")).toBeVisible();
  });

  test("buy again from the orders table lands on the form", async ({ page }) => {
    // It prefilled the form and never navigated, so from the orders table — the
    // only place the button exists — one click plus payment did nothing visible.
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "delivered", destination: "canister" });
    await page.locator("#history-link").click();
    await expect(page.locator("#history")).toBeVisible();

    await page.locator("button.buy-again").first().click();
    await expect(page.locator("#buy-flow")).toBeVisible();
    await expect(page.locator("#history")).toBeHidden();
    await expect(page).toHaveURL(/#\/buy$/);
    await expect(page.locator("#canister-principal")).toHaveValue(/.+/);
  });
});

test.describe("routes that name nothing", () => {
  test("an unknown order id says so instead of showing an empty panel", async ({ page }) => {
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await page.goto("/#/order/deadbeefdeadbeefdeadbeefdeadbeef");
    await expect(page.locator("#order-missing")).toBeVisible();
    await expect(page.locator("#order-missing")).toContainText(/could not find that order/i);
    await expect(page.locator("#active-order")).toBeHidden();
  });

  test("#/buy with no arm chosen shows the chooser", async ({ page }) => {
    // Deep-linked, this rendered an amount grid with no destination question on
    // screen at all.
    await page.goto("/#/buy");
    await expect(page.locator("#chooser")).toBeVisible();
    await expect(page.locator("#buy-flow")).toBeHidden();
  });
});
