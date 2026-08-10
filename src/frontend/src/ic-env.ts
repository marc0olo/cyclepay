/// Detect and recover from a **stale `ic_env` cookie**, a real failure diagnosed
/// against a running local network.
///
/// The shape of the bug: two `ic_env` cookies for one origin, advertising
/// different backend canister ids. `document.cookie` lists the stale copy first
/// and `safeGetCanisterEnv` takes the first match, so the app builds its actor
/// against a canister that no longer exists and every call fails. Nothing in the
/// UI explains it, the page looks broken, and clearing site data is not something
/// a visitor will guess.
///
/// Two things make this worth code rather than a note in a README:
///   - it presents as "the gateway is down" when the gateway is fine, and
///   - `cookieStore.delete` silently does nothing on a partitioned cookie unless
///     `partitioned: true` is passed, so the obvious cleanup does not work.
///
/// What is **measured**, what is **reported**, and what is **inferred** are kept
/// apart below, each with its source. Three successive versions of this comment
/// stated a guess as fact — including the error code this module keys on, which
/// was wrong for four rounds.
///
/// ── MEASURED ────────────────────────────────────────────────────────────────
///
/// **What a missing canister actually returns.** Probed against a local network
/// (icp-cli 1.2.0, network launcher v15.0.0-2026-07-17-04-19) on 2026-08-10, with
/// `@icp-sdk/core` 5.3, calling a well-formed but unallocated canister id
/// (`e5xzy-miaaa-aaaah-7777q-cai`):
///
///   class:  ProtocolError            (NOT a RejectError, and no reject code)
///   status: HTTP 400 Bad Request
///   body:   error: canister_not_found
///           details: The specified canister does not exist.
///
/// Identical for a query and for an update. **`IC0536` appears nowhere in it.**
///
/// **What IC0536 actually is.** Same probe, calling a method that does not exist
/// on a canister that does:
///
///   class:          RejectError, reject code 5
///   rejectErrorCode: IC0536
///   message:        Canister has no update method 'no_such_method_here'.
///                   …/references/execution-errors#method-not-found
///
/// So the previous `/IC0536/` test matched **method-not-found** and could never
/// match the condition this module exists for. The fallback `/[Cc]anister .* not
/// found/` missed it too: the real body says `canister_not_found` with an
/// underscore, and then "does not exist".
///
/// **`Set-Cookie` from the local gateway.** Complete response header, read on
/// 2026-08-10 from `http://frontend.local.localhost:8000/`:
///
///   set-cookie: ic_env=…; SameSite=Lax
///
/// That is the whole header: no `Path`, no `Max-Age`, no `Secure`, no
/// `Partitioned`. A previous table here claimed `secure; Max-Age=31536000;
/// Path=<certified>` for this row, and none of it was there.
///
/// **Who writes it.** The same response certifies `Set-Cookie`
/// (`ic-certificateexpression` lists it among the certified response headers) and
/// carries `x-ic-canister-id: <frontend>`, so the **asset canister** emits this
/// cookie, not the gateway.
///
/// **The vite dev server's copy**, from this repo: `vite.config.ts`
/// `getDevServerConfig()` sets `ic_env=…; SameSite=Lax;` and nothing else.
///
/// **The resolver takes the first match**, in
/// `@icp-sdk/core/src/agent/canister-env`:
///
///   document.cookie.split(';').find(c => c.trim().startsWith('ic_env='))
///
/// With several cookies present, which one wins is cookie ordering, not anything
/// this app controls.
///
/// ── REPORTED, not measured here ─────────────────────────────────────────────
///
/// **The mainnet header**: `ic_env=…; Secure; SameSite=None; Partitioned` — one
/// header, no `Max-Age` and no `Path`. Source: the retraction on
/// **dfinity/icp-js-core#1384**, which corrected an earlier table built by
/// grepping a whole response instead of the `Set-Cookie` line.
///
/// Not measurable from this repo yet, and that is itself measured: `nns.ic0.app`,
/// `identity.internetcomputer.org` and `oc.app` return **no `Set-Cookie` at all**
/// (checked 2026-08-10). `ic_env` comes from the icp-cli asset-canister recipe, so
/// seeing it on mainnet needs a canister deployed that way, and this project has
/// not deployed one.
///
/// **A stale cookie shadowing a fresh one.** Diagnosed against a running local
/// network but **not reproduced here**, so the provenance of the duplicate is not
/// established.
///
/// ── INFERRED, untested ──────────────────────────────────────────────────────
///
/// How two copies come to coexist. A cookie is keyed on (name, domain, path), and
/// a partitioned cookie lives in a separate jar from an unpartitioned one, so a
/// copy written under one configuration can survive beside a fresh one written
/// under another. Cookies ignore the port, so a dev server on `localhost:5173` and
/// a gateway on `localhost:8000` share a jar. Whether the recipe adds `Secure` and
/// `Partitioned` conditionally on https — which is what would make the mainnet and
/// local headers differ at all, given the same canister code emits both — is
/// likewise not established here.
///
/// The guard does not depend on any of that being right: it no-ops unless two
/// cookies advertise *different* backend ids, which is correct everywhere. The
/// real fix belongs upstream, tracked on **dfinity/icp-js-core#1384**: the
/// resolver is in `@icp-sdk/core`.

