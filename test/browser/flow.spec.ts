import { test, expect } from "./fixtures";

/// Reachability, not state transitions. The question each spec asks is "can a
/// person actually get to the next step from here", which is what the jsdom
/// suite cannot answer: it can click a disabled button, read a hidden one, and
/// never notice a dead end.
test.describe("sign-in is reachable from the flow", () => {
  test("the CTA offers sign-in rather than dead-ending", async ({ page }) => {
    // It used to read "Sign in to continue" and be permanently disabled, so the
    // only way forward was a header button — not where someone who has just
    // picked an amount is looking.
    await page.goto("/");
    await page.locator("#start-buy").click();
    const cta = page.locator("#create-order");
    await expect(cta).toBeVisible();
    await expect(cta).toBeEnabled();
    await expect(cta).toHaveText(/sign in/i);
  });

  test("the header offers sign-in without naming the mechanism", async ({ page }) => {
    // "Sign in with Internet Identity" above the fold reimports the vocabulary
    // the Google-plus-card path exists to delete.
    await page.goto("/");
    const header = page.locator("#auth-area");
    await expect(header.getByRole("button")).toHaveText(/^sign in$/i);
    // Nothing VISIBLE names the mechanism. The delivered tour does name Internet
    // Identity, deliberately: the CLI-access prerequisite is real and omitting it
    // strands the buyer at "CLI access not enabled". That surface is post-purchase
    // and technical, which is where #21 confines the vocabulary.
    await expect(
      page.getByText(/internet identity/i).filter({ visible: true }),
    ).toHaveCount(0);
  });

  test("no crypto vocabulary is in the prose before sign-in", async ({ page }) => {
    // The vocabulary policy: wallet, on-ramp, token, custody, seed phrase and
    // friends are confined to the FAQ, which does not exist yet, so none may
    // appear at all.
    //
    // Prose only, with <code> stripped: the CLI binary is literally named `icp`,
    // so the command strip necessarily contains it. The rule is about the token
    // in newcomer copy, not about the tool's name.
    //
    // "exchange account" is deliberately absent from this list: issue #21 carves
    // out one use, at the end of the cycles explainer, because the preceding
    // sentence introduces the concept. A negation only alarms a reader who did
    // not already have the worry.
    // The LANDING surface specifically: header, hero, the call to action,
    // explainers, footer. Not the whole body — the receipt block names the Exchange Rate
    // Canister and USD/ICP on purpose, and it is hidden, below the fold, and
    // aimed at a skeptic who has already bought. A detached clone loses
    // visibility, so it must be scoped by selector rather than filtered.
    await page.goto("/");
    const prose = await page.evaluate(() => {
      const parts: string[] = [];
      for (const section of document.querySelectorAll(
        ".site-header, .hero, .start-row, .explainer, .site-footer",
      )) {
        const clone = section.cloneNode(true) as HTMLElement;
        clone.querySelectorAll("code").forEach((n) => n.remove());
        parts.push(clone.textContent ?? "");
      }
      return parts.join("\n");
    });
    for (const word of [
      /wallet/i, /on-ramp/i, /seed phrase/i, /custody/i,
      /stablecoin/i, /blockchain/i, /on-chain/i, /\bICP\b/,
    ]) {
      expect(prose, `banned vocabulary ${word} in page prose`).not.toMatch(word);
    }
  });
});

test.describe("the hero states the sequence", () => {
  test("the four steps are on screen, with the real command", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("h1")).toContainText(/from zero to deployed/i);
    const steps = page.locator(".flow-step");
    await expect(steps).toHaveCount(4);
    await expect(steps.nth(2)).toContainText("icp identity link web");
  });

  test("the fee is disclosed beside the rate claim", async ({ page }) => {
    // "At the protocol exchange rate" alone is not true net of card processing,
    // and this is the page where that gets read carefully.
    await page.goto("/");
    await expect(page.locator("#rate-claim")).toContainText(/card processing/i);
  });
});

test.describe("failures stay human", () => {
  test("an unreachable gateway says so, and offers a retry", async ({ page }) => {
    // The backend is unreachable in these specs by construction, so this is the
    // real error path rather than a simulated one.
    await page.goto("/");
    await page.locator("#start-buy").click();
    const line = page.locator("#rate-line");
    await expect(line).toContainText(/could not reach the gateway/i);
    await expect(line.getByRole("button", { name: /try again/i })).toBeVisible();
  });

  test("no raw agent or HTTP error is ever printed", async ({ page }) => {
    await page.goto("/");
    await page.locator("#start-buy").click();
    const body = await page.locator("body").innerText();
    // The shapes agent errors take. Any of these on screen is a leak.
    expect(body).not.toMatch(/AgentError|Call failed:|read_state|\bfetch\b|HTTP \d{3}|501|undefined/);
  });

  test("an empty tier list never claims the product is empty", async ({ page }) => {
    // "No amounts are configured yet" is a claim about the OPERATOR. While the
    // gateway is unreachable it is simply false — and the agent retries for
    // several seconds, so a two-state flag showed it for that entire window and
    // only corrected itself afterwards. A single assertion at the end could not
    // see that, so this checks the early window too.
    await page.goto("/");
    await page.locator("#start-buy").click();
    await expect(page.locator("#tiers")).toContainText(/loading amounts/i);
    await expect(page.locator("#tiers")).not.toContainText(/no amounts are configured/i);
    // And once the gateway has actually given up, it says what went wrong.
    await expect(page.locator("#tiers")).toContainText(/could not be loaded/i, {
      timeout: 15_000,
    });
    await expect(page.locator("#tiers")).not.toContainText(/no amounts are configured/i);
  });
});
