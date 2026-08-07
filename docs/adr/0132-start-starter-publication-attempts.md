# ADR 0132: Start Starter Publication Attempts

## Context

A committed starter message can now produce an exact fixed Discord publication
plan. Before any non-idempotent external request, the durable publication
attempt store must record intent and reject reuse or changed message facts.

## Decision

Revalidate the complete starter publication plan against current configuration,
cooldown facts, persona, and webhook settings. Pass its exact publication plan,
loaded message, resolved persona, settings, and one injected UTC start instant
to an injected narrow attempt store. Accept only an exact loaded `started`
attempt whose message identity matches the committed message, whose start is not
before message insertion, and whose terminal fields remain empty.

Return the plan and attempt in one exact redacted capability. Preserve the
store's fixed validation, conflict, and availability outcomes, while containing
raised or malformed store behavior without exposing values.

Do not claim dispatch, construct or execute a webhook request, record an
external outcome, retry, update a cooldown, or advance the conversation.

## Consequences

The external publisher can require durable intent before obtaining its one-use
dispatch claim. Repeated or changed attempts remain store-level conflicts, and
restart recovery can distinguish work that may have reached Discord.
