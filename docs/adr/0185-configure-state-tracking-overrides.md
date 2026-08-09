# 0185. Configure state-tracking overrides

Date: 2026-08-09

## Status

Accepted

## Context

One global debounce threshold cannot represent observation sources with
different sampling reliability. Deployment-specific subject inventories may be
sensitive and are not otherwise part of public configuration, but the runtime
still needs a bounded declarative way to select stricter policies without
granting an observer or LLM policy control.

## Decision

Extend the version 1 `state_tracking` mapping with an optional list of at most
256 exact overrides. Every override contains one bounded nonempty source string,
an optional bounded nonempty subject string, and complete positive failure and
success thresholds. Reject unknown fields, duplicate source-subject selectors,
improper lists, oversized collections, invalid UTF-8, NUL bytes, and forged
normalized values.

Normalize overrides into a redacted map. Resolve an exact source-subject
selector first, then a source-only selector, then the global default. Return
only the existing fixed debounce-policy value. Preserve the original document
shape when no overrides exist and serialize overrides in deterministic order.

This boundary does not read observations, enumerate subjects, access durable
state, or start a worker. Runtime policy selection remains a separate change.

## Consequences

Version 1 deployments can declare bounded source and subject-specific debounce
thresholds while existing manifests retain their exact default behavior.
Configuration inspection omits selector values. Operators remain responsible
for keeping deployment-specific inventories in private configuration.
