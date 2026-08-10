/// Which of the two audiences the visitor said they are (issue #21).
///
/// Two people arrive here with opposite needs: someone with no canister who has
/// never touched the platform, and an operator whose live canister is running
/// low. Both are first class, so the page asks rather than guessing.
export type Audience = "newcomer" | "live";

const KEY = "icp.audience";

/// Persistence is **asymmetric, on purpose.**
///
/// "Already live" is remembered: a returning operator should land in the arm
/// they use, with a visible way back.
///
/// "I'm new here" is remembered by **nothing**. A newcomer who returns is asked
/// again, because by then they may not be one — and the cost of the two mistakes
/// is not symmetric. Wrongly resuming the expert arm shows a canister-id field to
/// someone who has no canister, which reads as "this isn't for me". Wrongly
/// re-asking an expert costs one click.
export function remember(choice: Audience): void {
  try {
    if (choice === "live") window.localStorage.setItem(KEY, choice);
    else window.localStorage.removeItem(KEY);
  } catch {
    // Private browsing, or storage disabled. The chooser still works; it just
    // asks every time, which is the safe direction.
  }
}

/// The remembered arm, or null to show the chooser. Only ever returns "live" —
/// see `remember`.
export function recall(): Audience | null {
  try {
    return window.localStorage.getItem(KEY) === "live" ? "live" : null;
  } catch {
    return null;
  }
}

export function forget(): void {
  try {
    window.localStorage.removeItem(KEY);
  } catch {
    /* see remember */
  }
}

/// The arm to *pre-select* for a signed-in visitor, from the destination of
/// their most recent order.
///
/// Deliberately a pre-selection and not a skip: a returning buyer's intent
/// legitimately differs between visits (last month a top-up, today a new
/// project), so the chooser is still shown. Silently picking would decide for
/// them.
export function suggestFrom(lastDestinationKind: "canister" | "cyclesLedgerAccount" | null): Audience | null {
  if (lastDestinationKind === null) return null;
  return lastDestinationKind === "canister" ? "live" : "newcomer";
}
