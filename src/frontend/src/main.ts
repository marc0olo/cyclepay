// CyclePay frontend (M2): II login, rail selector (Card | ck-USDC), order
// creation, Stripe Payment Link hand-off / approve→claim flow, live status
// polling, order history.
//
// The rail tabs are the §11.1 seam in UI form: each rail is a panel feeding
// the one shared destination form and the one shared order timeline.
import { Principal } from "@icp-sdk/core/principal";
import type { Identity } from "@icp-sdk/core/agent";
import {
  backendCanisterId,
  makeBackend,
  type PricingStatus,
  makeBackendAt,
  type Backend,
  type CkUsdcConfig,
  type Destination,
  type Order,
  type QuotePreview,
  Rail,
  type Tier,
} from "./actor";
import { currentIdentity, signIn, signOut } from "./auth";
import { linkIdentityCommand, verifyIdentityCommand } from "./config";
import {
  clearIcEnvCookies,
  distinctBackendIds,
  hasConflictingIcEnv,
  isWrongBackendId,
  parseIcEnvCookies,
  resolveLiveBackendId,
} from "./ic-env";
import { type Audience, recall, remember, forget, suggestFrom } from "./audience";
import { type View, type Route, parseRoute, routeHash, TOUR_STEPS, stepStates } from "./view";
import { makeCkUsdcLedger } from "./ledger";
import {
  RATE_LOCK_NOTE,
  STEPS,
  approveErrorMessage,
  checkReceipt,
  ckUnitsForCents,
  claimErrorInfo,
  createCkOrderErrorMessage,
  createOrderErrorMessage,
  type DestinationKind,
  estimateLine,
  type FeeConfig,
  feeBreakdown,
  gateReasonMessage,
  type GateReason,
  lockedVsEstimate,
  minAcceptableCycles,
  quoteChangedMessage,
  formatCkUsdcUnits,
  formatCycles,
  formatUsdCents,
  nsToMillis,
  parseSubaccountHex,
  parseUsdAmount,
  paymentLinkWithRef,
  rateSourceNote,
  shortPrincipal,
  statusInfo,
  type StatusKey,
} from "./format";

const POLL_MS = 3_000;
/// Debounce on the ck-USDC amount box: one query per pause in typing, not per
/// keystroke.
const QUOTE_DEBOUNCE_MS = 350;

// The bindgen wrapper surfaces OrderStatus as a string enum whose values are
// exactly the variant labels format.ts keys on.
function statusKeyOf(order: Order): StatusKey {
  return order.status as unknown as StatusKey;
}

// Rail is a payload-less variant → string enum in the wrapper, same story.
function isCkOrder(order: Order): boolean {
  return (order.rail as unknown as string) === "ckUsdc";
}

// --- state ---------------------------------------------------------------

type RailKey = "card" | "ckUsdc";

let identity: Identity | null = null;

/// The backend id the stale-cookie probe found answering, once it has run.
///
/// Module state, and consulted by **every** backend construction, because there
/// are two of them and they disagreed: `init` adopted the probed id into its own
/// local, then `setIdentity` rebuilt from `makeBackend()` on sign-in and went
/// straight back to the dead canister the cookie advertises. The self-heal
/// therefore worked exactly until the visitor signed in.
let liveBackendId: string | null = null;

/// Set only by the test-only fixture hook, and absent from a production build
/// (see fixtures.ts). Every construction consults it for the same reason as
/// above: a fixture that only replaced the first actor would be undone by
/// sign-in.
let backendFactory: ((who: Identity | null) => Backend) | null = null;

/// The one place a backend actor is built.
function buildBackend(who: Identity | null): Backend {
  if (backendFactory !== null) return backendFactory(who);
  return liveBackendId === null
    ? makeBackend(who ?? undefined)
    : makeBackendAt(liveBackendId, who ?? undefined);
}

let backend: Backend = buildBackend(null);
let tiers: Tier[] = [];
let selectedTierId: string | null = null;
let lowFloat = false;
let activeRail: RailKey = "card";

/// Null means "show the chooser". See audience.ts for why only "live" persists.
/// The order the order/delivered view is showing. Null on every other view.
let activeOrder: Order | null = null;

let audience: Audience | null = null;
/// The newcomer arm hides the destination question entirely; this opens the
/// escape hatch for funding someone else's canister without promoting it to a
/// co-equal choice.
let newcomerAdvanced = false;
let ckConfig: CkUsdcConfig | null = null;
// Payment links keyed by order id — known only for orders created this
// session (the backend stores no link; the tier carries it).
const payLinks = new Map<string, string>();
// Ledger-authoritative approve amounts (from insufficientAllowance claim
// errors) — they supersede the config-derived price + fee for that order.
const ckRequiredUnits = new Map<string, bigint>();
// Approve/claim flow guard: the order id of an in-flight ledger/claim call.
let ckBusyOrderId: string | null = null;
// Quotes the *backend* computed, keyed by tier id — never derived here, so what
// a buyer is shown and what create_order locks cannot disagree.
let tierQuotes = new Map<string, QuotePreview>();
let ckQuote: QuotePreview | null = null;
// Fee formulas, for rendering the split in words.
let cardFee: FeeConfig | null = null;
// The ledger's own deposit fee, from quote_previews.
let depositFee = 0n;
// Set when a created order's locked quantity differs from the estimate shown —
// within tolerance, so the order went through, but the buyer should still hear
// the real number rather than discover it.
let lockNotice: string | null = null;
let ckQuoteTimer: ReturnType<typeof setTimeout> | null = null;
let pollTimer: ReturnType<typeof setInterval> | null = null;
let pollOrderId: string | null = null;
let lastPolledStatus: string | null = null;

// --- tiny DOM helpers ----------------------------------------------------

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (!node) throw new Error(`missing #${id}`);
  return node as T;
}

/// Toggle by id, tolerating a node that is not in the document.
///
/// Absence is a real state here, not a bug: the ck-USDC markup is *removed*
/// while the rail is disabled (see `removeDisabledRailMarkup`), so every
/// `show("ck-…")` on the shared paths would otherwise throw. `el()` stays strict
/// for everything that must exist.
function show(id: string, visible: boolean): void {
  const node = document.getElementById(id);
  if (node) node.hidden = !visible;
}

// --- stale ic_env cookie ---------------------------------------------------

/// A stale `ic_env` cookie shadows the fresh one, so the app builds its actor
/// against a canister id that no longer exists and the gateway answers every
/// request with `400 canister_not_found`. See ic-env.ts for the probe that
/// established that, and for why this needs code rather than a README note.
///
/// Not local-only, as an earlier version of this heading claimed: the asset
/// canister serves `ic_env` on mainnet too (ic-env.ts, REPORTED), so the guard is
/// not scoped to development. It costs nothing where there is only one cookie.
///
/// Sets `liveBackendId` when it finds one, and no-ops unless the browser is
/// holding conflicting copies.
async function resolveStaleIcEnv(): Promise<void> {
  const candidates = distinctBackendIds(parseIcEnvCookies(document.cookie));
  if (candidates.length < 2) return;
  // eslint-disable-next-line no-console
  console.warn("conflicting ic_env cookies", candidates);
  // REVERSED, and the order is load-bearing rather than incidental. The one
  // measured fact this module rests on is that `safeGetCanisterEnv` takes the
  // FIRST `ic_env` match, and that first match is the id the app is already
  // failing against. Probing from the other end tries the copies it has not
  // used yet before the one that is known not to work.
  //
  // When more than one candidate answers, this is a preference and not a proof:
  // nothing in the cookie says which copy is fresher. It is still strictly
  // better than repeating the choice that produced the failure.
  const live = await resolveLiveBackendId([...candidates].reverse(), async (canisterId) => {
    // A cheap public query. Any answer at all proves the id exists.
    await makeBackendAt(canisterId).pricing_status();
  });
  if (live === null) return;
  staleCookieDetected = true;
  liveBackendId = live;
  backend = buildBackend(identity);
}

/// True once a stale cookie has been identified, so the failure copy can name it
/// instead of blaming the gateway.
let staleCookieDetected = false;

