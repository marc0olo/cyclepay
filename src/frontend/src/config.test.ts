import { describe, expect, test } from "vitest";
import { canonicalAppDomain, derivationOrigin, isLocalNetwork } from "./config";

/// The origin logic, which decides **who a buyer is**.
///
/// ⚠️ Internet Identity derives a principal per origin, so every function here feeds the
/// identity of the account we credit. The mainnet branch is the one that matters and the
/// one jsdom does not reach on its own: `window.location.hostname` is `localhost` under
/// vitest, so a test that did not pass a hostname would assert the LOCAL branch twice and
/// report the mainnet behaviour as covered.
/// ⚠️ **Passed in, not seeded through a cookie.** `safeGetCanisterEnv` reads nothing under
/// jsdom -- probed, both the plain and the `%5F`-encoded on-wire shapes return
/// `undefined` -- so a test that set `document.cookie` would exercise the
/// `frontendId === undefined` branch and report the mainnet path as covered. The cookie
/// path is load-bearing for the backend id too, so the whole app fails visibly if it
/// breaks; what needs asserting here is the branch and the string.
const FRONTEND = "4caro-hl777-77775-aaaba-cai";

describe("isLocalNetwork", () => {
  test("every shape a local network is served under", () => {
    for (const h of ["localhost", "127.0.0.1", "[::1]", "frontend.local.localhost"]) {
      expect(isLocalNetwork(h), h).toBe(true);
    }
  });

  test("⚠️ and nothing that merely contains one", () => {
    // `localhost.evil.com` is the trap the backend's own origin parser documents; the
    // same substring mistake here would put a production page on the local branch.
    for (const h of ["cyclepay.raymondk.co", "localhost.evil.com", "notlocalhost", `${FRONTEND}.icp.net`]) {
      expect(isLocalNetwork(h), h).toBe(false);
    }
  });
});

describe("derivationOrigin", () => {
  test("⚠️ on mainnet it is the CANISTER's origin, not the domain serving the page", () => {
    // The whole point: the same string for every domain this app is ever served from,
    // so a domain change does not hand every buyer a new principal.
    expect(derivationOrigin("cyclepay.raymondk.co", FRONTEND)).toBe(`https://${FRONTEND}.icp.net`);
    expect(derivationOrigin(`${FRONTEND}.icp.net`, FRONTEND)).toBe(`https://${FRONTEND}.icp.net`);
    expect(derivationOrigin("some.future.domain", FRONTEND))
      .toBe(derivationOrigin("cyclepay.raymondk.co", FRONTEND));
  });

  test("undefined locally, where II is served from the page's own origin", () => {
    expect(derivationOrigin("frontend.local.localhost", FRONTEND)).toBeUndefined();
  });
});

describe("canonicalAppDomain", () => {
  test("⚠️ with no frontend id there is no derivation origin, so nothing is silently wrong", () => {
    // A deployment whose `ic_env` lacks the frontend key must fall back to the page's own
    // origin rather than build `https://undefined.icp.net`, which would derive a
    // principal nobody could ever reach again.
    //
    // ⚠️ This reads the DEFAULT argument on purpose, and passing `undefined` explicitly
    // would be the same call: a JS default parameter fires on `undefined`. Under jsdom
    // that default resolves to nothing, which is exactly the state being asserted.
    expect(derivationOrigin("cyclepay.raymondk.co")).toBeUndefined();
    expect(canonicalAppDomain({ host: "cyclepay.raymondk.co", hostname: "cyclepay.raymondk.co" }))
      .toBe("cyclepay.raymondk.co");
  });

  test("⚠️ `--app` follows the DERIVATION origin, not the page", () => {
    // Printing the serving domain would hand the buyer a delegation for a different
    // principal than the page shows them, with an empty balance -- the exact failure
    // the printed command exists to prevent.
    expect(canonicalAppDomain({ host: "cyclepay.raymondk.co", hostname: "cyclepay.raymondk.co" }, FRONTEND))
      .toBe(`${FRONTEND}.icp.net`);
  });

  test("locally it is the page's host, port included", () => {
    // A port is part of the identity of a local origin.
    expect(canonicalAppDomain({ host: "frontend.local.localhost:8000", hostname: "frontend.local.localhost" }, FRONTEND))
      .toBe("frontend.local.localhost:8000");
  });
});
