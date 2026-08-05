# ADR 0102: Revalidate publication plans before execution

## Status

Accepted

## Context

A publication plan crosses from pure orchestration into a future external
adapter. Revalidating only its loaded message and webhook settings would not
prove that its payload still matches the selected persona and durable content.

## Decision

Carry the exact validated persona in the fully redacted publication plan. At
the execution boundary, require independently obtained current inputs: a freshly
loaded unpublished message record, the current valid enabled persona, and the
current valid webhook settings. Require those values to equal the plan snapshot,
then rebuild the fixed payload from the current inputs and require exact equality
with the planned payload.

## Consequences

External orchestration can reject forged, stale, or altered plans without exposing
content, persona details, or webhook credentials. This validation still makes
no storage or network request itself; callers must supply the freshly loaded
record immediately before execution. The boundary does not address the ambiguous
post-acceptance crash window.
