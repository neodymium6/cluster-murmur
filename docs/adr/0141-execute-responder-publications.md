# ADR 0141: Execute Responder Publications

## Status

Accepted.

## Context

A responder publication can now reach durable `started` intent. The external
effect must use the same one-use dispatch claim and conservative outcome
classification as starter publication, while preserving the responder plan's
exact configuration and cooldown correlations.

## Decision

Add a responder-specific executor that revalidates the complete redacted
started capability against current inputs before dispatch. Delegate the durable
`started` to `dispatching` claim and the fixed webhook request to the existing
narrow publisher, then persist exactly one correlated terminal result.

Treat proven remote success as `succeeded`, proven rejection or pre-send
failure as `failed`, and any potentially accepted but unknowable effect as
`ambiguous`. Do not retry an ambiguous effect. Return only redacted terminal
capabilities and never expose raw transport values or adapter diagnostics.

Do not record responder cooldowns or advance or close the conversation in this
boundary.

## Consequences

Responder messages can cross the only external publication boundary with a
durable one-use claim and conservative crash semantics. Downstream logic may
consume a proven terminal capability separately, without combining transport
I/O with conversation state changes.
