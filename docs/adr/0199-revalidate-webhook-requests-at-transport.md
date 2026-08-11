# 0199. Revalidate webhook requests at the transport boundary

Date: 2026-08-11

## Status

Accepted

## Context

Discord publication validates the complete plan against current persistence,
persona, and webhook settings before durably claiming external dispatch. The
injected runtime transport remains a static one-argument function and therefore
receives only the resulting request after that claim. A live implementation
still needs to reject forged or extended request values without reopening the
claimed publication or exposing a generic HTTP interface.

## Decision

Add a transport-side validator for one exact `WebhookRequest` and the
transport-captured `WebhookSettings`. Require the request URL to equal that
single fixed Discord HTTPS webhook credential, plus the POST method, JSON
content type, `wait=true` query, mention-disabled payload, transport limits,
and exact struct shape.
Revalidate generated content through the existing safe-message boundary and
bound the username and optional HTTPS avatar using the same limits that produced
the publication payload.

This validation supplements rather than replaces the stronger plan validation
performed before the durable dispatch claim. Return only
`invalid_webhook_request`; never return webhook credentials, message content,
persona identity, or rejected field values.

## Consequences

The next live Discord transport can remain compatible with the existing static
one-argument runtime seam by capturing one startup-validated setting while
rejecting values outside the fixed publication contract. It cannot reconstruct
persistence identity after the claim, so the publisher remains responsible for
exact current-input correlation and exclusive dispatch authorization.
