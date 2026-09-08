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
      { view: "admin" },
      { view: "order", orderId: "f22bd6dc4932a8480f3cee3669a48cc6" },
      { view: "next", orderId: "f22bd6dc4932a8480f3cee3669a48cc6" },
    ];
    for (const route of routes) {
      expect(parseRoute(routeHash(route))).toEqual(route);
    }
  });

  test("an unrecognised tab falls back to the landing page, like every other bad hash", () => {
    // Consistent with the rule parseRoute already documents rather than a special case:
    // a mangled URL shows the product. Pinned because "#/history/typo" quietly meaning
    // something else would be a silent behaviour change.
    expect(parseRoute("#/history/typo")).toEqual({ view: "landing" });
    expect(parseRoute("#/history/")).toEqual({ view: "landing" });
  });

  test("⚠️ the order route is still matched before its own /next prefix", () => {
    // Regression guard for a bug this router already had: `order/<id>/next` also
    // matches the order pattern's prefix, so testing the shorter one first sent every
    // next-steps link to the order view.
    expect(parseRoute("#/order/abc/next")).toEqual({ view: "next", orderId: "abc" });
    expect(parseRoute("#/order/abc")).toEqual({ view: "order", orderId: "abc" });
  });
});
