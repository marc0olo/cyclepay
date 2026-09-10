import { describe, expect, test } from "vitest";

import { type Route, parseRoute, routeHash } from "./view";

describe("the dashboard's two records are one view with a tab", () => {
  test("⚠️ the bare hash still means the DEFAULT tab", () => {
    // Every link, test and bookmark written before tabs existed points at `#/history`.
    // If the bare form stopped resolving, all of them would land on the landing page.
    expect(parseRoute("#/history")).toEqual({ view: "history", tab: "orders" });
  });

  test("the ledger tab is addressable", () => {
    expect(parseRoute("#/history/ledger")).toEqual({ view: "history", tab: "ledger" });
  });

  test("the default tab is also addressable explicitly", () => {
    // So a link can say which record it means rather than relying on the default.
    expect(parseRoute("#/history/orders")).toEqual({ view: "history", tab: "orders" });
  });

  test("the default tab keeps the BARE hash as its canonical form", () => {
    // Two spellings for one place would split bookmarks and make the address bar
    // change under a visitor who only clicked a tab.
    expect(routeHash({ view: "history", tab: "orders" })).toBe("#/history");
    expect(routeHash({ view: "history", tab: "ledger" })).toBe("#/history/ledger");
  });

  test("every route round-trips through its own hash", () => {
    const routes: Route[] = [
      { view: "landing" },
      { view: "buy" },
      { view: "history", tab: "orders" },
      { view: "history", tab: "ledger" },
      { view: "admin", tab: "now" },
      { view: "admin", tab: "worklists" },
      { view: "admin", tab: "orders" },
      { view: "admin", tab: "diagnostics" },
      { view: "admin", tab: "config" },
      { view: "order", orderId: "f22bd6dc4932a8480f3cee3669a48cc6" },
      { view: "cli" },
    ];
    for (const route of routes) {
      expect(parseRoute(routeHash(route))).toEqual(route);
    }
  });

  test("⚠️ the bare `#/admin` still means the default panel", () => {
    // The header link, the RUNBOOK's printed hash and every test written before the
    // panels existed all use the bare form. It must not become the landing page.
    expect(parseRoute("#/admin")).toEqual({ view: "admin", tab: "now" });
    expect(parseRoute("#/admin/now")).toEqual({ view: "admin", tab: "now" });
    // And the default panel keeps the bare hash, so links stay canonical.
    expect(routeHash({ view: "admin", tab: "now" })).toBe("#/admin");
    expect(routeHash({ view: "admin", tab: "diagnostics" })).toBe("#/admin/diagnostics");
  });

  test("an unrecognised ADMIN panel falls back to the landing page", () => {
    // Same rule as a mangled history tab: a bad URL shows the product rather than an
    // empty console. Pinned because a typo'd panel silently meaning "now" would hide
    // the mistake from whoever wrote the link.
    expect(parseRoute("#/admin/typo")).toEqual({ view: "landing" });
    expect(parseRoute("#/admin/")).toEqual({ view: "landing" });
  });

  test("an unrecognised tab falls back to the landing page, like every other bad hash", () => {
    // Consistent with the rule parseRoute already documents rather than a special case:
    // a mangled URL shows the product. Pinned because "#/history/typo" quietly meaning
    // something else would be a silent behaviour change.
    expect(parseRoute("#/history/typo")).toEqual({ view: "landing" });
    expect(parseRoute("#/history/")).toEqual({ view: "landing" });
  });

  test("the CLI page needs no order, and takes none", () => {
    // ⚠️ The `order/<id>/next` route is GONE, and with it the prefix-ordering hazard
    // it created. Everything that page shows is identity-derived, so the parameter
    // supplied nothing and made the page unreachable from the dashboard.
    expect(parseRoute("#/cli")).toEqual({ view: "cli" });
    expect(routeHash({ view: "cli" })).toBe("#/cli");
    expect(parseRoute("#/order/abc/next")).toEqual({ view: "landing" });
    expect(parseRoute("#/order/abc")).toEqual({ view: "order", orderId: "abc" });
  });
});
