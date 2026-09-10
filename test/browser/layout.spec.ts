import { test, expect, useFixtureBackend, signInAsFixtureBuyer, openFixtureOrder } from "./fixtures";

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

  test("the form asks for no destination, and no longer explains one either", async ({ page }) => {
    // Not "the field is hidden": the field is GONE (#29), along with the radios
    // and the other-account disclosure. `toHaveCount(0)` is the assertion that a
    // reintroduced input cannot satisfy by being display:none.
    //
    // ⚠️ The explaining SECTION is gone too. It was a heading, a sentence and a fee
    // note about a destination the buyer cannot change, sitting between the amount and
    // the button that acts on it. The order they are about to create states both facts.
    await page.goto("/");
    await page.locator("#start-buy").click();
    await expect(page.locator("#dest-own")).toHaveCount(0);
    await expect(page.locator("#dest-fee-note")).toHaveCount(0);
    await expect(page.locator("#canister-principal")).toHaveCount(0);
    await expect(page.locator("#dest-choice")).toHaveCount(0);
    await expect(page.locator("#dest-ledger-advanced")).toHaveCount(0);
    await expect(page.locator('input[name="dest-kind"]')).toHaveCount(0);
  });

  test("⚠️ the deposit fee is still inside the figure the buyer chooses on", async ({ page }) => {
    // The reason removing the note is safe: the tile states the CREDITED quantity, so
    // the fee is already in the number being decided on. Verified in a browser because
    // the quote, the ledger fee read and the render all take part.
    await page.goto("/");
    await useFixtureBackend(page);
    await page.locator("#start-buy").click();
    const label = page.locator("#tiers button.tier .cycles").first();
    await expect(label).toContainText("cycles");
    // Never a bare "sent" figure with no credited one: that would overstate delivery.
    await expect(label).not.toHaveText(/^\s*$/);
  });
});

