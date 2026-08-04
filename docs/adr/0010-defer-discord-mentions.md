# ADR 0010: Defer Discord Mentions and Preserve a Tool-Policy Boundary

## Status

Accepted.

## Context

Answering mentions adds untrusted user input, persona resolution, Gateway
connectivity, and potentially observation tools to the MVP boundary.

## Decision

Defer mention ingestion. Reserve the `discord.mentioned` event and a
`Questions.ToolPolicy` behaviour so future calls are selected and executed by
the application through explicit allowlists and hard budgets.

## Consequences

The MVP remains outbound-only. Future mention support has a defined extension
point but must still undergo a separate security and architecture review.