/// Offer the fix, and say what is actually wrong.
///
/// "Could not reach the gateway" is the wrong sentence here: the gateway is fine,
/// this browser is holding a cookie from a network that no longer exists. Nobody
/// guesses that, and "clear site data" is not a step a visitor will take on
/// instruction from a page that appears broken.
function renderStaleCookieNotice(into: HTMLElement): void {
  into.replaceChildren();
  const text = document.createElement("span");
  text.textContent =
    "This browser is holding a stale local-development cookie, so the app is " +
    "calling a canister that no longer exists. The gateway is fine. ";
  const fix = document.createElement("button");
  fix.type = "button";
  fix.className = "linklike";
  fix.textContent = "Clear it and reload";
  fix.onclick = () => {
    void clearIcEnvCookies().then((cleared) => {
      // `cookieStore.delete` resolves whether or not it removed anything, so a
      // resolved promise is not evidence. Re-read the cookies: reloading on an
      // unverified delete lands the visitor on the same broken page with the one
      // explanation of it now gone.
      if (cleared && !hasConflictingIcEnv(document.cookie)) {
        window.location.reload();
        return;
      }
      // Either there is no cookieStore (Safari, Firefox at time of writing), or
      // there is and the delete did not take. Both end in the same manual step,
      // and both are worth distinguishing for whoever is reading over a shoulder.
      fix.replaceWith(
        document.createTextNode(
          cleared
            ? "The cookies are still there after deleting them: clear site data " +
              "for this origin and reload."
            : "This browser cannot clear it from script: clear site data for this " +
              "origin and reload.",
        ),
      );
    });
  };
  into.append(text, fix);
}

// --- views -----------------------------------------------------------------

/// One view owns the screen at a time. See view.ts for why.
let currentView: View = "landing";
/// Orders this principal has, so the header link can hide when there are none.
let orderCount = 0;

/// Whose steps 3 and 4 are these?
///
/// - `none` — a canister top-up. The cycles are already where they will be spent,
///   so there is nothing to link and nothing to deploy against; a four-step strip
///   would promise this buyer two steps that never complete.
/// - `self` — the buyer's own cycles-ledger account. The two commands ARE the
///   deliverable.
/// - `third-party` — somebody else's account. `icp identity link web` links the
///   BUYER's identity, which is not the account that was funded, so the commands
///   cannot reach the balance and must not be printed. An unknown identity counts
///   as third-party: printing commands that may be for the wrong account is worse
///   than printing none.
type TourKind = "none" | "self" | "third-party";

function tourKind(order: Order | null): TourKind {
  if (order === null || !("cyclesLedgerAccount" in order.destination)) return "none";
  const owner = order.destination.cyclesLedgerAccount.owner;
  return identity !== null && owner.toText() === identity.getPrincipal().toText()
    ? "self"
    : "third-party";
}

function renderStepper(view: View, order: Order | null): void {
  const node = document.getElementById("stepper");
  if (!node) return;
  // Steps 3 and 4 belong to the buyer only when the balance is theirs.
  const relevant =
    view === "buy" || ((view === "order" || view === "delivered") && tourKind(order) === "self");
  if (!relevant) {
    node.hidden = true;
    return;
  }
  const states = stepStates(view, identity !== null);
  node.replaceChildren();
  TOUR_STEPS.forEach((step, i) => {
    const li = document.createElement("li");
    li.className = `step ${states[i]}`;
    const n = document.createElement("span");
    n.className = "step-n";
    n.textContent = String(step.n);
    const label = document.createElement("span");
    label.textContent = step.label;
    li.append(n, label);
    // Completion is carried by colour and weight, which is not enough on its
    // own. A checkmark glyph would be, but the brand rules ban pictographs and
    // exempting myself from a rule I wrote into the linter is not a precedent
    // worth setting — so the state goes to assistive tech as a word.
    if (states[i] !== "todo") {
      const sr = document.createElement("span");
      sr.className = "sr-only";
      sr.textContent = states[i] === "done" ? " (done)" : " (current step)";
      li.append(sr);
    }
    li.setAttribute("aria-current", states[i] === "current" ? "step" : "false");
    node.append(li);
  });
  node.hidden = false;
}

/// How the order the route names worked out. `ok` covers "we are not on the order
/// view at all", which is why it is the default.
///
/// Tri-state for the same reason the tier list is: "we could not find that order"
/// is a claim about the gateway's records and "we could not reach the gateway" is
/// a claim about the network, and while the lookup is in flight both are false.
type OrderLoad = "ok" | "loading" | "missing" | "unreachable";
let orderLoad: OrderLoad = "ok";

/// Show exactly one view.
function renderView(): void {
  const order = activeOrder;
  const delivered = currentView === "order" && order !== null && statusKeyOf(order) === "delivered";
  const effective: View = delivered ? "delivered" : currentView;
  const onOrder = effective === "order" || effective === "delivered";

  show("view-landing", effective === "landing");
  show("buy-flow", effective === "buy");
  show("chooser-back", effective === "buy" && audience === "live");
  // Nothing to show is not the same as an empty panel: signing out drops the
  // order, and the order view then has no content of its own.
  const ready = orderLoad === "ok" && order !== null;
  // `#active-order` has exactly one owner, and it is this line. `renderOrder`
  // used to unhide it too, which is how a poll tick could paint an order over the
  // history table the visitor had navigated to.
  show("active-order", onOrder && ready);
  show("order-missing", onOrder && !ready);
  show("history", effective === "history");
  show("history-link", orderCount > 0 && identity !== null);
  if (onOrder && !ready) renderOrderMissing();

  renderStepper(effective, order);

  // On delivery the next action is the tour, so the facts collapse under it.
  // Everywhere else they are the only content and stay open.
  const details = document.getElementById("order-details") as HTMLDetailsElement | null;
  if (details) details.open = !delivered;
  renderTour(order, delivered);
}

function renderOrderMissing(): void {
  const node = document.getElementById("order-missing-detail");
  if (!node) return;
  node.textContent =
    orderLoad === "loading"
      ? "Looking it up…"
      : orderLoad === "unreachable"
        ? "Could not reach the gateway to look it up. Nothing was charged. Reload to try again."
        : "That order id is not one this gateway holds for you. If you have just " +
          "paid, the payment reference on your card receipt is the one to quote.";
}

function navigate(route: Route, replace = false): void {
  const hash = routeHash(route);
  if (window.location.hash === hash) {
    applyRoute(route);
    return;
  }
  // replaceState for transitions the visitor did not ask for (a poll finding the
  // order delivered), so Back does not step through states they never chose.
  if (replace) window.history.replaceState(null, "", hash);
  else window.location.hash = hash;
  applyRoute(route);
}

function applyRoute(route: Route): void {
  // A deep link or a reload on #/buy with no arm chosen renders a form with no
  // destination question on it at all: the newcomer block is hidden, the
  // already-live radios are hidden, and the only thing left is an amount grid
  // wired to a destination the visitor was never asked about. Send them to the
  // question first. Replaced, not pushed, so Back leaves rather than bouncing.
  if (route.view === "buy" && audience === null) {
    navigate({ view: "landing" }, true);
    return;
  }

  // Leaving the order view ends the poll. The other half of `#active-order`
  // having one owner: a tick that arrives after the visitor has moved on has
  // nothing left to repaint.
  if (route.view !== "order" && pollOrderId !== null) stopPolling();

  currentView = route.view;
  if (route.view === "order" && activeOrder?.id !== route.orderId) {
    // Deep link or Back into an order we are not currently holding.
    orderLoad = "loading";
    void loadOrderById(route.orderId);
  }
  renderView();
}

async function loadOrderById(orderId: string): Promise<void> {
  let order: Order | null;
  try {
    order = await backend.get_order(orderId);
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("could not load order", orderId, error);
    orderLoad = "unreachable";
    renderView();
    return;
  }
  // The route may have moved on while the query was in flight.
  if (currentView !== "order") return;
  if (order === null) {
    orderLoad = "missing";
    renderView();
    return;
  }
  orderLoad = "ok";
  openOrder(order);
}

// --- auth ----------------------------------------------------------------

function renderAuth(): void {
  const area = el("auth-area");
  area.replaceChildren();
  if (identity) {
    const principal = document.createElement("span");
    principal.className = "principal";
    principal.title = identity.getPrincipal().toText();
    principal.textContent = shortPrincipal(identity.getPrincipal().toText());
    const out = document.createElement("button");
    out.textContent = "Sign out";
    out.onclick = async () => {
      await signOut();
      setIdentity(null);
    };
    area.append(principal, out);
  } else {
    const inBtn = document.createElement("button");
    inBtn.className = "cta-secondary";
    // Not "Sign in with Internet Identity": naming the mechanism above the fold
    // imports the vocabulary the Google-plus-card path is meant to delete. The
    // provider buttons are on the identity screen itself; this is just the way in.
    inBtn.textContent = "Sign in";
    // The same failure copy as the CTA, and for the same reason: this button can
    // fail with a blocked pop-up or an unreachable provider too, and it used to
    // swallow both. A header button that does nothing when clicked is the worst
    // of the three outcomes, because it looks like the app ignored you.
    inBtn.onclick = () => startSignIn(showAuthError);
    area.append(inBtn);
  }
}

/// Begin sign-in from a click, reporting failure wherever the caller says.
///
/// See `onSignInClick` for why `signIn()` must be the first statement: signer-js
/// opens its window itself and refuses to outside a click handler.
function startSignIn(report: (message: string | null) => void): void {
  report(null);
  signIn()
    .then((next) => setIdentity(next))
    .catch((error) => report(signInFailureMessage(error)));
}

