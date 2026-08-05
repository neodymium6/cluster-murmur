# ADR 0104: Validate loaded publication attempts centrally

## Status

Accepted

## Context

Database constraints protect normal writes, but every loaded publication
attempt still crosses a runtime trust boundary. Recovery and completion code
must not interpret malformed or unexpectedly rewritten lifecycle state.

## Decision

Validate exact loaded Ecto metadata and shape, a positive SQLite message ID,
canonical microsecond UTC timestamps, and the complete status, completion, and
error-class correlation. Keep `interrupted` exclusive to ambiguous outcomes and
stable external errors exclusive to classified failures.

## Consequences

All later attempt store and recovery consumers can fail closed through one
generic redacted error. The validator does not load messages, transition state,
retry publication, or make network requests.
