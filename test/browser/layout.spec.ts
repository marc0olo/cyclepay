import { test, expect, useFixtureBackend } from "./fixtures";

/// The bugs jsdom is structurally blind to: the CASCADE and LAYOUT.
///
/// Every assertion here uses visibility, never the `hidden` property. `el.hidden`
/// was true for all of these while they were plainly on screen, because a class
/// selector's `display` outranks the UA stylesheet's `[hidden] { display: none }`.
/// That is precisely what shipped, and what these specs exist to catch.
test.describe("the hidden attribute actually hides", () => {
  test("the landing view is the only thing offered before the visitor asks to buy", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("#start-buy")).toBeVisible();
    // THE regression, in its current form. It was `.chooser { display: grid }`
    // re-showing a chooser; the rule it broke is the one still under test here.
    await expect(page.locator("#buy-flow")).toBeHidden();
    await expect(page.locator("#tiers")).toBeHidden();
  });

  test("the call to action reveals the flow and removes the landing view", async ({ page }) => {
    await page.goto("/");
    await page.locator("#start-buy").click();
    await expect(page.locator("#view-landing")).toBeHidden();
    await expect(page.locator("#buy-flow")).toBeVisible();
  });

  test("the form states the destination and asks for no id", async ({ page }) => {
    // Not "the field is hidden": the field is GONE (#29), along with the radios
    // and the other-account disclosure. `toHaveCount(0)` is the assertion that a
    // reintroduced input cannot satisfy by being display:none.
    await page.goto("/");
    await page.locator("#start-buy").click();
    await expect(page.locator("#dest-own")).toBeVisible();
    await expect(page.locator("#canister-principal")).toHaveCount(0);
    await expect(page.locator("#dest-choice")).toHaveCount(0);
    await expect(page.locator("#dest-ledger-advanced")).toHaveCount(0);
    await expect(page.locator('input[name="dest-kind"]')).toHaveCount(0);
  });

  test("the deposit fee is disclosed without anything to toggle", async ({ page }) => {
    // It used to appear only after switching to the account destination. With one
    // destination it applies to every order, so it is on screen as soon as a
    // quote has named it.
    await page.goto("/");
    await useFixtureBackend(page);
    await page.locator("#start-buy").click();
    await expect(page.locator("#dest-fee-note")).toBeVisible();
    await expect(page.locator("#dest-fee-note")).toContainText("not added to your price");
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

  test("⚠️ the landing CTA is actually bigger, not just declared bigger", async ({ page }) => {
    // A CASCADE test, which is what this file is for. `.cta-hero` first sat ABOVE
    // `.cta` in the stylesheet, where `.cta`'s own `padding: 0.5rem 1.15rem` came
    // later at equal specificity and silently won: the button grew by 2px and read as
    // an ordinary pill. Every DOM assertion passed, the class was on the element, and
    // `getComputedStyle` for anything nobody thought to check looked fine.
    //
    // ⚠️ Asserted as a RELATION rather than a pixel count, so it survives a type-scale
    // change: the page's one call to action must be visibly larger than an ordinary
    // button, and the header's Sign out is the ordinary one.
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto("/");
    await useFixtureBackend(page);
    const cta = (await page.locator("#start-buy").boundingBox())!;
    const ordinary = (await page.locator("#theme-toggle").boundingBox())!;
    expect(cta.height).toBeGreaterThan(ordinary.height * 1.5);
    expect(cta.width).toBeGreaterThan(ordinary.width * 2);
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