function showAuthError(message: string | null): void {
  const node = document.getElementById("auth-error");
  if (!node) return;
  node.textContent = message ?? "";
  show("auth-error", message !== null);
}

function setIdentity(next: Identity | null): void {
  identity = next;
  backend = buildBackend(next);
  showAuthError(null);
  renderAuth();
  renderSubmitGate();
  // Visibility belongs to renderView, which is what makes history a VIEW rather
  // than a section pinned to the bottom of whatever else is on screen. Signing in
  // reveals the header link, not the table.
  renderView();
  if (identity) {
    const owner = el<HTMLInputElement>("ledger-owner");
    if (!owner.value) owner.value = identity.getPrincipal().toText();
    void refreshHistory();
  } else {
    stopPolling();
    orderCount = 0;
    activeOrder = null;
    orderLoad = "missing";
    el("orders").replaceChildren();
    // Visibility is renderView's, above: signing out cannot leave an order on
    // screen because the order view no longer owns anything to show.
    renderView();
  }
}

// --- tiers + gates -------------------------------------------------------

async function loadMarket(): Promise<void> {
  const [tierList, treasury, pricing, ck] = await Promise.all([
    backend.card_tiers(),
    backend.treasury_status(),
    backend.pricing_status(),
    backend.ck_usdc_config(),
  ]);
  tiers = tierList;
  lowFloat = treasury.lowFloat;
  ckConfig = ck;
  cardFee = { feeBps: pricing.config.feeBps, feeFixedCents: pricing.config.feeFixedCents };

  // Both rate inputs are shown, because both are needed to reproduce a quote —
  // the ICP price from the Exchange Rate Canister and the XDR/ICP rate the CMC
  // will actually mint at. A buyer can query either canister and check us.
  lastPricing = pricing;
  renderRateLine();

  const gate = el("gate-notice");
  if (lowFloat) {
    gate.textContent =
      "Operator float is low, so new orders may queue until it is refilled. Paid orders always deliver at their locked quantity.";
  }
  show("gate-notice", lowFloat);

  await refreshTierQuotes();
  renderTiers();
  renderCkPanel();
  renderDestinationNote();
  renderSubmitGate();
}

/// Which destination the form is currently pointing at — the landing quantity
/// differs by destination, so every estimate needs it.
function selectedDestinationKind(): DestinationKind {
  // On the newcomer arm the radios are not rendered at all: cycles go to the
  // signed-in account unless the advanced disclosure is open.
  if (audience === "newcomer") {
    return newcomerAdvanced ? "canister" : "cyclesLedgerAccount";
  }
  const checked = document.querySelector<HTMLInputElement>('input[name="dest-kind"]:checked');
  return checked?.value === "cyclesLedgerAccount" ? "cyclesLedgerAccount" : "canister";
}

/// One round trip for the whole tier grid. Prices come from the backend's
/// `quote_previews`, which runs the same code `create_order` runs.
async function refreshTierQuotes(): Promise<void> {
  tierQuotes = new Map();
  if (tiers.length === 0) return;
  try {
    const preview = await backend.quote_previews(Rail.card, tiers.map((t) => t.usdCents));
    depositFee = preview.cyclesLedgerDepositFee;
    preview.quotes.forEach((quote, index) => {
      const tier = tiers[index];
      if (tier) tierQuotes.set(tier.id, quote);
    });
  } catch {
    // Leave the map empty — tiers render without an estimate rather than with
    // a wrong one.
  }
  // Quotes are the authoritative answer to "can this gateway price right now",
  // so the rate strip is re-rendered from them rather than left at whatever the
  // cached pair implied at load.
  renderRateLine();
}

/// The cycles-ledger deposit fee, disclosed where the choice is made rather
/// than buried in a total.
function renderDestinationNote(): void {
  const node = el("dest-fee-note");
  if (selectedDestinationKind() === "canister" || depositFee === 0n) {
    show("dest-fee-note", false);
    return;
  }
  node.textContent =
    `The cycles ledger charges ${formatCycles(depositFee)} cycles to accept a deposit, ` +
    `so an account receives that much less than a canister top-up. It is not added to your price.`;
  show("dest-fee-note", true);
}

// maxUsdCents = 0 is the backend's fail-closed default: the rail exists but
// the operator has not sized it yet.
function ckRailDisabled(): boolean {
  return ckConfig === null || ckConfig.maxUsdCents === 0n;
}

/// Take the ck-USDC markup out of the document entirely while the rail is off.
///
/// Hiding it is not enough. The rail ships disabled and may never be activated,
/// so a tab and a panel that merely happen to be `hidden` still put "ck-USDC" in
/// the accessibility tree, in find-in-page, and one CSS mistake away from being
/// on screen — which is precisely how `.rails { display: flex }` put it back.
/// Absent beats hidden for something we may never ship.
/// Called only once the config has actually been read, never on the null-config
/// guess made at first paint.
function removeDisabledRailMarkup(): void {
  if (ckConfig === null || !ckRailDisabled()) return;
  document.getElementById("rail-nav")?.remove();
  document.getElementById("ck-panel")?.remove();
}

function renderCkPanel(): void {
  // Nothing to render once the markup is gone. Reached on the disabled path via
  // loadMarket, so this guard is what lets the removal above be safe.
  if (document.getElementById("ck-panel") === null) return;
  const disabled = ckRailDisabled();
  show("ck-disabled-notice", disabled);
  el<HTMLInputElement>("ck-amount").disabled = disabled;
  const line = el("ck-bounds-line");
  if (ckConfig === null || disabled) {
    line.textContent = "";
    return;
  }
  const fee =
    ckConfig.feeBps === 0n && ckConfig.feeFixedCents === 0n
      ? "no processor fee"
      : `fee ${Number(ckConfig.feeBps) / 100}% + ${formatUsdCents(ckConfig.feeFixedCents)}`;
  line.textContent =
    `Between ${formatUsdCents(ckConfig.minUsdCents > 0n ? ckConfig.minUsdCents : 1n)} and ${formatUsdCents(ckConfig.maxUsdCents)} · ${fee} · ` +
    `ledger fee ${formatCkUsdcUnits(ckConfig.ledgerFeeUnits)} per transfer · cycles are locked at order creation`;
}

/// Live estimate under the ck-USDC amount box, from the backend's quote.
function renderCkEstimate(): void {
  // The ck-USDC markup is removed while the rail is disabled, so every
  // shared code path that touches it needs this. See removeDisabledRailMarkup.
  if (document.getElementById("ck-panel") === null) return;
  const node = el("ck-estimate");
  if (ckQuote === null || ckConfig === null || ckRailDisabled()) {
    show("ck-estimate", false);
    return;
  }
  const destination = selectedDestinationKind();
  const fee = { feeBps: ckConfig.feeBps, feeFixedCents: ckConfig.feeFixedCents };
  node.textContent =
    `${estimateLine(ckQuote.cycles ?? null, destination, depositFee)} · ` +
    `${feeBreakdown(ckQuote.usdCents, ckQuote.feeCents, ckQuote.netCents, fee)} ${RATE_LOCK_NOTE}`;
  show("ck-estimate", true);
}

/// Debounced re-quote as the amount is typed. A malformed amount clears the
/// estimate rather than leaving a stale one that belongs to different input.
function scheduleCkQuote(): void {
  // The ck-USDC markup is removed while the rail is disabled, so every
  // shared code path that touches it needs this. See removeDisabledRailMarkup.
  if (document.getElementById("ck-panel") === null) return;

  clearRequote();
  if (ckQuoteTimer !== null) clearTimeout(ckQuoteTimer);
  const parsed = parseUsdAmount(el<HTMLInputElement>("ck-amount").value);
  if (!parsed.ok) {
    ckQuote = null;
    renderCkEstimate();
    return;
  }
  const cents = parsed.cents;
  ckQuoteTimer = setTimeout(() => {
    void (async () => {
      try {
        const preview = await backend.quote_previews(Rail.ckUsdc, [cents]);
        depositFee = preview.cyclesLedgerDepositFee;
        ckQuote = preview.quotes[0] ?? null;
      } catch {
        ckQuote = null;
      }
      renderCkEstimate();
    })();
  }, QUOTE_DEBOUNCE_MS);
}

