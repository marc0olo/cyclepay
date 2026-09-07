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
const TOKENS = readFileSync(
  resolve(__dirname, "tokens.css"),
  "utf8",
);

/// The light palette is the bare `:root` block; dark redefines a subset below it.
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
