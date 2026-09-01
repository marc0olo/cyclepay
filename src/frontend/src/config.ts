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

/// The command that links a buyer's browser identity to their CLI.
///
/// Always with the explicit `--app`. Omitted, icp-cli lets the auth domain pick
/// its default (`cli.id.ai` for id.ai), which is a different principal and an
/// empty balance.
export function linkIdentityCommand(profile = "dev"): string {
  return `icp identity link web ${profile} --app ${canonicalAppDomain()}`;
}

/// How a buyer checks the link landed on the right identity.
///
/// `icp identity principal --identity <name>` is a real subcommand of icp-cli
/// 1.2.0 ("Display the principal for the current identity", with an `--identity`
/// selector). Deliberately NOT phrased as "the link command prints the principal"
/// — the CLI guide does not say it does, and inventing output is how a tour
/// teaches someone to expect something that never appears.
export function verifyIdentityCommand(profile = "dev"): string {
  return `icp identity principal --identity ${profile}`;
}