/// The rate strip under the amounts.
///
/// Keyed on whether the gateway can actually QUOTE, not on whether a rate pair is
/// cached. Those differ: `pricing_status.rates` returns the last pair fetched even
/// when it has aged past `maxAgeNs` or the most recent refresh failed. Rendering
/// on presence alone printed a live-looking "ICP $4.55 · 3.5000 XDR/ICP" directly
/// above three tiles each saying "No exchange rate available right now" — the page
/// quoting a price it would refuse to honour.
function renderRateLine(): void {
  const node = document.getElementById("rate-line");
  if (!node || lastPricing === null) return;
  const pricing = lastPricing;
  // The authoritative signal: a quote either came back with a cycle quantity or
  // it did not. Falls back to the last refresh attempt before any tier is priced.
  const priceable =
    tierQuotes.size > 0
      ? [...tierQuotes.values()].some((q) => q.cycles !== undefined)
      : pricing.lastAttempt?.ok !== false;

  if (pricing.rates && priceable) {
    const rates = pricing.rates;
    const usdPerIcp = (Number(rates.usdPerIcpMicros) / 1e6).toFixed(2);
    const xdrPerIcp = (Number(rates.xdrPermyriadPerIcp) / 1e4).toFixed(4);
    const fee = `fee ${Number(pricing.config.feeBps) / 100}% + ${formatUsdCents(pricing.config.feeFixedCents)}`;
    node.textContent =
      `ICP $${usdPerIcp} · ${xdrPerIcp} XDR/ICP · ${fee} · cycles are locked at order creation`;
    return;
  }
  node.textContent =
    "No exchange rate available right now. Orders are paused until one is fetched.";
}

/// The last `pricing_status`, so the rate strip can be re-rendered when quotes
/// arrive rather than only at load.
let lastPricing: PricingStatus | null = null;

function renderTiers(): void {
  const container = el("tiers");
  container.replaceChildren();
  if (tiers.length === 0) {
    const p = document.createElement("p");
    p.className = "muted";
    // Distinguish "the operator has configured none" from "we could not ask".
    // Printing the former on a network failure tells the visitor the product is
    // empty when it is merely unreachable.
    p.textContent =
      marketState === "loading"
        ? "Loading amounts…"
        : marketState === "failed"
          ? "Amounts could not be loaded."
          : "No amounts are configured yet.";
    container.append(p);
    return;
  }
  const destination = selectedDestinationKind();
  for (const tier of tiers) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "tier" + (tier.id === selectedTierId ? " selected" : "");
    const amount = document.createElement("span");
    amount.className = "amount";
    amount.textContent = formatUsdCents(tier.usdCents);
    // The cycle quantity, which is what the buyer is actually choosing between.
    const label = document.createElement("span");
    label.className = "cycles";
    const quoted = tierQuotes.get(tier.id);
    label.textContent = quoted === undefined
      ? "not yet"
      : estimateLine(quoted.cycles ?? null, destination, depositFee);
    btn.append(amount, label);
    btn.onclick = () => {
      selectedTierId = tier.id;
      clearRequote();
      renderTiers();
      renderTierDetail();
      renderSubmitGate();
    };
    container.append(btn);
  }
  renderTierDetail();
}

/// Fee split and rate-lock note for the selected tier.
function renderTierDetail(): void {
  const node = el("tier-detail");
  const quote = selectedTierId === null ? undefined : tierQuotes.get(selectedTierId);
  if (!quote || cardFee === null) {
    show("tier-detail", false);
    return;
  }
  node.textContent =
    `${feeBreakdown(quote.usdCents, quote.feeCents, quote.netCents, cardFee)} ${RATE_LOCK_NOTE}`;
  show("tier-detail", true);
}

/// Show the chooser, or the arm the visitor picked.
///
/// The two arms differ in what they ASK, not only in wording: the newcomer arm
/// renders no destination question at all, because a canister-id field is
/// unanswerable for someone whose first canister does not exist yet.
/// Owns the DESTINATION arms only. View visibility belongs to `renderView`;
/// having both toggle `#buy-flow` meant two owners for one decision, and they
/// disagreed the moment routing arrived.
function renderAudience(): void {
  const chosen = audience !== null;
  show("dest-newcomer", audience === "newcomer");
  show("dest-choice", audience === "live");

  const kind = selectedDestinationKind();
  show("dest-canister", chosen && kind === "canister");
  // The newcomer escape hatch is "sending to someone else's canister?", so it
  // reveals the canister field and nothing else. The owner/subaccount fields
  // belong to the already-live account option; showing them on the newcomer arm
  // put two destination inputs on screen at once, only one of which was read.
  show("dest-ledger-advanced", audience === "live" && kind === "cyclesLedgerAccount");

  // The rail nav is a nav only when there is something to navigate between. A
  // single visible tab is noise, and a disabled second one promises a rail that
  // may never ship — so when it is off the markup is removed outright.
  // Hidden here, removed later. At first paint `ckConfig` is still null, so
  // `ckRailDisabled()` is true for a rail that may turn out to be enabled —
  // removing on that guess deleted the markup before the answer arrived.
  show("rail-nav", !ckRailDisabled());
  if (ckRailDisabled() && activeRail !== "card") setRail("card");

  renderDestinationNote();
}

function chooseAudience(next: Audience): void {
  audience = next;
  newcomerAdvanced = false;
  remember(next);
  renderAudience();
  renderTiers();
  renderCkEstimate();
  renderSubmitGate();
  // A chosen arm IS the buy view. Pushed, not replaced: the visitor asked for
  // this, so Back should return them to the chooser.
  navigate({ view: "buy" });
}

function renderSubmitGate(): void {
  const btn = el<HTMLButtonElement>("create-order");
  // Reset both every render: the button's ROLE changes with sign-in state, and a
  // stale click handler left over from the signed-out state would swallow the
  // submit once the user signs in.
  if (identity) {
    btn.type = "submit";
    btn.onclick = null;
  }
  show("signin-providers", !identity);
  if (!identity) {
    // Enabled, not disabled. A permanently greyed-out button at the end of the
    // flow is a dead end: the only other affordance was a header button, which
    // is not where someone who just picked an amount is looking.
    //
    // And type="button", not submit: signer-js will only open its window from a
    // click handler, so sign-in cannot travel through the form's submit event.
    btn.disabled = false;
    btn.type = "button";
    btn.onclick = onSignInClick;
    btn.textContent = "Sign in and continue";
  } else if (activeRail === "card" && selectedTierId === null) {
    btn.disabled = true;
    btn.textContent = "Pick an amount";
  } else if (activeRail === "ckUsdc" && ckRailDisabled()) {
    btn.disabled = true;
    btn.textContent = "ck-USDC is not enabled yet";
  } else if (activeRail === "card" && tierQuotes.get(selectedTierId ?? "")?.cycles === undefined) {
    // Pricing is unavailable, so create_order would refuse. Say that here
    // instead of letting the user find out by clicking.
    btn.disabled = true;
    btn.textContent = "Pricing unavailable, try again shortly";
  } else if (acknowledgedQuote !== null) {
    btn.disabled = false;
    btn.textContent = "Confirm at the new rate";
  } else {
    btn.disabled = false;
    btn.textContent = "Create order & lock the rate";
  }
}

/// The estimate the buyer has acknowledged for the current amount.
///
/// Set when the gateway refuses a purchase because the rate moved past the 5%
/// tolerance: the new figure goes on screen and the next click pins *it*, so a
/// second refusal means a second real move rather than a loop.
let acknowledgedQuote: { cents: bigint; cycles: bigint } | null = null;

function clearRequote(): void {
  if (acknowledgedQuote === null) return;
  acknowledgedQuote = null;
  showQuoteNotice(null);
  renderSubmitGate();
}

function showQuoteNotice(message: string | null): void {
  const node = el("quote-notice");
  node.textContent = message ?? "";
  show("quote-notice", message !== null);
}

/// The quantity to pin for an amount, honouring an acknowledged re-quote.
/// `null` means "no expectation pinned" — the gateway prices without a floor.
/// Only reached when no estimate was ever displayed, which is the one case where
/// there is nothing to protect the buyer against.
function pinFor(usdCents: bigint, shown: bigint | null): bigint | null {
  const base = acknowledgedQuote?.cents === usdCents ? acknowledgedQuote.cycles : shown;
  return base === null ? null : minAcceptableCycles(base);
}

/// Show a `#quoteChanged` refusal and arm the confirming click.
function onQuoteChanged(usdCents: bigint, quoted: bigint): void {
  acknowledgedQuote = { cents: usdCents, cycles: quoted };
  showQuoteNotice(quoteChangedMessage(quoted, selectedDestinationKind(), depositFee));
  renderSubmitGate();
}

function setRail(rail: RailKey): void {
  activeRail = rail;
  clearRequote();
  document.getElementById("rail-card")?.classList.toggle("active", rail === "card");
  document.getElementById("rail-ckusdc")?.classList.toggle("active", rail === "ckUsdc");
  show("card-panel", rail === "card");
  show("ck-panel", rail === "ckUsdc");
  showFormError(null);
  renderSubmitGate();
}

// --- order creation ------------------------------------------------------

