# 0202. Include observer settings in startup

Date: 2026-08-11

## Status

Accepted; amends ADRs 0117, 0118, and 0193.

## Context

The startup boundary claims to prepare every deployment setting before worker
construction, but the Observer MCP endpoint and mounted token were introduced
after that aggregate. Provider and webhook settings are loaded and revalidated
through `RuntimeSettings`; observer settings remain disconnected even though a
fixed live observer transport now exists.

## Decision

Load and revalidate `MCPSettings` as the first external settings stage in the
same redacted `RuntimeSettings` aggregate as provider and webhook settings.
Label its stable startup errors with the `observer` stage and preserve the
existing fail-closed order: normalized public configuration, observer settings,
provider settings, then webhook settings.

Continue to perform no network I/O during preparation. The exact aggregate
remains inspect-redacted and rejects missing, malformed, or extended fields
before runtime construction.

## Consequences

One validated `Startup.Prepared` value now contains every credential-bearing
input required by the three fixed live transports. Runtime assembly can capture
these settings without reopening files or reading the environment lazily.

Deployments that previously prepared only model and webhook secrets must now
also supply the documented Observer MCP endpoint and mounted-token path before
startup can succeed.
