# 0220. Test isolated end-to-end recovery

Date: 2026-08-11

## Status

Accepted

## Context

The repository tests each bounded production transport and each durable
pipeline stage, but an operator-facing example should demonstrate the complete
observation-to-publication flow without accessing infrastructure, a model
provider, or Discord. Redirecting the production Discord transport to a local
server would weaken its fixed `discord.com` authority and TLS contract.

## Decision

Provide one focused executable integration test as the isolated example. Use
real bounded loopback HTTP transports for the observer MCP and OpenAI-compatible
model boundaries, real SQLite lifecycle stores, the application-owned trigger
and conversation pipeline, and the real webhook request validator and
publisher. Replace only the final network effect with an in-process destination
that records one validated request and returns one clearly fake Discord ID.

After the first degraded observation publishes, invoke the same recovery pass
used during startup and require it to find no abandoned work. Poll a later
observation of the same state and require the durable entity timestamp to
advance without another event, generation request, or publication. Assert exact
durable counts and redacted aggregate inspection.

## Consequences

One small command demonstrates transition detection, durable state, bounded
generation, publication-once behavior, and safe resumed polling. It remains
fully local and cannot contact Discord or infrastructure. The example does not
pretend to validate a Discord TLS connection; that separate production
transport retains its fixed-host tests and cannot be redirected through example
configuration.
