# ADR 0131: Plan Starter Publication

## Context

A generated starter message can now be atomically persisted with its advanced
conversation. The fixed Discord publication planner already converts an exact
unpublished message record, persona, and webhook settings into a bounded
mention-disabled payload. Runtime flow needs to resolve those inputs without
trusting a persona snapshot or unrelated durable message.

## Decision

Revalidate the complete persisted starter capability against current
configuration and supplied cooldown facts. Resolve the message persona by ID
from the current configuration and require it to remain structurally identical
to the selected starter in the conversation plan. Delegate the exact loaded
message, persona, and current exact webhook settings to the existing publication
planner and immediately revalidate the resulting payload correlation.

Return the persisted capability and fixed publication plan in one exact
redacted value. Normalize all invalid input and planning outcomes to one stable
error without exposing content, persona identity, or webhook credentials.

Do not start a publication attempt, execute a request, retry, record a Discord
ID or persona cooldown, or advance the conversation.

## Consequences

External publication can consume a closed plan whose outbound content and
display identity remain tied to the committed message and selected configured
starter. Publication attempt durability and transport execution remain later
reviewed boundaries.