function readDestination(): { ok: true; value: Destination } | { ok: false; error: string } {
  // Newcomer arm, default path: their own account. No field to fill in, and no
  // way to mistype a principal, which is the whole point of hiding the question.
  if (audience === "newcomer" && !newcomerAdvanced) {
    if (!identity) return { ok: false, error: "Sign in to continue." };
    return {
      ok: true,
      value: {
        __kind__: "cyclesLedgerAccount",
        cyclesLedgerAccount: { owner: identity.getPrincipal(), subaccount: undefined },
      },
    };
  }
  const kind = selectedDestinationKind();
  if (kind === "canister") {
    const text = el<HTMLInputElement>("canister-principal").value.trim();
    if (!text) return { ok: false, error: "Enter the canister id to top up." };
    try {
      return { ok: true, value: { __kind__: "canister", canister: Principal.fromText(text) } };
    } catch {
      return { ok: false, error: `"${text}" is not a valid principal.` };
    }
  }
  const ownerText = el<HTMLInputElement>("ledger-owner").value.trim();
  if (!ownerText) return { ok: false, error: "Enter the account owner principal." };
  let owner: Principal;
  try {
    owner = Principal.fromText(ownerText);
  } catch {
    return { ok: false, error: `"${ownerText}" is not a valid principal.` };
  }
  const sub = parseSubaccountHex(el<HTMLInputElement>("ledger-subaccount").value);
  if (!sub.ok) return { ok: false, error: sub.error };
  return {
    ok: true,
    value: {
      __kind__: "cyclesLedgerAccount",
      cyclesLedgerAccount: { owner, subaccount: sub.value ?? undefined },
    },
  };
}

/// A sentence for the visitor, and the real error for whoever is debugging.
///
/// Raw agent and HTTP messages must never reach the page: they are unreadable to
/// the audience this is built for, and on a property that takes card details they
/// leak internals to no one's benefit. Every call site pairs a plain sentence
/// with a console entry carrying the original.
function reportCallFailure(context: string, error: unknown): string {
  // eslint-disable-next-line no-console
  console.error(context, error);
  return "Could not reach the gateway. Nothing was charged. Please try again.";
}

/// Why sign-in did not complete.
///
/// A blanket "Sign-in was cancelled" was wrong and actively harmful: it is the
/// one outcome that needs no action, so reporting it for a blocked popup or an
/// unreachable identity provider tells the user to relax about a problem they
/// have to fix. Closing the window is only ONE of the ways this rejects.
function signInFailureMessage(error: unknown): string {
  // eslint-disable-next-line no-console
  console.error("sign-in failed", error);
  const text = error instanceof Error ? error.message : String(error);
  if (/UserInterrupt|closed|cancel/i.test(text)) {
    return "Sign-in was cancelled. Nothing was charged.";
  }
  if (/popup|blocked|window/i.test(text)) {
    return "The sign-in window could not open. Allow pop-ups for this site and try again.";
  }
  // Anything else: the provider is unreachable or refused. Say that, and say
  // where to look, rather than implying the user did something.
  return (
    "Could not reach the sign-in service. Nothing was charged. " +
    "The browser console has the details."
  );
}

function showFormError(message: string | null): void {
  const node = el("form-error");
  node.textContent = message ?? "";
  show("form-error", message !== null);
}

/// Start sign-in from a **click**, synchronously.
///
/// signer-js opens the signer window itself and refuses to do so outside a click
/// handler: "channels must be established in a click handler". Routing this
/// through the form's `submit` handler broke that — the window never opened and
/// the page reported a blocked pop-up, which sent the user to their browser
/// settings for a problem that was not there.
///
/// So `signIn()` is invoked as the first statement of a real click listener, with
/// nothing awaited before it. The promise is handled afterwards; only the CALL
/// has to happen inside the gesture.
function onSignInClick(): void {
  startSignIn(showFormError);
}

async function onCreateOrder(event: SubmitEvent): Promise<void> {
  event.preventDefault();
  // Signed out the CTA is not a submit button at all (see renderSubmitGate), so
  // this is unreachable then. Kept as a guard rather than an assumption.
  if (!identity) return;
  showFormError(null);
  if (!identity) return;
  const dest = readDestination();
  if (!dest.ok) {
    showFormError(dest.error);
    return;
  }

  const btn = el<HTMLButtonElement>("create-order");
  btn.disabled = true;
  btn.textContent = "Creating order…";
  try {
    if (activeRail === "card") await createCardOrder(dest.value);
    else await createCkOrder(dest.value);
  } catch (error) {
    showFormError(reportCallFailure("create_order failed", error));
  } finally {
    renderSubmitGate();
  }
}

async function createCardOrder(dest: Destination): Promise<void> {
  if (selectedTierId === null) return;
  const tier = tiers.find((t) => t.id === selectedTierId);
  if (!tier) {
    showFormError("That amount is no longer offered. Reload the page.");
    return;
  }
  const shown = tierQuotes.get(tier.id)?.cycles ?? null;
  const result = await backend.create_order(tier.id, dest, pinFor(tier.usdCents, shown));
  if (result.__kind__ === "err") {
    if (result.err.__kind__ === "quoteChanged") {
      onQuoteChanged(tier.usdCents, result.err.quoteChanged.quoted);
      return;
    }
    showFormError(
      result.err.__kind__ === "notAdmitted"
        ? gateReasonMessage(result.err.notAdmitted as GateReason)
        : createOrderErrorMessage(result.err.__kind__),
    );
    return;
  }
  clearRequote();
  const created = result.ok;
  payLinks.set(created.order.id, paymentLinkWithRef(tier.paymentLinkUrl, created.clientReferenceId));
  lockNotice = lockedVsEstimate(created.order.lockedCycles, shown);
  openOrder(created.order, created.clientReferenceId);
  void refreshHistory();
}

async function createCkOrder(dest: Destination): Promise<void> {
  const amount = parseUsdAmount(el<HTMLInputElement>("ck-amount").value);
  if (!amount.ok) {
    showFormError(amount.error);
    return;
  }
  const shown = ckQuote?.cycles ?? null;
  const result = await backend.create_ck_usdc_order(amount.cents, dest, pinFor(amount.cents, shown));
  if (result.__kind__ === "err") {
    if (result.err.__kind__ === "quoteChanged") {
      onQuoteChanged(amount.cents, result.err.quoteChanged.quoted);
      return;
    }
    showFormError(createCkOrderErrorMessage(result.err));
    return;
  }
  clearRequote();
  const created = result.ok;
  lockNotice = lockedVsEstimate(created.order.lockedCycles, shown);
  // approveUnits as quoted at creation — the claim error corrects it if the
  // ledger fee config drifts before the user gets around to approving.
  ckRequiredUnits.set(created.order.id, created.approveUnits);
  openOrder(created.order);
  void refreshHistory();
}

// --- active order + polling ----------------------------------------------

function describeDestination(order: Order): string {
  const dest = order.destination;
  switch (dest.__kind__) {
    case "canister":
      return `canister ${dest.canister.toText()}`;
    case "cyclesLedgerAccount": {
      const account = dest.cyclesLedgerAccount;
      const sub = account.subaccount;
      const subText = sub && sub.length > 0
        ? `, subaccount ${[...sub].map((b) => b.toString(16).padStart(2, "0")).join("")}`
        : "";
      // "cycles-ledger account <62-char principal>" is operator vocabulary. The
      // buyer's own account is the common case by far and needs no id at all;
      // anything else is someone else's, and there the id is the whole point.
      const mine = identity !== null && account.owner.toText() === identity.getPrincipal().toText();
      if (mine && subText === "") return "your account";
      return `account ${account.owner.toText()}${subText}`;
    }
  }
}

