// The duplicate-cookie parser (issue: stale ic_env). A browser will not produce
// a duplicate partitioned cookie on demand, so the parser is the only part of
// the self-heal that can be pinned directly — which is exactly why it is a pure
// function taking a string rather than reading document.cookie itself.
import { describe, expect, test } from "vitest";
import {
  parseIcEnvCookies,
  distinctBackendIds,
  hasConflictingIcEnv,
  isCanisterNotFound,
  resolveLiveBackendId,
} from "./ic-env";

/// Cookies are percent-encoded with `_` as %5F, which encodeURIComponent leaves
/// alone — matching the real asset-canister and dev-server output.
function icEnv(backendId: string): string {
  const enc = (s: string) =>
    s.replace(/_/g, "%5F").replace(/:/g, "%3A").replace(/=/g, "%3D").replace(/&/g, "%26");
  return `ic_env=${enc("ic_root_key")}%3Dabc%26${enc("PUBLIC_CANISTER_ID:backend")}%3D${backendId}`;
}

describe("parsing", () => {
  test("decodes a single cookie into its entries", () => {
    const [cookie] = parseIcEnvCookies(icEnv("aaaaa-aa"));
    expect(cookie!.entries["PUBLIC_CANISTER_ID:backend"]).toBe("aaaaa-aa");
    expect(cookie!.entries.ic_root_key).toBe("abc");
  });

  test("finds BOTH copies when a stale one shadows the fresh one", () => {
    // The reported failure: document.cookie lists the stale partitioned copy
    // first, and safeGetCanisterEnv takes the first match — so the app calls a
    // canister that no longer exists and every query rejects IC0536.
    const both = `${icEnv("stale-id")}; ${icEnv("fresh-id")}`;
    expect(parseIcEnvCookies(both)).toHaveLength(2);
    expect(distinctBackendIds(parseIcEnvCookies(both))).toEqual(["stale-id", "fresh-id"]);
    expect(hasConflictingIcEnv(both)).toBe(true);
  });

  test("two copies that agree are not a conflict", () => {
    // Same id twice is harmless: whichever wins is correct. Reporting it would
    // send someone hunting for a problem they do not have.
    const same = `${icEnv("aaaaa-aa")}; ${icEnv("aaaaa-aa")}`;
    expect(hasConflictingIcEnv(same)).toBe(false);
  });

  test("ignores unrelated cookies and survives a malformed one", () => {
    const mixed = `theme=dark; ic_env=%ZZ; other=1; ${icEnv("aaaaa-aa")}`;
    const parsed = parseIcEnvCookies(mixed);
    // The malformed copy is still COUNTED: dropping it would understate the
    // duplicate count, which is the one number this module exists to get right.
    expect(parsed).toHaveLength(2);
    expect(distinctBackendIds(parsed)).toEqual(["aaaaa-aa"]);
  });

  test("no ic_env at all is the mainnet case, and reports nothing", () => {
    expect(parseIcEnvCookies("theme=dark")).toHaveLength(0);
    expect(hasConflictingIcEnv("theme=dark")).toBe(false);
  });
});

describe("recognising the failure", () => {
  test("IC0536 is the canister-not-found signature", () => {
    expect(isCanisterNotFound(new Error("Reject code 3: IC0536: Canister x not found"))).toBe(true);
    expect(isCanisterNotFound("Canister aaaaa-aa not found")).toBe(true);
  });

  test("an ordinary outage is not mistaken for a stale cookie", () => {
    // Telling someone to clear a cookie when the gateway is simply down sends
    // them down a path that cannot help.
    expect(isCanisterNotFound(new Error("fetch failed"))).toBe(false);
    expect(isCanisterNotFound(new Error("IC0503: trapped explicitly"))).toBe(false);
  });
});

describe("adopting the live backend", () => {
  test("picks the candidate that answers, not the first one listed", () => {
    const probe = async (id: string) => {
      if (id !== "fresh-id") throw new Error("IC0536");
      return {};
    };
    return expect(resolveLiveBackendId(["stale-id", "fresh-id"], probe)).resolves.toBe("fresh-id");
  });

  test("null when none answer, because then it is not a cookie problem", () => {
    const probe = async () => {
      throw new Error("fetch failed");
    };
    return expect(resolveLiveBackendId(["a", "b"], probe)).resolves.toBeNull();
  });
});
