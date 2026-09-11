// CyclePay frontend (M2): II login, order
// creation, Stripe Checkout Session hand-off, live status
// polling, order history.
//
import type { Identity } from "@icp-sdk/core/agent";
import {
  makeBackend,
  backendCanisterId,
  cyclesLedgerCanisterId,
  makeCyclesIndex,
  makeCyclesLedger,
  type CyclesIndex,
  type IndexTransaction,
  type CyclesLedger,
  type PricingStatus,
  makeBackendAt,
  type Backend,
  type Destination,
  type Amount,
  type Order,
  type QuotePreview,
  type Tier,
} from "./actor";
import { currentIdentity, signIn, signOut } from "./auth";
import {
  CLI_IDENTITY_GUIDE,
  IDENTITY_SETTINGS,
  deployCommand,
  identityDefaultCommand,
  linkIdentityCommand,
  verifyBalanceCommand,
  verifyPrincipalCommand,
} from "./config";
import {
  DELIVERY_FIELDS,
  GATE_FIELDS,
  ORDER_STATUS_HINTS,
  ORPHAN_KIND_HINTS,
  PRICING_FIELDS,
  PROBLEM_KIND_HINTS,
  REFUSAL_HINTS,
  type FieldDoc,
  type Hint,
  type RefusalTag,
} from "./operator";
import {
  renderCall,
  irreversibleNote,
  type ArgumentFreeMethod,
  type CommandMethod,
} from "./candid";
import {
  clearIcEnvCookies,
  distinctBackendIds,
  hasConflictingIcEnv,
  isWrongBackendId,
  parseIcEnvCookies,
  resolveLiveBackendId,
} from "./ic-env";
import { type View, type Route, type HistoryTab, type AdminTab, parseRoute, routeHash } from "./view";
import {
  RATE_LOCK_NOTE,
  formatAgo,
  formatDuration,
  checkReceipt,
  cancelOrderErrorMessage,
  createOrderErrorMessage,
  PRE_ANNOUNCED_GATE_REASONS,
  type GateReason,
  amountLabels,
  creditedSplit,
  depositFeeLine,
  type FeeConfig,
  feeRows,
  gateReasonMessage,
  lockedVsEstimate,
  minAcceptableCycles,
  quoteChangedMessage,
  decodeBurnMemo,
  decodeOrderMemo,
  formatCycles,
  formatUsdCents,
  parseUsdAmount,
  clientReferenceFor,
  nsToMillis,
  timeUntil,
  rateSourceNote,
  shortPrincipal,
  statusInfo,
  type StatusKey,
} from "./format";

const POLL_MS = 3_000;

// The bindgen wrapper surfaces OrderStatus as a string enum whose values are
// exactly the variant labels format.ts keys on.
/// ⚠️ **No cast.** A string enum member IS assignable to its template-literal value
/// union, so `as unknown as StatusKey` was residue from when `StatusKey` was a
/// hand-written union of seven strings.
///
/// Removing it is the point rather than tidiness: bindgen has three renderings for a
/// Candid variant, and the defect this week was not knowing one of them. If an upgrade or
/// a Candid change alters how `status` is rendered, a double cast still compiles and the
/// failure lands at runtime on a buyer's order page. A plain return makes it a compile
/// error, which is the whole asymmetry the derived type was introduced to close.
function statusKeyOf(order: Order): StatusKey {
  return order.status;
}

// --- state ---------------------------------------------------------------


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
let cyclesLedgerFactory: (() => CyclesLedger) | null = null;
let cyclesIndexFactory: (() => CyclesIndex) | null = null;

/// The one place a cycles-ledger actor is built (#30 PR-A).
///
/// Separate from `buildBackend` because it is a different canister with a
/// different trust story: this app only ever READS from the ledger, and it reads
/// what the ledger alone is authoritative about.
function buildCyclesLedger(): CyclesLedger {
  if (cyclesLedgerFactory !== null) return cyclesLedgerFactory();
  return makeCyclesLedger();
}

function buildCyclesIndex(): CyclesIndex {
  if (cyclesIndexFactory !== null) return cyclesIndexFactory();
  return makeCyclesIndex();
}

/// The buyer's own cycles balance, read from the LEDGER.
///
/// ⚠️ **Read from the ledger, not proxied through this canister, and that is the
/// point.** It is the one number a buyer should never have to take our word for: the
/// cycles ledger is a public canister anyone can query. It also closes the loop on
/// what the purchase flow promises, since "your cycles go to your account" becomes
/// something the page demonstrates rather than asserts.
async function refreshLedgerBalance(): Promise<void> {
  const node = document.getElementById("ledger-balance");
  const note = document.getElementById("ledger-balance-note");
  if (!node || !note) return;
  if (identity === null) {
    ledgerBalance = null;
    node.textContent = "sign in to see it";
    note.textContent = "";
    return;
  }
  try {
    const balance = await buildCyclesLedger().icrc1_balance_of({
      owner: identity.getPrincipal(),
      subaccount: [],
    });
    ledgerBalance = balance;
    node.textContent = `${formatCycles(balance)} cycles`;
    note.textContent =
      "Read from the cycles ledger, which anyone can query. This is your whole balance,"
      + " not only what you bought here.";
  } catch {
    // ⚠️ Says the read failed rather than printing a zero. A zero is a claim about
    // the buyer's money, and "we could not ask" is a different statement.
    ledgerBalance = null;
    node.textContent = "could not read the ledger";
    note.textContent = "The balance is unchanged; only this page could not fetch it.";
  }
}

/// One account's cycles-ledger history, from the index canister.
///
/// ⚠️ **Read on-chain, and every row links out.** The gateway's own record shows the
/// orders it delivered; this shows what the LEDGER says happened, which is a superset
/// and is not ours to edit. A buyer reconciling a balance needs the second one.
async function refreshLedgerHistory(): Promise<void> {
  const host = document.getElementById("ledger-history");
  if (!host) return;
  // ⚠️ **Every path below ends in ONE `replaceChildren`, never clear-then-append.**
  // `renderView` fires this more than once per navigation, so two runs overlap: with
  // a clear at the top and an append at the bottom, both appended and the page showed
  // the list TWICE. Building the nodes first and writing once at the end makes the
  // last writer authoritative instead of additive.
  if (identity === null) {
    host.replaceChildren(mutedLine("Sign in to see your ledger activity."));
    return;
  }
  const me = identity.getPrincipal().toText();
  let result: Awaited<ReturnType<CyclesIndex["get_account_transactions"]>>;
  try {
    result = await buildCyclesIndex().get_account_transactions({
      account: { owner: identity.getPrincipal(), subaccount: [] },
      start: [],
      // A page, not everything: an account with a long history would otherwise render
      // thousands of rows nobody scrolls to.
      max_results: 25n,
    });
  } catch {
    host.replaceChildren(mutedLine(
      "Could not reach the cycles ledger index. Your balance and orders above are"
      + " unaffected; only this list could not be fetched.",
    ));
    return;
  }
  if ("Err" in result) {
    // The index answers with a message rather than a reject when it cannot serve the
    // account, so it is reported rather than swallowed into the same generic line.
    host.replaceChildren(mutedLine(`The ledger index refused: ${result.Err.message}`));
    return;
  }
  const rows = result.Ok.transactions;
  if (rows.length === 0) {
    host.replaceChildren(mutedLine(
      "No ledger activity yet. A delivered order appears here as a transfer in.",
    ));
    return;
  }

  const table = document.createElement("table");
  table.className = "orders-table";
  const head = document.createElement("thead");
  head.innerHTML =
    "<tr><th>When</th><th>Block</th><th>What</th><th>Amount</th><th>Counterparty</th>"
    + "<th>Order</th></tr>";
  const body = document.createElement("tbody");
  for (const row of rows) {
    const tr = document.createElement("tr");
    const described = describeLedgerTx(row.transaction, me);
    const when = document.createElement("td");
    when.textContent = new Date(Number(row.transaction.timestamp / 1_000_000n)).toLocaleString();
    const block = document.createElement("td");
    const link = document.createElement("a");
    link.href =
      `https://dashboard.internetcomputer.org/tokens/${cyclesLedgerCanisterId}`
      + `/transaction/${row.id}`;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.className = "order-link mono";
    link.textContent = row.id.toString();
    block.append(link);
    const what = document.createElement("td");
    what.textContent = described.what;
    const amount = document.createElement("td");
    amount.className = "mono";
    amount.textContent = described.amount;
    const other = document.createElement("td");
    other.className = "mono";
    if (described.canister !== undefined) {
      const canisterLink = document.createElement("a");
      canisterLink.href =
        `https://dashboard.internetcomputer.org/canister/${described.canister}`;
      canisterLink.target = "_blank";
      canisterLink.rel = "noopener noreferrer";
      canisterLink.className = "order-link mono";
      canisterLink.textContent = described.counterparty;
      other.append(canisterLink);
    } else {
      other.textContent = described.counterparty;
    }
    // ⚠️ **Header and cell in one change.** This table once shipped six headers and
    // five cells, which shifted every column after the gap and made the whole row read
    // wrong. A column is added in both places or neither.
    const order = document.createElement("td");
    if (described.orderId === undefined) {
      order.textContent = "-";
    } else {
      const orderLink = document.createElement("a");
      orderLink.href = `#/order/${described.orderId}`;
      orderLink.className = "order-link mono";
      orderLink.textContent = shortPrincipal(described.orderId);
      order.append(orderLink);
    }
    tr.append(when, block, what, amount, other, order);
    body.append(tr);
  }
  table.append(head, body);
  const out: HTMLElement[] = [table];
  // ⚠️ **Compared against the account's OLDEST id, not against the page size.** A full
  // page is not evidence that anything was left out: an account with exactly 25
  // transactions filled one and was told the rest were elsewhere. The index reports the
  // oldest id it holds for the account, so the last row reaching it means this page is
  // the whole history.
  const oldest = result.Ok.oldest_tx_id[0];
  if (oldest !== undefined && rows[rows.length - 1]!.id > oldest) {
    out.push(mutedLine("Showing the 25 most recent. Older entries are on the dashboard."));
  }
  host.replaceChildren(...out);
}

function mutedLine(text: string): HTMLElement {
  const p = document.createElement("p");
  p.className = "muted";
  p.textContent = text;
  return p;
}

/// Show one dashboard record and mark which tab is selected.
///
/// ⚠️ **The selected tab must be distinguishable without colour.** `aria-current`
/// carries it for assistive tech, and the stylesheet keys its weight and underline off
/// the same attribute, so the highlight is never colour alone. A tab styled only by a
/// hue fails for the colour-blind reader and disappears entirely in forced-colours
/// mode, and this control is the only thing telling you which of two similar tables
/// you are looking at.
function renderRecordTabs(tab: HistoryTab): void {
  show("panel-orders", tab === "orders");
  show("panel-ledger", tab === "ledger");
  for (const [id, owns] of [
    ["tab-orders", tab === "orders"],
    ["tab-ledger", tab === "ledger"],
  ] as const) {
    const node = document.getElementById(id);
    if (node === null) continue;
    // Set/removed rather than written as "false": `aria-current="false"` still reads as
    // present to some assistive tech, which would announce both tabs as current.
    if (owns) node.setAttribute("aria-current", "true");
    else node.removeAttribute("aria-current");
  }
}

/// Show one console panel and mark which tab is selected.
///
/// ⚠️ **Same contract as `renderRecordTabs`, including the `aria-current` handling:** set
/// or removed, never written as `"false"`, because `aria-current="false"` still reads as
/// present to some assistive tech and would announce every tab as current. The stylesheet
/// keys weight and rule off the same attribute, so the highlight is never colour alone.
function renderAdminTabs(tab: AdminTab): void {
  for (const [name, panel] of ADMIN_PANELS) {
    show(panel, name === tab);
    const node = document.getElementById(`atab-${name}`);
    if (node === null) continue;
    if (name === tab) node.setAttribute("aria-current", "true");
    else node.removeAttribute("aria-current");
  }
}

/// ⚠️ **A tuple list, not a `Record`, so the ORDER is the tab order** — and the order is
/// the design: `now` first because that is what an incident needs, `config` last because
/// it is what you touch rarely.
const ADMIN_PANELS: ReadonlyArray<readonly [AdminTab, string]> = [
  ["now", "apanel-now"],
  ["worklists", "apanel-worklists"],
  ["orders", "apanel-orders"],
  ["diagnostics", "apanel-diagnostics"],
  ["config", "apanel-config"],
];

/// The count that rides the Worklists tab.
///
/// ⚠️ **Hidden at zero rather than showing "0".** A badge that is always present trains an
/// operator to stop reading it, which defeats the reason it exists: seeing that there is
/// work without opening the panel.
///
/// ⚠️ **Fed from `operator_summary`'s own count, never from a row tally** — see the note
/// at the call site for what the two disagreeing looked like.
function renderWorklistCount(n: number): void {
  const node = document.getElementById("atab-worklists-count");
  if (node === null) return;
  node.hidden = n === 0;
  node.textContent = n === 0 ? "" : String(n);
}

/// One ledger transaction, in the buyer's terms.
///
/// ⚠️ **Direction is computed from the ACCOUNTS, not from the kind.** A `transfer` is
/// money in or money out depending on which side the caller is, and rendering "0.5 T
/// transfer" without a sign is the one formatting choice here that could make a buyer
/// think they were charged when they were paid.
function describeLedgerTx(
  tx: IndexTransaction,
  me: string,
): { what: string; amount: string; counterparty: string; canister?: string; orderId?: string } {
  const short = (a: { owner: unknown }) => shortPrincipal(String(a.owner));
  if (tx.transfer.length > 0) {
    const t = tx.transfer[0]!;
    const outgoing = String(t.from.owner) === me;
    // A delivery arrives as a transfer FROM the gateway, and its memo is the order id.
    // Gated on the sender inside `decodeOrderMemo`, because transfer memos are
    // caller-supplied and an ungated read would let a stranger name one of our orders.
    const orderId = decodeOrderMemo(
      t.memo,
      String(t.from.owner),
      liveBackendId ?? backendCanisterId,
    );
    return {
      what: outgoing ? "Sent" : "Received",
      amount: `${outgoing ? "-" : "+"}${formatCycles(t.amount)}`,
      counterparty: outgoing ? short(t.to) : short(t.from),
      ...(orderId === null ? {} : { orderId }),
    };
  }
  if (tx.mint.length > 0) {
    const m = tx.mint[0]!;
    // ⚠️ **Not "minted from ICP", and deliberately not labelled from its memo either.**
    // Cycles recovered from a deleted canister arrive as a mint, and so do the refunds of
    // a failed creation (memo `FD * 32`) and a failed withdraw (memo `FF * 32`). Naming
    // those would be forgeable: `deposit` takes a CALLER-supplied memo and a deposit is a
    // mint, so anyone could deposit memoed `FF * 32` and fake a refund row here. Burns
    // are safe to decode because no burn path accepts a memo. This label therefore states
    // only what is observable: cycles entered the account from outside it. A delivered
    // order is a transfer from the gateway, not a mint, so it is not this row.
    return { what: "Added", amount: `+${formatCycles(m.amount)}`, counterparty: "-" };
  }
  if (tx.burn.length > 0) {
    const b = tx.burn[0]!;
    // ⚠️ **`b.from` is the VIEWER, so it must not go in the counterparty column** — it
    // rendered their own principal under "Other party". What is useful sits in the memo,
    // which only a burn's memo can be trusted for: see `decodeBurnMemo`.
    const amount = `-${formatCycles(b.amount)}`;
    const purpose = decodeBurnMemo(b.memo);
    // ⚠️ **Both labels name the CHARGE, not an outcome.** A create and a withdraw that
    // FAIL write the same burn as one that succeeds, and the refund that reveals the
    // failure is a separate later row. "Created a canister" / "Topped up" would assert
    // something the block does not carry.
    if (purpose.kind === "topUp") {
      return {
        what: "Canister top-up",
        amount,
        counterparty: shortPrincipal(purpose.canister),
        canister: purpose.canister,
      };
    }
    if (purpose.kind === "creation") {
      // No principal: the ledger does not record which canister a creation made.
      return { what: "Canister creation", amount, counterparty: "-" };
    }
    return { what: "Spent", amount, counterparty: "-" };
  }
  if (tx.approve.length > 0) {
    const a = tx.approve[0]!;
    return {
      what: "Approved",
      amount: formatCycles(a.amount),
      counterparty: short(a.spender),
    };
  }
  // An unrecognised kind is NAMED rather than dropped: a row the ledger recorded and
  // this page cannot classify still belongs in a list the buyer reconciles against.
  return { what: tx.kind, amount: "-", counterparty: "-" };
}

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
/// A typed amount in gross USD cents, or null when the buyer has not entered a
/// usable one. Mutually exclusive with `selectedTierId`: picking a preset clears
/// this and typing clears that, because "which amount am I buying" must have one
/// answer.
let customUsdCents: bigint | null = null;
/// The backend's quote for the typed amount, from `quote_previews` — never
/// computed here, so what the buyer is shown and what `create_order` locks cannot
/// disagree.
///
/// ⚠️ **The WHOLE preview, not just its cycles.** This held only `.cycles` and threw
/// `feeCents` and `netCents` away, so the detail card had no split for a typed amount
/// and rendered three labelled rows with nothing in them: "Payment processing",
/// "Buys cycles", "Operator margin", all empty. The comment there justified the blanks
/// by claiming a typed amount is quoted for cycles but not for the split, which is
/// simply false — `QuotePreview` carries all four fields for any amount. The data was
/// arriving and being discarded one line before it was needed.
let customQuote: QuotePreview | null = null;
/// The gate's bounds, read from `lifecycle_config`. Null until the market loads;
/// the input stays disabled until then rather than guessing a range.
let amountBounds: { min: bigint; max: bigint } | null = null;