function renderOrder(order: Order, clientReferenceId?: string): void {
  // Writes into `#active-order`, which the order view owns and no other view
  // does. The poll ticks every 3 s regardless of where the visitor has since
  // navigated, so without this a tick could refill and re-reveal the order panel
  // underneath the history table or the buy form.
  if (currentView !== "order") return;
  el("order-id-short").textContent = `${order.id.slice(0, 8)}…`;
  el("order-rail").textContent = isCkOrder(order) ? "ck-USDC" : "Card";
  // No "≈" here: the rate is locked, so this figure is what the order pays out.
  const destination = order.destination.__kind__ === "canister" ? "canister" : "cyclesLedgerAccount";
  el("order-cycles").textContent = estimateLine(order.lockedCycles, destination, depositFee)
    .replace(/^≈ /, "");
  el("order-price").textContent = formatUsdCents(order.pricing.usdCents);
  el("order-dest").textContent = describeDestination(order);
  const lockNode = el("order-lock-notice");
  lockNode.textContent = lockNotice ?? "";
  show("order-lock-notice", lockNotice !== null);
  el("order-rate").textContent =
    `$${(Number(order.pricing.usdPerIcpMicros) / 1e6).toFixed(2)}/ICP · ` +
    `${(Number(order.pricing.xdrPermyriadPerIcp) / 1e4).toFixed(4)} XDR/ICP · locked at creation`;
  // XDR is the unit the CMC mints against, so it belongs in the verifiable
  // record — but the headline number a buyer recognises is the dollar rate.

  const key = statusKeyOf(order);
  const info = statusInfo(key);

  const timeline = el("timeline");
  timeline.replaceChildren();
  STEPS.forEach((step, index) => {
    const li = document.createElement("li");
    li.textContent = step;
    if (info.step >= 0) {
      if (index < info.step || (info.terminal && index === info.step)) li.className = "done";
      else if (index === info.step) li.className = "now";
    }
    timeline.append(li);
  });

  const statusLine = el("order-status-line");
  statusLine.textContent = info.label;
  statusLine.className = `tone-${info.tone}`;

  const awaitingPayment = key === "created" || key === "expired";
  const isCk = isCkOrder(order);

  const link = payLinks.get(order.id);
  show("pay-area", !isCk && awaitingPayment && link !== undefined);
  if (link !== undefined) {
    el<HTMLAnchorElement>("pay-link").href = link;
  }
  if (clientReferenceId !== undefined) {
    el("client-ref").textContent = clientReferenceId;
  }

  // Unlike the card link, the approve→claim flow is reconstructable for any
  // session: the amount derives from the pricing snapshot, the ledger fee
  // from public config — so reopened ck orders stay payable.
  show("ck-pay-area", isCk && awaitingPayment);
  if (isCk && awaitingPayment) renderCkPay(order);

  // Only an unpaid order can be given up on; past payment it is going to
  // deliver, and offering a cancel there would promise something untrue.
  show("cancel-area", awaitingPayment && identity !== null);
  el<HTMLButtonElement>("cancel-order").disabled = false;

  void renderReceipt(order);
}

/// Receipt + price verification for a delivered order.
///
/// The check runs here, on the buyer's machine, from the rate inputs the receipt
/// carries — both queryable from the XRC and the CMC. A gateway asserting its own
/// price is correct proves nothing; recomputing it somewhere the operator does
/// not control is the whole point.
/// The guided tour: steps 3 and 4, on the screen where they are the next action.
///
/// For a newcomer these two commands ARE the deliverable — cycles they cannot
/// reach from the CLI are worth nothing to them — so on delivery they lead and
/// the order facts collapse beneath.
///
/// A canister top-up gets none of it: the cycles are already where they will be
/// spent. An already-live buyer funding their ACCOUNT does get it, but collapsed,
/// because a repeat buyer has probably linked already (issue #21).
/// A third-party account gets the fact and none of the commands: `icp identity
/// link web` links the buyer's own identity, so following it would land them on
/// their own empty balance and read as the cycles having gone missing.
function renderTour(order: Order | null, delivered: boolean): void {
  const node = document.getElementById("tour");
  if (!node) return;
  const kind = tourKind(order);
  if (!delivered || kind === "none") {
    node.hidden = true;
    return;
  }
  show("tour-steps", kind === "self");
  show("tour-third-party", kind === "third-party");
  if (kind === "self") {
    const owner = (order!.destination as { cyclesLedgerAccount: { owner: Principal } })
      .cyclesLedgerAccount.owner;
    el("credited-principal").textContent = owner.toText();
    el("cmd-link").textContent = linkIdentityCommand();
    el("cmd-verify").textContent = verifyIdentityCommand();
  }
  node.hidden = false;
}

async function renderReceipt(order: Order): Promise<void> {
  if (!identity || statusKeyOf(order) !== "delivered") {
    show("receipt-area", false);
    return;
  }
  let receipt: Awaited<ReturnType<Backend["receipt"]>>;
  try {
    receipt = await backend.receipt(order.id);
  } catch {
    show("receipt-area", false);
    return;
  }
  if (!receipt) {
    show("receipt-area", false);
    return;
  }
  const v = receipt.verification;
  el("receipt-paid").textContent = receipt.paidUsdCents === undefined
    ? "not yet"
    : formatUsdCents(receipt.paidUsdCents);
  el("receipt-minted").textContent = receipt.cyclesMinted === undefined
    ? "not yet"
    : formatCycles(receipt.cyclesMinted);
  el("receipt-block").textContent = receipt.mintBlockIndex === undefined
    ? "not yet"
    : receipt.mintBlockIndex.toString();
  el("receipt-sources").textContent =
    rateSourceNote(v.rateReceivedRates, v.rateQueriedSources) || "not yet";

  const check = checkReceipt(v, receipt.order.lockedCycles);
  el("receipt-formula").textContent = check.formula;
  const verdict = el("receipt-verdict");
  verdict.textContent = check.matches
    ? "Verified: recomputed from these inputs, the price matches the cycles this order locked."
    : "Mismatch: recomputing from these inputs does not match the locked quantity. Please contact support with the order id.";
  verdict.className = check.matches ? "tone-ok" : "tone-err";
  show("receipt-area", true);
}

/// Give up on an unpaid order.
///
/// The open-order cap counts unpaid orders, so without this a buyer who started
/// several checkouts and finished none would be refused new orders until the TTL
/// expired them — with the refusal telling them to abandon one and no way to.
async function onCancelOrder(): Promise<void> {
  if (!identity || pollOrderId === null) return;
  const orderId = pollOrderId;
  const btn = el<HTMLButtonElement>("cancel-order");
  btn.disabled = true;
  const status = el("cancel-status");
  try {
    const result = await backend.cancel_order(orderId);
    if (result.__kind__ === "err") {
      status.textContent = result.err;
      show("cancel-status", true);
      btn.disabled = false;
      return;
    }
    show("cancel-status", false);
    lockNotice = null;
    renderOrder(result.ok);
    void refreshHistory();
  } catch (error) {
    status.textContent = reportCallFailure("cancel_order failed", error);
    show("cancel-status", true);
    btn.disabled = false;
  }
}

// --- ck-USDC approve → claim ------------------------------------------------

function ckApproveUnitsFor(order: Order): bigint {
  const fallbackFee = ckConfig?.ledgerFeeUnits ?? 10_000n;
  return ckRequiredUnits.get(order.id) ?? ckUnitsForCents(order.pricing.usdCents) + fallbackFee;
}

function setCkFlowStatus(message: string | null, tone: "muted" | "err" = "muted"): void {
  const node = el("ck-flow-status");
  node.textContent = message ?? "";
  node.className = tone === "err" ? "error" : "muted";
  show("ck-flow-status", message !== null);
}

/// Re-rendered on every poll tick — updates amounts and button state but
/// never clobbers the flow-status line an in-flight call owns.
function renderCkPay(order: Order): void {
  el("ck-pay-amount").textContent = formatCkUsdcUnits(ckApproveUnitsFor(order));
  const busy = ckBusyOrderId === order.id;
  el<HTMLButtonElement>("ck-approve").disabled = busy || !identity;
  el<HTMLButtonElement>("ck-claim").disabled = busy || !identity;
}

async function onCkApprove(): Promise<void> {
  if (!identity || pollOrderId === null || ckBusyOrderId !== null) return;
  if (!backendCanisterId) return;
  const orderId = pollOrderId;
  let order: Order | null = null;
  try {
    order = await backend.get_order(orderId);
  } catch {
    setCkFlowStatus("Could not reach the gateway. Try again.", "err");
    return;
  }
  if (order === null) return;
  const units = ckApproveUnitsFor(order);
  ckBusyOrderId = orderId;
  renderCkPay(order);
  setCkFlowStatus(`Approving ${formatCkUsdcUnits(units)} on the ck-USDC ledger…`);
  try {
    const result = await makeCkUsdcLedger(identity).icrc2_approve({
      from_subaccount: [],
      spender: { owner: Principal.fromText(backendCanisterId), subaccount: [] },
      amount: units,
      expected_allowance: [],
      expires_at: [],
      fee: [],
      memo: [],
      created_at_time: [],
    });
    if ("Err" in result) {
      setCkFlowStatus(approveErrorMessage(result.Err), "err");
      return;
    }
    setCkFlowStatus("Approved. Claiming…");
    await claimCkOrder(orderId);
  } catch (error) {
    setCkFlowStatus(
      reportCallFailure("ck-USDC approve failed", error),
      "err",
    );
  } finally {
    ckBusyOrderId = null;
    if (order) renderCkPay(order);
  }
}

async function onCkClaim(): Promise<void> {
  if (!identity || pollOrderId === null || ckBusyOrderId !== null) return;
  const orderId = pollOrderId;
  ckBusyOrderId = orderId;
  setCkFlowStatus("Claiming…");
  try {
    await claimCkOrder(orderId);
  } finally {
    ckBusyOrderId = null;
  }
}

