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
/// surface of this app — shipped broken twice, and both times the only evidence
/// it worked came from injecting DOM state, which a test can pass against while a
/// visitor sees nothing.
///
/// The hook replaces the BACKEND and nothing else (see fixtures.ts), so sign-in,
/// routing, the view machine, the 3 s poll and every render below are the app's.
test.describe("the delivered view", () => {
  test("the tour is on screen and legible, with the real commands", async ({ page }) => {
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "delivered" });

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
  });

  test("the POLL brings the tour up, with no navigation at all", async ({ page }) => {
    // What a buyer actually does: create, pay, wait. They never navigate again,
    // so the poll is the only thing that can reach the delivered view — and it
    // did not, because it repainted the order facts without re-running the view
    // machine. Nothing outside a browser could see that.
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "paid" });
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

  test("a payable order offers a REACHABLE pay button, and a reload keeps it", async ({ page }) => {
    // The defect this pins was found in a manual run, not by a test: the session
    // URL lived in a browser-session `Map`, so any reload lost the pay button on
    // an order that was still payable. With a one-open-order cap the buyer could
    // not even start over.
    //
    // Here rather than only in jsdom because jsdom cannot tell "in the DOM" from
    // "on screen and clickable" — and the button being *reachable* is the whole
    // property. `toBeVisible` plus a real href is what a buyer actually needs.
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "created" });
    const pay = page.locator("#pay-link");
    await expect(pay).toBeVisible();
    await expect(pay).toHaveAttribute("href", /^https:\/\/checkout\.stripe\.com\//);

    // The reload. Nothing was cached, because `create_order` never ran.
    await page.reload();
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "created" });
    await expect(page.locator("#pay-link")).toBeVisible();
    await expect(page.locator("#pay-link")).toHaveAttribute("href", /^https:\/\/checkout\.stripe\.com\//);
  });

  test("an undelivered order is offered no commands yet", async ({ page }) => {
    // The two cases that used to suppress the tour — a canister top-up, with
    // nothing to link, and somebody else's account, which the buyer's identity
    // cannot reach — are destinations `create_order` refuses (#29), so their
    // specs went with them. Status is the only thing left that withholds it.
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "paid" });
    await expect(page.locator("#active-order")).toBeVisible();
    await expect(page.locator("#tour")).toBeHidden();
  });
});

test.describe("one view owns the screen, under a live poll", () => {
  test("a poll tick does not repaint the order over the orders table", async ({ page }) => {
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "paid" });
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
    await openFixtureOrder(page, { status: "delivered" });
    await page.locator("#history-link").click();
    await expect(page.locator("#history")).toBeVisible();

    await page.locator("button.buy-again").first().click();
    await expect(page.locator("#buy-flow")).toBeVisible();
    await expect(page.locator("#history")).toBeHidden();
    await expect(page).toHaveURL(/#\/buy$/);
    // The amount is the whole prefill now: the destination is the caller's own
    // account, so there is no field to carry it into (#29).
    await expect(page.locator("button.tier.selected")).toBeVisible();
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

  test("#/buy is a bookmarkable route, not a redirect", async ({ page }) => {
    // It used to send the visitor back to the chooser: with no arm picked the
    // form had no destination question on it at all. With one destination the
    // form is complete on arrival (#29), so a deep link has to resolve to it.
    await page.goto("/#/buy");
    await expect(page.locator("#buy-flow")).toBeVisible();
    await expect(page.locator("#view-landing")).toBeHidden();
  });
});
