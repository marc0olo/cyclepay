/// Which single view owns the screen.
///
/// The page used to stack everything at once: hero, chooser, amount picker,
/// destination form, active order, history, explainers, all in one column. One
/// view at a time makes the next action unambiguous, which matters most for the
/// audience that has never done this before.
///
/// `delivered` is not a separate route. It is the `order` route rendered for an
/// order that has arrived, because that is a property of the order rather than of
/// where the visitor navigated.
///
/// `admin` is the operator console (#68). It is a view rather than a separate page for
/// the same reason as the others: one owner of the screen, and hash routing that cannot
/// 404 on reload from an asset canister.
///
/// ⚠️ Deliberately not ADVERTISED: a console link on a purchase page is noise for every
/// visitor who is not an operator.
///
/// Since the header gained `#admin-nav` that rule is implemented rather than abandoned —
/// the link renders only when `admin_status` says the caller is granted or is a
/// controller, so the visitors it would be noise for never see it. What changed is that
/// an operator no longer has to know to type `#/admin`.
/// `cli` is the post-delivery guidance: linking the CLI and deploying. It is its own
/// view rather than a panel on the order, because those are two different questions.
/// "What did I buy" is a record with numbers and a receipt; "what do I do now" is a
/// sequence of commands. The order view previously answered the second one so loudly
/// that it answered the first not at all: everything numeric sat inside a disclosure
/// that collapsed on exactly the view where the buyer wanted it.
export type View =
  | "landing"
  | "buy"
  | "order"
  | "delivered"
  | "cli"
  | "history"
  | "admin";

/// Which record the dashboard is showing.
///
/// ⚠️ **A TAB, not a view.** The balance sits above both panels and belongs to
/// neither record, so the page is one view whose panel changes. Modelling the ledger
/// as its own view would duplicate the balance's load and let the two drift.
///
/// In the hash, so a tab is deep-linkable, survives a reload and works with Back.
/// That is also why the tabs are links with `aria-current` rather than an ARIA tab
/// widget: faking `role="tab"` over a router gives the keyboard two conflicting
/// models (arrow keys vs. Back) and the URL stops describing the page.
export type HistoryTab = "orders" | "ledger";

/// Which panel of the operator console owns the screen.
///
/// ⚠️ **Ordered by what an operator needs FIRST, not by what was built first.** The
/// console previously stacked all of it in one column: identity, configuration, actions,
/// then the summary, then the worklists. Someone opening it during an incident scrolled
/// past their own principal and a configuration table to reach "what needs a person".
///
///   `now`          is anything wrong, and how bad — the landing panel
///   `worklists`    the queues a person acts on
///   `orders`       the record, and lookup by id
///   `diagnostics`  read-only state the RUNBOOK asks for by name
///   `config`       what you change rarely, plus this browser's identity
///
/// ⚠️ **A TAB, not a view, for the same reason as `HistoryTab`** — and links with
/// `aria-current` rather than an ARIA tab widget, so the URL keeps describing the page
/// and the keyboard has one model instead of two.
export type AdminTab = "now" | "worklists" | "orders" | "diagnostics" | "config";

/// A parsed location hash.
export type Route =
  | { view: "landing" }
  | { view: "buy" }
  | { view: "order"; orderId: string }
  /// ⚠️ **No order id, and that absence is the design.** Everything this page shows
  /// is derived from the signed-in identity: the link command names this origin, the
  /// principal to verify is the caller's, and the balance comes from the ledger. The
  /// order it used to be scoped to supplied nothing, and the parameter made the page
  /// unreachable from the dashboard, where there is no one order to name.
  | { view: "cli" }
  | { view: "history"; tab: HistoryTab }
  | { view: "admin"; tab: AdminTab };

/// Parse `window.location.hash`.
///
/// Hash routing rather than the History API for one reason: this is served from
/// an asset canister, and a real path needs SPA rewrites configured to match.
/// A hash cannot 404 on reload, and Back works without any server involvement.
///
/// Anything unrecognised is the landing page. A visitor who lands on a mangled
/// URL should see the product, not an error.
export function parseRoute(hash: string): Route {
  const clean = hash.replace(/^#\/?/, "");
  if (clean === "buy") return { view: "buy" };
  // ⚠️ The tabbed forms BEFORE the bare one is not required here (these are exact
  // equalities, not prefixes) but the bare form must keep meaning the default tab:
  // every link and test written before tabs existed points at `#/history`.
  if (clean === "history" || clean === "history/orders") {
    return { view: "history", tab: "orders" };
  }
  if (clean === "history/ledger") return { view: "history", tab: "ledger" };
  // ⚠️ The bare form must keep meaning the default panel: `#/admin` is what the header
  // link points at, what the RUNBOOK prints, and what every test written before the
  // panels existed uses.
  if (clean === "admin" || clean === "admin/now") return { view: "admin", tab: "now" };
  const adminTab = /^admin\/(worklists|orders|diagnostics|config)$/.exec(clean);
  if (adminTab) return { view: "admin", tab: adminTab[1] as AdminTab };
  if (clean === "cli") return { view: "cli" };
  const order = /^order\/([a-zA-Z0-9-]+)$/.exec(clean);
  if (order) return { view: "order", orderId: order[1]! };
  return { view: "landing" };
}

/// The hash for a route. Always with the leading `#/`, so a link is never
/// mistaken for a path.
export function routeHash(route: Route): string {
  switch (route.view) {
    case "buy":
      return "#/buy";
    case "history":
      // The default tab keeps the bare hash, so existing links stay canonical.
      return route.tab === "ledger" ? "#/history/ledger" : "#/history";
    case "admin":
      // The default panel keeps the bare hash, so existing links stay canonical.
      return route.tab === "now" ? "#/admin" : `#/admin/${route.tab}`;
    case "order":
      return `#/order/${route.orderId}`;
    case "cli":
      return "#/cli";
    case "landing":
      return "#/";
  }
}

/// ⚠️ **The four-step strip is GONE, and this note is the record of why.** It read
/// "1 Sign in, 2 Pay, 3 Link the CLI, 4 Deploy" and was carried across the buy view
/// and the guidance page. Two things killed it: the guidance page is now reachable
/// from the dashboard by someone who is not partway through a purchase, and on the buy
/// view it narrated a four-stage journey above a single decision, where the only step
/// the visitor can act on is the one in front of them. Do not reinstate it without a
/// stage a buyer can actually be stuck between.
