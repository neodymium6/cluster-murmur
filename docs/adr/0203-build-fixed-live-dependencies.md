# 0203. Build fixed live dependencies

Date: 2026-08-11

## Status

Accepted

## Context

Startup now prepares the independently validated Observer MCP, model-provider,
and Discord webhook settings required by the three fixed live transports. The
standalone runtime still needs application-owned callback values matching the
existing scheduler and pipeline seams. Allowing deployment code to select
adapter modules or reopen settings would weaken those reviewed boundaries.

## Decision

Build one inspect-redacted live dependency bundle only from an exact validated
`Startup.Prepared` value. Fix the adapter modules to `MCPClient`,
`OpenAICompatibleProvider`, and `WebhookPublisher`. Capture each corresponding
setting in a one-argument closure around its fixed HTTP transport and use the
observer closure only as the opaque context of a validated read-only `Client`.

Construction performs no network connection, persistence access, clock read,
random sampling, or worker start. It exposes no module selection, endpoint
override, generic HTTP input, or raw credential value.

## Consequences

Later scheduler-option assembly can consume one application-built bundle rather
than reconstruct transport closures or accept caller-selected external
adapters. The provider and webhook settings remain available through the same
validated prepared value because their established pipeline APIs require those
values independently of the transports.

The closures deliberately remain execution capabilities. They must stay inside
the supervised runtime and must not be logged, serialized, or returned through
an operational interface.