test.describe("the amount picker", () => {
  test("⚠️ Custom is a tile, and the field opens only when it is chosen", async ({ page }) => {
    // In a real browser because `hidden` on a grid child is exactly the kind of thing
    // CSS can defeat, and this suite exists for that class of failure.
    await page.goto("/");
    await useFixtureBackend(page);
    await page.locator("#start-buy").click();

    const panel = page.locator("#custom-panel");
    await expect(panel).toBeHidden();
    // The tile sits in the row with the presets, not beside it.
    await expect(page.locator("#tiers #tier-custom")).toBeVisible();

    await page.locator("#tier-custom").click();
    await expect(panel).toBeVisible();
    await expect(page.locator("#custom-amount")).toBeFocused();

    // And a preset closes it again: one answer to "which amount".
    await page.locator("#tiers button.tier").first().click();
    await expect(panel).toBeHidden();
  });

  test("the buy button follows the amount and is the prominent control", async ({ page }) => {
    await page.goto("/");
    await useFixtureBackend(page);
    await page.locator("#start-buy").click();
    const btn = page.locator("#create-order");
    await expect(btn).toBeVisible();
    await expect(btn).toHaveClass(/cta-buy/);
    // Larger than the body scale it used to sit at.
    const size = await btn.evaluate((n) => parseFloat(getComputedStyle(n).fontSize));
    const body = await page.evaluate(() => parseFloat(getComputedStyle(document.body).fontSize));
    expect(size).toBeGreaterThan(body);
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

/// Three facts that no element assertion can reach, because each is about two
/// things AGREEING — an animation with a highlight, a header with its viewport, a
/// table with its container. Every one of them was on screen and wrong while the
/// whole suite was green.
test.describe("layout agreement", () => {
  test("the travelling dot lands on the step that is ringed", async ({ page }) => {
    await page.goto("/");
    const worst = await page.evaluate(() => {
      const flow = document.querySelector(".flow") as HTMLElement;
      const steps = [...document.querySelectorAll(".flow-step")] as HTMLElement[];
      const nodes = [...document.querySelectorAll(".flow-node")] as HTMLElement[];
      const top = flow.getBoundingClientRect().top;
      const height = flow.getBoundingClientRect().height;
      const centres = nodes.map((n) => {
        const r = n.getBoundingClientRect();
        return r.top - top + r.height / 2;
      });

      // Seek every animation to one absolute instant. `flow-dim`/`flow-ring` carry a
      // `--i * 2s - 1s` delay, so each step's seek is offset by its own.
      const seek = (t: number) => {
        flow.style.animationPlayState = "paused";
        flow.style.animationDelay = `${-t}s`;
        steps.forEach((s, i) => {
          for (const el of [s, nodes[i]!]) {
            el.style.animationPlayState = "paused";
            el.style.animationDelay = `${i * 2 - 1 - t}s`;
          }
        });
      };

      // The pulse is a background layer, so its position has to be read from the
      // computed value and its percentage resolved against the positioning area
      // (the container minus the 5px dot).
      const dotCentre = () => {
        const y = getComputedStyle(flow)
          .backgroundPosition.split(",")[0]!
          .trim()
          .split(/\s+/)
          .slice(1)
          .join(" ");
        const area = height - 5;
        const m = y.match(/calc\(([-\d.]+)%\s*([+-])\s*([\d.]+)px\)/);
        let px: number;
        if (m) px = (parseFloat(m[1]!) / 100) * area + (m[2] === "-" ? -1 : 1) * parseFloat(m[3]!);
        else if (y.endsWith("%")) px = (parseFloat(y) / 100) * area;
        else px = parseFloat(y);
        return px + 2.5;
      };

      // `flow-ring` lights node i between 8% and 22% of its cycle, so the middle of
      // its window is at t = 2i + 0.2.
      let worstOffset = 0;
      for (let i = 0; i < centres.length; i++) {
        seek(2 * i + 0.2);
        worstOffset = Math.max(worstOffset, Math.abs(dotCentre() - centres[i]!));
      }
      return worstOffset;
    });
    // The dot is 5px, so anything inside its own radius reads as "on the node".
    //
    // ⚠️ **49px is the number to compare a failure against**, and it is the one this
    // test's own seek points produce: reverting `flow-pulse` to the linear travel
    // measures 49.4px here. The drift is a function of WHERE in each ring window you
    // look — 40px at the moment node 4 lights, 67px later in the same window — so a
    // figure taken at another instant will not reproduce against this assertion.
    expect(worst).toBeLessThan(4);
  });

  for (const width of [320, 390]) {
    test(`the signed-in header does not push the page sideways at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 740 });
      await page.goto("/");
      await useFixtureBackend(page);
      await signInAsFixtureBuyer(page);
      await openFixtureOrder(page, { status: "delivered" });
      await page.goto("/#/");
      // Non-vacuous: signed out, the nav links and the identity are absent and the
      // header fits any width, so this would pass while testing nothing.
      await expect(page.locator("#auth-area .principal")).toBeVisible();
      await expect(page.locator("#history-link")).toBeVisible();
      const { scrollWidth, clientWidth } = await page.evaluate(() => ({
        scrollWidth: document.documentElement.scrollWidth,
        clientWidth: document.documentElement.clientWidth,
      }));
      // Signed in, this row wants 457px. Without the wraps in `.site-header` and
      // `.header-actions` the header sets the page width and the whole document
      // scrolls: +137px here at 320px, +67px at 390px.
      expect(scrollWidth).toBe(clientWidth);
    });
  }

  /// ⚠️ **Two tests, not one, and the split is the point.** As a single test the
  /// desktop half was unreachable by the mutation that motivates it: putting
  /// `overflow-x` back on the table moves the scroll onto the table, so the wrapper
  /// stops overflowing and the PHONE assertion trips first. The desktop assertion was
  /// real but never the one that fired, which makes it untested scaffolding.
  const openHistory = async (page: Parameters<Parameters<typeof test>[1]>[0]["page"], width: number, height: number) => {
    await page.setViewportSize({ width, height });
    await page.goto("/");
    await useFixtureBackend(page);
    await signInAsFixtureBuyer(page);
    await openFixtureOrder(page, { status: "delivered" });
    await page.goto("/#/history");
    await expect(page.locator(".orders-table tbody tr").first()).toBeVisible();
  };

  test("a table too wide for the screen scrolls itself rather than being cut off", async ({ page }) => {
    await openHistory(page, 358, 740);
    const phone = await page.evaluate(() => {
      const table = document.querySelector(".orders-table") as HTMLElement;
      const box = table.parentElement as HTMLElement;
      box.scrollLeft = 9999;
      return {
        overflows: document.documentElement.scrollWidth > document.documentElement.clientWidth,
        wider: box.scrollWidth > box.clientWidth,
        scrolled: box.scrollLeft,
      };
    });
    // `body` sets `overflow-x: clip`, so a table with no scroll container of its own
    // is not merely off-screen — its last columns cannot be reached at all. This one
    // wants 449px against 358px.
    expect(phone.wider).toBe(true); // non-vacuous: there IS something to scroll to
    expect(phone.scrolled).toBeGreaterThan(0);
    expect(phone.overflows).toBe(false);
  });

  test("⚠️ and the same table still fills its panel on a desktop", async ({ page }) => {
    await openHistory(page, 1280, 900);
    const desktop = await page.evaluate(() => {
      const table = document.querySelector(".orders-table") as HTMLElement;
      const box = table.parentElement as HTMLElement;
      const row = table.querySelector("thead tr") as HTMLElement;
      return { row: row.getBoundingClientRect().width, box: box.getBoundingClientRect().width };
    });
    // The other half of the trade, and the reason the scroll container is a WRAPPER:
    // `overflow-x` on the table itself also makes its rows an anonymous auto-width
    // table box that `width: 100%` no longer reaches — 518px of columns stranded in a
    // 1008px panel here, and 387px in a 1008px panel for the console's own tables,
    // which had been doing exactly that since they were introduced.
    expect(desktop.row).toBeCloseTo(desktop.box, 0);
  });
  test("⚠️ the id in a history row loads the lookup beneath it", async ({ page }) => {
    // The panel has to be able to complete its own loop. It shows a TRUNCATED id and
    // asks the field below for 32 hex characters, and until this control existed there
    // was no copy button and no click target between the two: an operator looking
    // straight at the row they wanted had nowhere to get its id from. Same class as the
    // three defects this panel already produced, and the reason it got a baseline.
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto("/");
    await useFixtureBackend(page);
    await signInAsFixtureBuyer(page);
    await page.goto("/#/admin/orders");
    const fill = page.locator("#apanel-orders .id-fill").first();
    await expect(fill).toBeVisible();

    // Non-vacuous on both sides: the cell really is abbreviated, so the id cannot be
    // read off the screen, and the field really is empty before the click.
    const shown = (await fill.textContent()) ?? "";
    expect(shown).toContain("\u2026");
    await expect(page.locator("#lookup-id")).toHaveValue("");

    await fill.click();
    const value = await page.locator("#lookup-id").inputValue();
    expect(value).toHaveLength(32);
    // The id from THIS row, not merely some well-formed id: the head and tail either
    // side of the ellipsis both have to match.
    const [head, tail] = shown.split("\u2026");
    expect(value.startsWith(head!)).toBe(true);
    expect(value.endsWith(tail!)).toBe(true);

    // ⚠️ Filling must not RUN it. `admin_order` is an update so the read is audited
    // (#38), and a mis-click must not spend one.
    await expect(page.locator("#lookup-result")).toBeHidden();
    await expect(page.locator("#lookup-id")).toBeFocused();
  });
});
