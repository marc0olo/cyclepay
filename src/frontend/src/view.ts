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
/// `next` is the post-delivery guidance: linking the CLI and deploying. It is its own
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
  | "next"
  | "history"
  | "admin";

/// A parsed location hash.
export type Route =
  | { view: "landing" }
  | { view: "buy" }
  | { view: "order"; orderId: string }
  | { view: "next"; orderId: string }
  | { view: "history" }
  | { view: "admin" };

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
  if (clean === "history") return { view: "history" };
  if (clean === "admin") return { view: "admin" };
  // ⚠️ The longer pattern first: `order/<id>/next` also matches the order pattern's
  // prefix, and a route table that tests the shorter one first sends every next-steps
  // link to the order view instead.
  const next = /^order\/([a-zA-Z0-9-]+)\/next$/.exec(clean);
  if (next) return { view: "next", orderId: next[1]! };
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
      return "#/history";
    case "admin":
      return "#/admin";
    case "order":
      return `#/order/${route.orderId}`;
    case "next":
      return `#/order/${route.orderId}/next`;
    case "landing":
      return "#/";
  }
}

/// The four steps the whole flow is sold as (distinct from format.ts's STEPS, which is
/// the ORDER pipeline — created, paid, delivered, three of them), and which of them a
/// given view has already completed.
///
/// ⚠️ **The strip is for BUYING, and for the guidance that follows it — not for the
/// order record.** It used to persist onto the order view, where it competed with the
/// facts the buyer had opened that page to read. The four steps are a promise about
/// the purchase journey; an order detail page is a receipt, and a receipt with a
/// progress bar on it is answering a question nobody asked there.
export type StepState = "todo" | "current" | "done";

export const TOUR_STEPS = [
  { n: 1, label: "Sign in" },
  { n: 2, label: "Pay" },
  { n: 3, label: "Link the CLI" },
  { n: 4, label: "Deploy" },
] as const;

/// Step states for a view.
///
/// `signedIn` matters on the buy view only: someone who has signed in but not yet
/// paid is genuinely past step 1, and showing it as pending would understate
/// their progress.
///
/// A canister top-up has no steps 3 and 4 — the cycles are already where they are
/// being spent — so the caller omits the strip entirely rather than showing two
/// steps that will never complete.
export function stepStates(view: View, signedIn: boolean): StepState[] {
  switch (view) {
    case "buy":
      return [signedIn ? "done" : "current", signedIn ? "current" : "todo", "todo", "todo"];
    case "next":
      // The cycles have landed, so paying is done and linking is the live step.
      return ["done", "done", "current", "todo"];
    case "order":
    case "delivered":
      // ⚠️ No strip on the order record. The caller omits it entirely rather than
      // rendering four steps beside a receipt.
      return ["todo", "todo", "todo", "todo"];
    default:
      return ["todo", "todo", "todo", "todo"];
  }
}
