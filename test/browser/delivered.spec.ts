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
    // ⚠️ The tour lives on its OWN view now. It used to sit on the order record and
    // lead, with the facts collapsed beneath it — which is how the delivered view
    // came to show no cycle quantity at all. Following the link is what a buyer does.
    await page.locator("#order-next-link").click();

    const tour = page.locator("#cli-steps");
    await expect(tour).toBeVisible();
    // Visible, not merely un-`hidden`. The whole reason this suite exists.
    await expect(page.locator("#cmd-link")).toBeVisible();
    await expect(page.locator("#cmd-link")).toContainText("icp identity link web");
    // ⚠️ The full four-step sequence, in order, in a real browser. Step 2
    // (`icp identity default`) was missing from this page entirely: without it a buyer
    // links, verifies, sees a match, then deploys as whatever their default identity
    // was — a different principal with an empty balance.
    await expect(page.locator("#cmd-default")).toHaveText("icp identity default cyclepay-id");
    await expect(page.locator("#cmd-principal")).toHaveText("icp identity principal");
    await expect(page.locator("#cmd-balance")).toHaveText("icp cycles balance");
    await expect(page.locator("#cmd-deploy")).toHaveText("icp deploy -e ic");
    // The numerals come from the list counter, so a browser is the only place the
    // buyer's actual "step 1, 2, 3, 4" can be checked at all.
    await expect(page.locator("#cli-steps > li")).toHaveCount(4);
    // And the guide points at the version the commands were verified against.
    await expect(page.locator("#cli-guide")).toHaveAttribute("href", /\/1\.4\//);
    // The command must name THIS origin, or it derives a different principal and
    // the buyer lands on an empty balance.
    await expect(page.locator("#cmd-link")).toContainText(`--app ${new URL(page.url()).host}`);
    await expect(page.locator("#credited-principal")).toHaveText(await fixturePrincipal(page));
    // The quantity, which the collapsed version never stated anywhere.
    // The quantity comes from the LEDGER now, not from the order this page used to be
    // scoped to: what there is to spend is the question the page answers.
    await expect(page.locator("#cli-summary")).toContainText(/in your account/i);
    // One view owns the screen: the record is not also on it.
    await expect(page.locator("#active-order")).toBeHidden();
  });

  test("⚠️ the order record shows the numbers, with nothing collapsed over them", async ({ page }) => {
    // The defect this pins. `order-problems` and `receipt-area` were NESTED inside a
    // `<details id="order-details">` that the app collapsed on the delivered view, so
    // the one page a buyer opens to see what they got showed no cycle quantity, hid
    // the receipt two clicks deep, and buried a problem notice behind one. Nothing
    // hid them; the nesting did.
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "delivered" });

    await expect(page.locator("#order-cycles")).toBeVisible();
    await expect(page.locator("#order-cycles")).not.toHaveText("");
    // The receipt, and its ledger link, with no disclosure to open.
    await expect(page.locator("#receipt-area")).toBeVisible();
    await expect(page.locator("#receipt-verdict")).toBeVisible();
    await expect(page.locator("#receipt-block a")).toHaveAttribute(
      "href",
      /dashboard\.internetcomputer\.org\/tokens\/.*\/transaction\//,
    );
    // And no step strip: the four steps are a promise about buying, and a receipt
    // with a progress bar on it answers a question nobody asked here.
    await expect(page.locator("#stepper")).toBeHidden();
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
    await expect(page.locator("#cli-steps")).toBeHidden();

    await setFixtureStatus(page, "delivered");

    // The poll ticks every 3 s; this waits for the app to notice on its own.
    // ⚠️ What it brings up is the RECORD's delivered state and the way onward, not the
    // tour: the record no longer turns into the guidance.
    await expect(page.locator("#order-next-row")).toBeVisible({ timeout: 15_000 });
    await expect(page.locator("#receipt-verdict")).toContainText(/verified/i);
    await expect(page.locator("#cli-steps")).toBeHidden();
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
    await expect(page.locator("#cli-steps")).toBeHidden();
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

  test("⚠️ a dashboard row is a LINK to the order, and there is no buy-again", async ({ page }) => {
    // The button is gone: it rendered on every row including unpaid ones, where the
    // one-open-order cap refuses the very order it offered to start. And a row that
    // only responded to `tr.onclick` showed no destination and could not be tabbed
    // to, which is an affordance property only a browser can see.
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "delivered" });
    await page.locator("#history-link").click();
    await expect(page.locator("#history")).toBeVisible();

    await expect(page.locator("button.buy-again")).toHaveCount(0);
    // The balance leads the dashboard, read from the ledger rather than from us.
    await expect(page.locator("#ledger-balance")).toBeVisible();

    const link = page.locator(".orders-table a.order-link").first();
    await expect(link).toBeVisible();
    await link.click();
    await expect(page.locator("#active-order")).toBeVisible();
    await expect(page.locator("#history")).toBeHidden();
    await expect(page).toHaveURL(/#\/order\//);
  });

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