/// The order the order/delivered view is showing. Null on every other view.
let activeOrder: Order | null = null;

// Quotes the *backend* computed, keyed by tier id — never derived here, so what
// a buyer is shown and what create_order locks cannot disagree.
let tierQuotes = new Map<string, QuotePreview>();
// Fee formulas, for rendering the split in words.
let cardFee: FeeConfig | null = null;
// The cycles ledger's own transfer fee. ⚠️ NOT from `quote_previews` any more —
// #30 PR-A stopped disclosing it there, so this is read from the ledger directly.
let transferFee = 0n;

/// The account's balance as the LEDGER last reported it, or null when it has not been
/// read or the read failed.
///
/// ⚠️ **Held here rather than read back out of `#ledger-balance`.** The CLI page states
/// the balance in its own words, and it used to get it by sniffing that cell's
/// `textContent` with `/^[\d]/` — deriving render state from the DOM, which
/// `customChosen` warns about a few hundred lines up for the same reason: the sniff
/// answers "does this look like a number" instead of "did the read succeed", so a
/// failure message that happened to start with a digit would be quoted back as a
/// balance, and the two renderers disagreed about the fallback.
let ledgerBalance: bigint | null = null;
// Set when a created order's locked quantity differs from the estimate shown —
// within tolerance, so the order went through, but the buyer should still hear
// the real number rather than discover it.
let lockNotice: string | null = null;
let pollTimer: ReturnType<typeof setInterval> | null = null;
/// Separate from the poll so the countdown ticks every second without making a
/// call every second.
let deadlineTimer: ReturnType<typeof setInterval> | null = null;
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
/// Which dashboard record is showing. Mirrors the hash, so a reload or a Back lands
/// on the same panel rather than snapping to the default.
let currentHistoryTab: HistoryTab = "orders";
/// Which console panel is showing. Mirrors `currentHistoryTab`.
let currentAdminTab: AdminTab = "now";
/// Orders this principal has, so the header link can hide when there are none.
let orderCount = 0;

/// Steps 3 and 4 — link the CLI, deploy — are the deliverable for every order,
/// because every order credits the buyer's own account (#29). So the only
/// question is whether there is an order at all.
///
/// ⚠️ A second destination kind brings back the question this used to answer:
/// `icp identity link web` links the CALLER's identity, so for a balance that is
/// not theirs the commands reach the wrong account and must not be printed.

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
  // ⚠️ Declared HERE, beside `onOrder`. It was declared further down and read by the
  // `order-missing` line above it — a `const` in its temporal dead zone, so
  // `renderView` threw a ReferenceError partway through and left every view hidden.
  // The symptom was a blank page, which reads as a routing bug rather than a crash.
  const onCli = currentView === "cli";

  show("view-landing", effective === "landing");
  show("buy-flow", effective === "buy");
  // Nothing to show is not the same as an empty panel: signing out drops the
  // order, and the order view then has no content of its own.
  const ready = orderLoad === "ok" && order !== null;
  // `#active-order` has exactly one owner, and it is this line. `renderOrder`
  // used to unhide it too, which is how a poll tick could paint an order over the
  // history table the visitor had navigated to.
  show("active-order", onOrder && ready);
  // ⚠️ **The ORDER view only, and this reverses an earlier fix on purpose.** It was
  // widened to cover the next-steps view because a deep link there that could not load
  // its order showed nothing at all: not the guidance, not a missing-order message,
  // a blank page. That reasoning died with the order parameter. The CLI page needs no
  // order, so keeping it here made "We could not find that order" the greeting for
  // anyone arriving from the dashboard.
  show("order-missing", onOrder && !ready);
  show("history", effective === "history");
  show("admin", effective === "admin");
  // The next-steps view owns the screen like any other: the tour is no longer a panel
  // stacked on the order record.
  // ⚠️ No `ready` gate: the CLI page no longer depends on an order, so waiting for one
  // to load would leave a visitor arriving from the dashboard on a blank screen.
  show("view-cli", onCli);
  if (effective === "admin") {
    renderAdminTabs(currentAdminTab);
    renderAdminIdentity();
    renderOperatorSummary();
    // ⚠️ Per-panel, for the same reason the ledger list is: reads for a panel nobody
    // opened are work with no reader — and two of these WRITE to the audit trail, so
    // fetching them eagerly would fill it with lines nobody asked for.
    if (currentAdminTab === "diagnostics") void loadDiagnostics();
  }
  if (effective === "history") {
    // The balance is above the tabs and belongs to neither record, so it loads either
    // way. The ledger list is only fetched when its panel is actually showing:
    // 25 index rows for a panel nobody opened is work with no reader.
    void refreshLedgerBalance();
    renderRecordTabs(currentHistoryTab);
    if (currentHistoryTab === "ledger") void refreshLedgerHistory();
  }
  show("history-link", orderCount > 0 && identity !== null);
  if ((onOrder || onCli) && !ready) renderOrderMissing();


  // ⚠️ **Nothing collapses over the order's facts any more.** This used to close
  // `#order-details` on the delivered view so the tour could lead — and because the
  // receipt and the problems panel were NESTED inside that disclosure, the one view a
  // buyer opens to see what they got showed no cycle quantity, hid the receipt two
  // clicks deep, and buried a problem notice. The tour moved to its own view instead,
  // which is the fix the collapse was standing in for.
  renderCliSteps(onCli);
  if (onCli) {
    // ⚠️ **BOTH renderers re-run when the read lands, not just the summary.** They
    // state the same balance in two places — the lede, and the figure step 3 tells the
    // buyer to expect — and re-rendering one left the other saying "the balance above"
    // about a number the page had by then.
    void refreshLedgerBalance().then(() => {
      renderCliSummary();
      renderCliSteps(onCli);
    });
    renderCliSummary();
  }

  // The way from the record to the guidance. Only on a DELIVERED order: before that
  // there is nothing to link the CLI to, and offering the step early is how a buyer
  // ends up running a command against an empty balance.
  show("order-next-row", delivered && order !== null);
  // Still order-scoped at this layer. The page's content is identity-derived, so the
  // parameter is unused and it makes the page unreachable from the dashboard: that is
  // the next change, not this one.
  const nextLink = document.getElementById("order-next-link") as HTMLAnchorElement | null;
  if (nextLink && order !== null) {
    nextLink.href = routeHash({ view: "cli" });
  }
}

/// What the operator console knows about the caller's own identity.
///
/// ⚠️ `admin_status` is a PUBLIC query on purpose, and this is the reason: an operator who
/// has not been granted yet must be able to read their own principal and see that it is
/// not granted. A guarded version would reject exactly the caller who needs the answer,
/// and this panel could not tell "not granted" from "not reachable".
let adminStatus: Awaited<ReturnType<typeof backend.admin_status>> | null = null;

/// The gate and delivery configs, for the console's configuration surface.
///
/// ⚠️ Read on the admin route rather than at load: it is an operator's question, and
/// the buy view already reads what it needs from `lifecycle_config` separately.
let lifecycleConfig: Awaited<ReturnType<typeof backend.lifecycle_config>> | null = null;

/// The scalar settings, each of which is one call rather than a record.
let expectedLivemode: boolean | null = null;
let stripeOrigin: string | null = null;
let cardTiersConfig: Awaited<ReturnType<typeof backend.card_tiers>> = [];
let secretStatus: { apiKey: boolean; webhook: boolean } | null = null;

async function loadAdminConfig(): Promise<void> {
  try {
    const [lifecycle, pricing, livemode, origin, tiers, apiKey, webhook] = await Promise.all([
      backend.lifecycle_config(),
      backend.pricing_status(),
      backend.expected_livemode(),
      backend.stripe_origin(),
      backend.card_tiers(),
      backend.stripe_api_key_status(),
      backend.webhook_secret_status(),
    ]);
    lifecycleConfig = lifecycle;
    lastPricing = pricing;
    expectedLivemode = livemode;
    stripeOrigin = origin;
    cardTiersConfig = tiers;
    secretStatus = { apiKey: apiKey.isSet, webhook: webhook.isSet };
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("could not read the configuration", error);
    lifecycleConfig = null;
  }
  if (currentView === "admin") renderAdminConfig();
}

async function loadAdminStatus(): Promise<void> {
  try {
    adminStatus = await backend.admin_status();
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("could not read admin status", error);
    adminStatus = null;
  }
  if (currentView === "admin") renderAdminIdentity();
  renderAdminNav();
}

/// Show the console link only to someone who can use it.
///
/// ⚠️ **This does not contradict `view.ts`'s "not advertised" rule, it implements
/// it.** The rule's reason is that a console link is noise for every visitor who is
/// not an operator — and one that appears only for a granted admin or a controller
/// is invisible to exactly those visitors. What it replaces is an operator having to
/// know to type `#/admin`.
///
/// Both tiers, because they are nested rather than exclusive: a controller passes the
/// admin guard without being granted.
function renderAdminNav(): void {
  const link = document.getElementById("admin-nav");
  if (!link) return;
  const operator = adminStatus !== null && (adminStatus.granted || adminStatus.isController);
  link.hidden = !operator;
}

/// One configuration group: the values, what each means, and the command that changes
/// them pre-filled with what is set NOW.
///
/// ⚠️ **Pre-filled from the current values, not from blanks.** #97's point is that the
/// failure mode in these calls is transcription: the config setters take whole Candid
/// records, and hand-authoring one while omitting a field silently changes a live
/// parameter. Rendering the current record means an operator edits one number in a
/// command that is otherwise already correct.
function renderConfigGroup<T extends object>(
  title: string,
  note: string,
  config: T,
  docs: Record<keyof T, FieldDoc>,
  method: CommandMethod,
  command: string,
): HTMLElement {
  const section = document.createElement("section");
  section.className = "config-group";
  const h = document.createElement("h4");
  h.className = "summary-h";
  h.textContent = title;
  section.append(h);
  const intro = document.createElement("p");
  intro.className = "muted";
  intro.textContent = note;
  section.append(intro);

  const list = document.createElement("dl");
  list.className = "config-fields";
  // ⚠️ Iterating the DOCS, not the config: the docs are the exhaustive table, so a
  // field the canister added and nobody explained is a typecheck failure rather than a
  // row that renders with an empty description.
  for (const key of Object.keys(docs) as Array<keyof T & string>) {
    const doc = docs[key];
    const dt = document.createElement("dt");
    dt.textContent = doc.label;
    const dd = document.createElement("dd");
    dd.className = "config-value";
    dd.dataset.field = key;
    dd.textContent = formatConfigValue(key, config[key]);
    const why = document.createElement("dd");
    why.className = "muted config-doc";
    why.textContent = `${doc.means} ${doc.effect}${doc.bound ? ` Bound: ${doc.bound}` : ""}`;
    list.append(dt, dd, why);
  }
  section.append(list);

  const cmd = document.createElement("div");
  cmd.className = "cmd";
  const code = document.createElement("code");
  code.className = "mono";
  code.id = `config-cmd-${title.toLowerCase().replace(/[^a-z]+/g, "-")}`;
  code.textContent = command;
  const copy = copyButton(command, `Copy the command that changes ${title.toLowerCase()}`);
  cmd.append(code, copy);
  section.append(cmd);
  // ⚠️ **The irreversible note is the reason this is a command and not a button.** A
  // button removes the wrong half of the interaction: the machine should do the exact
  // arguments, and the human should read what cannot be undone before running it.
  const danger = irreversibleNote(method);
  if (danger !== undefined) {
    const warn = document.createElement("p");
    warn.className = "config-danger";
    warn.textContent = danger;
    section.append(warn);
  }
  return section;
}

/// The argument-free operator actions, each as one command.
///
/// ⚠️ **Rendered even though they take no arguments**, because the value is not only
/// transcription: `withdraw_reserve` and `recount_orders` are levers an operator has no
/// way to discover otherwise. The console previously listed none of them, so knowing
/// they existed meant reading the source.
const ARGUMENT_FREE_ACTIONS: ReadonlyArray<{ method: ArgumentFreeMethod; what: string }> = [
  {
    method: "refresh_reserve",
    what:
      "Observe the reserve balance now. REQUIRED after a top-up: the floor only learns"
      + " about incoming cycles by looking, so without this the gateway refuses every"
      + " sale against a fully funded reserve and nothing says why.",
  },
  {
    method: "refresh_rates",
    what: "Force a rate refresh now instead of waiting for the timer.",
  },
  {
    method: "recount_orders",
    what:
      "Run the tally reconcile now. Not a stronger repair than the timer's: a recount"
      + " BELOW the maintained tally is refused rather than adopted, because an"
      + " incomplete index and a lost adjustment are indistinguishable from here.",
  },
  {
    method: "withdraw_reserve",
    what:
      "Return the reserve to the caller. Refused while any order still holds a promise,"
      + " so nothing owed to a buyer can leave.",
  },
];

function renderAdminActions(): void {
  const host = document.getElementById("action-list");
  if (!host) return;
  host.replaceChildren();
  for (const action of ARGUMENT_FREE_ACTIONS) {
    const wrap = document.createElement("section");
    wrap.className = "config-group";
    const h = document.createElement("h4");
    h.className = "summary-h";
    h.textContent = action.method;
    const what = document.createElement("p");
    what.className = "muted";
    what.textContent = action.what;
    wrap.append(h, what);

    const command = renderCall(action.method);
    const cmd = document.createElement("div");
    cmd.className = "cmd";
    const code = document.createElement("code");
    code.className = "mono";
    code.textContent = command;
    cmd.append(code, copyButton(command, `Copy the ${action.method} command`));
    wrap.append(cmd);

    const danger = irreversibleNote(action.method);
    if (danger !== undefined) {
      const warn = document.createElement("p");
      warn.className = "config-danger";
      warn.textContent = danger;
      wrap.append(warn);
    }
    host.append(wrap);
  }
}

