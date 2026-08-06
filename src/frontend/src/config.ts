/// Deployment-wide constants that must exist in exactly one place.

/// The canonical origin this app is served from.
///
/// **Load-bearing on money.** Internet Identity derives a principal per frontend
/// origin, so this string determines which account is credited, which balance the
/// cycles land in, and what the buyer must pass to `icp identity link web --app`.
/// Serving the same app from a second origin gives the same human a second
/// principal and a second balance, which surfaces as a support ticket that reads
/// like theft.
///
/// It is read from the live origin rather than hardcoded, so that:
///   - local, staging and production each print their own correct value, and
///   - the still-open `build.` vs `cycles.` decision (issue #21) is a DNS change
///     rather than a hunt through string literals.
///
/// Every user-visible occurrence of the origin MUST come from here. Never write
/// the bare `icp identity link web dev` form without `--app`: a mismatched origin
/// yields a different principal and an empty balance, and that failure reads to
/// the buyer as "you took my money".
export function canonicalOrigin(): string {
  return window.location.origin;
}

/// The command that links a buyer's browser identity to their CLI, always with
/// the explicit `--app` so the principal matches the one credited here.
export function linkIdentityCommand(profile = "dev"): string {
  return `icp identity link web ${profile} --app ${canonicalOrigin()}`;
}
