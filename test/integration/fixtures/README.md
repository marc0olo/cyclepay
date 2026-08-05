# Recorded Stripe event bodies

Captured with `scripts/capture-stripe-fixtures.sh`, asserted by
`test/integration/src/fixtures.spec.ts`, tracked by issue #4.

**Why these are committed.** Every other Stripe payload in this repo is JSON written
from the API docs, so the suites prove the canister matches *our reading* of Stripe
rather than Stripe itself. These files are the only evidence of the real wire format.

It has been earned once already: a unit test "covered" delayed-payment settlement by
sending a second `checkout.session.completed` — an event Stripe does not send. The
real one is `checkout.session.async_payment_succeeded`.

**Sanitisation.** These come from a Stripe **sandbox** account, so they contain no
real customer data. Still, skim a body before committing it — if you used a real
email or name while testing, replace it. Nothing in the parser reads those fields.

**Regenerating.** Re-running a capture action overwrites that fixture, so a bad
capture is cheap to redo. `scripts/capture-stripe-fixtures.sh --status` lists what is
still missing.