/// One claim attempt; on success the order is #paid and the regular poll
/// takes over (it hides this whole area on the next render).
async function claimCkOrder(orderId: string): Promise<void> {
  let result: Awaited<ReturnType<Backend["claim_ck_usdc_order"]>>;
  try {
    result = await backend.claim_ck_usdc_order(orderId);
  } catch (error) {
    setCkFlowStatus(
      reportCallFailure("ck-USDC claim failed", error),
      "err",
    );
    return;
  }
  if (result.__kind__ === "err") {
    const info = claimErrorInfo(result.err);
    setCkFlowStatus(info.message, info.action === "retry" ? "muted" : "err");
    if (info.action === "approve" && info.requiredUnits !== undefined) {
      // The ledger's number wins — the next approve uses it.
      ckRequiredUnits.set(orderId, info.requiredUnits);
    }
    return;
  }
  setCkFlowStatus(null);
  renderOrder(result.ok);
  void refreshHistory();
}

function stopPolling(): void {
  if (pollTimer !== null) clearInterval(pollTimer);
  pollTimer = null;
  pollOrderId = null;
  lastPolledStatus = null;
}

function openOrder(order: Order, clientReferenceId?: string): void {
  activeOrder = order;
  orderLoad = "ok";
  navigate({ view: "order", orderId: order.id }, true);
  stopPolling();
  setCkFlowStatus(null);
  renderOrder(order, clientReferenceId);
  pollOrderId = order.id;
  lastPolledStatus = statusKeyOf(order);
  pollTimer = setInterval(() => void pollActiveOrder(), POLL_MS);
  el("active-order").scrollIntoView({ behavior: "smooth", block: "nearest" });
}

async function pollActiveOrder(): Promise<void> {
  if (pollOrderId === null) return;
  let order: Order | null = null;
  try {
    order = await backend.get_order(pollOrderId);
  } catch {
    return; // transient query failure — next tick retries
  }
  if (order === null || order.id !== pollOrderId) return;
  const key = statusKeyOf(order);
  // Through the VIEW MACHINE, not only the order panel. `delivered` is a property
  // of the ORDER rather than of the route (see view.ts), so a status the poll
  // discovers has to travel the same path a navigation does. It did not: the poll
  // refilled the facts and left `renderView` unrun, so on the only path a buyer
  // actually takes — create, pay, wait — the tour never appeared, the stepper kept
  // saying step 2 and the facts stayed expanded. The flagship surface of the whole
  // flow was reachable only by reopening the order from history.
  activeOrder = order;
  renderOrder(order);
  renderView();
  if (key !== lastPolledStatus) {
    lastPolledStatus = key;
    void refreshHistory();
  }
  if (statusInfo(key).terminal) stopPolling();
}

// --- history ---------------------------------------------------------------

async function refreshHistory(): Promise<void> {
  if (!identity) return;
  let orders: Order[];
  try {
    orders = await backend.list_orders();
  } catch {
    return;
  }
  orders.sort((a, b) => (b.createdAtNs > a.createdAtNs ? 1 : -1));

  // Post-sign-in there is a second signal beyond the stored preference: what
  // this principal last bought. It PRE-SELECTS an arm; it never skips the
  // chooser, because a returning buyer's intent legitimately differs between
  // visits (last month a top-up, today a new project).
  const latest = orders[0];
  const suggestion = suggestFrom(
    latest ? ("canister" in latest.destination ? "canister" : "cyclesLedgerAccount") : null,
  );
  el("choose-new").classList.toggle("suggested", suggestion === "newcomer");
  el("choose-live").classList.toggle("suggested", suggestion === "live");

  orderCount = orders.length;
  // The header link appears only once there is something behind it, so this has
  // to run after the count is known rather than at sign-in.
  renderView();

  const body = el("orders");
  body.replaceChildren();
  for (const order of orders) {
    const info = statusInfo(statusKeyOf(order));
    const row = document.createElement("tr");
    const cells = [
      new Date(nsToMillis(order.createdAtNs)).toLocaleString(),
      `${order.id.slice(0, 8)}…`,
      isCkOrder(order) ? "ck-USDC" : "Card",
      formatCycles(order.lockedCycles),
      formatUsdCents(order.pricing.usdCents),
      info.label,
    ];
    cells.forEach((text, index) => {
      const td = document.createElement("td");
      td.textContent = text;
      if (index === cells.length - 1) td.className = `tone-${info.tone}`;
      row.append(td);
    });
    row.onclick = () => {
      lockNotice = null;
      openOrder(order);
    };

    // Buy again: for an operator refilling the same canister every month this
    // is the whole flow — one click plus payment.
    const actions = document.createElement("td");
    const again = document.createElement("button");
    again.type = "button";
    again.className = "buy-again";
    again.textContent = "Buy again";
    again.onclick = (event) => {
      event.stopPropagation(); // the row itself opens the order
      repeatOrder(order);
    };
    actions.append(again);
    row.append(actions);
    body.append(row);
  }
}

/// Prefill a new order from an existing one: same amount, same destination.
///
/// Deliberately does NOT submit. The price is re-quoted at today's rate, and
/// charging a card from a table row without showing the new figure would be the
/// one place this app takes money without the buyer seeing the number first.
function repeatOrder(order: Order): void {
  lockNotice = null;
  stopPolling();

  const toCanister = "canister" in order.destination;
  // Match `suggestFrom`: an account-funded order means this buyer was topping up
  // their own balance, which is the newcomer arm's shape. Defaulting that case to
  // "live" contradicted the very helper that decides the same question elsewhere.
  audience = toCanister ? "live" : "newcomer";
  newcomerAdvanced = false;
  // Deliberately NOT remembered. Repeating a past order says nothing about which
  // arm this visitor wants next time, and `remember` exists to record a choice
  // they made in the chooser — not one inferred from a table row.
  renderAudience();

  if (toCanister) {
    setDestinationKind("canister");
    el<HTMLInputElement>("canister-principal").value =
      (order.destination as { canister: Principal }).canister.toText();
    validateCanisterId();
  } else {
    // Carry the WHOLE account across, owner and subaccount both. Prefilling only
    // the kind left whatever happened to be sitting in the collapsed advanced
    // fields to decide where the money went — a silent substitution of one
    // destination for another.
    const account = (order.destination as {
      cyclesLedgerAccount: { owner: Principal; subaccount?: Uint8Array | number[] };
    }).cyclesLedgerAccount;
    if (audience === "live") setDestinationKind("cyclesLedgerAccount");
    const ownerField = document.getElementById("ledger-owner") as HTMLInputElement | null;
    if (ownerField) ownerField.value = account.owner.toText();
    const subField = document.getElementById("ledger-subaccount") as HTMLInputElement | null;
    if (subField) {
      subField.value = account.subaccount
        ? [...account.subaccount].map((b) => b.toString(16).padStart(2, "0")).join("")
        : "";
    }
  }

  // Match the tier by price. A tier that no longer exists (retired, or repriced)
  // leaves nothing selected rather than silently picking a neighbour.
  const tier = tiers.find((t) => t.usdCents === order.pricing.usdCents);
  selectedTierId = tier ? tier.id : null;
  if (tier === undefined) {
    showFormError("That amount is no longer offered. Pick one below.");
  } else {
    showFormError(null);
  }
  clearRequote();
  renderTiers();
  renderTierDetail();
  renderSubmitGate();
  // The prefill is on the BUY view, and "Buy again" is clicked from the history
  // view. Without this the button filled in a form nobody was looking at and the
  // orders table stayed on screen, so the one-click repeat purchase did nothing
  // visible at all. Pushed, not replaced: the visitor asked for it, so Back
  // returns them to their orders.
  navigate({ view: "buy" });
  el("card-panel").scrollIntoView({ behavior: "smooth", block: "start" });
}

/// Validate the canister id's shape as it is typed.
///
/// Only the already-live arm can produce an `Undeliverable` order (spec §1: only
/// canister destinations can), so catching a malformed id before payment is the
/// cheapest place to stop that. This checks SHAPE only — whether the canister
/// exists, and whether it accepts deposits, is not knowable from here.
function validateCanisterId(): boolean {
  const field = document.getElementById("canister-principal") as HTMLInputElement | null;
  const error = document.getElementById("canister-id-error");
  if (!field || !error) return true;
  const text = field.value.trim();
  if (text === "") {
    error.hidden = true;
    return false;
  }
  try {
    Principal.fromText(text);
    error.hidden = true;
    return true;
  } catch {
    error.textContent = `"${text}" is not a valid canister id.`;
    error.hidden = false;
    return false;
  }
}

