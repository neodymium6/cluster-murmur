# 0197. Classify invalid provider transport responses explicitly

Date: 2026-08-11

## Status

Accepted; amends ADR 0115.

## Context

The fixed OpenAI-compatible provider transport contract distinguishes failures
before dispatch from outcomes that become uncertain after dispatch. A live HTTP
executor must also reject malformed or oversized response framing locally, but
the injected contract cannot currently express that stable result. Treating a
proven response-validation failure as outcome unknown loses useful operational
classification.

## Decision

Allow the narrow provider transport to return `{:error, :invalid_response}` in
addition to its existing not-sent and outcome-unknown classes. Pass that exact
stable class through the OpenAI-compatible provider. Continue mapping malformed
transport return values to invalid response and post-dispatch transport
uncertainty to unavailable. Do not expose raw response bytes, parser errors,
provider diagnostics, or transport implementation details.

## Consequences

The future fixed HTTP executor can report local response-boundary rejection
without pretending the request was not sent or exposing diagnostics. Callers
still receive only the existing external error vocabulary, and the transport
does not gain retry authority or a generic HTTP interface.