/// One `ic_env` cookie's decoded key/value pairs, with the raw value kept so a
/// caller can tell two copies apart.
export type IcEnvCookie = {
  raw: string;
  entries: Record<string, string>;
};

/// Every `ic_env` cookie in a `document.cookie` string, in the order the browser
/// reports them (which is the order `safeGetCanisterEnv` resolves).
///
/// Pure and exported for tests: the browser will not produce a duplicate on
/// demand, so the parser is the only part of this that can be pinned directly.
export function parseIcEnvCookies(cookieString: string): IcEnvCookie[] {
  const out: IcEnvCookie[] = [];
  for (const part of cookieString.split(";")) {
    const trimmed = part.trim();
    if (!trimmed.startsWith("ic_env=")) continue;
    const raw = trimmed.slice("ic_env=".length);
    const entries: Record<string, string> = {};
    // The value is percent-encoded twice over: `&` and `=` separators are encoded
    // as %26 and %3D, and so is `_` (%5F). Decode the whole thing once, then split.
    let decoded: string;
    try {
      decoded = decodeURIComponent(raw);
    } catch {
      // A malformed cookie is exactly the kind of thing this module exists for.
      // Record it as present-but-unreadable rather than dropping it, so the
      // duplicate count stays honest.
      out.push({ raw, entries });
      continue;
    }
    for (const pair of decoded.split("&")) {
      const eq = pair.indexOf("=");
      if (eq === -1) continue;
      entries[pair.slice(0, eq)] = pair.slice(eq + 1);
    }
    out.push({ raw, entries });
  }
  return out;
}

/// The distinct backend canister ids advertised across all `ic_env` cookies.
///
/// More than one means the browser is holding a stale copy, and which one wins is
/// down to cookie ordering rather than anything the app controls.
export function distinctBackendIds(cookies: IcEnvCookie[]): string[] {
  const ids = new Set<string>();
  for (const cookie of cookies) {
    const id = cookie.entries["PUBLIC_CANISTER_ID:backend"];
    if (id) ids.add(id);
  }
  return [...ids];
}

/// Is the browser holding conflicting `ic_env` cookies right now?
export function hasConflictingIcEnv(cookieString: string): boolean {
  return distinctBackendIds(parseIcEnvCookies(cookieString)).length > 1;
}

