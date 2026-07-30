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
  type Backend,
  type CkUsdcConfig,
  type Destination,
  type Order,
  type QuotePreview,
  Rail,
  type Tier,
} from "./actor";
import { currentIdentity, signIn, signOut } from "./auth";
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
let backend: Backend = makeBackend();
let tiers: Tier[] = [];
let selectedTierId: string | null = null;
let lowFloat = false;
let activeRail: RailKey = "card";
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

function show(id: string, visible: boolean): void {
  el(id).hidden = !visible;
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
    inBtn.className = "primary";
    inBtn.textContent = "Sign in with Internet Identity";
    inBtn.onclick = async () => {
      try {
        setIdentity(await signIn());
      } catch {
        // User closed the popup — nothing to clean up.
      }
    };
    area.append(inBtn);
  }
}

function setIdentity(next: Identity | null): void {
  identity = next;
  backend = makeBackend(identity ?? undefined);
  renderAuth();
  renderSubmitGate();
  show("history", identity !== null);
  if (identity) {
    const owner = el<HTMLInputElement>("ledger-owner");
    if (!owner.value) owner.value = identity.getPrincipal().toText();
    void refreshHistory();
  } else {
    stopPolling();
    show("active-order", false);
    el("orders").replaceChildren();
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
  const rateLine = el("rate-line");
  if (pricing.rates) {
    const usdPerIcp = (Number(pricing.rates.usdPerIcpMicros) / 1e6).toFixed(2);
    const xdrPerIcp = (Number(pricing.rates.xdrPermyriadPerIcp) / 1e4).toFixed(4);
    const fee = `fee ${Number(pricing.config.feeBps) / 100}% + ${formatUsdCents(pricing.config.feeFixedCents)}`;
    rateLine.textContent =
      `ICP $${usdPerIcp} · ${xdrPerIcp} XDR/ICP · ${fee} · cycles are locked at order creation`;
  } else {
    rateLine.textContent =
      "No exchange rate available yet — orders are paused until one is fetched.";
  }

  const gate = el("gate-notice");
  if (lowFloat) {
    gate.textContent =
      "Operator float is low — new orders may queue until it is refilled. Paid orders always deliver at their locked quantity.";
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

function renderCkPanel(): void {
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
  const node = el("ck-estimate");
  if (ckQuote === null || ckConfig === null || ckRailDisabled()) {
    show("ck-estimate", false);
    return;
  }
  const destination = selectedDestinationKind();
  const fee = { feeBps: ckConfig.feeBps, feeFixedCents: ckConfig.feeFixedCents };
  node.textContent =
    `${estimateLine(ckQuote.cycles ?? null, destination, depositFee)} · ` +
    `${feeBreakdown(ckQuote.usdCents, ckQuote.feeCents, ckQuote.netCents, fee)} — ${RATE_LOCK_NOTE}`;
  show("ck-estimate", true);
}

/// Debounced re-quote as the amount is typed. A malformed amount clears the
/// estimate rather than leaving a stale one that belongs to different input.
function scheduleCkQuote(): void {
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

function renderTiers(): void {
  const container = el("tiers");
  container.replaceChildren();
  if (tiers.length === 0) {
    const p = document.createElement("p");
    p.className = "muted";
    p.textContent = "No tiers configured yet — check back soon.";
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
      ? "—"
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
    `${feeBreakdown(quote.usdCents, quote.feeCents, quote.netCents, cardFee)} — ${RATE_LOCK_NOTE}`;
  show("tier-detail", true);
}

function renderSubmitGate(): void {
  const btn = el<HTMLButtonElement>("create-order");
  if (!identity) {
    btn.disabled = true;
    btn.textContent = "Sign in to continue";
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
    btn.textContent = "Pricing unavailable — try again shortly";
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
  el("rail-card").classList.toggle("active", rail === "card");
  el("rail-ckusdc").classList.toggle("active", rail === "ckUsdc");
  show("card-panel", rail === "card");
  show("ck-panel", rail === "ckUsdc");
  showFormError(null);
  renderSubmitGate();
}

// --- order creation ------------------------------------------------------

function readDestination(): { ok: true; value: Destination } | { ok: false; error: string } {
  const kind = (document.querySelector('input[name="dest-kind"]:checked') as HTMLInputElement).value;
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

function showFormError(message: string | null): void {
  const node = el("form-error");
  node.textContent = message ?? "";
  show("form-error", message !== null);
}

async function onCreateOrder(event: SubmitEvent): Promise<void> {
  event.preventDefault();
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
    showFormError(`Call failed: ${error instanceof Error ? error.message : String(error)}`);
  } finally {
    renderSubmitGate();
  }
}

async function createCardOrder(dest: Destination): Promise<void> {
  if (selectedTierId === null) return;
  const tier = tiers.find((t) => t.id === selectedTierId);
  if (!tier) {
    showFormError("Selected tier vanished — reload the page.");
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
      return `cycles-ledger account ${account.owner.toText()}${subText}`;
    }
  }
}

function renderOrder(order: Order, clientReferenceId?: string): void {
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

  show("active-order", true);
  void renderReceipt(order);
}

/// Receipt + price verification for a delivered order.
///
/// The check runs here, on the buyer's machine, from the rate inputs the receipt
/// carries — both queryable from the XRC and the CMC. A gateway asserting its own
/// price is correct proves nothing; recomputing it somewhere the operator does
/// not control is the whole point.
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
    ? "—"
    : formatUsdCents(receipt.paidUsdCents);
  el("receipt-minted").textContent = receipt.cyclesMinted === undefined
    ? "—"
    : formatCycles(receipt.cyclesMinted);
  el("receipt-block").textContent = receipt.mintBlockIndex === undefined
    ? "—"
    : receipt.mintBlockIndex.toString();
  el("receipt-sources").textContent =
    rateSourceNote(v.rateReceivedRates, v.rateQueriedSources) || "—";

  const check = checkReceipt(v, receipt.order.lockedCycles);
  el("receipt-formula").textContent = check.formula;
  const verdict = el("receipt-verdict");
  verdict.textContent = check.matches
    ? "✓ Recomputed from these inputs, the price matches the cycles this order locked."
    : "⚠ Recomputing from these inputs does not match the locked quantity — please contact support with the order id.";
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
    status.textContent = `Could not cancel: ${error instanceof Error ? error.message : String(error)}`;
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
    setCkFlowStatus("Could not reach the gateway — try again.", "err");
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
    setCkFlowStatus("Approved — claiming…");
    await claimCkOrder(orderId);
  } catch (error) {
    setCkFlowStatus(
      `Approval call failed: ${error instanceof Error ? error.message : String(error)}`,
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
      `Claim call failed: ${error instanceof Error ? error.message : String(error)}`,
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
  renderOrder(order);
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
    body.append(row);
  }
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

async function init(): Promise<void> {
  renderAuth();
  wireDestinationToggle();
  el<HTMLFormElement>("order-form").onsubmit = (e) => void onCreateOrder(e);
  el<HTMLInputElement>("ck-amount").oninput = () => scheduleCkQuote();
  el("rail-card").onclick = () => setRail("card");
  el("rail-ckusdc").onclick = () => setRail("ckUsdc");
  el("cancel-order").onclick = () => void onCancelOrder();
  el("ck-approve").onclick = () => void onCkApprove();
  el("ck-claim").onclick = () => void onCkClaim();

  const restored = await currentIdentity();
  if (restored) setIdentity(restored);

  try {
    await loadMarket();
  } catch (error) {
    el("rate-line").textContent = `Could not reach the gateway: ${
      error instanceof Error ? error.message : String(error)
    }`;
  }
}

void init();