/// The settings that are one call rather than a record, plus the two secrets that are
/// deliberately NOT offered as a command.
function renderScalarConfig(host: HTMLElement): void {
  const section = document.createElement("section");
  section.className = "config-group";
  const h = document.createElement("h4");
  h.className = "summary-h";
  h.textContent = "Rail and identity";
  section.append(h);

  const rows: Array<{ doc: FieldDoc; value: string; command?: string }> = [
    {
      doc: {
        label: "Stripe mode",
        means:
          expectedLivemode === null
            ? "Unset, which means EITHER mode is accepted. This is the default, and it only makes sense while nothing of value is at stake."
            : expectedLivemode
              ? "Live. Only live-mode payments deliver."
              : "Test. Only test-mode payments deliver.",
        effect:
          "Checked twice: at session creation against what Stripe returns, and again on"
          + " the webhook. A live payment arriving at a test-configured gateway becomes an"
          + " obligation rather than a delivery.",
        bound:
          "Anything but test is refused while a simulation divisor is set, so neither"
          + " order of operations reaches a state that takes real money at a scaled"
          + " cycle quantity.",
      },
      value:
        expectedLivemode === null ? "unset (either mode)" : expectedLivemode ? "live" : "test",
      command: renderCall("set_expected_livemode", expectedLivemode),
    },
    {
      doc: {
        label: "Stripe return origin",
        means: "Where Stripe sends the buyer back after paying.",
        effect:
          "A wrong origin still takes the payment and returns the buyer to a page that"
          + " is not this one. The webhook still delivers.",
        bound: "https, no query and no fragment. A caller-supplied one is deliberately impossible.",
      },
      value: stripeOrigin ?? "not set: the card rail is closed",
      command: renderCall("set_stripe_origin", stripeOrigin ?? "https://example.invalid"),
    },
    {
      doc: {
        label: "Card presets",
        means: `${cardTiersConfig.length} preset amount(s) offered as tiles.`,
        effect:
          "An empty list shows no tiles and does NOT close the rail: the switch is the two"
          + " Stripe secrets. A custom amount is bounded by the gate, not by this list.",
        bound: "Every preset must sit within the purchase floor and ceiling.",
      },
      value:
        cardTiersConfig.length === 0
          ? "none"
          : cardTiersConfig.map((t) => `${t.id} = ${formatUsdCents(t.usdCents)}`).join(", "),
      command: renderCall("set_card_tiers", cardTiersConfig),
    },
    {
      doc: {
        label: "Stripe secrets",
        means: `API key ${secretStatus?.apiKey ? "set" : "NOT set"}, webhook secret ${secretStatus?.webhook ? "set" : "NOT set"}. The rail is live only while both are.`,
        effect:
          "Rotating the webhook secret closes the rail until the new one is set, which is"
          + " the lever for stopping new orders during an incident.",
        bound:
          "No command is offered for either, and that is permanent: a rendered command"
          + " containing a key would land in this page's DOM and clipboard. Set them from a"
          + " terminal. Whoever can set the webhook secret can sign a payment event and take"
          + " delivery having paid nothing.",
      },
      value: secretStatus === null
        ? "unknown"
        : `${secretStatus.apiKey ? "key set" : "key missing"}, ${secretStatus.webhook ? "webhook set" : "webhook missing"}`,
    },
  ];

  const list = document.createElement("dl");
  list.className = "config-fields";
  for (const row of rows) {
    const dt = document.createElement("dt");
    dt.textContent = row.doc.label;
    const dd = document.createElement("dd");
    dd.className = "config-value";
    dd.textContent = row.value;
    const why = document.createElement("dd");
    why.className = "muted config-doc";
    why.textContent =
      `${row.doc.means} ${row.doc.effect}${row.doc.bound ? ` Bound: ${row.doc.bound}` : ""}`;
    list.append(dt, dd, why);
    if (row.command !== undefined) {
      const cmdWrap = document.createElement("dd");
      const cmd = document.createElement("div");
      cmd.className = "cmd";
      const code = document.createElement("code");
      code.className = "mono";
      code.textContent = row.command;
      cmd.append(code, copyButton(row.command, `Copy the command that changes ${row.doc.label.toLowerCase()}`));
      cmdWrap.append(cmd);
      list.append(cmdWrap);
    }
  }
  section.append(list);
  host.append(section);
}

/// Values in an operator's units rather than the canister's.
///
/// ⚠️ Nanoseconds and basis points are the two that mislead when printed raw: a
/// 7,200,000,000,000 is not a number anyone reads as two hours, and 290 is not a
/// number anyone reads as 2.9%.
function formatConfigValue(key: string, value: unknown): string {
  if (typeof value !== "bigint") return String(value);
  // ⚠️ `formatDuration` takes MILLISECONDS. Handing it nanoseconds prints a duration
  // a million times too long, which is exactly the kind of unit slip a raw value would
  // at least have made obvious.
  if (key.endsWith("Ns")) return `${formatDuration(Number(value / 1_000_000n))} (${value} ns)`;
  if (key.endsWith("Bps")) return `${Number(value) / 100}% (${value} bps)`;
  if (key.endsWith("UsdCents")) return `${formatUsdCents(value)} (${value} cents)`;
  if (key === "minCanisterCycles") return `${formatCycles(value)} cycles`;
  if (key === "divisor") {
    return value === 1n ? "1 (production)" : `${value} (simulation: 1/${value} delivered)`;
  }
  return value.toString();
}

/// The configuration surface, and the answer to "what can I change here".
function renderAdminConfig(): void {
  const host = document.getElementById("config-groups");
  if (!host) return;
  host.replaceChildren();
  const pricing = lastPricing?.config;
  if (pricing === undefined || lifecycleConfig === null) {
    const p = document.createElement("p");
    p.className = "muted";
    // Says which read failed rather than rendering an empty table, which would read
    // as "nothing is configured".
    p.textContent = "Could not read the configuration. The canister may be unreachable.";
    host.append(p);
    return;
  }
  host.append(renderConfigGroup(
    "Pricing and simulation",
    "How dollars become cycles, and whether this gateway is scaled.",
    pricing,
    PRICING_FIELDS,
    "set_pricing_config",
    renderCall("set_pricing_config", pricing),
  ));
  host.append(renderConfigGroup(
    "Admission gate",
    "What the gateway will and will not sell.",
    lifecycleConfig.gate,
    GATE_FIELDS,
    "set_gate_config",
    renderCall("set_gate_config", lifecycleConfig.gate),
  ));
  host.append(renderConfigGroup(
    "Delivery timeline",
    "When a slow delivery is reported, and when it escalates to a person.",
    lifecycleConfig.delivery,
    DELIVERY_FIELDS,
    "set_delivery_config",
    renderCall("set_delivery_config", lifecycleConfig.delivery),
  ));
  renderScalarConfig(host);
  renderAdminActions();
}

function renderAdminIdentity(): void {
  const who = document.getElementById("admin-principal");
  const state = document.getElementById("admin-grant-state");
  const link = document.getElementById("admin-link");
  const command = document.getElementById("admin-link-command");
  const note = document.getElementById("admin-link-note");
  if (!who || !state || !link || !command || !note) return;

  if (adminStatus === null) {
    who.textContent = "";
    state.textContent = "Reading this identity failed. The canister may be unreachable.";
    link.hidden = true;
    return;
  }

  who.textContent = adminStatus.caller.toText();
  // Three states, three sentences. ⚠️ A controller is NOT on the granted list and does not
  // need to be: it passes the admin guard anyway, so reporting "not granted" for one would
  // be true and useless. The tiers are nested, not exclusive.
  state.textContent = adminStatus.isController
    ? "A controller of this canister. Every operator command is available to this identity."
    : adminStatus.granted
      ? "Granted operator access. Case decisions and operator reads are available; changing configuration or secrets is not."
      : "Not granted. Send the principal above to a controller, who can grant it.";

  link.hidden = false;
  command.textContent = linkIdentityCommand("operator");
  // ⚠️ **Says "as printed", NOT "this page's domain", and the difference is the whole
  // point.** It used to say the domain, which was true until the derivation origin was
  // pinned. On a custom domain the printed value is deliberately the canister's origin
  // and not the address bar, so the old sentence invited an operator to "correct" the
  // command into the one thing it exists to prevent: a delegation for a different
  // principal, with an empty balance.
  note.textContent =
    "Use the --app value exactly as printed. It names the origin this principal is " +
    "derived from, which is not always the domain in your address bar. Changing it, or " +
    "omitting it, links a different identity than the one above.";
}

/// The operator summary: nine counts, one public query (#68).
let operatorSummary: Awaited<ReturnType<typeof backend.operator_summary>> | null = null;

async function loadOperatorSummary(): Promise<void> {
  try {
    operatorSummary = await backend.operator_summary();
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("could not read the operator summary", error);
    operatorSummary = null;
  }
  if (currentView === "admin") renderOperatorSummary();
}

/// One figure row. Kept as a helper so the two groups cannot drift in shape.
function figureRow(into: HTMLElement, label: string, value: bigint): void {
  const dt = document.createElement("dt");
  dt.textContent = label;
  const dd = document.createElement("dd");
  dd.textContent = value.toString();
  // ⚠️ A DATA attribute, not a class name, and the styling hangs off it: this is the
  // hook the Chromium suite reads to check that a non-zero count in the act group is
  // visually distinguishable from a zero. A class alone is what jsdom can confirm and an
  // operator cannot see.
  dd.dataset.zero = value === 0n ? "true" : "false";
  into.append(dt, dd);
}

/// One figure row whose value is text rather than a count.
///
/// ⚠️ Separate from `figureRow` on purpose: that one sets `data-zero`, which the Chromium
/// suite reads to check a non-zero count is visually distinguishable from a zero. A
/// duration or a principal has no zero, and tagging one would make that assertion
/// meaningless.
function textFigureRow(into: HTMLElement, label: string, value: string): void {
  const dt = document.createElement("dt");
  dt.textContent = label;
  const dd = document.createElement("dd");
  dd.textContent = value;
  into.append(dt, dd);
}

/// The diagnostics panel: the reads RUNBOOK asks for by name, none of which had a surface.
///
/// ⚠️ **Fetched only when the panel is open** (see `applyRoute`). `audit_log` is the one
/// list here that grows without bound, so it pages; everything else is a fixed-shape
/// record or is bounded by a variant.
async function loadDiagnostics(): Promise<void> {
  const locked = document.getElementById("diag-locked");
  const body = document.getElementById("diagnostics-body");
  const state = document.getElementById("diag-health-state");
  const depths = document.getElementById("diag-depth-figures");
  const recovery = document.getElementById("diag-recovery-figures");
  const drift = document.getElementById("diag-recovery-drift");
  if (!locked || !body || !state || !depths || !recovery || !drift) return;

  try {
    const [healthy, problems, orphans, rec] = await Promise.all([
      backend.health(),
      backend.problem_depth(),
      backend.orphan_depth(),
      backend.recovery_status(),
    ]);

    // ⚠️ Says what it does and does NOT cover. "Healthy" beside a closed rail would read
    // as "the gateway is selling", which this boolean does not claim.
    state.textContent = healthy
      ? "The canister answers healthy."
      : "The canister reports NOT healthy. Read the queue depths and the sweep below.";
    state.dataset.healthy = healthy ? "true" : "false";

    depths.replaceChildren();
    figureRow(depths, "Orders carrying a problem", problems.orders);
    figureRow(depths, "Unresolved problems", problems.unresolved);
    figureRow(depths, "Payments retained", orphans.retained);
    figureRow(depths, "Unresolved payments", orphans.unresolved);

    recovery.replaceChildren();
    const scan = rec.indexScan;
    figureRow(recovery, "Orders stored", scan.storedOrders);
    figureRow(recovery, "Orders read this cycle", scan.inFlightCycle.ordersRead);
    figureRow(recovery, "Repairs this cycle", scan.inFlightCycle.repairs);
    textFigureRow(
      recovery,
      "A full cycle takes",
      formatDuration(nsToMillis(scan.expectedFullCycleNs)),
    );
    const done = scan.lastCompletedCycle;
    textFigureRow(
      recovery,
      "Last completed cycle",
      done === undefined
        ? "none yet (the first cycle is still running)"
        : `${formatAgo(nsToMillis(done.completedAtNs), Date.now())}` +
          `, ${done.ordersRead} read, ${done.repairs} repaired`,
    );

    // ⚠️ Drift is the reconcile disagreeing with the maintained count, which is the one
    // reading here that means something is actually wrong rather than merely slow.
    const last = rec.lastCountReconcile;
    if (last === undefined) {
      drift.textContent = "The count reconcile has not completed a pass yet.";
    } else if (last.drift.length === 0 && last.refused.length === 0) {
      drift.textContent =
        `Last reconcile ${formatAgo(nsToMillis(last.atNs), Date.now())}: ` +
        `${last.ordersRead} orders read, no drift.`;
    } else {
      const parts: string[] = [];
      for (const d of last.drift) parts.push(`${d.status} was ${d.was}, is ${d.is}`);
      const shown = parts.join("; ");
      drift.textContent =
        `Last reconcile ${formatAgo(nsToMillis(last.atNs), Date.now())} found drift: ${shown}.` +
        (last.refused.length === 0 ? "" : ` ${last.refused.length} refused.`);
    }

    auditCursor = null;
    await loadAuditPage(true);
    locked.hidden = true;
    body.hidden = false;
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("could not read the diagnostics", error);
    // ⚠️ One message, and the body hidden. Reporting the failure on the health line while
    // leaving the depths, the sweep and the trail as empty headings made a refused read
    // look like a broken page.
    locked.hidden = false;
    body.hidden = true;
    locked.textContent =
      "These reads are admin-gated and this identity was refused. " +
      "Grant it with add_admin, or run them from a linked CLI identity.";
  }
}

/// Cursor for the next audit page; `null` means "from the newest".
let auditCursor: bigint | null = null;

/// One page of the audit trail.
///
/// ⚠️ **The only genuinely paginated table in the console.** The trail gains a line per
/// operator action and per audited read and never loses one, so it is the one list whose
/// length is neither bounded by the reserve nor by a variant.
///
/// ⚠️ **`audit_log_recent`, not `audit_log`.** The ascending view starts at the first line
/// ever written, so on a trail of any age the panel would open on ancient history and
/// "Load more" would walk *towards* the present. `auditCursor` is therefore a `beforeSeq`:
/// null starts at the newest, and each page walks further into the past.
async function loadAuditPage(reset: boolean): Promise<void> {
  const rows = document.getElementById("diag-audit-rows");
  const empty = document.getElementById("diag-audit-empty");
  const more = document.getElementById("diag-audit-more");
  if (!rows || !empty || !more) return;

  try {
    const page = await backend.audit_log_recent(auditCursor, 25n);
    if (reset) rows.replaceChildren();
    for (const event of page.events) {
      const tr = document.createElement("tr");
      for (const text of [
        event.seq.toString(),
        formatAgo(nsToMillis(event.atNs), Date.now()),
        event.tag,
        event.detail,
      ]) {
        const td = document.createElement("td");
        td.textContent = text;
        tr.append(td);
      }
      rows.append(tr);
    }
    auditCursor = page.nextCursor ?? null;
    more.hidden = page.nextCursor === undefined;
    empty.hidden = rows.children.length > 0;
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("could not read the audit trail", error);
    empty.hidden = false;
    empty.textContent = "The audit trail could not be read. It is admin-gated.";
  }
}

