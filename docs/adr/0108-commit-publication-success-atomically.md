# 0108. Commit publication success atomically

Date: 2026-08-05

## Status

Accepted

## Context

A known successful Discord response supplies a canonical message ID. Recording
that ID separately from the publication-attempt outcome could leave durable
state claiming either an unpublished message or an unfinished attempt after a
crash.

## Decision

Commit the Discord message ID and the attempt's `succeeded` transition in one
database transaction. The operation requires exact validated capabilities for
the same started attempt and unpublished message. Both records are compared
against all supplied durable facts before mutation and revalidated afterward.

An exact repeat of the same successful result is idempotent. Any different
attempt outcome, message fact, completion instant, or Discord message ID is a
conflict. Only the canonical Discord identifier is stored; response bodies and
diagnostics remain outside persistence.

## Consequences

Durable state cannot expose a success transition without its corresponding
Discord identifier through this operation. Callers may safely retry a storage
acknowledgement failure using the same known response, while conflicting
results fail closed.
