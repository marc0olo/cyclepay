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

  test("all three brand faces load, and each is actually applied", async ({ page }) => {
    await page.goto("/");
    // A self-hosted face that 404s falls back silently to something that looks
    // close enough to miss in a screenshot. Newsreader was the only one checked,
    // so Inter and JetBrains Mono could 404 unnoticed — and they carry the body
    // copy and every CLI command on the page between them.
    const faces = await page.evaluate(async () => {
      await document.fonts.ready;
      return [...document.fonts].map((f) => `${f.family}/${f.style}:${f.status}`);
    });
    for (const family of ["Newsreader", "Inter", "JetBrains Mono"]) {
      expect(faces.join(" "), `${family} did not load`).toContain(`${family}/normal:loaded`);
    }
    // The italic Newsreader is a separate file, and the display face is used
    // italic in every headline the brand rules emphasise.
    expect(faces.join(" ")).toContain("Newsreader/italic:loaded");

    // Loaded is not applied. Each face has to reach the element it is for.
    const applied = await page.evaluate(() => ({
      display: getComputedStyle(document.querySelector("h1")!).fontFamily,
      // `.meta-strip`, not `.lede`: the lede is prose and takes the DISPLAY face
      // by design. Inter carries the UI text around it.
      ui: getComputedStyle(document.querySelector(".meta-strip")!).fontFamily,
      mono: getComputedStyle(document.querySelector("code.flow-detail")!).fontFamily,
    }));
    expect(applied.display).toContain("Newsreader");
    expect(applied.ui).toContain("Inter");
    expect(applied.mono).toContain("JetBrains Mono");
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

  test("the connector and the pulse never touch a step number", async ({ page }) => {
    // Found by a screenshot, and invisible to every other assertion in this suite.
    // The connector runs through the node centres and the pulse travels along it,
    // so both cross each numeral. As absolutely-positioned pseudo elements they
    // painted ON TOP: the hairline ran down through every digit and the 5px rust
    // dot parked on the "1" and erased it. Visibility passed, opacity passed, the
    // font checks passed; the digit simply was not there.
    //
    // The fix is that they are BACKGROUND LAYERS of `.flow` rather than
    // absolutely-positioned pseudo elements. That is what this asserts, and the
    // assertion is structural on purpose: "a background paints below its own
    // element's content" is a guarantee of the box model, whereas z-index here is
    // not. Two z-index arrangements were tried and measured at 8x magnification —
    // sinking the pseudo elements to -1, and raising the steps to 1 — and neither
    // moved the dot off the digit, because `.flow-step` animates its opacity and
    // so composites separately.
    //
    // A pixel-equality check cannot stand in for this: `.flow-step` dims to
    // opacity 0.55, which makes the node's fill translucent, so a decoration
    // BEHIND it still tints the numeral slightly. Legible, and the point — the
    // pulse passes behind the node rather than over the number.
    await page.goto("/");
    const figure = await page.evaluate(() => {
      const flow = document.querySelector(".flow")!;
      const cs = getComputedStyle(flow);
      return {
        image: cs.backgroundImage,
        animation: cs.animationName,
        // No decoration may return to a pseudo element. `content: none` means the
        // pseudo element is not generated at all.
        before: getComputedStyle(flow, "::before").content,
        after: getComputedStyle(flow, "::after").content,
      };
    });
    // The pulse and the connector, in that order.
    expect(figure.image).toContain("radial-gradient");
    expect(figure.image).toContain("linear-gradient");
    expect(figure.animation).toBe("flow-pulse");
    expect(figure.before).toBe("none");
    expect(figure.after).toBe("none");
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
    // The pulse is a background layer, so "removed" means the layer is gone —
    // otherwise the dot would sit parked on the first node forever, which is a
    // smudge rather than a resting state. The connector layer stays.
    const flow = await page.evaluate(() => {
      const cs = getComputedStyle(document.querySelector(".flow")!);
      return { animation: cs.animationName, image: cs.backgroundImage };
    });
    expect(flow.animation).toBe("none");
    expect(flow.image).not.toContain("radial-gradient");
    expect(flow.image).toContain("linear-gradient");
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
