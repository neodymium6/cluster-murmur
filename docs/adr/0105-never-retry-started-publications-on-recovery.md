# ADR 0105: Never retry started publications on recovery

## Status

Accepted

## Context

A process may stop after Discord accepts a webhook request but before the
returned message ID and successful attempt are committed. Discord webhooks do
not provide an application idempotency key that can safely close this window.

## Decision

During restart recovery, inject a canonical UTC startup cutoff and classify
every exact loaded `started` publication at or before that cutoff as
`mark_ambiguous`. Never return a retry action. A start after the cutoff belongs
to the current process and requires no recovery action. Already succeeded,
classified failed, or ambiguous attempts also require no action.

Keep classification pure; a later store performs an exact compare-and-set from
`started` to `ambiguous` with error class `interrupted`.

## Consequences

Recovery favors avoiding duplicate public messages over automatically filling a
possibly missed publication. Operators can observe and reconcile ambiguous
outcomes without the application blindly resending sensitive content.
