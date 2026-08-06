# 0110. Decode Discord responses to stable outcomes

Date: 2026-08-05

## Status

Accepted

## Context

Discord response bodies may contain approved publication content, remote
diagnostics, and fields the application does not need. Returning or logging the
raw body would widen the sensitive-data boundary. Orchestration needs only a
canonical message identifier or one stable external error class.

## Decision

Accept only exact response values whose raw body is within the request's fixed
response limit. A successful publication requires status 200 and bounded JSON
containing a canonical Discord snowflake string in `id`; all other success
shapes are invalid responses.

Classify 401, 403, and 404 as authentication failures, 408 as timeout, 429 as
rate limiting, other 4xx statuses as invalid requests, and 5xx statuses as
unavailable. Redirects and unexpected informational or success statuses are
invalid responses. Never return or inspect raw response bodies or diagnostics.

## Consequences

Conversation and persistence code receive only the fact needed to commit a
known success or a bounded error class. Unknown Discord fields remain allowed
only inside the shared bounded JSON decoder and are discarded immediately.
Transport-level timeouts and interrupted outcomes remain separate from HTTP
response classification.
