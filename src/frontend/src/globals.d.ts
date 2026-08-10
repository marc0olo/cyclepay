/// Build-time constants injected by `define` in vite.config.ts.

/// True only in a fixtures build (`CYCLEPAY_FIXTURES=1`, used by the browser
/// specs). Vite replaces it with a literal, so `if (__FIXTURES__)` is dead code
/// Rollup removes from the shipping bundle — which is what lets the fixture hook
/// exist at all. See src/fixtures.ts.
declare const __FIXTURES__: boolean;
