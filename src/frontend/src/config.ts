/// Deployment-wide constants that must exist in exactly one place.
import { safeGetCanisterEnv } from "@icp-sdk/core/agent/canister-env";

/// Is this page being served by a local `icp network`?
///
/// The same guard `auth.ts` uses to pick the local Internet Identity, and for the same
/// reason: a production origin can never take the local branch.
export function isLocalNetwork(hostname: string = window.location.hostname): boolean {
  return (
    hostname === "localhost"
    || hostname === "127.0.0.1"
    || hostname === "[::1]"
    || hostname.endsWith(".localhost")
  );
}

/// The origin Internet Identity derives this app's principals from.
///
/// ⚠️ **II derives a principal PER ORIGIN, so this string decides who a buyer is.**
/// Served from a custom domain with no derivation origin, the same person signing in at
/// `cyclepay.raymondk.co` and at the canister URL gets two different principals, two
/// cycles balances, and an allow-list entry that works on one and not the other.
///
/// ⚠️ **Pinned to the FRONTEND CANISTER's own origin, never to the domain the page came
/// from — and that is what makes the domain reversible.** #40 records the origin as
/// irreversible after the first purchase, which is true of a domain used as the
/// derivation origin. Deriving from the canister id instead means this test domain and
/// whatever production domain #40 settles on both yield the SAME principals, so the
/// decision stops being one-way. The canister id is the one identifier a domain change
/// cannot alter.
///
/// The cost is a second file: II fetches `/.well-known/ii-alternative-origins` from THIS
/// origin and refuses to derive for any serving origin the file does not list. Both files
/// live in `src/frontend/public/.well-known/`, so the canister serves them at the
/// derivation origin and at the custom domain alike.
///
/// ⚠️ **`icp.net`, and the choice is as irreversible as the domain question it defers.**
/// `icp0.io` serves the same canister and would derive DIFFERENT principals, so this is
/// not a cosmetic preference: the two spellings are two identities. `icp.net` is the
/// current canonical host for a canister, which is the property that matters for a string
/// that has to keep resolving for as long as the accounts derived from it exist. Change it
/// only before the first sign-in; afterwards it strands every principal.
///
/// `undefined` locally: II is served from the same origin there, and passing a
/// derivation origin it cannot verify would break sign-in for every local run.
export function derivationOrigin(
  hostname: string = window.location.hostname,
  frontendId: string | undefined = frontendCanisterId(),
): string | undefined {
  if (isLocalNetwork(hostname)) return undefined;
  return frontendId === undefined ? undefined : `https://${frontendId}.icp.net`;
}

/// The frontend canister's own id, from the `ic_env` cookie the canister sets.
///
/// Read rather than compiled in, for the reason `actor.ts` reads the backend id the same
/// way: a build that hardcoded it would be wrong on any other deployment of this repo.
///
/// ⚠️ **Measured, not assumed: the deployed canister really does publish this key.**
/// `Set-Cookie` from a live `@dfinity/static-site` canister carries
/// `PUBLIC_CANISTER_ID:frontend` beside the backend id and the root key. Injectable
/// above because `safeGetCanisterEnv` reads nothing under jsdom, so a unit test asserting
/// the mainnet branch through it would assert `undefined` and pass for the wrong reason.
function frontendCanisterId(): string | undefined {
  return safeGetCanisterEnv()?.["PUBLIC_CANISTER_ID:frontend"];
}

