// CyclePay frontend (M1, Card rail): II login, tier picker, order creation,
// Stripe Payment Link hand-off, live status polling, order history.
//
// The rail selector is the §11.1 seam in UI form: Card is live, ck-USDC is a
// disabled tab until M2 — adding it is a new panel, not a refactor.
import { Principal } from "@icp-sdk/core/principal";
import type { Identity } from "@icp-sdk/core/agent";
import {
  makeBackend,
  type Backend,
  type Destination,
  type Order,
  type Tier,
} from "./actor";
import { currentIdentity, signIn, signOut } from "./auth";
import {
  STEPS,
  createOrderErrorMessage,
  formatCycles,
  formatUsdCents,
  nsToMillis,
  parseSubaccountHex,
  paymentLinkWithRef,
  shortPrincipal,
  statusInfo,
  type StatusKey,
} from "./format";

const POLL_MS = 3_000;

// The bindgen wrapper surfaces OrderStatus as a string enum whose values are
// exactly the variant labels format.ts keys on.
function statusKeyOf(order: Order): StatusKey {
  return order.status as unknown as StatusKey;
}

// --- state ---------------------------------------------------------------

let identity: Identity | null = null;
let backend: Backend = makeBackend();
let tiers: Tier[] = [];
let selectedTierId: string | null = null;
let lowFloat = false;
// Payment links keyed by order id — known only for orders created this
// session (the backend stores no link; the tier carries it).
const payLinks = new Map<string, string>();
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
  const [tierList, treasury, forex] = await Promise.all([
    backend.card_tiers(),
    backend.treasury_status(),
    backend.forex_status(),
  ]);
  tiers = tierList;
  lowFloat = treasury.lowFloat;

  const rateLine = el("rate-line");
  if (forex.rate) {
    const xdrPerUsd = (Number(forex.rate.xdrPerUsdMicros) / 1e6).toFixed(3);
    rateLine.textContent = `Rate: ${xdrPerUsd} XDR/USD · fee ${Number(forex.config.feeBps) / 100}% + ${formatUsdCents(forex.config.feeFixedCents)} · cycles are locked at order creation`;
  } else {
    rateLine.textContent = "No exchange rate cached yet — order creation will fetch one.";
  }

  const gate = el("gate-notice");
  if (lowFloat) {
    gate.textContent =
      "Operator float is low — new orders may queue until it is refilled. Paid orders always deliver at their locked quantity.";
  }
  show("gate-notice", lowFloat);

  renderTiers();
  renderSubmitGate();
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
  for (const tier of tiers) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "tier" + (tier.id === selectedTierId ? " selected" : "");
    const amount = document.createElement("span");
    amount.className = "amount";
    amount.textContent = formatUsdCents(tier.usdCents);
    const label = document.createElement("span");
    label.className = "cycles";
    label.textContent = tier.id;
    btn.append(amount, label);
    btn.onclick = () => {
      selectedTierId = tier.id;
      renderTiers();
      renderSubmitGate();
    };
    container.append(btn);
  }
}

function renderSubmitGate(): void {
  const btn = el<HTMLButtonElement>("create-order");
  if (!identity) {
    btn.disabled = true;
    btn.textContent = "Sign in to continue";
  } else if (selectedTierId === null) {
    btn.disabled = true;
    btn.textContent = "Pick an amount";
  } else {
    btn.disabled = false;
    btn.textContent = "Create order";
  }
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
  if (!identity || selectedTierId === null) return;
  const tier = tiers.find((t) => t.id === selectedTierId);
  if (!tier) {
    showFormError("Selected tier vanished — reload the page.");
    return;
  }
  const dest = readDestination();
  if (!dest.ok) {
    showFormError(dest.error);
    return;
  }

  const btn = el<HTMLButtonElement>("create-order");
  btn.disabled = true;
  btn.textContent = "Creating order…";
  try {
    const result = await backend.create_order(tier.id, dest.value);
    if (result.__kind__ === "err") {
      showFormError(createOrderErrorMessage(result.err.__kind__));
      return;
    }
    const created = result.ok;
    payLinks.set(created.order.id, paymentLinkWithRef(tier.paymentLinkUrl, created.clientReferenceId));
    openOrder(created.order, created.clientReferenceId);
    void refreshHistory();
  } catch (error) {
    showFormError(`Call failed: ${error instanceof Error ? error.message : String(error)}`);
  } finally {
    renderSubmitGate();
  }
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
  el("order-cycles").textContent = formatCycles(order.lockedCycles);
  el("order-price").textContent = formatUsdCents(order.pricing.usdCents);
  el("order-dest").textContent = describeDestination(order);

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

  const link = payLinks.get(order.id);
  const awaitingPayment = key === "created" || key === "expired";
  show("pay-area", awaitingPayment && link !== undefined);
  if (link !== undefined) {
    el<HTMLAnchorElement>("pay-link").href = link;
  }
  if (clientReferenceId !== undefined) {
    el("client-ref").textContent = clientReferenceId;
  }

  show("active-order", true);
}

function stopPolling(): void {
  if (pollTimer !== null) clearInterval(pollTimer);
  pollTimer = null;
  pollOrderId = null;
  lastPolledStatus = null;
}

function openOrder(order: Order, clientReferenceId?: string): void {
  stopPolling();
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
      formatCycles(order.lockedCycles),
      formatUsdCents(order.pricing.usdCents),
      info.label,
    ];
    cells.forEach((text, index) => {
      const td = document.createElement("td");
      td.textContent = text;
      if (index === 4) td.className = `tone-${info.tone}`;
      row.append(td);
    });
    row.onclick = () => openOrder(order);
    body.append(row);
  }
}

// --- wiring ----------------------------------------------------------------

function wireDestinationToggle(): void {
  for (const radio of document.querySelectorAll<HTMLInputElement>('input[name="dest-kind"]')) {
    radio.onchange = () => {
      show("dest-canister", radio.value === "canister" ? radio.checked : !radio.checked);
      show("dest-ledger", radio.value === "cyclesLedgerAccount" ? radio.checked : !radio.checked);
    };
  }
}

async function init(): Promise<void> {
  renderAuth();
  wireDestinationToggle();
  el<HTMLFormElement>("order-form").onsubmit = (e) => void onCreateOrder(e);

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
