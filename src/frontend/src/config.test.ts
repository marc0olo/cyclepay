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
  test("⚠️ from a custom domain it is the CANISTER's origin, not the serving domain", () => {
    // The whole point: one string for every domain this app is ever served from, so a
    // domain change does not hand every buyer a new principal.
    expect(derivationOrigin("cyclepay.raymondk.co", FRONTEND)).toBe(`https://${FRONTEND}.icp.net`);
    expect(derivationOrigin("some.future.domain", FRONTEND))
      .toBe(derivationOrigin("cyclepay.raymondk.co", FRONTEND));
  });

  test("⚠️ the PRIMARY origin passes nothing, at any of the three gateway spellings", () => {
    // Per the Internet Identity guidance: only the alternative origin sets a derivation
    // origin, and II canonicalises `ic0.app` / `icp0.io` / `icp.net` to one form during
    // delegation -- so passing a gateway origin is the case that BREAKS authentication
    // rather than a harmless no-op. Which also means the icp0.io -> icp.net switch is a
    // readability choice, not two identities.
    for (const gateway of ["icp.net", "icp0.io", "ic0.app"]) {
      expect(derivationOrigin(`${FRONTEND}.${gateway}`, FRONTEND), gateway).toBeUndefined();
    }
    // A DIFFERENT canister on a gateway domain is not this page's primary origin.
    expect(derivationOrigin("aaaaa-aa.icp.net", FRONTEND)).toBe(`https://${FRONTEND}.icp.net`);
  });

  test("undefined locally, where II is served from the page's own origin", () => {
    expect(derivationOrigin("frontend.local.localhost", FRONTEND)).toBeUndefined();
  });

  test("⚠️ with no frontend id it THROWS rather than deriving from the domain", () => {
    // Fail closed. Returning undefined would let II derive from the serving domain: a
    // working app, a silently different principal, and the one outcome that cannot be
    // undone once a buyer holds cycles on it.
    //
    // ⚠️ This reads the DEFAULT argument, and passing `undefined` explicitly is the same
    // call -- a JS default parameter fires on `undefined`. Under jsdom that default
    // resolves to nothing, which is exactly the state being asserted.
    expect(() => derivationOrigin("cyclepay.raymondk.co")).toThrow(/PUBLIC_CANISTER_ID:frontend/);
    // Local is decided BEFORE the id is needed, so a local run never throws.
    expect(() => derivationOrigin("frontend.local.localhost")).not.toThrow();
  });
});

describe("canonicalAppDomain", () => {
  test("⚠️ with no frontend id it throws here too, rather than printing the wrong origin", () => {
    // The printed `--app` selects which origin's principal the CLI asks for. Falling back
    // to the serving domain would hand the buyer a delegation for a principal the page is
    // not showing them -- the failure this function exists to prevent. Propagating the
    // refusal is the only answer that cannot be acted on wrongly.
    expect(() => canonicalAppDomain({ host: "cyclepay.raymondk.co", hostname: "cyclepay.raymondk.co" }))
      .toThrow(/PUBLIC_CANISTER_ID:frontend/);
  });

  test("⚠️ `--app` follows the DERIVATION origin, not the page", () => {
    // Printing the serving domain would hand the buyer a delegation for a different
    // principal than the page shows them, with an empty balance -- the exact failure
    // the printed command exists to prevent.
    expect(canonicalAppDomain({ host: "cyclepay.raymondk.co", hostname: "cyclepay.raymondk.co" }, FRONTEND))
      .toBe(`${FRONTEND}.icp.net`);
  });

  test("at the canister's own origin it is that host, since nothing is pinned there", () => {
    expect(canonicalAppDomain({ host: `${FRONTEND}.icp.net`, hostname: `${FRONTEND}.icp.net` }, FRONTEND))
      .toBe(`${FRONTEND}.icp.net`);
  });

  test("locally it is the page's host, port included", () => {
    // A port is part of the identity of a local origin.
    expect(canonicalAppDomain({ host: "frontend.local.localhost:8000", hostname: "frontend.local.localhost" }, FRONTEND))
      .toBe("frontend.local.localhost:8000");
  });
});
