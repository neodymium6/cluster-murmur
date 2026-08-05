# 0107. Close publication attempts with compare-and-set transitions

Date: 2026-08-05

## Status

Accepted

## Context

A Discord request can end in a classified failure, or the process can lose the
ability to determine whether Discord accepted the request. These outcomes must
be durable without retaining raw responses, endpoints, or diagnostic payloads.
Concurrent or repeated completion must not overwrite a different outcome.

## Decision

Close a publication attempt only from one exact, validated `started` record.
The store compares all durable started facts before changing the status. A
classified external failure becomes `failed`; an unknowable outcome becomes
`ambiguous` with the fixed `interrupted` class. Completion timestamps are
canonicalized before comparison.

Repeating the exact same transition is idempotent. A missing attempt, changed
started fact, or different terminal outcome is a conflict. Raw external errors
and responses are never persisted.

## Consequences

Callers can safely repeat a known terminal write after a local storage error,
but cannot reinterpret or overwrite an already recorded outcome. Recovery can
distinguish an explicit external failure from a request whose effect is unknown.
