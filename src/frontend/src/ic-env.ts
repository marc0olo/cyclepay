/// Detect and recover from a **stale `ic_env` cookie**, a real failure diagnosed
/// against a running local network.
///
/// The shape of the bug: two `ic_env` cookies for one origin, advertising
/// different backend canister ids. `document.cookie` lists the stale copy first
/// and `safeGetCanisterEnv` takes the first match, so the app builds its actor
/// against a canister that no longer exists and every call rejects with
/// **IC0536** (canister not found). Nothing in the UI explains it, the page looks
/// broken, and clearing site data is not something a visitor will guess.
///
/// They coexist rather than replacing each other because a partitioned and an
/// unpartitioned cookie live in separate jars (see the measured attributes
/// below), so a copy written under one configuration survives alongside a fresh
/// one written under another.
///
/// Two things make this worth code rather than a note in a README:
///   - it presents as "the gateway is down" when the gateway is fine, and
///   - `cookieStore.delete` silently does nothing on a partitioned cookie unless
///     `partitioned: true` is passed, so the obvious cleanup does not work.
///
/// What is **measured**, what is **reported**, and what is **inferred** — kept
/// apart on purpose, because an earlier version of this comment stated a guess as
/// fact and got the mainnet/local behaviour backwards.
///
/// MEASURED — `Set-Cookie` attributes, read from live responses and source:
///
///   mainnet asset canister:  Partitioned; SameSite=None; Secure; Max-Age=31536000; Path=<certified>
///   local gateway:                        SameSite=Lax;  secure; Max-Age=31536000; Path=<certified>
///   vite dev server:                      SameSite=Lax                (no Path, no Max-Age)
///
/// So the **partitioned** variant is the MAINNET one, and production serves
/// `ic_env` exactly as local does. An earlier comment claimed the opposite of
/// both.
///
/// MEASURED — the resolver takes the first match, in
/// `@icp-sdk/core/src/agent/canister-env`:
///
///   document.cookie.split(';').find(c => c.trim().startsWith('ic_env='))
///
/// With several cookies present, which one wins is cookie ordering, not anything
/// this app controls.
///
/// REPORTED — a stale cookie shadowing a fresh one, producing IC0536 on every
/// call. Diagnosed against a running local network, but **not reproduced here**,
/// so the exact provenance of the duplicate is not established.
///
/// INFERRED, and untested — how two copies come to coexist. A cookie is keyed on
/// (name, domain, **path**) and the three writers above disagree on `Path`;
/// partitioning adds a separate jar; cookies ignore the port, so a dev server on
/// `localhost:5173` and a gateway on `localhost:8000` share one jar; and a
/// one-year `Max-Age` lets a stale copy outlive any development cycle. Each is
/// plausible and none has been demonstrated to be the cause.
///
/// The guard does not depend on any of that being right: it no-ops unless two
/// cookies advertise *different* backend ids, which is correct everywhere. The
/// real fix belongs upstream — see dfinity/icp-js-core (resolver) and
/// dfinity/icp-cli#702 (cookie lifetime).

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

/// Does this error look like "the canister id I called does not exist"?
///
/// IC0536 is the replica's canister-not-found code. Matched on the code rather
/// than message prose, which is not a stable interface.
export function isCanisterNotFound(error: unknown): boolean {
  const text = error instanceof Error ? error.message : String(error);
  return /IC0536/.test(text) || /[Cc]anister .* not found/.test(text);
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
