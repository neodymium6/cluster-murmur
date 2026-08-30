# ADR 0237: Serve External Ingestion on Loopback

## Status

Accepted. Extends
[ADR 0236](0236-validate-external-ingestion-requests.md).

## Context

The request-validation and atomic commit boundaries are not externally
reachable. A production listener must connect them without widening the health
probe listener, exposing plaintext beyond a trusted sidecar boundary, or
allowing slow and concurrent clients to consume unbounded resources.

## Decision

Add a dedicated raw HTTP/1.1 listener fixed to `127.0.0.1` and the fixed route
`POST /v1/events`. Start it only when external sources are configured, after
the repository and before the recovered conversation runtime. Deployments that
need a non-loopback endpoint must terminate TLS and enforce network policy in a
trusted sidecar sharing the loopback namespace.

Accept one request per connection with an 8 KiB header limit, 64 KiB body
limit, one-second absolute input-receive deadline, at most 16 active workers, and at
most 20 admitted connections per one-second window. Require HTTP/1.1 Host,
Content-Length, JSON media type, exactly one case-insensitive Authorization
header, and no Transfer-Encoding. Unknown bounded headers confer no capability.

Authenticate before reading or decoding the body. After authentication, use
the exact decoder from ADR 0236 and the atomic commit from ADR 0235. Return only
fixed value-free responses. Treat an exact retry as accepted, a changed durable
identity as conflict, invalid input as a client error, and storage uncertainty
as unavailable.

Emit structured outcomes without request bodies, facts, labels, or credentials.
For accepted input only, allow the application-derived
`external-<sha256>` event ID and a Boolean duplicate flag through the production
log allowlist.

## Consequences

Health probes remain unable to ingest events, and no plaintext ingestion socket
binds to a routable interface. Every acknowledged request has already committed
one immutable event and durable dispatch handoff. The existing dispatch cycle
continues to own trigger matching, cooldowns, conversation budgets, generation,
and publication.

The fixed limits favor small normalized events and a local trusted adapter over
general-purpose webhook compatibility. Operations documentation must show the
sidecar TLS boundary and mounted-secret wiring before the feature is released.
