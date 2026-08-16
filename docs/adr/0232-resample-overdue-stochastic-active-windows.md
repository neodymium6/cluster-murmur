# ADR 0232: Resample Overdue Stochastic Active Windows

## Status

Accepted. Amends
[ADR 0155](0155-run-bounded-stochastic-cycles.md).

## Context

A stochastic schedule that became due outside `active_hours` remained due.
Every scheduler cycle skipped it until the window opened, then executed it on
the first eligible cycle. This turned a random conversation into a predictable
burst at the configured opening boundary.

Simply sampling again in memory would move the replacement after every process
restart. Advancing the schedule as a completed execution would incorrectly
consume the daily limit and alter its last-run history.

## Decision

When a due schedule is ineligible only because it is outside active hours,
calculate the next local active window and sample one replacement inside that
window. Use the trigger's existing shifted-exponential sample. When its minimum
interval fits in the window, preserve that minimum offset from the opening and
wrap the remaining delay within the available interval. For a narrower window,
wrap the complete positive delay strictly between the opening and closing
instants. Opening is inclusive for eligibility, but a deferred replacement is
always strictly later than it.

Resolve possible window boundaries in the configured IANA timezone and retain
both UTC occurrences of an ambiguous opening. Try future opening occurrences
in order with the same single random sample. When an ambiguous closing causes
eligibility to resume after a clock fold, derive that transition-induced UTC
opening from the same evaluator and include it before the next local day.
Revalidate every resulting candidate through the active-hours evaluator used
for execution, so a daylight-saving fold cannot hide an inactive interval
between two wall-clock boundaries. Gap and cross-midnight candidates follow the
same validation, and only canonical UTC instants reach storage. Search a fixed
maximum of eight local dates so a window swallowed completely by a
clock-forward gap advances to the next real occurrence without creating an
unbounded calculation.

Claim the exact overdue schedule version before persisting the sampled
replacement. Add one fixed store operation that conditionally replaces
`next_run_at` through that opaque live claim and clears the lease. Preserve
`last_run_at`, `daily_count`, and `daily_count_date`. Count a successful
deferral as a skip and a sampling, claim, or update conflict as a cycle failure.

Do not emit an event, enqueue a dispatch, or consume a daily-limit count for a
deferral. Daily-limit ineligibility retains the existing no-claim skip policy.

## Consequences

The opening boundary no longer releases an accumulated overdue event. Different
triggers consume independent random samples, while a successfully persisted
replacement survives restarts without moving or duplicating. A crash before
the conditional update leaves only a bounded lease; after expiry, the same due
version can be sampled and claimed again.

The deferral distribution is a bounded wrapping of the configured wait rather
than an unbounded shifted exponential. This deliberate conditioning guarantees
that the replacement belongs to one known active window.