/// The value `icp identity link web --app` expects: a **bare domain**, no scheme.
///
/// Verified against icp-cli 1.2.0 rather than assumed —
/// `icp identity link web --help` describes `--app <APP>` as the "Delegation
/// domain to get an identity for (e.g. oisy.com)", and the guide's example is
/// `--app nns.ic0.app`. An earlier version of this file passed
/// `window.location.origin`, i.e. `https://host`, which is not the documented
/// form; the whole point of printing this command is that the buyer ends up on
/// the principal their cycles are in, so the wrong shape here is the exact
/// failure the command exists to prevent.
///
/// ⚠️ **It is the DERIVATION origin's host, not the page's.** `--app` selects which
/// origin's principal the CLI asks for, so with a derivation origin pinned, printing
/// `window.location.host` would hand the buyer a delegation for the serving domain —
/// a different principal from the one the page is showing them, with an empty balance.
/// That is precisely the failure this function was written to prevent, one level up: it
/// used to be `window.location.origin` (wrong shape), then `window.location.host` (right
/// shape, right origin only while there was no derivation origin), and now follows
/// whatever the principals are actually derived from.
///
/// `host`, not `hostname`: a port is part of the identity of a local origin.
export function canonicalAppDomain(
  page: { host: string; hostname: string } = window.location,
  frontendId: string | undefined = frontendCanisterId(),
): string {
  const derived = derivationOrigin(page.hostname, frontendId);
  return derived === undefined ? page.host : new URL(derived).host;
}

/// The identity name the CLI stores this site's delegation under.
///
/// Named after the app rather than `dev`, which is what this used to be: `dev` is
/// what everyone's throwaway local identity is already called, so the command
/// silently proposed overwriting it. A per-app name also makes it obvious which
/// site a stored identity came from once someone has linked two.
export const CLI_IDENTITY = "cyclepay-id";

/// ⚠️ **These five commands are an ORDERED sequence, and the order is load-bearing.**
/// Five commands in four numbered steps — step 3 verifies twice, the principal and the
/// balance — which is why the page's summary counts steps and this list counts
/// functions. Counting the same things differently is how it came to say four of both.
/// `identityDefaultCommand` is what makes `icp identity principal`, `icp cycles
/// balance` and `icp deploy` act as the linked identity. Without it a buyer links
/// successfully, verifies with an explicit `--identity` flag, sees a match, and then
/// deploys as whatever their default was — a different principal with an empty
/// balance. That step was missing from the page entirely, which is why the verify
/// commands below carry no `--identity` flag: they are correct only *after* step 2,
/// and printing them with the flag hid the fact that step 2 was needed at all.

/// 1. Link the browser identity to the CLI.
///
/// Always with the explicit `--app`. Omitted, icp-cli lets the auth domain pick
/// its default (`cli.id.ai` for id.ai), which is a different principal and an
/// empty balance.
export function linkIdentityCommand(profile = CLI_IDENTITY): string {
  return `icp identity link web ${profile} --app ${canonicalAppDomain()}`;
}

/// 2. Make it the identity every later command acts as.
export function identityDefaultCommand(profile = CLI_IDENTITY): string {
  return `icp identity default ${profile}`;
}

/// 3a. The principal, which must equal the one this page shows.
///
/// No `--identity` flag: step 2 already made it the default, and the page's own value
/// is the thing to compare against. Deliberately NOT phrased as "the link command
/// prints the principal" — the CLI guide does not say it does, and inventing output is
/// how a tour teaches someone to expect something that never appears.
export function verifyPrincipalCommand(): string {
  return "icp identity principal";
}

/// 3b. The balance, which must equal the one this page shows.
export function verifyBalanceCommand(): string {
  return "icp cycles balance";
}

/// 4. Deploy the buyer's own project to mainnet.
export function deployCommand(): string {
  return "icp deploy -e ic";
}

/// Where the prerequisite is actually performed: the identity provider's own settings.
///
/// ⚠️ **The guide alone was not enough.** The page said "enable CLI access for your
/// Internet Identity" and linked the guide, without saying WHERE — so a buyer had to
/// read a docs page to discover that the switch lives in their id.ai settings. Naming
/// the place and linking straight to it is the difference between a warning and an
/// instruction, and without the switch the link command fails outright.
export const IDENTITY_SETTINGS = "https://id.ai";

/// The guide for enabling CLI access on an Internet Identity — the prerequisite that
/// makes the link command possible at all.
export const CLI_IDENTITY_GUIDE =
  "https://cli.internetcomputer.org/1.4/guides/managing-identities/#signing-in-as-a-specific-app";
