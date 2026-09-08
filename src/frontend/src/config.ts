/// Deployment-wide constants that must exist in exactly one place.

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
/// `host`, not `hostname`: a port is part of the identity of a local origin.
export function canonicalAppDomain(): string {
  return window.location.host;
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
