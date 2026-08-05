# ADR 0070: Record Message Publication Once

## Status

Accepted.

## Context

Appended messages are deliberately unpublished. After Discord accepts one
publication, its returned message ID must be correlated with the exact durable
message without allowing a retry, stale capability, or duplicate external ID to
overwrite committed facts.

## Decision

Add one narrow store operation that accepts an exact loaded unpublished message
capability and one canonical nonzero uint64 Discord message ID. In an immediate
transaction, reload and compare every committed field, update the optional ID
once, enforce global uniqueness, then reload and compare every published field
before returning the redacted record.

Return stable invalid-input, stale/conflicting publication, invalid-record, and
storage classifications without values. Do not call Discord, retry delivery,
change content, or update conversation state.

## Consequences

Publication identity is a one-way compare-and-set transition. The store cannot
eliminate the crash window between Discord acceptance and this transaction;
later publication orchestration must define an idempotency strategy before
production readiness.