/// Set the destination radio AND run the app's reaction to it.
///
/// Assigning `.checked` fires no `change` event, so the handler that owns
/// `#dest-canister` / `#dest-ledger-advanced` visibility never ran and the two
/// could disagree with the radio. One owner: this function.
function setDestinationKind(kind: DestinationKind): void {
  const radio = document.querySelector<HTMLInputElement>(
    `input[name="dest-kind"][value="${kind}"]`,
  );
  if (!radio) return;
  radio.checked = true;
  radio.dispatchEvent(new Event("change", { bubbles: true }));
}

/// Copy-to-clipboard for the CLI commands. Falls back to selecting the text:
/// clipboard access is refused in some browsers and over plain HTTP, and a
/// button that silently does nothing is worse than one that selects for you.
function wireCopyButtons(): void {
  for (const btn of document.querySelectorAll<HTMLButtonElement>("button.copy")) {
    btn.onclick = () => {
      const target = document.getElementById(btn.dataset.copy ?? "");
      if (!target) return;
      const text = target.textContent ?? "";
      const done = () => {
        const original = btn.textContent;
        btn.textContent = "Copied";
        setTimeout(() => { btn.textContent = original; }, 1_500);
      };
      void navigator.clipboard?.writeText(text).then(done).catch(() => {
        const range = document.createRange();
        range.selectNodeContents(target);
        const sel = window.getSelection();
        sel?.removeAllRanges();
        sel?.addRange(range);
      });
    };
  }
}

/// Light is the mandatory default and dark is opt-in, so this never consults
/// prefers-color-scheme — the brand guidelines forbid auto-switching. The choice
/// persists because a visitor who picked dark meant it.
const THEME_KEY = "icp.theme";

function applyTheme(dark: boolean): void {
  document.documentElement.toggleAttribute("data-theme", false);
  if (dark) document.documentElement.setAttribute("data-theme", "dark");
  else document.documentElement.removeAttribute("data-theme");
  const btn = el("theme-toggle");
  btn.textContent = dark ? "Light" : "Dark";
  btn.setAttribute("aria-label", dark ? "Switch to light theme" : "Switch to dark theme");
}

function wireThemeToggle(): void {
  let dark = false;
  try {
    dark = window.localStorage.getItem(THEME_KEY) === "dark";
  } catch {
    /* storage disabled; light default stands */
  }
  applyTheme(dark);
  el("theme-toggle").onclick = () => {
    dark = !dark;
    try {
      window.localStorage.setItem(THEME_KEY, dark ? "dark" : "light");
    } catch {
      /* the toggle still works for this session */
    }
    applyTheme(dark);
  };
}

// --- wiring ----------------------------------------------------------------

function wireDestinationToggle(): void {
  for (const radio of document.querySelectorAll<HTMLInputElement>('input[name="dest-kind"]')) {
    radio.onchange = () => {
      show("dest-canister", radio.value === "canister" ? radio.checked : !radio.checked);
      show("dest-ledger", radio.value === "cyclesLedgerAccount" ? radio.checked : !radio.checked);
      // The landing quantity depends on the destination, so every estimate on
      // screen has to follow the toggle.
      renderDestinationNote();
      renderTiers();
      renderCkEstimate();
    };
  }
}

/// Load the market, and say something a person can act on if it fails.
///
/// The previous version printed the raw error into the page. An agent or HTTP
/// message is not copy: it is unreadable to the audience this page is for, and it
/// leaks internals on a property that takes card details. The detail goes to the
/// console for whoever is debugging; the visitor gets a sentence and a retry.
/// Tri-state on purpose. "No amounts are configured yet" is a claim about the
/// operator; "could not be loaded" is a claim about the network. Before the first
/// answer arrives BOTH are false, and the agent retries an unreachable gateway
/// for several seconds — so a two-state flag put a false statement on screen for
/// the whole of that window.
let marketState: "loading" | "loaded" | "failed" = "loading";

async function loadMarketWithRetry(): Promise<void> {
  const line = el("rate-line");
  line.replaceChildren();
  try {
    await loadMarket();
    marketState = "loaded";
    // Now the rail's status is known rather than assumed, so a rail that is off
    // can be taken out of the document for good.
    removeDisabledRailMarkup();
  } catch (error) {
    marketState = "failed";
    // eslint-disable-next-line no-console
    console.error("market load failed", error);
    // A wrong-backend-id failure **with conflicting cookies present** is the
    // stale-cookie case, not an outage. Naming it is the whole difference between
    // a 30-second fix and an unexplained broken page.
    //
    // Both halves are required, in both directions. A missing canister with a
    // single correct cookie is an ordinary bad deployment; an IC0536 with a single
    // correct cookie is our own stale bindings. Telling either visitor to clear a
    // cookie sends them after something that is not there while the real cause
    // goes unnamed.
    //
    // Reached only when the init-time probe found nothing live: whenever it does
    // find a live id, `staleCookieDetected` short-circuits this. So this arm is the
    // both-copies-dead case, which is precisely when the visitor most needs to be
    // told it is their cookies and not the gateway.
    if (staleCookieDetected || (isWrongBackendId(error) && hasConflictingIcEnv(document.cookie))) {
      renderStaleCookieNotice(line);
      renderTiers();
      renderSubmitGate();
      return;
    }
    const message = document.createElement("span");
    message.textContent = "Could not reach the gateway. Nothing was charged. ";
    const again = document.createElement("button");
    again.type = "button";
    again.className = "linklike";
    again.textContent = "Try again";
    again.onclick = () => void loadMarketWithRetry();
    line.append(message, again);
    renderTiers();
    renderSubmitGate();
  }
}

async function init(): Promise<void> {
  renderAuth();
  wireDestinationToggle();
  el<HTMLFormElement>("order-form").onsubmit = (e) => void onCreateOrder(e);
  // Optional chaining, not el(): when the rail is disabled these nodes are
  // removed from the document rather than hidden.
  const canisterField = document.getElementById("canister-principal") as HTMLInputElement | null;
  if (canisterField) canisterField.oninput = () => validateCanisterId();
  const ckAmount = document.getElementById("ck-amount") as HTMLInputElement | null;
  if (ckAmount) ckAmount.oninput = () => scheduleCkQuote();
  document.getElementById("rail-card")?.addEventListener("click", () => setRail("card"));
  document.getElementById("rail-ckusdc")?.addEventListener("click", () => setRail("ckUsdc"));
  el("cancel-order").onclick = () => void onCancelOrder();
  el("ck-approve").onclick = () => void onCkApprove();
  el("ck-claim").onclick = () => void onCkClaim();

  el("choose-new").onclick = () => chooseAudience("newcomer");
  el("choose-live").onclick = () => chooseAudience("live");
  el("back-to-chooser").onclick = () => {
    // Always available from the remembered arm, so the preference can never
    // trap someone in a path that stopped fitting.
    audience = null;
    forget();
    renderAudience();
    navigate({ view: "landing" });
  };
  el("show-advanced-dest").onclick = () => {
    newcomerAdvanced = true;
    renderAudience();
    renderTiers();
    renderSubmitGate();
  };
  wireCopyButtons();
  wireThemeToggle();
  // Hash routing so Back works. An asset canister would need SPA rewrites for
  // real paths; a hash cannot 404 on reload.
  window.addEventListener("hashchange", () => applyRoute(parseRoute(window.location.hash)));
  el("history-link").onclick = () => {
    // The anchor already sets the hash; this only stops a same-hash click from
    // being a no-op after the view moved on.
    applyRoute({ view: "history" });
  };

  // Test-only, and gone from a production build: `__FIXTURES__` is replaced with
  // the literal `false` unless the build sets CYCLEPAY_FIXTURES=1, so Rollup drops
  // this branch and the dynamic import with it. See fixtures.ts for why the
  // delivered view needs a hook to be testable at all.
  if (__FIXTURES__) {
    const { installFixtures } = await import("./fixtures");
    installFixtures({
      useBackend: (factory) => {
        backendFactory = factory;
        backend = buildBackend(identity);
      },
      signIn: setIdentity,
      openOrder,
      reloadMarket: loadMarketWithRetry,
      reloadHistory: refreshHistory,
    });
  }

  // Before anything talks to the backend: if this browser is holding conflicting
  // ic_env cookies, find the id that actually answers and use that one.
  await resolveStaleIcEnv();

  audience = recall();
  renderAudience();

  // The session BEFORE the route, because the route can depend on it. `get_order`
  // answers per caller, so resolving `#/order/<id>` while still anonymous looks up
  // an order this principal cannot see, gets nothing back, and lands on "we could
  // not find that order" — for an order the visitor owns, on a plain reload. It
  // also decides whose steps 3 and 4 the tour is showing (see `tourKind`).
  const restored = await currentIdentity();
  if (restored) setIdentity(restored);

  // Parse the route the page was OPENED with, not only later hashchanges. Without
  // this a deep link or a reload on #/history silently rendered the landing view.
  applyRoute(parseRoute(window.location.hash));

  await loadMarketWithRetry();
}

void init();