/// Look up one order by id: the record, its receipt, and its delivery journal entry.
///
/// ⚠️ **Behind a button, deliberately, because two of these three reads are UPDATES that
/// audit themselves** (#38). Fetching them when the panel opens would write a line to the
/// trail per render and make the trail useless — which is the same reason `admin_order` is
/// excluded from the console's command table rather than rendered as a command.
async function runLookup(): Promise<void> {
  const input = document.getElementById("lookup-id");
  const state = document.getElementById("lookup-state");
  const result = document.getElementById("lookup-result");
  const journal = document.getElementById("lookup-journal");
  if (!(input instanceof HTMLInputElement) || !state || !result || !journal) return;

  const id = input.value.trim();
  state.hidden = false;
  result.hidden = true;
  journal.hidden = true;
  if (id === "") {
    state.textContent = "Enter an order id.";
    return;
  }
  state.textContent = "Reading...";

  try {
    // All three in one go: an operator asking about an order wants the record and what
    // was delivered, and three sequential round trips would show the panel filling in.
    const [order, receipt, entry] = await Promise.all([
      backend.admin_order(id),
      backend.admin_receipt(id),
      backend.delivery_journal(id),
    ]);

    if (order === undefined || order === null) {
      state.textContent =
        "No order with that id. Check the payment reference on the Now panel's " +
        "unattributed payments, which is where an id that never became an order shows up.";
      return;
    }

    state.hidden = true;
    result.hidden = false;
    const figures = document.createElement("dl");
    figures.className = "figures";
    textFigureRow(figures, "Status", order.status);
    textFigureRow(figures, "Cycles locked", `${formatCycles(order.lockedCycles)} cycles`);
    textFigureRow(
      figures,
      "Paid",
      order.paidUsdCents === undefined ? "not paid" : formatUsdCents(order.paidUsdCents),
    );
    textFigureRow(
      figures,
      "Created",
      formatAgo(nsToMillis(order.createdAtNs), Date.now()),
    );
    textFigureRow(
      figures,
      "Unresolved problems",
      String(order.problems.filter((pr) => pr.resolvedAtNs === undefined).length),
    );
    textFigureRow(
      figures,
      "Receipt",
      receipt === undefined || receipt === null ? "none" : "available",
    );
    result.replaceChildren(figures);

    // The journal entry is the delivery half of the same question: whether a transfer was
    // attempted, how often, and which ledger block settled it.
    journal.replaceChildren();
    if (entry === undefined || entry === null) {
      journal.hidden = false;
      textFigureRow(journal, "Delivery journal", "no entry: nothing has been attempted");
    } else {
      journal.hidden = false;
      textFigureRow(journal, "Delivery attempts", String(entry.retries));
      textFigureRow(
        journal,
        "Ledger block",
        entry.blockIndex === undefined ? "not settled" : entry.blockIndex.toString(),
      );
      textFigureRow(journal, "Last error", entry.lastError ?? "none");
    }
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("could not look up the order", error);
    state.textContent = "That read was refused. It is admin-gated and audited.";
  }
}

/// Sort one table by a column, in place.
///
/// ⚠️ **Client-side and deliberately so: these tables hold what is in front of you.** The
/// worklists are bounded by the reserve (§5.4), so the rows on screen are all the rows
/// there are and sorting them sorts the queue. The order history is the one table where
/// that is NOT true — a page is a page — so its headers carry no `data-sort` and this
/// never attaches to them.
function sortTableBy(table: HTMLTableElement, index: number, kind: string): void {
  const body = table.tBodies[0];
  if (body === undefined) return;
  const header = table.tHead?.rows[0]?.cells[index];
  // Third click is not "unsorted": there is no meaningful original order to return to
  // once the rows have moved, so it toggles.
  const descending = header?.getAttribute("aria-sort") === "ascending";

  const rows = [...body.rows];
  rows.sort((a, b) => {
    const x = a.cells[index]?.textContent ?? "";
    const y = b.cells[index]?.textContent ?? "";
    // ⚠️ `number` parses the LEADING number out of the cell, so "3" and "2 h 14 m" both
    // sort by magnitude rather than by string order, where "10" precedes "9".
    if (kind === "number") {
      const nx = Number.parseFloat(x) || 0;
      const ny = Number.parseFloat(y) || 0;
      return descending ? ny - nx : nx - ny;
    }
    return descending ? y.localeCompare(x) : x.localeCompare(y);
  });
  body.append(...rows);

  for (const cell of table.tHead?.rows[0]?.cells ?? []) cell.removeAttribute("aria-sort");
  header?.setAttribute("aria-sort", descending ? "descending" : "ascending");
}

function renderOperatorSummary(): void {
  const headline = document.getElementById("summary-headline");
  const act = document.getElementById("summary-act-figures");
  const wait = document.getElementById("summary-wait-figures");
  const reserve = document.getElementById("summary-reserve");
  if (!headline || !act || !wait || !reserve) return;

  if (operatorSummary === null) {
    // No figure means no badge: a stale count beside "could not be read" would be a
    // claim the page has just said it cannot make.
    renderWorklistCount(0);
    headline.textContent = "The summary could not be read. The canister may be unreachable.";
    act.replaceChildren();
    wait.replaceChildren();
    reserve.textContent = "";
    return;
  }
  const s = operatorSummary;

  // ⚠️ Split by whether a human is required, NOT by severity. A self-clearing retry
  // ranked next to an unattributed payment is the mistake this grouping exists to
  // prevent: one is waiting, the other is owed an answer.
  act.replaceChildren();
  figureRow(act, "Orders under review", s.ordersNeedingReview);
  figureRow(act, "Payments not attributed", s.orphansUnresolved);
  // ⚠️ **`ordersWithProblems` is the SAME problems grouped by order, so it goes ON this
  // row rather than beside it as a fourth.** As its own row the group read
  // 1 + 2 + 2 + 1 = 6 above a headline of 5: correct arithmetic, because `owed` must not
  // count one problem set twice, and a disagreement to anyone who reads the list. The
  // rows in this group now sum to `owed` exactly, which is the only way a reader can
  // check the headline at all.
  figureRow(
    act,
    s.ordersWithProblems === 0n
      ? "Open problems"
      : s.ordersWithProblems === 1n
        ? "Open problems, on 1 order"
        : `Open problems, on ${s.ordersWithProblems} orders`,
    s.problemsUnresolved,
  );

  wait.replaceChildren();
  figureRow(wait, "Deliveries outstanding", s.deliveriesOutstanding);
  figureRow(wait, "Deliveries past the alert threshold", s.deliveriesDelayed);

  const owed =
    s.ordersNeedingReview + s.orphansUnresolved + s.problemsUnresolved;
  // ⚠️ **The badge is this SAME number, not a tally of worklist rows.** Counting rows
  // gave 3 against a headline of 5 on one screen, because the summary counts orders
  // needing review and open problems while the rows count unattributed payments and
  // per-problem obligations. Two numbers for "needs a person" is worse than none: an
  // operator who notices the disagreement stops trusting both. Driving both from `owed`
  // also means the badge is populated before the Worklists panel is ever opened, which
  // is the only reason a badge is useful.
  renderWorklistCount(Number(owed));
  // Said in words, because the whole point of the grouping is answerable at a glance.
  headline.textContent =
    owed === 0n
      ? "Nothing needs a person right now."
      : owed === 1n
        ? "One thing needs a person."
        : `${owed} things need a person.`;

  // ⚠️ The two delivery numbers are measured over DIFFERENT populations and neither
  // contains the other, so the UI must not present one as a subset of the other. See
  // `operator_summary` in Main.mo.
  const observed =
    s.reserveObservedAtNs === undefined
      ? "never observed"
      : `observed ${formatAgo(nsToMillis(s.reserveObservedAtNs), Date.now())}`;
  reserve.textContent =
    `Reserve available to sell: ${formatCycles(s.availableToSell)} cycles (${observed}).`;
}

/// One worklist row: what it is, and what its state means.
///
/// ⚠️ **The hint is rendered per ROW where the kind varies** (orphans have two kinds,
/// problems four) and per SECTION where it does not (both delivery lists are one state).
/// A single section-level hint on a mixed list would describe the first row and mislead
/// about the rest.
/// One worklist row, as a table row.
///
/// ⚠️ **Cells are passed as an ARRAY so each queue can have its own columns**, which is
/// the point of the tables: an operator triaging compares rows on one field — how long
/// this has waited, how many attempts it has had — and four stacked paragraphs per row
/// cannot support that. The header row in `index.html` is the contract; a mismatch shows
/// as a short row rather than failing, so the count is asserted in the tests.
///
/// The hint always occupies the LAST cell, collapsed. A list of twenty stays scannable and
/// the meaning is one click away rather than in another window.
///
/// ⚠️ `data-urgency` stays on the row: the wait-versus-act distinction is carried by token
/// colour there, and the Chromium suite asserts an operator can tell them apart.
function worklistRow(
  into: HTMLElement,
  cells: readonly string[],
  hint: Hint,
  fillId?: string,
): void {
  const tr = document.createElement("tr");
  tr.className = "worklist-row";
  tr.dataset.urgency = hint.urgency;

  for (const [i, text] of cells.entries()) {
    const td = document.createElement("td");
    // The first cell identifies the row, so it carries the emphasis the old title had.
    if (i === 0) td.className = "worklist-title";
    // ⚠️ **With `fillId`, the identifying cell becomes a BUTTON that loads the lookup
    // below.** Without it the panel could not complete its own loop: the cell shows a
    // TRUNCATED id, the field under it asks for 32 hex characters, and there was no copy
    // control and no click target between them. An operator looking straight at the row
    // they wanted had nowhere to get its id from.
    //
    // A button rather than a click handler on the row: it is keyboard reachable, it
    // announces itself, and it does not fire when someone opens "What this means".
    //
    // ⚠️ It FILLS and focuses; it does not run. `admin_order` is an update so that the
    // read is audited (#38), and a mis-click must not spend one.
    if (i === 0 && fillId !== undefined) {
      const fill = document.createElement("button");
      fill.type = "button";
      fill.className = "id-fill";
      fill.textContent = text;
      fill.dataset.orderId = fillId;
      fill.title = "Put this id in the lookup below";
      td.append(fill);
    } else {
      td.textContent = text;
    }
    tr.append(td);
  }

  const why = document.createElement("details");
  const summary = document.createElement("summary");
  summary.textContent = "What this means";
  const means = document.createElement("p");
  means.textContent = hint.means;
  const then = document.createElement("p");
  then.className = "worklist-then";
  then.textContent = hint.then;
  why.append(summary, means, then);
  const last = document.createElement("td");
  last.append(why);
  tr.append(last);

  into.append(tr);
}

function fillWorklist(rowsId: string, emptyId: string, fill: (into: HTMLElement) => number): void {
  const rows = document.getElementById(rowsId);
  const empty = document.getElementById(emptyId);
  if (!rows || !empty) return;
  rows.replaceChildren();
  const n = fill(rows);
  empty.hidden = n > 0;
}

/// The four worklists. All admin-gated, so nothing here renders for a caller the canister
/// will refuse: the panel says so instead of showing four empty lists, which would read as
/// "nothing to do".
async function loadWorklists(): Promise<void> {
  const locked = document.getElementById("worklists-locked");
  const wrap = document.getElementById("worklists");
  if (!locked || !wrap) return;

  // The two self-clearing lists carry their meaning at the SECTION level, because every
  // row in them is the same state. Taken from the same table the rows use, so the console
  // cannot say two different things about `#paid`.
  const paid = document.getElementById("wl-pending-note");
  const delayedNote = document.getElementById("wl-delayed-note");
  if (paid) paid.textContent = `Clears itself. ${ORDER_STATUS_HINTS.paid.then}`;
  if (delayedNote) {
    delayedNote.textContent =
      "Clears itself, and late enough to be worth reading. " + ORDER_STATUS_HINTS.paid.then;
  }

  const allowed = adminStatus !== null && (adminStatus.granted || adminStatus.isController);
  locked.hidden = allowed;
  wrap.hidden = !allowed;
  if (!allowed) {
    locked.textContent =
      "The worklists need operator access. This identity does not have it, so they are not shown: " +
      "four empty lists would read as nothing to do.";
    return;
  }

  try {
    const [orphans, problems, delayed, pending] = await Promise.all([
      backend.orphans_unresolved(null, 50n),
      backend.admin_orders(
        {
          withUnresolvedProblems: true,
          status: undefined,
          owner: undefined,
          createdFromNs: undefined,
          createdToNs: undefined,
        },
        null,
        50n,
      ),
      backend.delayed_deliveries(null, 50n),
      backend.pending_deliveries(),
    ]);

    fillWorklist("wl-orphans-rows", "wl-orphans-empty", (into) => {
      for (const entry of orphans.entries) {
        worklistRow(
          into,
          [`Payment ${entry.id}`, entry.detail],
          ORPHAN_KIND_HINTS[entry.kind.__kind__],
        );
      }
      return orphans.entries.length;
    });

    fillWorklist("wl-problems-rows", "wl-problems-empty", (into) => {
      let n = 0;
      for (const order of problems.orders) {
        // One row per unresolved PROBLEM, not per order: `resolve_problem` takes a kind,
        // so an order with two open problems is two obligations.
        for (const problem of order.problems) {
          if (problem.resolvedAtNs !== undefined) continue;
          worklistRow(
            into,
            [shortPrincipal(order.id), problem.kind.__kind__, problem.detail],
            PROBLEM_KIND_HINTS[problem.kind.__kind__],
          );
          n += 1;
        }
      }
      return n;
    });

    fillWorklist("wl-delayed-rows", "wl-delayed-empty", (into) => {
      for (const entry of delayed.entries) {
        worklistRow(
          into,
          [
            shortPrincipal(entry.orderId),
            formatDuration(nsToMillis(entry.waitedNs)) +
              (entry.pastMaxHold ? " · past the max hold" : ""),
            String(entry.retries),
          ],
          ORDER_STATUS_HINTS[entry.status],
        );
      }
      return delayed.entries.length;
    });

    fillWorklist("wl-pending-rows", "wl-pending-empty", (into) => {
      for (const entry of pending) {
        worklistRow(
          into,
          [
            shortPrincipal(entry.orderId),
            String(entry.retries),
            entry.lastError ?? "none",
          ],
          ORDER_STATUS_HINTS[entry.status],
        );
      }
      return pending.length;
    });
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("could not read the worklists", error);
    locked.hidden = false;
    wrap.hidden = true;
    locked.textContent = "The worklists could not be read. The canister may be unreachable.";
  }
}

/// Refusal counts, public. Seven counts against the gate's five reasons.
async function loadRefusals(): Promise<void> {
  const rows = document.getElementById("refusal-rows");
  if (!rows) return;
  let counts: Awaited<ReturnType<typeof backend.refusal_counts>>;
  try {
    counts = await backend.refusal_counts();
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("could not read refusal counts", error);
    return;
  }
  rows.replaceChildren();
  // ⚠️ Iterate the HINT table, not the response: the table is exhaustive over
  // `keyof RefusalCounts` by type, so every count has a meaning and a new one is a
  // compile error rather than a row with no explanation.
  for (const tag of Object.keys(REFUSAL_HINTS) as RefusalTag[]) {
    const n = counts.counts[tag];
    if (n === 0n) continue;
    worklistRow(rows, [tag, String(n)], REFUSAL_HINTS[tag]);
  }
}

/// The order-history filter, as the operator has set it.
let historyFilterStatus = "";
let historyFilterProblems = false;
/// Cursor for the next page; `null` means "from the start".
let historyCursor: string | null = null;