test.describe("the dashboard's two records, in a real browser", () => {
  /// ⚠️ **The only place the whole chain runs unmocked.** jsdom can assert that a
  /// panel's `hidden` flag flipped; it cannot tell you the tab highlight is visible or
  /// that clicking the link navigates. Both of those are what a buyer actually uses to
  /// tell two similar tables apart.
  test("clicking a tab switches the record and moves the highlight", async ({ page }) => {
    await page.goto("/#/history");
    await signInAsFixtureBuyer(page);

    // The bare hash is the orders record.
    await expect(page.locator("#panel-orders")).toBeVisible();
    await expect(page.locator("#panel-ledger")).toBeHidden();
    await expect(page.locator("#tab-orders")).toHaveAttribute("aria-current", "true");
    await expect(page.locator("#tab-ledger")).not.toHaveAttribute("aria-current", "true");

    await page.locator("#tab-ledger").click();

    // The tab is a LINK, so the selection is in the address bar and Back works.
    await expect(page).toHaveURL(/#\/history\/ledger$/);
    await expect(page.locator("#panel-ledger")).toBeVisible();
    await expect(page.locator("#panel-orders")).toBeHidden();
    await expect(page.locator("#tab-ledger")).toHaveAttribute("aria-current", "true");
    await expect(page.locator("#tab-orders")).not.toHaveAttribute("aria-current", "true");

    // ⚠️ The highlight must be more than a colour: the selected tab carries a rule and
    // heavier text, so it survives a colour-blind reader and forced-colours mode.
    const selectedWeight = await page.locator("#tab-ledger").evaluate(
      (n) => getComputedStyle(n).fontWeight,
    );
    const otherWeight = await page.locator("#tab-orders").evaluate(
      (n) => getComputedStyle(n).fontWeight,
    );
    expect(Number(selectedWeight)).toBeGreaterThan(Number(otherWeight));

    await page.goBack();
    await expect(page.locator("#panel-orders")).toBeVisible();
  });

  test("a delivery row in the ledger links back to its order", async ({ page }) => {
    // The fixture's delivery transfer is sent FROM the gateway principal and memoed
    // with the order id, which is the only combination the cross-reference trusts.
    //
    // The order is opened first because `get_order` answers with whatever order the
    // fixture is standing in: without one, the link would resolve to the missing-order
    // view and this would prove only that the href was well-formed.
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "delivered" });

    await page.locator("#history-link").click();
    await page.locator("#tab-ledger").click();
    await expect(page.locator("#panel-ledger")).toBeVisible();

    const orderLink = page.locator('#ledger-history a[href^="#/order/"]').first();
    await expect(orderLink).toBeVisible();
    await orderLink.click();
    // It resolves: the id in the memo is one the router and the backend both accept.
    await expect(page.locator("#active-order")).toBeVisible();
  });

  test("the ledger table's column count matches its headers", async ({ page }) => {
    // Regression guard: this table once shipped six headers and five cells, which
    // shifted every column after the gap so each row read one field to the left.
    await page.goto("/#/history/ledger");
    await signInAsFixtureBuyer(page);
    const headers = await page.locator("#ledger-history thead th").count();
    const cells = await page.locator("#ledger-history tbody tr").first().locator("td").count();
    expect(cells).toBe(headers);
  });
});

test.describe("the CLI page is reachable without an order", () => {
  test("straight from the dashboard, no order in play", async ({ page }) => {
    // The reason it stopped being order-scoped: a buyer who bought last week has no
    // order in mind, they want to spend the balance. Verified in a real browser
    // because the route, the view machine and the identity all take part.
    await page.goto("/");
    await signInAsFixtureBuyer(page);
    await page.goto("/#/history");
    await page.locator("#cli-link").click();

    await expect(page).toHaveURL(/#\/cli$/);
    await expect(page.locator("#view-cli")).toBeVisible();
    await expect(page.locator("#cmd-link")).toBeVisible();
    await expect(page.locator("#cmd-link")).toContainText("icp identity link web");
    // Never the missing-order page, which is what an order-scoped route showed here.
    await expect(page.locator("#order-missing")).toBeHidden();
    // And no numbered journey: the visitor may not be on one.
    await expect(page.locator("#stepper")).toBeHidden();
  });

  test("a deep link to it works cold, with no navigation history", async ({ page }) => {
    await page.goto("/#/cli");
    await signInAsFixtureBuyer(page);
    await expect(page.locator("#view-cli")).toBeVisible();
    await expect(page.locator("#credited-principal"))
      .toHaveText(await fixturePrincipal(page));
  });
});
