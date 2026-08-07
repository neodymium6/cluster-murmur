# ADR 0128: Plan Starter Generation

## Context

An event-trigger action can now atomically consume its durable authorization and
return an exact starting conversation with the selected configured starter.
Fact projection, persona projection, context validation, and provider-neutral
prompt assembly exist independently, but later execution needs one closed input.

## Decision

Revalidate the exact one-use conversation-start capability against current
configuration and supplied cooldown facts. Project only the starter's display
name and instructions, the fixed allowlisted event facts, an application-owned
conversation kind taken from the exact configuration-validated binding group,
the fixed mood `attentive`, and empty history for the first turn. Assemble these
fields through the existing structured prompt boundary and return the start
capability, context, and request in one redacted exact plan.

Do not let a free-form event group control creative framing or infer a cause,
diagnosis, remediation, or other fact from severity or event text.

Do not call a provider, choose a model, resolve credentials, generate fallback
content, append a message, publish, or update lifecycle state.

## Consequences

The provider executor can receive a fully validated request without access to
persona selection metadata, webhook details, raw configuration, or arbitrary
event fields. Conversation-history projection remains later work for replies.
