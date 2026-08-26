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
export type View = "landing" | "buy" | "order" | "delivered" | "history";

/// A parsed location hash.
export type Route =
  | { view: "landing" }
  | { view: "buy" }
  | { view: "order"; orderId: string }
  | { view: "history" };

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
    case "order":
      return `#/order/${route.orderId}`;
    case "landing":
      return "#/";
  }
}

/// The four steps the whole flow is sold as (distinct from format.ts's STEPS,
/// which is the ORDER pipeline: created, paid, delivered — three since #30 PR-C
/// dropped the unreachable `minting` segment), and which of them a given view has
/// already completed.
///
/// The strip persists across buy, order and delivered so the visitor can always
/// see how far along they are and how much is left. Issue #21's headline promises
/// exactly four steps; showing them only in the hero would make that a claim
/// rather than a progress indicator.
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
    case "order":
      // Paid, waiting on delivery: step 2 is underway, not finished.
      return ["done", "current", "todo", "todo"];
    case "delivered":
      return ["done", "done", "current", "todo"];
    default:
      return ["todo", "todo", "todo", "todo"];
  }
}
