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
  isWrongBackendId,
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
    // canister that no longer exists and the gateway answers 400
    // canister_not_found to every request.
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
  /// The real message, copied verbatim from a probe against a local network
  /// (2026-08-10, icp-cli 1.2.0, @icp-sdk/core 5.3) calling a well-formed but
  /// unallocated canister id. See the MEASURED section in ic-env.ts.
  const CANISTER_NOT_FOUND =
    "HTTP request failed:\n  Status: 400 (Bad Request)\n" +
    '  Headers: [["content-type","text/plain; charset=utf-8"]]\n' +
    "  Body: error: canister_not_found\ndetails: The specified canister does not exist.";

  /// Same probe, calling a method that does not exist on a canister that does.
  /// This is what IC0536 actually means, and what the previous implementation
  /// matched instead of the case above.
  const METHOD_NOT_FOUND =
    "The replica returned a rejection error:\n  Reject code: 5\n" +
    "  Reject text: Error from Canister 4fbx2-kt777-77775-aaabq-cai: " +
    "Canister has no update method 'no_such_method_here'..\n" +
    "Check that the method being called is exported by the target canister. " +
    "See documentation: " +
    "https://docs.internetcomputer.org/references/execution-errors#method-not-found\n" +
    "  Error code: IC0536";

  test("the 400 body's canister_not_found is the signature", () => {
    expect(isCanisterNotFound(new Error(CANISTER_NOT_FOUND))).toBe(true);
    // And when the SDK stops embedding the body in `message`, the structured
    // field still carries it.
    const structured = Object.assign(new Error("HTTP request failed"), {
      code: { bodyText: "error: canister_not_found\ndetails: The specified canister does not exist." },
    });
    expect(isCanisterNotFound(structured)).toBe(true);
  });

  test("IC0536 is METHOD-not-found, and is not canister-not-found", () => {
    // The defect this pins. Keying the matcher on IC0536 matched this error — a
    // bug in the caller's own code — while the condition the self-heal exists for
    // went unrecognised.
    expect(isCanisterNotFound(new Error(METHOD_NOT_FOUND))).toBe(false);
  });

  test("BOTH signatures mean the id is not our backend", () => {
    // The trap on the far side of that correction. A stale `ic_env` can name an id
    // that no longer exists (→ canister_not_found) or one that exists and is a
    // different canister (→ IC0536). The reported failure was the SECOND: the
    // cookie's backend entry held the frontend canister's id, which answers
    // everything except the methods this app calls. A self-heal keyed on absence
    // alone would miss it.
    expect(isWrongBackendId(new Error(CANISTER_NOT_FOUND))).toBe(true);
    expect(isWrongBackendId(new Error(METHOD_NOT_FOUND))).toBe(true);
  });

  test("neither an outage nor an unrelated trap is a wrong backend id", () => {
    // The gate in main.ts pairs this with `hasConflictingIcEnv`, because IC0536
    // with one correct cookie is our own stale bindings and no cookie will fix it.
    expect(isWrongBackendId(new Error("fetch failed"))).toBe(false);
    expect(isWrongBackendId(new Error("IC0503: trapped explicitly"))).toBe(false);
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
      if (id !== "fresh-id") throw new Error("Body: error: canister_not_found");
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
