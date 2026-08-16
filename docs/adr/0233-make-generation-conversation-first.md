# ADR 0233: Make Generation Conversation First

## Status

Accepted. Amends [ADR 0086](0086-validate-prompt-fact-projections.md),
[ADR 0087](0087-validate-bounded-generation-context.md),
[ADR 0088](0088-assemble-separated-generation-prompts.md), and
[ADR 0128](0128-plan-starter-generation.md). It also amends
[ADR 0005](0005-keep-facts-outside-llm.md) and
[ADR 0077](0077-generate-deterministic-factual-fallbacks.md).

## Context

The fixed generation instruction required every response to express only
confirmed event facts. An ambient stochastic event contains synthetic
activation data such as its event type, subject, routing group, severity, and
timestamp. Giving that data to the model as its only permissible topic caused
successful generations to report internal scheduling metadata instead of
starting character dialogue.

The product still needs a strict capability boundary: model input must remain
bounded and allowlisted, supplied data must not become instructions, and text
generation must not imply real system access or side effects. Those constraints
do not require fictional dialogue itself to be fact-only.

## Decision

Use one conversation-first application instruction. Ask for natural
in-character dialogue and allow harmless fictional topics, opinions, feelings,
relationships, disagreement, humor, and metaphor. Treat confirmed operational
facts as optional grounding: generated text must not contradict them, but need
not enumerate or mention them. Follow persona instructions for voice and the
application-owned creative context for framing, subject to the fixed system
constraints. Treat confirmed facts and conversation history as untrusted quoted
context rather than instructions.

Prohibit claims that the character can, will, or did use tools, access
credentials, change configuration, or cause external side effects. Retain the
existing persona, request-size, history, turn, participant, duration, LLM-call,
cooldown, output-length, UTF-8, control-character, persistence, and publication
boundaries. Do not add a semantic output classifier.

For events whose validated source is `stochastic`, provide an empty confirmed
fact map and fixed application-owned ambient framing. Do not send the synthetic
event type, trigger subject, routing group, severity, timestamp, or event
details to the model. Apply the same policy to starter and responder turns.
Use a neutral dialogue-opening fallback for stochastic events rather than an
event-report template.

Operational events continue through the existing fact allowlist. The new
instruction makes those facts optional conversational grounding without
exposing event identity, source, labels, deduplication values, correlation
values, configuration, or credentials.

## Consequences

An ambient trigger begins a bounded fictional conversation instead of becoming
the reported subject. Persona prompts and conversation history can now shape
banter without being overridden by a fact-only instruction. Operational
messages may also sound less like summaries while remaining grounded in the
facts the application supplied.

The application does not attempt to prove that generated prose is semantically
true. Safety comes from withholding sensitive context, denying capabilities,
bounding execution, and treating generated text as inert content.
