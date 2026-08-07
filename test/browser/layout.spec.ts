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

  test("prose holds the 720px measure inside the wider app shell", async ({ page }) => {
    // The shell is 1040px because tier grids and tables are DATA, not prose, and
    // squeezing them to the reading measure wraps columns that read better side
    // by side. The guidelines' 720px rule is about READING, so it is enforced on
    // the prose blocks rather than the container.
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto("/");
    const shell = await page.evaluate(
      () => document.querySelector("main")!.getBoundingClientRect().width,
    );
    expect(shell).toBeLessThanOrEqual(1040);

    // `.hero` is now the two-column GRID, so the measure lives on `.hero-copy`.
    // The figure beside it is a diagram, not prose, and is not bound by it.
    const proseWidths = await page.evaluate(() =>
      [...document.querySelectorAll(".lede, .explainer p, .hero-copy")].map(
        (n) => n.getBoundingClientRect().width,
      ),
    );
    expect(proseWidths.length).toBeGreaterThan(0);
    for (const w of proseWidths) expect(w).toBeLessThanOrEqual(720);
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

test.describe("the four-step hero figure", () => {
  test("every step is legible at rest, not only while animating", async ({ page }) => {
    // The animation raises attention; it must not CARRY information. A step that
    // is invisible between pulses would hide the sequence from anyone who looks
    // at the wrong moment, screenshots the page, or disables motion.
    await page.goto("/");
    for (let i = 0; i < 4; i += 1) {
      const step = page.locator(".flow-step").nth(i);
      await expect(step).toBeVisible();
      const opacity = await step.evaluate((n) => Number(getComputedStyle(n).opacity));
      expect(opacity).toBeGreaterThanOrEqual(0.5);
    }
  });

  test("reduced motion removes the animation entirely", async ({ page }) => {
    // Not slowed down: removed. Every step rests fully legible, so dropping the
    // motion loses nothing.
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto("/");
    const states = await page.evaluate(() =>
      [...document.querySelectorAll(".flow-step")].map((n) => ({
        animation: getComputedStyle(n).animationName,
        opacity: getComputedStyle(n).opacity,
      })),
    );
    for (const s of states) {
      expect(s.animation).toBe("none");
      expect(Number(s.opacity)).toBe(1);
    }
    const pulse = await page.evaluate(
      () => getComputedStyle(document.querySelector(".flow")!, "::after").display,
    );
    expect(pulse).toBe("none");
  });

  test("the hero is two columns on desktop and one on a phone", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto("/");
    const wide = await page.evaluate(
      () => getComputedStyle(document.querySelector(".hero")!).gridTemplateColumns.split(" ").length,
    );
    expect(wide).toBe(2);

    await page.setViewportSize({ width: 390, height: 844 });
    const narrow = await page.evaluate(
      () => getComputedStyle(document.querySelector(".hero")!).gridTemplateColumns.split(" ").length,
    );
    expect(narrow).toBe(1);
  });
});