/// The whole order history, filtered, paged.
///
/// ⚠️ **`admin_orders` returns full `Order` records, so a row needs no follow-up read.**
/// `admin_order` audits itself on every use, deliberately, and calling it per row would
/// put a line in the trail for every page render.
async function loadAdminOrders(append = false): Promise<void> {
  const locked = document.getElementById("admin-history-locked");
  const rows = document.getElementById("admin-history-rows");
  const empty = document.getElementById("admin-history-empty");
  const more = document.getElementById("admin-history-more");
  if (!locked || !rows || !empty || !more) return;

  const allowed = adminStatus !== null && (adminStatus.granted || adminStatus.isController);
  locked.hidden = allowed;
  if (!allowed) {
    locked.textContent = "The order history needs operator access. This identity does not have it.";
    rows.replaceChildren();
    empty.hidden = true;
    more.hidden = true;
    return;
  }

  try {
    const page = await backend.admin_orders(
      {
        withUnresolvedProblems: historyFilterProblems,
        // ⚠️ `undefined`, never `null`: the wrapper renders a Candid `opt` as `?: T`, so
        // absent is undefined. `null` is a value of the wrong shape, which is one of the
        // four defects the fixtures were hiding earlier in this PR.
        status: historyFilterStatus === "" ? undefined : (historyFilterStatus as never),
        owner: undefined,
        createdFromNs: undefined,
        createdToNs: undefined,
      },
      append ? historyCursor : null,
      25n,
    );
    if (!append) rows.replaceChildren();
    for (const order of page.orders) {
      const hint = ORDER_STATUS_HINTS[order.status];
      worklistRow(
        rows,
        [
          shortPrincipal(order.id),
          order.status,
          `${formatCycles(order.lockedCycles)} cycles`,
          order.paidUsdCents === undefined ? "not paid" : formatUsdCents(order.paidUsdCents),
          formatAgo(nsToMillis(order.createdAtNs), Date.now()),
        ],
        hint,
        order.id,
      );
    }
    historyCursor = page.nextCursor ?? null;
    more.hidden = page.nextCursor === undefined;
    empty.hidden = rows.children.length > 0;
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error("could not read the order history", error);
    locked.hidden = false;
    locked.textContent = "The order history could not be read. The canister may be unreachable.";
  }
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
  // #/buy is answerable from a cold deep link: there is one destination and the
  // page states it, so the form is complete on arrival and nothing has to be
  // asked first.
  //
  // Leaving the order view ends the poll. The other half of `#active-order`
  // having one owner: a tick that arrives after the visitor has moved on has
  // nothing left to repaint.
  if (route.view !== "order" && pollOrderId !== null) stopPolling();

  currentView = route.view;
  if (route.view === "history") currentHistoryTab = route.tab;
  if (route.view === "admin") currentAdminTab = route.tab;
  if (route.view === "admin") {
    // Worklists depend on the grant, so they follow the status read rather than racing it.
    void loadAdminStatus().then(async () => {
      await loadWorklists();
      await loadAdminOrders();
    });
    void loadOperatorSummary();
    void loadRefusals();
    void loadAdminConfig();
  }
  // The order view is the only route that names an order, so it is the only one that
  // has to fetch. The CLI page used to be `#/order/<id>/next` and needed the same
  // order; it is order-free now, which is what collapsed this condition to one term.
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
  // The route may have moved on while the query was in flight, and a query resolving
  // after the visitor navigated away must not paint an order over the view they moved
  // to. Keyed on the ONE view that shows an order: it briefly also had to admit the
  // next-steps view, which was scoped to an order back then and rendered "we could not
  // find that order" for an order that had loaded fine. That view no longer takes one.
  if (currentView !== "order") return;
  if (order === null) {
    orderLoad = "missing";
    renderView();
    return;
  }
  orderLoad = "ok";
  // ⚠️ **Adopt the order without changing the route.** `openOrder` navigates to
  // `#/order/<id>` with `replaceState`, which is right when a visitor CLICKS a row and
  // wrong here: the route already says where the visitor is, so rewriting it can only
  // lose whatever it said. It did exactly that to the guidance page's deep link while
  // that page still carried an order id.
  activeOrder = order;
  stopPolling();
  renderOrder(order);
  // Unconditional: the guard above already returned for every other view, so a second
  // `currentView === "order"` here could not be false. It was reachable while the
  // guidance page shared this loader, and reading it as a live condition would suggest
  // there is still a view that loads an order and does not poll it.
  pollOrderId = order.id;
  lastPolledStatus = statusKeyOf(order);
  pollTimer = setInterval(() => void pollActiveOrder(), POLL_MS);
  renderView();
}

// --- auth ----------------------------------------------------------------

