import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

/// Text tokens must be readable against the ground they sit on, in BOTH themes.
///
/// ⚠️ **This exists because a palette value shipped that failed AA and nobody could
/// see it from the CSS.** `--icp-fg-muted` was `#868078`, which is 3.71:1 on the
/// parchment background: it fails WCAG AA for body text and clears only the
/// large-text bar, while `.muted` is 0.875rem prose all over the app. It was found by
/// a person saying the light theme was hard to read, which is the slowest possible
/// detector and only works for whoever happens to look.
///
/// ⚠️ **And the DARK palette was already correct**, tuned upward from the same brand
/// values (`#8f867a` where the reference has `#7a7367`). So one mode had been fixed and
/// the other had not, with nothing recording that the fix had happened. That asymmetry
/// is the thing this file prevents from recurring.
/// ⚠️ **What this suite CANNOT see: opacity composition.** It measures a token against
/// a token, and `opacity` composites on top of the result afterwards — so a rule like
/// `.flow-step { opacity: 0.55 }` (`styles.css:1125`) makes text render at a ratio this
/// file never computes. Measured on the landing page's four-step rail:
///
///   light   --icp-fg-muted      5.15:1  →  2.19:1 at 0.55
///           --icp-fg-secondary  8.54:1  →  2.74:1
///   dark    --icp-fg-muted      5.25:1  →  2.41:1
///           --icp-fg-secondary  9.98:1  →  3.78:1
///
/// That rail is deliberate — 0.55 is the trough of an 8 s cycle that brings each step to
/// full opacity, and `prefers-reduced-motion` sets `opacity: 1` with `animation: none`.
/// It is recorded here because a green run of this file was cited as covering
/// "text the same colour as its background", and for anything faded it does not.
///
/// ⚠️ **What DOES cover it: `test/browser/visual.spec.ts`.** Playwright's
/// `animations: "disabled"` cancels an infinite animation to its initial state, and the
/// `0%` keyframe is the 0.55 trough — so the committed baselines pin the DIMMEST frame,
/// and a change that faded the rail further fails there. The two suites are complements:
/// this one is exact about tokens and blind to composition; that one sees the composed
/// pixels and cannot tell you a ratio.
const TOKENS = readFileSync(
  resolve(__dirname, "tokens.css"),
  "utf8",
);

/// The light palette is the bare `:root` block; dark redefines a subset below it.
///
/// ⚠️ **The split is asserted, because failing to find it fails SILENTLY in the
/// direction that passes.** At -1, `LIGHT` becomes the whole file, `DARK` becomes one
/// character, `themed` falls back to light for every token, and all four dark
/// assertions re-test the light palette and pass — a contrast suite that checks one
/// theme twice, in the file whose whole reason for existing is that a palette failure
/// was invisible. Changing the selector's quotes is enough to do it.
const DARK_AT = TOKENS.indexOf(":root[data-theme='dark']");
const LIGHT = TOKENS.slice(0, DARK_AT);
const DARK = TOKENS.slice(DARK_AT);

function token(block: string, name: string): string | null {
  const m = new RegExp(`--${name}:\\s*([^;]+);`).exec(block);
  return m ? m[1]!.trim() : null;
}

/// A token's value in a theme, falling back to light: dark redefines only what moves.
function themed(block: string, name: string): string {
  const v = token(block, name) ?? token(LIGHT, name);
  if (v === null) throw new Error(`no --${name} in tokens.css`);
  return v;
}

function rgb(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  const full = h.length === 3 ? [...h].map((c) => c + c).join("") : h;
  return [0, 2, 4].map((i) => parseInt(full.slice(i, i + 2), 16)) as [number, number, number];
}

/// WCAG 2.1 relative luminance.
function luminance(c: [number, number, number]): number {
  const [r, g, b] = c.map((v) => {
    const s = v / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  }) as [number, number, number];
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a: string, b: string): number {
  const [la, lb] = [luminance(rgb(a)), luminance(rgb(b))];
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

const THEMES = [
  { name: "light", block: LIGHT },
  { name: "dark", block: DARK },
] as const;

describe("every text token is readable on its own ground", () => {
  test("⚠️ the theme blocks were actually found", () => {
    // Guards every assertion below: see the note at `DARK_AT`.
    expect(DARK_AT).toBeGreaterThan(0);
    expect(LIGHT.length).toBeGreaterThan(200);
    expect(DARK.length).toBeGreaterThan(200);
  });

  /// ⚠️ **`icp-accent` is NOT in this list, and the omission is stated rather than
  /// silent.** It is 4.31:1 on the dark ground — under the 4.5 body bar, over the 3.0
  /// large-text one — and it is the brand's identity colour, so darkening it is a
  /// bigger call than nudging a grey. It has its own looser assertion below, and the
  /// standing constraint is that accent must not be the only carrier of small body
  /// text. Listing it here at 4.5 would just fail; leaving it out with no note would
  /// hide the near-miss.
  const BODY_TOKENS = ["icp-fg", "icp-fg-secondary", "icp-fg-muted"] as const;

  for (const { name, block } of THEMES) {
    for (const t of BODY_TOKENS) {
      test(`${name}: --${t} clears AA for body text`, () => {
        const fg = themed(block, t);
        const bg = themed(block, "icp-bg");
        const ratio = contrast(fg, bg);
        expect(
          ratio,
          `--${t} (${fg}) on ${bg} is ${ratio.toFixed(2)}:1, under the 4.5 AA body bar`,
        ).toBeGreaterThanOrEqual(4.5);
      });
    }

    test(`${name}: --icp-fg-muted also clears AA on the sunk surface`, () => {
      // `.explainer.sunk` and the elevated cards carry muted prose too, and a token
      // measured only against the page background can still fail on a panel.
      const fg = themed(block, "icp-fg-muted");
      for (const surface of ["icp-bg-sunk", "icp-bg-elev"] as const) {
        const bg = themed(block, surface);
        const ratio = contrast(fg, bg);
        expect(
          ratio,
          `--icp-fg-muted (${fg}) on --${surface} (${bg}) is ${ratio.toFixed(2)}:1`,
        ).toBeGreaterThanOrEqual(4.5);
      }
    });

    test(`${name}: --icp-accent clears the large-text bar at least`, () => {
      const ratio = contrast(themed(block, "icp-accent"), themed(block, "icp-bg"));
      expect(ratio).toBeGreaterThanOrEqual(3.0);
    });

    test(`${name}: the status tones are readable`, () => {
      // A status colour that cannot be read is worse than a plain one: it carries the
      // meaning AND hides it.
      for (const tone of ["icp-ok", "icp-warn", "icp-err"] as const) {
        const fg = themed(block, tone);
        const bg = themed(block, "icp-bg");
        const ratio = contrast(fg, bg);
        expect(ratio, `--${tone} (${fg}) is ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(4.5);
      }
    });
  }

  test("⚠️ the CTA bar's own pair is checked against each other, not the page", () => {
    // It is theme-stable near-black by rule, so measuring it against `--icp-bg` would
    // pass in light and fail in dark while the bar itself is identical in both.
    const ratio = contrast(themed(LIGHT, "icp-cta-bar-fg"), themed(LIGHT, "icp-cta-bar"));
    expect(ratio).toBeGreaterThanOrEqual(4.5);
  });
});
