# 0109. Use fixed revalidated Discord requests

Date: 2026-08-05

## Status

Accepted

## Context

Discord publication needs a webhook credential and generated content, but the
application must not expose a generic HTTP capability. Generated request values
and webhook URLs may also be sensitive. A receive timeout alone does not bound
DNS, connection, TLS, or request-upload time.

## Decision

Encode a Discord publication only from a publication plan revalidated against
independently supplied current message, persona, and webhook settings. Fix the
method to `POST`, the content type to JSON, the query to `wait=true`, and the
body to content, persona display identity, an optional validated avatar, and
disabled mention parsing.

Carry fixed connection, receive, and overall timeouts plus a maximum response
size. The eventual transport adapter must enforce every limit and revalidate
the complete encoded request immediately before execution. The public request
struct is data, not an execution capability, and its inspection omits the URL,
body, headers, and query.

## Consequences

Callers cannot select arbitrary endpoints, methods, headers, queries, bodies,
or transport limits through the validated boundary. A changed credential or
forged request is rejected before network access. The adapter remains
responsible for mapping bounded transport outcomes to stable error classes.