function renderAuth(): void {
  const area = el("auth-area");
  area.replaceChildren();
  if (identity) {
    // ⚠️ **Truncated for width, so the full value needs a way OUT of the page.** A
    // `title` tooltip cannot be copied and truncated text cannot be selected into
    // something usable — and this principal is what a buyer pastes into
    // `add_allowed_buyer`, what an operator pastes into `add_admin`, and what the
    // step-3 command's output has to match. Shown short, copied in full.
    const full = identity.getPrincipal().toText();
    const principal = document.createElement("span");
    principal.className = "principal";
    principal.title = full;
    principal.textContent = shortPrincipal(full);
    const copy = copyButton(full, "Copy your principal");
    // Paired in a wrapper so the header reads as TWO controls rather than three: the
    // identity (with its copy) and the way out. `#auth-area`'s flex gap would
    // otherwise space all three equally and make Copy look like a peer of Sign out.
    const pair = document.createElement("span");
    pair.className = "identity-pair";
    pair.append(principal, copy);
    const out = document.createElement("button");
    // ⚠️ **Identified, not positional.** Three tests selected the header's FIRST
    // button to mean "sign out", and adding a copy button beside the principal broke
    // all three — they clicked Copy, stayed signed in, and asserted on a sign-in that
    // never happened. An id says which control is meant.
    out.id = "sign-out";
    out.textContent = "Sign out";
    out.onclick = async () => {
      await signOut();
      setIdentity(null);
    };
    area.append(pair, out);
  } else {
    const inBtn = document.createElement("button");
    inBtn.id = "sign-in";
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
  // ⚠️ Re-probed on every identity change, because the allow-list is per PRINCIPAL:
  // the answer at load was about the anonymous caller (exempt from the list), and it
  // is only after signing in that "may this buyer buy" has a subject.
  void refreshEligibility();
  // Visibility belongs to renderView, which is what makes history a VIEW rather
  // than a section pinned to the bottom of whatever else is on screen. Signing in
  // reveals the header link, not the table.
  renderView();
  if (identity) {
    // ⚠️ Read the grant HERE, not only on the `#/admin` route: the header link has
    // to know before the operator navigates, which was the whole gap. `admin_status`
    // is a public caller-scoped query, so this costs one cheap read per sign-in and
    // discloses nothing about anyone else.
    void loadAdminStatus();
    // No field to prefill any more: the destination is the caller's own account
    // and `readDestination` reads it from the session (#29), so signing in has
    // nothing to write into the form.
    void refreshHistory();
  } else {
    // Signed out: the grant is not ours to remember, and a stale link would offer a
    // console the caller can no longer reach.
    adminStatus = null;
    renderAdminNav();
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

/// Ask the gate whether this caller can buy AT ALL, and say so before they pick an
/// amount (#99 2b).
///
/// ⚠️ **Probed at the gate's own minimum, not at a chosen amount**, because the point
/// is to catch refusals that no amount can fix. That is also why only two reasons are
/// rendered: `#buyerNotAllowed` and `#unboundedGiveaway` are invariant for this caller
/// until an operator acts, while `#reserveShort`, `#canisterCyclesLow` and the amount
/// bounds are volatile or amount-dependent and belong at the moment of the attempt —
/// see `loadMarket`.
///
/// ⚠️ **Failures leave the notice hidden.** A network error is not evidence that this
/// buyer is barred, and a banner saying so would be worse than the refusal it guesses at.
async function refreshEligibility(): Promise<void> {
  const bounds = amountBounds;
  if (bounds === null) return;
  let reason: GateReason | null = null;
  try {
    const answer = await backend.can_purchase(bounds.min);
    reason = "err" in answer ? answer.err : null;
  } catch {
    show("gate-notice", false);
    return;
  }
  // ⚠️ **The table is the filter.** Not a hand-written `||` over two tag names beside
  // a second copy of the same two names in `format.ts` — that pair is the mirror this
  // repo has removed four times. A key present means the refusal is invariant for this
  // caller until an operator acts; absent means it belongs at the moment of the
  // attempt, and this stays silent.
  const notice = reason === null ? undefined : PRE_ANNOUNCED_GATE_REASONS[reason.__kind__];
  if (notice === undefined) {
    show("gate-notice", false);
    return;
  }
  el("gate-notice").textContent = notice;
  show("gate-notice", true);
}

/// The two trust figures, and they are not the same kind of claim.
///
/// ⚠️ **Capacity is read from the cycles ledger, so a visitor can check it without
/// trusting us** — that is why it leads and why it is shown even at zero deliveries. The
/// delivered totals are ours to report, so they are supporting evidence rather than the
/// headline.
///
/// ⚠️ **Always rendered, including at zero — do NOT add a threshold.** #39's body argued
/// that "0 orders delivered" is worse than no badge, and that was rejected: an absent
/// number is indistinguishable from a withheld one, and a rule that hides the figure
/// exactly when the news is bad is a misleading presentation rather than a neutral one.
/// Showing zero is honest and self-correcting; hiding it asks the reader to trust that
/// nothing is being concealed.
function renderTrustFigures(
  stats: Awaited<ReturnType<typeof backend.delivery_stats>>,
): void {
  const wrap = document.getElementById("trust-figures");
  const capLabel = document.getElementById("trust-capacity-label");
  const cap = document.getElementById("trust-capacity");
  const delWrap = document.getElementById("trust-delivered-wrap");
  const del = document.getElementById("trust-delivered");
  if (!wrap || !capLabel || !cap || !delWrap || !del) return;

  capLabel.textContent = "Available to buy right now";
  cap.textContent = `${formatCycles(stats.availableToSell)} cycles`;

  // ⚠️ **This figure stays in REAL cycles while quotes are scaled**, because
  // `availableToSell` is `reserveFloor - promised` and only `promised` is scaled. So it
  // can read 775 T while $10 buys 7 G.
  //
  // ⚠️ **It no longer carries its own sentence about that, and the reason is where the
  // reader is.** The note explained the ratio between this figure and a QUOTE, which is
  // a comparison only someone mid-purchase makes; these figures are the landing page's
  // trust panel. The page banner already states the scale on every view, so the note
  // was a second copy of it aimed at a comparison the reader is not making yet.

  // The account these figures come from, on a dashboard that is not us. Built here
  // because it needs this deployment's own canister id rather than a hardcoded one.
  const accountLink = document.getElementById("reserve-account-link") as HTMLAnchorElement | null;
  const gateway = liveBackendId ?? backendCanisterId;
  if (accountLink && gateway !== undefined && gateway !== "") {
    accountLink.href =
      `https://dashboard.internetcomputer.org/tokens/${cyclesLedgerCanisterId}`
      + `/account/${gateway}`;
  }

  // ⚠️ One quantity at figure size. Three of them wrapped mid-number at the promoted
  // scale, and none of the three read as the headline.
  const orders = stats.deliveredOrders === 1n ? "1 order" : `${stats.deliveredOrders} orders`;
  del.textContent = `${formatCycles(stats.deliveredCycles)} cycles`;
  const delNote = document.getElementById("trust-delivered-note");
  if (delNote) {
    delNote.textContent = `across ${orders} · ${formatUsdCents(stats.deliveredUsdCents)}`;
  }
  delWrap.hidden = false;
  wrap.hidden = false;
}

// --- tiers + gates -------------------------------------------------------

async function loadMarket(): Promise<void> {
  const [tierList, pricing, stats] = await Promise.all([
    backend.card_tiers(),
    backend.pricing_status(),
    backend.delivery_stats(),
  ]);
  // ⚠️ Before `renderTrustFigures`, which reads the divisor for its note.
  lastPricing = pricing;
  renderTrustFigures(stats);
  renderSimulationNote();
  tiers = tierList;
  cardFee = { feeBps: pricing.config.feeBps, feeFixedCents: pricing.config.feeFixedCents };

  // ⚠️ **The first configured amount is preselected, and it is the FIRST rather than
  // the cheapest or a hardcoded $10.** The operator decides the order of these, so the
  // one they put first is the one they mean as the default; picking the minimum by value
  // would silently override that. A buyer arriving at "Pick an amount" with nothing
  // picked has to act before the page tells them anything: with a selection, the
  // breakdown is on screen immediately and the button is live.
  //
  // Only when nothing is chosen yet, so a reload mid-flow does not move a buyer's own
  // choice, and a typed amount is never overwritten.
  if (selectedTierId === null && !customChosen && tiers.length > 0) {
    selectedTierId = tiers[0]!.id;
  }

  // Both rate inputs are shown, because both are needed to reproduce a quote —
  // the ICP price from the Exchange Rate Canister and the XDR/ICP rate the CMC
  // will actually price at. A buyer can query either canister and check us.
  renderRateLine();

  // ⚠️ **No pre-emptive "we might not be able to serve you" banner, and that rule
  // still stands** for every VOLATILE, amount-dependent refusal: the gateway either
  // admits an order or refuses it with a reason the buyer can act on (`#reserveShort`
  // names how much is available, so a smaller amount may work), and that refusal
  // arrives at the moment it is true. A banner rendered from a separately-polled
  // figure would be stale by construction.
  //
  // ⚠️ **`#buyerNotAllowed` and `#unboundedGiveaway` are the exception, because they
  // are neither volatile nor amount-dependent** (#99). An uninvited tester is refused
  // for EVERY amount, always, until an operator acts — so there is no fresher moment
  // for that refusal to arrive at, and letting them pick an amount, sign in and press
  // Buy to discover it is the outcome the pre-emptive rule was never about.
  // `refreshEligibility` renders those two and stays silent on everything else.
  show("gate-notice", false);

  // The gate's own bounds, so the custom-amount field can say "between $10 and
  // $100" in the backend's numbers rather than in a second copy of them.
  try {
    const lifecycle = await backend.lifecycle_config();
    amountBounds = {
      min: lifecycle.gate.minPurchaseUsdCents,
      max: lifecycle.gate.maxPurchaseUsdCents,
    };
  } catch {
    // Leave it null: the field stays disabled rather than offering a range it
    // cannot vouch for. The presets still work.
  }
  renderAmountBounds();

  // Concurrent, and deliberately so: they hit different canisters and neither
  // reads the other's answer. Sequencing them would add a round trip to the
  // first paint of the only screen a visitor sees.
  //
  // ⚠️ `refreshEligibility` joins the group rather than running before it: it reads
  // `amountBounds`, which is only set above. Called earlier it read `null` and
  // returned without probing — which is how it silently did nothing.
  await Promise.all([refreshTierQuotes(), refreshDepositFee(), refreshEligibility()]);
  renderTiers();
  renderSubmitGate();
}

/// One round trip for the whole tier grid. Prices come from the backend's
/// `quote_previews`, which runs the same code `create_order` runs.
async function refreshTierQuotes(): Promise<void> {
  tierQuotes = new Map();
  if (tiers.length === 0) return;
  try {
    const preview = await backend.quote_previews(tiers.map((t) => t.usdCents));
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

/// The ledger's transfer fee, read from the ledger (#30 PR-A).
///
/// It used to arrive on `quote_previews`. It does not any more: the backend
/// would have had to store a copy and correct it on `#BadFee`, because a query
/// cannot await the ledger — a staleness class in exchange for a number this
/// app can just ask for.
///
/// A failure leaves `transferFee` at 0, which `depositFeeLine` and `creditedSplit`
/// both treat as "not known yet": the buyer sees the locked quantity with no fee note
/// rather than a quantity computed from a guessed fee. Shown-too-high is the safe
/// direction — the alternative is promising cycles that will not arrive.
async function refreshDepositFee(): Promise<void> {
  try {
    transferFee = await buildCyclesLedger().icrc1_fee();
  } catch {
    transferFee = 0n;
  }
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

  // ⚠️ **This strip now says ONE thing: that there is no rate.** It used to print the
  // rate, the fee and "cycles are locked at order creation" - all three of which the
  // detail card above already states, the fee twice over. It keeps the no-rate notice
  // because when there is no rate there is no card to put it in.
  if (pricing.rates && priceable) {
    node.textContent = "";
    return;
  }
  node.textContent =
    "No exchange rate available right now. Orders are paused until one is fetched.";
}

/// The last `pricing_status`, so the rate strip can be re-rendered when quotes
/// arrive rather than only at load.
let lastPricing: PricingStatus | null = null;

/// The simulation divisor (#99), read from the config `pricing_status` already
/// returns — **no new endpoint**, and one place that answers "are we simulating".
///
/// `1n` when the gateway has not answered yet, which is the production value: a
/// page that has not loaded its config must not claim a simulation.
function simulationDivisor(): bigint {
  return lastPricing?.config.divisor ?? 1n;
}

/// Say it plainly on the buy view and on the receipt: a real charge in Stripe's
/// sandbox, and a fraction of the cycles.
///
/// ⚠️ **A sentence, not a badge.** A badge announces that a state exists; a buyer
/// needs to know what it means for the purchase in front of them. At divisor 1
/// both elements stay hidden, so a production page is unchanged.
function renderSimulationNote(): void {
  const divisor = simulationDivisor();
  const text =
    `Simulation mode: this gateway is running against Stripe's test environment, ` +
    `and it delivers 1/${divisor} of the cycles a purchase would buy in production. ` +
    `The card charge is real inside the sandbox; no money moves.`;
  // ⚠️ **ONE element, and the loop over two was the bug.** This same sentence was
  // written into the page banner AND into the receipt, so a delivered order stated
  // simulation mode twice on one screen. The banner is the right home: it is a fact
  // about the gateway, not about this order, and the divisor already appears inside
  // the receipt's formula as one of its terms.
  const node = document.getElementById("simulation-note");
  if (node === null) return;
  node.textContent = text;
  node.hidden = divisor === 1n;
}

/// Whether the buyer has opened the custom-amount field.
///
/// ⚠️ **State, not a DOM read.** Deriving it from the field's `hidden` attribute would
/// make the render depend on what the last render painted, which is how a panel ends up
/// stuck open after a re-render it did not expect.
let customChosen = false;

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
    // ⚠️ **The QUANTITY or nothing, never the shared reason.** `estimateLine(null, …)`
    // returns "No exchange rate available right now. Orders are paused until one is.",
    // so with no rate every tile printed the same sentence and the page said it three
    // times in one row, plus again under the field, plus in the button. It is a fact
    // about the gateway, not about this tier: `#rate-line` states it once.
    // ⚠️ **The FIGURE, not the explanation.** This printed
    // "≈ 7.138 G cycles credited (7.238 G sent, less the cycles ledger's 100 M transfer
    // fee)": eighty-five characters of prose inside a button, wrapping to three lines,
    // and byte-identical in the parenthetical across every tile. That parenthetical says
    // nothing distinguishing one amount from another, which is the only job a label in a
    // chooser has. It moved under the tiles, once, for the amount actually chosen.
    label.textContent = quoted?.cycles === undefined || quoted.cycles === null
      ? ""
      : `≈ ${creditedSplit(quoted.cycles, transferFee).figure}`;
    btn.append(amount, label);
    btn.onclick = () => {
      selectedTierId = tier.id;
      // The other direction of the same rule: a tile clears the typed amount, and
      // closes the field with it. One answer to "which amount".
      customChosen = false;
      customUsdCents = null;
      customQuote = null;
      const field = document.getElementById("custom-amount") as HTMLInputElement | null;
      if (field) field.value = "";
      show("custom-amount-error", false);
      clearRequote();
      renderTiers();
      renderAmountDetail();
      renderSubmitGate();
    };
    container.append(btn);
  }

  // ⚠️ **Custom is the FOURTH tile, not a control beside the row.** It is one of four
  // ways to name an amount, so it sits at the same weight as the presets; an
  // always-open field below them competed with the presets for the same decision and
  // needed the label "or enter an amount" to explain a relationship the layout was
  // denying. Selecting it opens the field; picking a preset closes it again, which is
  // the same one-answer rule the presets and the field already had between them.
  const custom = document.createElement("button");
  custom.type = "button";
  custom.id = "tier-custom";
  custom.className = "tier tier-custom" + (customChosen ? " selected" : "");
  const customAmount = document.createElement("span");
  customAmount.className = "amount";
  customAmount.textContent = "Custom";
  const customHint = document.createElement("span");
  customHint.className = "cycles";
  customHint.textContent = amountBounds === null
    ? ""
    : `${formatUsdCents(amountBounds.min)} to ${formatUsdCents(amountBounds.max)}`;
  custom.append(customAmount, customHint);
  custom.onclick = () => {
    customChosen = true;
    selectedTierId = null;
    clearRequote();
    renderTiers();
    renderAmountDetail();
    renderSubmitGate();
    // Focus follows the reveal: the tile exists to get the buyer into the field, and
    // making them click twice for one intent is the cost of hiding it.
    document.getElementById("custom-amount")?.focus();
  };
  container.append(custom);

  show("custom-panel", customChosen);
  renderAmountDetail();
}

/// The chosen amount's detail: the same card the order page shows after locking.
///
/// ⚠️ **ONE renderer for the preset and the typed amount.** There were two writing
/// different shapes into the same node, which is how one of them came to join the fee
/// line to the rate-lock sentence while the other did not.
function renderAmountDetail(): void {
  const chosen = chosenAmount();
  // ⚠️ ONE source for both kinds of amount. A preset's quote and a typed amount's
  // preview are the same shape from the same backend query, so there is no reason for
  // the card to know which it is looking at.
  const quote = chosen?.kind === "tier"
    ? tierQuotes.get(chosen.tierId)
    : (customQuote ?? undefined);
  const cycles = quote?.cycles ?? null;
  const gross = quote?.usdCents ?? (customUsdCents ?? undefined);

  const hideAll = (): void => {
    show("amount-detail", false);
    show("amount-too-small", false);
    show("rate-lock-note", false);
  };
  if (chosen === null || cardFee === null || gross === undefined) {
    hideAll();
    return;
  }

  // ⚠️ **An absent `netCents` means the fee EXCEEDS the amount, and it is the only
  // thing that means that.** `feeRows` reads it that way, which is right: the backend
  // omits the net exactly when the processor's fee would swallow the whole charge. This
  // used to be reachable for a typed amount too, because the preview's split was being
  // discarded on arrival, so a valid $25 order landed behind "Pick a larger amount".
  const split = quote === undefined
    ? null
    : feeRows(gross, quote.feeCents, quote.netCents, cardFee);
  if (split?.kind === "tooSmall") {
    // Not a formatting variant of the card: there is no split to show, so the card
    // stays down and the reason stands alone.
    el("amount-too-small").textContent = split.message;
    show("amount-too-small", true);
    show("amount-detail", false);
    show("rate-lock-note", false);
    return;
  }

  // ⚠️ **No rate means NO CARD, not a card with a hole in it.** This wrote an empty
  // string into "You receive" and showed the rest, so the buyer got "You pay $53.00"
  // beside a labelled row with nothing in it: a figure that looks like it failed to
  // load, next to a charge that looks committed. The card's job is to say what is
  // being bought, and with no rate it cannot. `#rate-line` carries the reason and the
  // button already refuses, so there is nowhere for this to be silently wrong.
  //
  // Same posture as the tiles, which show the quantity or nothing rather than a
  // placeholder, and as `term-block`/`term-sources`, which hide rather than print
  // "not yet" into the middle of the terms.
  if (cycles === null) {
    hideAll();
    return;
  }

  el("detail-pay").textContent = formatUsdCents(gross);
  el("detail-processing").textContent = split?.processing ?? "";
  el("detail-net").textContent = split?.net ?? "";
  el("detail-margin").textContent = split?.margin ?? "";
  el("detail-rate").textContent = rateTerms();

  const credited = creditedSplit(cycles, transferFee);
  el("detail-receive").textContent = `≈ ${credited.figure}`;
  // `depositFeeLine`, not `credited.note`: the note is silent when the two figures read
  // the same, which is every order large enough for the fee to round away.
  const feeLine = depositFeeLine(cycles, transferFee);
  el("detail-fee-note").textContent = feeLine ?? "";
  show("detail-fee-note", feeLine !== null);
  el("rate-lock-note").textContent = RATE_LOCK_NOTE;
  show("rate-lock-note", true);
  show("amount-detail", true);
  show("amount-too-small", false);
}

/// The rate, for the card's own row. The strip below no longer prints it.
function rateTerms(): string {
  const rates = lastPricing?.rates;
  if (!rates) return "";
  const usdPerIcp = (Number(rates.usdPerIcpMicros) / 1e6).toFixed(2);
  const xdrPerIcp = (Number(rates.xdrPermyriadPerIcp) / 1e4).toFixed(4);
  return `ICP $${usdPerIcp} · ${xdrPerIcp} XDR/ICP`;
}

/// The one way into the buy view. Pushed, not replaced: the visitor asked for
/// it, so Back returns them to the landing page.
function startBuying(): void {
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
  } else if (chosenAmount() === null) {
    btn.disabled = true;
    btn.textContent = "Pick an amount";
  } else if (customUsdCents !== null && (customQuote?.cycles ?? null) === null) {
    // A typed amount the gateway could not price. Same refusal as an unpriceable
    // preset, said in the same words.
    btn.disabled = true;
    btn.textContent = "Pricing unavailable, try again shortly";
  } else if (selectedTierId !== null && tierQuotes.get(selectedTierId)?.cycles === undefined) {
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
  showQuoteNotice(quoteChangedMessage(quoted, transferFee));
  renderSubmitGate();
}

// --- order creation ------------------------------------------------------

/// The signed-in principal's own account, default subaccount — the only
/// destination `create_order` accepts (#29).
///
/// Nothing is read from the form, because there is nothing on it to read: no
/// canister id to mistype and no other-account fields to leave stale. The
/// remaining failure is having no identity, and that is a state the submit
/// button already prevents.
function readDestination(): { ok: true; value: Destination } | { ok: false; error: string } {
  if (!identity) return { ok: false, error: "Sign in to continue." };
  return {
    ok: true,
    value: {
      __kind__: "cyclesLedgerAccount",
      cyclesLedgerAccount: { owner: identity.getPrincipal(), subaccount: undefined },
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
    await createCardOrder(dest.value);
  } catch (error) {
    showFormError(reportCallFailure("create_order failed", error));
  } finally {
    renderSubmitGate();
  }
}

/// Show the range and enable the field, once the backend has told us the bounds.
function renderAmountBounds(): void {
  const field = document.getElementById("custom-amount") as HTMLInputElement | null;
  const label = document.getElementById("custom-amount-range");
  if (!field || !label) return;
  if (amountBounds === null) {
    label.textContent = "Loading amounts…";
    field.disabled = true;
    return;
  }
  label.textContent =
    `Any amount from ${formatUsdCents(amountBounds.min)} to ${formatUsdCents(amountBounds.max)}`;
  field.disabled = false;
}

/// React to typing: validate, quote through the backend, and clear any preset.
async function onCustomAmountInput(): Promise<void> {
  const read = readCustomAmount();
  const error = el("custom-amount-error");
  if (!read.ok) {
    customUsdCents = null;
    customQuote = null;
    error.textContent = read.error;
    show("custom-amount-error", true);
    renderSubmitGate();
    return;
  }
  show("custom-amount-error", false);
  customUsdCents = read.cents;
  customQuote = null;
  if (read.cents !== null) {
    // Typing an amount deselects the tiles, so exactly one amount is chosen.
    selectedTierId = null;
    clearRequote();
    renderTiers();
    // Priced by the BACKEND, through the same `quoteCents` that `create_order`
    // calls — never derived here, or a buyer could be shown a number the gateway
    // would not honour.
    try {
      const preview = await backend.quote_previews([read.cents]);
      customQuote = preview.quotes[0] ?? null;
    } catch {
      customQuote = null;
    }
  }
  renderAmountDetail();
  renderSubmitGate();
}


/// The one place "what amount is the buyer buying" is answered.
///
/// Returns null when nothing usable is chosen, which is also what keeps the
/// submit button honest — `renderSubmitGate` asks the same question.
function chosenAmount():
  | { kind: "tier"; tierId: string; usdCents: bigint }
  | { kind: "custom"; usdCents: bigint }
  | null {
  if (customUsdCents !== null) return { kind: "custom", usdCents: customUsdCents };
  if (selectedTierId === null) return null;
  const tier = tiers.find((t) => t.id === selectedTierId);
  if (!tier) return null;
  return { kind: "tier", tierId: tier.id, usdCents: tier.usdCents };
}

/// Parse and bound-check the custom-amount field.
///
/// The bounds are the BACKEND's, read from `lifecycle_config` rather than written
/// down here — a second copy would drift, and `Gate.admit` is the one that
/// decides. This check exists so the buyer hears "between $10 and $100" before
/// they click, not so the bound is enforced: a frontend-only bound is not a bound.
function readCustomAmount(): { ok: true; cents: bigint | null } | { ok: false; error: string } {
  const field = document.getElementById("custom-amount") as HTMLInputElement | null;
  if (!field) return { ok: true, cents: null };
  const raw = field.value.trim();
  if (raw === "") return { ok: true, cents: null };
  const parsed = parseUsdAmount(raw);
  if (!parsed.ok) return { ok: false, error: parsed.error };
  if (amountBounds === null) return { ok: false, error: "Loading amounts…" };
  if (parsed.cents < amountBounds.min || parsed.cents > amountBounds.max) {
    return {
      ok: false,
      error: `Enter an amount between ${formatUsdCents(amountBounds.min)} and ${formatUsdCents(amountBounds.max)}.`,
    };
  }
  return { ok: true, cents: parsed.cents };
}

async function createCardOrder(dest: Destination): Promise<void> {
  // A preset or a typed amount — the same order either way. `create_order` takes
  // a variant (#33), so both go down one path and both are bounded by the same
  // floor and ceiling.
  const chosen = chosenAmount();
  if (chosen === null) return;
  const shown = chosen.kind === "tier"
    ? (tierQuotes.get(chosen.tierId)?.cycles ?? null)
    : (customQuote?.cycles ?? null);
  const amount: Amount = chosen.kind === "tier"
    ? { __kind__: "tier", tier: chosen.tierId }
    : { __kind__: "custom", custom: chosen.usdCents };
  const result = await backend.create_order(amount, dest, pinFor(chosen.usdCents, shown));
  if (result.__kind__ === "err") {
    if (result.err.__kind__ === "quoteChanged") {
      onQuoteChanged(chosen.usdCents, result.err.quoteChanged.quoted);
      return;
    }
    showFormError(
      result.err.__kind__ === "notAdmitted"
        ? gateReasonMessage(result.err.notAdmitted)
        : createOrderErrorMessage(result.err.__kind__),
    );
    return;
  }
  clearRequote();
  const created = result.ok;
  // No link to assemble any more: the canister created a Checkout Session and the
  // order carries its URL (#33). Nothing session-shaped lives in browser memory,
  // which is what makes a reload keep working.
  lockNotice = lockedVsEstimate(created.order.lockedCycles, shown);
  openOrder(created.order);
  void refreshHistory();
}

// --- active order + polling ----------------------------------------------

function describeDestination(order: Order): string {
  const account = order.destination.cyclesLedgerAccount;
  // "cycles-ledger account <62-char principal>" is operator vocabulary, and the
  // account is the caller's own by construction (#29) — so for the signed-in
  // owner it needs no id at all. The id still appears when the page cannot
  // confirm whose it is, rather than asserting "yours" on no evidence.
  const mine = identity !== null && account.owner.toText() === identity.getPrincipal().toText();
  return mine ? "your account" : `account ${account.owner.toText()}`;
}

/// The live countdown to Stripe's deadline.
///
/// Only while the order is still payable: on a paid or delivered order the
/// deadline is history, and showing a timer next to "Delivered" would read as
/// something still being at risk.
/// When the deadline advice stops being noise and starts being useful. Five minutes,
/// because that is the span in which "start now" changes what a buyer does: above it
/// the caution qualifies a price nobody is about to lose.
const URGENT_WINDOW_MS = 5 * 60 * 1000;

function renderDeadline(order: Order): void {
  const node = document.getElementById("order-deadline");
  if (!node) return;
  const deadline = order.expiresAtNs;
  if (deadline === undefined || statusKeyOf(order) !== "created") {
    show("order-deadline", false);
    return;
  }
  const left = timeUntil(nsToMillis(deadline), Date.now());
  if (left === null) {
    // The status line already says expired (see `renderOrder`); repeating it here
    // would be two owners for one statement.
    show("order-deadline", false);
    return;
  }
  // ⚠️ **The warning fires on the CLOCK, not on every render.** The advice
  // ("start with minutes to spare, an in-flight payment fails at the window") is worth
  // reading at four minutes and is noise at thirty-four, where it was a hundred and
  // forty characters of caution above the price it qualified. Progressive disclosure
  // driven by state rather than by a click, so nobody has to open anything to be
  // warned at the moment it matters.
  const msLeft = nsToMillis(deadline) - Date.now();
  const urgent = msLeft <= URGENT_WINDOW_MS;
  node.textContent = urgent
    ? `Price held for ${left}. Start now: a payment still in flight when the window `
      + `closes fails, and you are not charged.`
    : `Price held for ${left}.`;
  node.classList.toggle("tone-warn", urgent);
  show("order-deadline", true);
}

/// Whether Stripe's own deadline has passed.
///
/// Null means no session exists yet, which is a transient state during creation
/// rather than an expired one — treated as not-past so the UI does not flash
/// "expired" at an order that is mid-creation.
function isPastDeadline(order: Order): boolean {
  const deadline = order.expiresAtNs;
  if (deadline === undefined) return false;
  return Date.now() >= nsToMillis(deadline);
}

/// Render #37's attached problems, newest first, with their resolution state.
///
/// ⚠️ **Hidden when there are none, which is the normal case.** A panel headed "What
/// happened to this order" showing nothing reads as a fault on every healthy order —
/// the same reasoning as the lock notice above it.
///
/// ⚠️ **Resolved problems are SHOWN, struck through, not filtered out.** #37's whole
/// premise is that nothing drops: a buyer whose refund was reconciled should see that it
/// happened and was dealt with, and hiding it would make the record look like it never
/// existed. The worklist filters by unresolved; a *view of one order* does not.
function renderProblems(order: Order): void {
  const list = el("order-problem-list");
  list.textContent = "";
  const problems = order.problems ?? [];
  show("order-problems", problems.length > 0);
  if (problems.length === 0) return;

  // Newest first: the most recent trouble is what a reader is looking for. `filedAtNs`
  // is when it FIRST happened, and a refresh does not move it (see `Problems.file`), so
  // this ordering is stable across re-renders.
  const ordered = [...problems].sort((a, b) => (b.filedAtNs > a.filedAtNs ? 1 : -1));
  for (const problem of ordered) {
    const item = document.createElement("li");
    const resolved = problem.resolvedAtNs !== null && problem.resolvedAtNs !== undefined;
    if (resolved) item.classList.add("resolved");
    const label = document.createElement("strong");
    label.textContent = problemLabel(problem);
    item.append(label);
    item.append(document.createTextNode(`: ${problem.detail}`));
    if (resolved) item.append(document.createTextNode(" (resolved)"));
    list.append(item);
  }
}

/// A buyer-facing name for each problem kind.
///
/// ⚠️ **Named for what happened to the BUYER, not for the variant.** `paidNotCredited`
/// is our word for our bug; "we took your payment and have not delivered yet" is what
/// the person reading it needs. The variant name stays in the audit trail and the
/// runbook, where the audience is different.
function problemLabel(problem: Order["problems"][number]): string {
  const kind = problem.kind;
  if ("duplicate" in kind) return "A second payment arrived for this order";
  if ("deliveryStuck" in kind) return "Delivery stopped and needs a human";
  if ("refundAfterDelivery" in kind) return "Refunded after the cycles were delivered";
  if ("paidNotCredited" in kind) return "Paid, and not yet credited";
  // ⚠️ No default that invents a name: an unhandled kind should be visibly unhandled
  // rather than quietly labelled "problem", which is how a new kind ships unnoticed.
  return "Unrecognised problem (see the audit trail)";
}

function renderOrder(order: Order): void {
  // Writes into `#active-order`, which the order view owns and no other view
  // does. The poll ticks every 3 s regardless of where the visitor has since
  // navigated, so without this a tick could refill and re-reveal the order panel
  // underneath the history table or the buy form.
  if (currentView !== "order") return;
  const idNode = el("order-id-short");
  idNode.textContent = `${order.id.slice(0, 8)}…`;
  // Truncated ids exist to be quoted, so the full one is reachable without a
  // selection. `replaceChildren` because renderOrder runs on every 3 s poll tick and
  // appending would stack a copy button per tick.
  idNode.parentElement?.replaceChildren(
    document.createTextNode("Order "),
    idNode,
    copyButton(order.id, "Copy the full order id"),
  );
  // No "≈" here: the rate is locked, so this figure is what the order pays out.
  // ⚠️ The FIGURE alone. The explanation of why it differs from what was bought is a
  // separate node under it, because a value cell is not where prose belongs.
  const credited = creditedSplit(order.lockedCycles, transferFee);
  el("order-cycles").textContent = credited.figure;
  const feeLine = depositFeeLine(order.lockedCycles, transferFee);
  el("order-cycles-note").textContent = feeLine ?? "";
  show("order-cycles-note", feeLine !== null);
  el("order-price").textContent = formatUsdCents(order.pricing.usdCents);
  el("order-dest").textContent = describeDestination(order);
  renderDeadline(order);

  const lockNode = el("order-lock-notice");
  lockNode.textContent = lockNotice ?? "";
  show("order-lock-notice", lockNotice !== null);
  el("order-rate").textContent =
    `$${(Number(order.pricing.usdPerIcpMicros) / 1e6).toFixed(2)}/ICP · ` +
    `${(Number(order.pricing.xdrPermyriadPerIcp) / 1e4).toFixed(4)} XDR/ICP · locked at creation`;
  // XDR is the unit the CMC mints against, so it belongs in the verifiable
  // record — but the headline number a buyer recognises is the dollar rate.

  renderProblems(order);

  const key = statusKeyOf(order);
  // ⚠️ **Expiry is rendered from the DEADLINE, not the status.** An order sits in
  // `#created` past its `expiresAtNs` whenever the `checkout.session.expired`
  // webhook is late or lost — Stripe closed the session on its own clock either
  // way. Showing "Awaiting payment" there tells the buyer to do something that
  // cannot work, so the page reports what Stripe's timestamp says. Zero backend
  // cost, and the backend still moves the status when the event lands.
  const info = key === "created" && isPastDeadline(order)
    ? statusInfo("expired")
    : statusInfo(key);

  // ⚠️ **The heading IS the outcome.** The credited quantity is passed in, so a
  // delivered order reads "7.138 G cycles delivered" rather than a neutral title beside
  // a badge a buyer has to go looking for.
  const headline = el("order-headline");
  const creditedFigure = creditedSplit(order.lockedCycles, transferFee).figure;
  headline.textContent = info.headline(
    statusKeyOf(order) === "delivered" ? creditedFigure : undefined,
  );
  headline.className = `section-h tone-${info.tone}`;

  const statusLine = el("order-status-line");
  statusLine.textContent = info.guidance ?? "";
  statusLine.className = `tone-${info.tone}`;
  // ⚠️ **Shown only when the status has something to DO about it**, which is a fact
  // about the status rather than a comparison between two of its strings. It used to
  // print `label` whenever `label !== pill`; with the heading now carrying the outcome,
  // that fired for every status and repeated what the heading had just said.
  show("order-status-line", info.guidance !== undefined);

  // Tense follows the order. Two labels, two facts: a paid order HAS paid but has not
  // yet received, so one "done" flag would promise cycles that have not moved.
  const labels = amountLabels(key);
  el("order-pay-label").textContent = labels.pay;
  el("order-receive-label").textContent = labels.receive;

  // `#expired` used to be here, on the §4 grounds that a late payment still
  // completed. #34 deleted `#expired → #paid`, so an expired order is not
  // awaiting anything — offering a pay link would send a buyer to spend money the
  // gateway would then have to refund. `#cancelled` was never payable.
  //
  // Past `expiresAtNs` the order is also not payable, even while the status is
  // still `#created`: Stripe closes the session on its own clock and the webhook
  // telling us may be late or lost. Rendering from the timestamp means a buyer
  // never sees a live pay button for a session Stripe has already closed.
  const awaitingPayment = key === "created" && !isPastDeadline(order);

  // ⚠️ FROM THE ORDER, not from browser memory. This used to read a
  // session-scoped `Map` populated only when `create_order` returned, so ANY
  // reload lost the pay button on an order that was still payable — and with a
  // one-open-order cap the buyer could not even start over. The URL is on the
  // record now (#33/#34), so a reload, a second device and a deep link all work.
  const link = order.stripeSessionUrl;
  const payable = awaitingPayment && link !== undefined;
  show("pay-area", payable);
  // The note is about that button. One predicate for both, so a note cannot outlive
  // the control it describes.
  show("pay-note", payable);
  if (link !== undefined) {
    el<HTMLAnchorElement>("pay-link").href = link;
  }
  // Derived rather than handed back by `create_order` (#33): it is the reference
  // on the buyer's card receipt, so it stays on screen, but it was only ever in
  // the response so the frontend could build a Payment Link URL.
  if (identity !== null) {
    const ref = clientReferenceFor(identity.getPrincipal().toText(), order.id);
    const refNode = el("client-ref");
    refNode.textContent = `${ref.slice(0, 12)}…${ref.slice(-6)}`;
    refNode.parentElement?.replaceChildren(
      document.createTextNode("Payment reference "),
      refNode,
      copyButton(ref, "Copy the payment reference"),
    );
  }

  // Only an unpaid order can be given up on; past payment it is going to
  // deliver, and offering a cancel there would promise something untrue.
  show("cancel-area", awaitingPayment && identity !== null);
  el<HTMLButtonElement>("cancel-order").disabled = false;

  // ⚠️ **The `.catch` is not decoration.** `void`-ing this swallowed every error the
  // receipt render could throw: the section stayed hidden, no message appeared, and
  // nothing anywhere said why — a buyer would see an order with no receipt and no
  // explanation. Found because a missing export in a test mock produced exactly that
  // silence, and the only way to see it was to add this.
  void renderReceipt(order).catch((error) => {
    // eslint-disable-next-line no-console
    console.error("could not render the receipt", error);
  });
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
/// Every delivered order gets it, because every order credits the buyer's own
/// account (#29). The two suppressed cases — a canister top-up, where there was
/// nothing to link, and somebody else's account, where the buyer's identity
/// could not reach the balance — are destinations the gateway no longer accepts.
function renderCliSteps(onCli: boolean): void {
  const node = document.getElementById("cli-steps");
  if (!node) return;
  // ⚠️ **Gated on the IDENTITY, not on a delivered order.** The principal came from
  // `order.destination.cyclesLedgerAccount.owner`, which §2 forces to equal the
  // caller's own account, so it was the signed-in principal by a longer route. Reading
  // it from the identity is what lets this page exist without an order.
  //
  // ⚠️ If a destination that is NOT the caller's ever ships, this becomes wrong for
  // it: `icp identity link web` links the CALLER, so commands printed for someone
  // else's balance reach the wrong account. Today every order credits the buyer (#29).
  if (!onCli || identity === null) {
    node.hidden = true;
    return;
  }
  el("credited-principal").textContent = identity.getPrincipal().toText();
  // ⚠️ Rendered in the ORDER the page presents them, and every one of them is a real
  // subcommand rather than prose about one: see `config.ts` for why step 2 exists and
  // why the verify commands carry no `--identity` flag.
  el("cmd-link").textContent = linkIdentityCommand();
  el("cmd-default").textContent = identityDefaultCommand();
  el("cmd-principal").textContent = verifyPrincipalCommand();
  el("cmd-balance").textContent = verifyBalanceCommand();
  el("cmd-deploy").textContent = deployCommand();
  // The guide URL is a deployment constant like the commands, so it is set from
  // `config.ts` rather than typed into the markup: one place to change when the CLI
  // version moves, which is exactly what went stale at 1.2.
  el<HTMLAnchorElement>("cli-guide").href = CLI_IDENTITY_GUIDE;
  el<HTMLAnchorElement>("cli-settings").href = IDENTITY_SETTINGS;
  // The balance to compare against comes from the same ledger read the heading uses,
  // so the page cannot tell a buyer to expect a figure it is not itself showing.
  el("cli-expect-balance").textContent = ledgerBalance === null
    ? "the balance above"
    : `${formatCycles(ledgerBalance)} cycles`;
  node.hidden = false;
}

/// The one-line summary at the top of the CLI page: what there is to spend.
///
/// ⚠️ **The LEDGER's balance, not one order's figure.** This said "N cycles are in
/// your account" from the order it was scoped to, which is the wrong number the moment
/// a buyer has more than one order and an impossible one when they arrive from the
/// dashboard. `refreshLedgerBalance` already reads the account; this reuses its
/// result rather than adding a second read with its own failure mode.
function renderCliSummary(): void {
  const node = document.getElementById("cli-summary");
  if (!node) return;
  if (identity === null) {
    node.textContent = "Sign in to see the commands for your account.";
    return;
  }
  node.textContent = ledgerBalance === null
    ? "One setting and four steps to deploy."
    : `${formatCycles(ledgerBalance)} cycles in your account. One setting and four steps to deploy.`;
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
  // ⚠️ **`paidUsdCents` and `cyclesDelivered` are NOT rendered here any more.** They
  // were the same two numbers the summary card already states, written by a second
  // code path, so the page showed "$10.00" and "7.138 G" twice. The card is the one
  // owner. This function keeps the facts only the receipt has.
  // ⚠️ **The block index becomes a LINK, because it is the one fact on this page a
  // buyer can check without this canister.** The cycles ledger is public, so the
  // dashboard entry is evidence rather than a convenience: it is where "the cycles
  // arrived" stops being our claim and becomes someone else's record.
  const blockCell = el("receipt-block");
  blockCell.replaceChildren();
  if (receipt.deliveryBlockIndex !== undefined) {
    const link = document.createElement("a");
    link.href =
      `https://dashboard.internetcomputer.org/tokens/${cyclesLedgerCanisterId}`
      + `/transaction/${receipt.deliveryBlockIndex}`;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    link.className = "mono";
    link.textContent = `${receipt.deliveryBlockIndex} (view on the dashboard)`;
    blockCell.append(link);
  }
  const sources = rateSourceNote(v.rateReceivedRates, v.rateQueriedSources);
  el("receipt-sources").textContent = sources;
  // These two live in the summary card now, so an empty one is a BLANK ROW in the
  // middle of the terms rather than a line in a section of its own. Hidden instead of
  // printing "not yet", which on a delivered order would be a claim, and on an unpaid
  // one is noise about a fact that cannot exist yet.
  show("term-block", receipt.deliveryBlockIndex !== undefined);
  show("term-sources", sources !== "");

  // ⚠️ The divisor comes from config, not the order — see `checkReceipt`. In
  // simulation mode `check.recomputed` is what PRODUCTION would have locked, which
  // is the more interesting of the two numbers and is already on screen.
  const check = checkReceipt(v, receipt.order.lockedCycles, simulationDivisor());
  renderSimulationNote();
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
      status.textContent = cancelOrderErrorMessage(result.err);
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

function stopPolling(): void {
  if (pollTimer !== null) clearInterval(pollTimer);
  pollTimer = null;
  if (deadlineTimer !== null) clearInterval(deadlineTimer);
  deadlineTimer = null;
  pollOrderId = null;
  lastPolledStatus = null;
}

function openOrder(order: Order): void {
  activeOrder = order;
  orderLoad = "ok";
  navigate({ view: "order", orderId: order.id }, true);
  stopPolling();
  renderOrder(order);
  pollOrderId = order.id;
  lastPolledStatus = statusKeyOf(order);
  pollTimer = setInterval(() => void pollActiveOrder(), POLL_MS);
  // The countdown has to move between polls, or a 3 s tick makes it look stuck.
  // Re-rendering only the deadline keeps it off the view machine's path.
  if (deadlineTimer !== null) clearInterval(deadlineTimer);
  deadlineTimer = setInterval(() => {
    if (activeOrder !== null && currentView === "order") renderDeadline(activeOrder);
  }, 1_000);
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
  // ⚠️ **Paged since #38, and the buyer's view wants ALL of them.** `list_orders` used
  // to return every order unbounded, which is a trap rather than a convenience: a query
  // response is capped at ~2 MB and an oversized read traps rather than truncating.
  // Nothing drops orders under #37, so this only grows.
  //
  // ⚠️ **Paging to exhaustion here is deliberate, not lazy.** The history view sorts by
  // time and shows a count, so a first page would silently mis-sort and undercount —
  // the backend pages by order ID, which is NOT time order. If this list ever gets big
  // enough for that to hurt, the fix is a paged UI, not a bigger first page.
  let orders: Order[];
  try {
    orders = [];
    // The generated bindings use `T | null` for a Candid `opt`, not the tuple form the
    // integration suite's hand-written IDL uses. Same wire type, two conventions.
    let cursor: string | null = null;
    for (;;) {
      const page = await backend.list_orders(cursor, 200n);
      orders.push(...page.orders);
      if (page.nextCursor === null || page.nextCursor === undefined) break;
      cursor = page.nextCursor;
    }
  } catch {
    return;
  }
  orders.sort((a, b) => (b.createdAtNs > a.createdAtNs ? 1 : -1));

  orderCount = orders.length;
  // The header link appears only once there is something behind it, so this has
  // to run after the count is known rather than at sign-in.
  renderView();

  const body = el("orders");
  body.replaceChildren();
  for (const order of orders) {
    const info = statusInfo(statusKeyOf(order));
    const row = document.createElement("tr");
    // ⚠️ **Five cells against five headers.** The header used to carry a RAIL column
    // with no cell behind it — six headers, five cells — so every column from Rail
    // onward was rendering the NEXT field's value: cycles under "Rail", price under
    // "Cycles", status under "Price". A column whose only value is "card" cost width,
    // said nothing, and silently shifted the whole table.
    const cells = [
      new Date(nsToMillis(order.createdAtNs)).toLocaleString(),
      null, // the order id, rendered as a link below
      formatCycles(order.lockedCycles),
      formatUsdCents(order.pricing.usdCents),
      // ⚠️ The BADGE form, not the label. This rendered "Expired. This order can no
      // longer be paid" into a status column: a sentence where two words belong, in a
      // table whose other cells are a date, an id and two figures. `pill` exists for
      // exactly this and was only being used on the order page.
      info.pill,
    ];
    cells.forEach((text, index) => {
      const td = document.createElement("td");
      if (text === null) {
        // ⚠️ A LINK, not just a clickable row. `tr.onclick` is unreachable by keyboard
        // and shows no destination on hover; an anchor is both, and it makes the row's
        // purpose legible without a hint column.
        const link = document.createElement("a");
        link.className = "order-link mono";
        link.href = routeHash({ view: "order", orderId: order.id });
        link.textContent = `${order.id.slice(0, 8)}…`;
        td.append(link);
      } else {
        td.textContent = text;
      }
      if (index === cells.length - 1) td.className = `tone-${info.tone}`;
      row.append(td);
    });
    row.className = "order-row";
    row.onclick = () => {
      lockNotice = null;
      openOrder(order);
    };
    // ⚠️ **"Buy again" is gone, and it was worse than redundant.** It rendered on
    // EVERY row including unpaid ones, where the one-open-order cap refuses the very
    // order it was offering to start: the button led a buyer into `#tooManyOpenOrders`.
    // Starting an order is what the buy view is for.
    body.append(row);
  }
}


/// Copy-to-clipboard for the CLI commands. Falls back to selecting the text:
/// clipboard access is refused in some browsers and over plain HTTP, and a
/// button that silently does nothing is worse than one that selects for you.
/// The copy glyph, and the tick that replaces it on success.
///
/// ⚠️ **Inline SVG, not an emoji.** `scripts/brand-lint.sh` bans pictographs in
/// user-facing copy, and it is right to: clipboard emoji render differently on every
/// platform and some fonts have no glyph at all, which shows as a box.
///
/// `aria-hidden` on the SVG because the accessible name lives on the button's
/// `aria-label` — otherwise a screen reader reads the icon and the label.
const COPY_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false">'
  + '<rect x="5.5" y="5.5" width="8" height="9" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/>'
  + '<path d="M10.5 3.5V2.75A1.25 1.25 0 0 0 9.25 1.5H3.75A1.25 1.25 0 0 0 2.5 2.75v7.5A1.25 1.25 0 0 0 3.75 11.5H4.5"'
  + ' fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>';

const DONE_ICON =
  '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false">'
  + '<path d="M3 8.5l3.2 3.2L13 5" fill="none" stroke="currentColor" stroke-width="1.8"'
  + ' stroke-linecap="round" stroke-linejoin="round"/></svg>';

/// Copy `text`, and **report the outcome whichever way it goes** (#106 follow-up).
///
/// ⚠️ **Three ways this used to fail silently, and all three read to a user as "the
/// button does nothing".**
///
/// 1. `navigator.clipboard?.writeText(t).then(…).catch(…)` — optional chaining
///    short-circuits the WHOLE chain, so where `navigator.clipboard` is absent
///    (any non-secure origin: a LAN IP, a plain-http host) `writeText` was never
///    called, `then` never ran so there was no feedback, and `catch` never ran so
///    there was no fallback either. Nothing happened at all.
/// 2. When `writeText` REJECTED — permission denied, or a browser that wants the
///    write closer to the gesture — the catch ran, and for the header button there
///    was no node to select, so it returned having done nothing visible.
/// 3. Success flashed a label; failure flashed nothing. A user cannot tell "copied"
///    from "ignored me" if only one of them speaks.
///
/// So: a synchronous `execCommand` fallback that works without the async API, and a
/// state on the button for every outcome including failure.
function copyWithFeedback(btn: HTMLButtonElement, text: string, fallbackNode?: Element): void {
  const settle = (state: "copied" | "failed") => {
    btn.dataset.state = state;
    btn.innerHTML = state === "copied" ? DONE_ICON : COPY_ICON;
    // Announced, not just drawn: the icon swap is invisible to a screen reader.
    btn.setAttribute("aria-live", "polite");
    const label = btn.dataset.label ?? "Copy";
    btn.title = state === "copied" ? "Copied" : "Press Ctrl/Cmd+C to copy";
    setTimeout(() => {
      btn.dataset.state = "idle";
      btn.innerHTML = COPY_ICON;
      btn.title = label;
    }, 1_600);
  };

  /// Select the value so Ctrl/Cmd+C works, which is the honest last resort: it puts
  /// the user one keystroke from the thing they asked for instead of nowhere.
  const selectIt = (): boolean => {
    if (!fallbackNode) return false;
    const range = document.createRange();
    range.selectNodeContents(fallbackNode);
    const sel = window.getSelection();
    if (!sel) return false;
    sel.removeAllRanges();
    sel.addRange(range);
    return true;
  };

  /// The pre-`navigator.clipboard` path. Synchronous, so it works in the places the
  /// async API is unavailable — and it needs a node in the document, hence the
  /// off-screen textarea rather than a detached one.
  const execCopy = (): boolean => {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.top = "-1000px";
    area.style.opacity = "0";
    document.body.append(area);
    area.select();
    let ok = false;
    try {
      ok = document.execCommand("copy");
    } catch {
      ok = false;
    }
    area.remove();
    return ok;
  };

  const write = navigator.clipboard?.writeText;
  if (typeof write !== "function") {
    // ⚠️ Not an optional-chained no-op any more. No async clipboard means go
    // straight to the synchronous path, and report either way.
    settle(execCopy() || selectIt() ? "copied" : "failed");
    return;
  }
  void navigator.clipboard.writeText(text).then(
    () => settle("copied"),
    () => settle(execCopy() || selectIt() ? "copied" : "failed"),
  );
}

/// A copy button for a value rendered by JS rather than sitting in the markup.
function copyButton(text: string, ariaLabel: string): HTMLButtonElement {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "copy copy-inline";
  btn.innerHTML = COPY_ICON;
  btn.dataset.state = "idle";
  btn.dataset.label = ariaLabel;
  btn.title = ariaLabel;
  // The accessible name, because the button has no text of its own now.
  btn.setAttribute("aria-label", ariaLabel);
  btn.onclick = () => copyWithFeedback(btn, text);
  return btn;
}

function wireCopyButtons(): void {
  for (const btn of document.querySelectorAll<HTMLButtonElement>("button.copy")) {
    // The markup carries the label; the glyph is installed here so there is ONE
    // definition of what a copy button looks like.
    const label = btn.getAttribute("aria-label") ?? "Copy";
    btn.dataset.label = label;
    btn.dataset.state = "idle";
    btn.title = label;
    btn.innerHTML = COPY_ICON;
    btn.onclick = () => {
      const target = document.getElementById(btn.dataset.copy ?? "");
      if (!target) return;
      copyWithFeedback(btn, target.textContent ?? "", target);
    };
  }
}

/// Light is the mandatory default and dark is opt-in, so this never consults
/// prefers-color-scheme — the brand guidelines forbid auto-switching. The choice
/// persists because a visitor who picked dark meant it.
const THEME_KEY = "icp.theme";

/// The two theme glyphs: a moon to go dark, a sun to come back.
///
/// ⚠️ **Inline SVG, not an emoji** — `brand-lint` bans pictographs in user-facing
/// copy, and rightly: a platform that renders these as boxes puts a box in the
/// header. `aria-hidden` because the accessible name is on the button's
/// `aria-label`, which says which direction the click goes.
const MOON_ICON =
  '<svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true" focusable="false">'
  + '<path d="M13.5 10.2A5.8 5.8 0 0 1 5.8 2.5 5.8 5.8 0 1 0 13.5 10.2Z"'
  + ' fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>';

const SUN_ICON =
  '<svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true" focusable="false">'
  + '<circle cx="8" cy="8" r="3.1" fill="none" stroke="currentColor" stroke-width="1.4"/>'
  + '<path d="M8 1v1.6M8 13.4V15M1 8h1.6M13.4 8H15M3.1 3.1l1.1 1.1M11.8 11.8l1.1 1.1'
  + 'M12.9 3.1l-1.1 1.1M4.2 11.8l-1.1 1.1" stroke="currentColor" stroke-width="1.4"'
  + ' stroke-linecap="round"/></svg>';

function applyTheme(dark: boolean): void {
  document.documentElement.toggleAttribute("data-theme", false);
  if (dark) document.documentElement.setAttribute("data-theme", "dark");
  else document.documentElement.removeAttribute("data-theme");
  const btn = el("theme-toggle");
  // ⚠️ The glyph shows the DESTINATION, not the current state: in light mode you
  // see a moon, because the button's job is "click for dark". Showing the current
  // theme instead reads as a status light and makes the click a guess. The label
  // and the `title` say the same thing in words.
  btn.innerHTML = dark ? SUN_ICON : MOON_ICON;
  const label = dark ? "Switch to light theme" : "Switch to dark theme";
  btn.setAttribute("aria-label", label);
  btn.title = label;
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
    // ⚠️ **Re-render, because `loadMarket` already rendered while this still said
    // "loading".** The flag is set HERE, after the await, so the `renderTiers()` at the
    // end of `loadMarket` always observed `"loading"`. With tiers configured that is
    // invisible: the placeholder branch is never reached. With an EMPTY list it is the
    // only output, so a gateway that has registered no tiles read "Loading amounts..."
    // for ever and its "No amounts are configured yet." branch was unreachable — the
    // state every fresh deployment starts in, so the first thing an operator saw on
    // mainnet was a page that looked broken.
    //
    // Mirrors the catch path below, which has always re-rendered for the same reason.
    renderTiers();
    renderSubmitGate();
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
  el<HTMLFormElement>("order-form").onsubmit = (e) => void onCreateOrder(e);
  el("cancel-order").onclick = () => void onCancelOrder();
  el("start-buy").onclick = startBuying;
  const customField = document.getElementById("custom-amount") as HTMLInputElement | null;
  if (customField) customField.oninput = () => void onCustomAmountInput();
  wireCopyButtons();
  wireThemeToggle();
  // Hash routing so Back works. An asset canister would need SPA rewrites for
  // real paths; a hash cannot 404 on reload.
  window.addEventListener("hashchange", () => applyRoute(parseRoute(window.location.hash)));
  // ⚠️ **No cursor reset here, and that is not an omission.** `loadAdminOrders()` with
  // `append` false passes `null` and then overwrites `historyCursor` from the response, so
  // the cursor is read ONLY when appending. An explicit reset alongside these handlers
  // looked prudent and was dead code: removing it changed no test, which is how it was
  // found. The property that matters is one step later, and it is pinned: after a filter
  // change, "Load more" pages the NEW filter's cursor.
  const status = document.getElementById("filter-status") as HTMLSelectElement | null;
  if (status) {
    status.onchange = () => {
      historyFilterStatus = status.value;
      void loadAdminOrders();
    };
  }
  const onlyProblems = document.getElementById("filter-problems") as HTMLInputElement | null;
  if (onlyProblems) {
    onlyProblems.onchange = () => {
      historyFilterProblems = onlyProblems.checked;
      void loadAdminOrders();
    };
  }
  const more = document.getElementById("admin-history-more");
  if (more) more.onclick = () => void loadAdminOrders(true);

  const auditMore = document.getElementById("diag-audit-more");
  if (auditMore) auditMore.onclick = () => void loadAuditPage(false);

  const lookup = document.getElementById("lookup-run");
  if (lookup) lookup.onclick = () => void runLookup();
  const lookupId = document.getElementById("lookup-id");
  // Delegated, because the rows are replaced on every page of the history and a listener
  // per row would be rebound each time. Same shape as the sort listener above.
  const ordersPanel = document.getElementById("apanel-orders");
  if (ordersPanel) {
    ordersPanel.addEventListener("click", (event) => {
      const fill = (event.target as HTMLElement | null)?.closest(".id-fill");
      if (!(fill instanceof HTMLElement)) return;
      const id = fill.dataset.orderId;
      if (id === undefined || !(lookupId instanceof HTMLInputElement)) return;
      lookupId.value = id;
      // Focus rather than run: the lookup is an audited read, so the operator confirms.
      lookupId.focus();
    });
  }
  // Enter submits, because typing an id and reaching for the mouse is the wrong shape
  // for the one control on this panel.
  if (lookupId instanceof HTMLInputElement) {
    lookupId.onkeydown = (event) => {
      if (event.key === "Enter") void runLookup();
    };
  }

  // ⚠️ **Delegated on the console, not bound per header.** The worklist bodies are
  // replaced on every refresh, and a listener bound to a header would survive that while
  // one bound per row would not — delegation keeps sorting working across a reload of the
  // data without re-binding anything.
  const console_ = document.getElementById("admin");
  if (console_) {
    console_.addEventListener("click", (event) => {
      const target = event.target;
      if (!(target instanceof HTMLElement)) return;
      const header = target.closest("th[data-sort]");
      if (!(header instanceof HTMLTableCellElement)) return;
      const table = header.closest("table");
      if (!(table instanceof HTMLTableElement)) return;
      sortTableBy(table, header.cellIndex, header.dataset.sort ?? "text");
    });
  }

  el("history-link").onclick = () => {
    // The anchor already sets the hash; this only stops a same-hash click from
    // being a no-op after the view moved on.
    applyRoute({ view: "history", tab: "orders" });
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
      useCyclesLedger: (factory) => {
        cyclesLedgerFactory = factory;
      },
      useCyclesIndex: (factory) => {
        cyclesIndexFactory = factory;
      },
      // Safe despite also being the actor's id: `backendFactory` is set above and
      // short-circuits `buildBackend`, so this only ever feeds the sender gate.
      useGatewayPrincipal: (id) => {
        liveBackendId = id;
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


  // The session BEFORE the route, because the route can depend on it. `get_order`
  // answers per caller, so resolving `#/order/<id>` while still anonymous looks up
  // an order this principal cannot see, gets nothing back, and lands on "we could
  // not find that order" — for an order the visitor owns, on a plain reload. It
  // also decides whether the delivered tour renders at all, and which principal
  // it prints as the credited account.
  const restored = await currentIdentity();
  if (restored) setIdentity(restored);

  // Parse the route the page was OPENED with, not only later hashchanges. Without
  // this a deep link or a reload on #/history silently rendered the landing view.
  applyRoute(parseRoute(window.location.hash));

  await loadMarketWithRetry();
}

void init();