/// Does this error say "the canister id I called does not exist"?
///
/// Keyed on `canister_not_found`, which is the machine-readable identifier the
/// gateway puts in the 400 response body — see the MEASURED section at the top of
/// this file for the probe it came from. Not on the prose beside it, and not on a
/// reject code, because this failure carries none.
///
/// It used to test for `IC0536`. That code is **method-not-found**, so the test
/// matched a completely different failure and never matched this one. The
/// stale-cookie self-heal's trigger was therefore unexercised for four rounds of
/// review while the comment above it asserted the opposite.
export function isCanisterNotFound(error: unknown): boolean {
  return /canister_not_found/.test(errorText(error));
}

/// Does this error mean "the id I called is not this app's backend"?
///
/// One root cause, two measured wire formats, because a stale `ic_env` can name
/// either kind of id:
///
///   - an id that no longer exists → `canister_not_found`, above
///   - an id that exists but is a **different canister** → IC0536, method-not-found
///
/// The second is the case actually reported: the stale cookie's `backend` entry
/// held the **frontend** canister's id. That canister exists and answers; it simply
/// has no `card_tiers`. So a self-heal keyed on absence alone would miss the very
/// failure it was written for — which is the trap on the other side of the IC0536
/// correction, and why both signatures are named here rather than one replacing
/// the other.
///
/// **Only meaningful behind a conflicting-cookie check.** On its own, IC0536 means
/// this app called a method its backend does not export — our bug, typically stale
/// bindings after an interface change — and telling that visitor to clear a cookie
/// sends them after something that is not there. `main.ts` gates it on
/// `hasConflictingIcEnv` for exactly that reason.
export function isWrongBackendId(error: unknown): boolean {
  return isCanisterNotFound(error) || /IC0536/.test(errorText(error));
}

/// Everything an agent error can carry the identifier in.
///
/// `message` already embeds the response body for a `ProtocolError`, but the body
/// is also on `error.code.bodyText`, and reading both costs nothing and survives a
/// change to how the SDK formats its messages.
function errorText(error: unknown): string {
  const parts = [error instanceof Error ? error.message : String(error)];
  const body = (error as { code?: { bodyText?: unknown } } | null)?.code?.bodyText;
  if (typeof body === "string") parts.push(body);
  return parts.join("\n");
}

/// Delete every `ic_env` cookie this document can reach.
///
/// `partitioned: true` is **mandatory** and is the whole reason this is not a
/// one-liner: a partitioned cookie lives in a separate jar, and a delete without
/// the flag reports success while removing nothing. Both variants are attempted
/// because the stale and fresh copies need not agree on partitioning.
///
/// Returns false when the browser has no `cookieStore` (Safari, Firefox at time
/// of writing), where the caller has to fall back to telling the user.
export async function clearIcEnvCookies(): Promise<boolean> {
  const store = (globalThis as { cookieStore?: CookieStoreLike }).cookieStore;
  if (!store) return false;
  const paths = ["/", window.location.pathname];
  for (const path of new Set(paths)) {
    for (const partitioned of [true, false]) {
      try {
        await store.delete({ name: "ic_env", path, partitioned });
      } catch {
        // A delete for a variant that does not exist is not an error worth
        // surfacing; the caller verifies by re-reading document.cookie.
      }
    }
  }
  return true;
}

type CookieStoreLike = {
  delete(options: { name: string; path?: string; partitioned?: boolean }): Promise<void>;
};

/// Pick the backend id that actually answers.
///
/// `probe` is injected rather than imported so this stays testable and so the
/// caller owns actor construction. The first candidate that resolves wins; if
/// none do, null means "this is not a stale-cookie problem".
///
/// **Order is the caller's decision, and it matters.** When exactly one candidate
/// answers, order is irrelevant. When more than one does, this returns whichever
/// comes first, and nothing in a cookie says which copy is fresher — so the caller
/// has to choose deliberately and say why (see `resolveStaleIcEnv` in main.ts).
export async function resolveLiveBackendId(
  candidates: string[],
  probe: (canisterId: string) => Promise<unknown>,
): Promise<string | null> {
  for (const candidate of candidates) {
    try {
      await probe(candidate);
      return candidate;
    } catch {
      // Expected for the stale id. Keep going.
    }
  }
  return null;
}
