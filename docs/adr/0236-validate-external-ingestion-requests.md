# ADR 0236: Validate External Ingestion Requests Before Listening

## Status

Accepted. Extends
[ADR 0234](0234-define-normalized-external-event-ingestion.md) and
[ADR 0235](0235-persist-external-events-atomically.md).

## Context

The normalized envelope and atomic persistence boundary do not define how an
HTTP request becomes trusted input. Combining secret loading, authentication,
JSON decoding, socket ownership, concurrency control, and persistence in one
listener would make the security boundary difficult to review.

## Decision

Define the network-independent request validation pieces first. An empty
external source policy disables ingestion without reading any listener or
secret setting. Enabling a source requires a fixed environment-selected port
and a Bearer credential read through the existing mounted-secret boundary.
Accept tokens only in a bounded token68 form and retain only their SHA-256
digest. Compare valid presented credentials through fixed-length constant-time
digest comparison.

Decode at most 64 KiB of JSON through the existing bounded decoder. Require the
exact normalized envelope keys, reject duplicate and trailing JSON input, and
accept only timestamps carrying a zero UTC offset. Construct the typed envelope
and apply its source-scoped allowlists before returning it. All failures expose
stable value-free errors.

This decision adds no socket, route, request logging, persistence call, trigger,
conversation, or external action. A later listener must remain loopback-only so
a trusted sidecar can provide TLS when the boundary is exposed beyond the pod
or host.

## Consequences

Authentication and payload validation can be tested without binding a port or
mutating durable state. The future listener remains responsible for exact HTTP
syntax, duplicate headers, method and path, content length, timeouts, rate and
concurrency limits, response mapping, redacted logs, and calling the atomic
commit store only after all checks pass.
