# ADR 0002: Separate Observation and Conversation Orchestration

## Status

Accepted.

## Context

Infrastructure access has different credentials, risks, and ownership from
character conversation orchestration.

## Decision

Keep raw infrastructure APIs and read-only diagnostic implementation in
`cluster-observer-mcp` or another bounded observer. Cluster Murmur consumes only
normalized observations and never receives a generic infrastructure primitive.

## Consequences

Each service has a smaller security boundary and can evolve independently. MCP
contracts and normalization errors become explicit integration concerns.
