# 0112. Publish through a claimed narrow transport

Date: 2026-08-05

## Status

Accepted; amended by ADR 0200.

## Context

An adapter must not permit repeated calls with the same prepared attempt to
send duplicate messages. It must also distinguish responses that prove Discord
rejected a request from failures that may occur after Discord accepted it.

## Decision

The webhook publisher validates the exact started attempt and independently
current plan inputs, builds and revalidates the fixed request, then performs the
durable dispatch claim itself. Only a successful `started` to `dispatching` CAS
reaches the injected transport. The returned dispatch record accompanies every
external outcome so orchestration can commit it through the attempt store.

Treat authentication, invalid-request, and rate-limit HTTP responses as known
rejections. Treat malformed or oversized success responses, HTTP 408, all 5xx
responses, unexpected statuses, unknown transport outcomes, and transport
exceptions as ambiguous. A transport may return timeout or unavailable as a
known failure only when it proves no request was sent.

## Consequences

Calling the publisher twice with the same started record invokes the transport
at most once. Ambiguous effects have no retry path. The transport accepts only
the fixed request and remains responsible for enforcing its connection,
receive, overall, and response-size limits.
