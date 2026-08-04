# ADR 0035: Evaluate Stochastic Eligibility Purely

## Status

Accepted.

## Context

Active-hours evaluation and shifted-exponential sampling are pure, but runtime
policy still needs one deterministic decision combining an active window with a
persisted daily execution count. The date used to query that count must be
explicit, especially for windows that cross midnight.

## Decision

Evaluate active hours before the daily limit. When no daily limit exists,
require no execution count and return no date bucket. When a daily limit exists,
require a bounded non-negative count tagged with the trigger timezone's local
calendar date, and reject a tag that does not match the calculated bucket. Treat
a count equal to or above the configured limit as ineligible.

Return a redacted decision containing eligibility, a stable reason, and the
local date bucket the caller must use for its count. Attribute the post-midnight
part of a crossing window to that instant's calendar date rather than the date
on which the window began. Do not read or update a store, sample randomness,
schedule a run, or execute an action.

## Consequences

Eligibility is replayable from a trigger, instant, and date-tagged loaded count.
Store transactions can later use the returned bucket to atomically enforce and
increment daily limits without embedding timezone policy in persistence code.
