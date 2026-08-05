# ADR 0082: Evaluate Conversation Budgets

## Status

Accepted.

## Context

Generation, publication, and continuation must stop within configured turns,
participants, duration, and LLM-call limits. Deriving capacity from ambient
clocks or partially validated state would make restarts and tests inconsistent.

## Decision

Represent the four positive bounded limits as an immutable redacted budget.
Add a pure evaluator that revalidates one exact runtime conversation and one
injected canonical UTC instant, rejects instants before the conversation start,
and projects clamped remaining turns, participant slots, duration, and LLM
calls.

Mark active conversations open only while turns, duration, and LLM calls all
remain. Report a full participant set separately without closing the
conversation because an existing participant may still respond. Treat the
exact duration deadline and every terminal lifecycle state as closed. Return
only stable reason atoms and redacted capacity values.

## Consequences

Directors can check the same deterministic budget projection before each
operation without reading clocks or storage inside policy code. Responder
eligibility can distinguish adding a participant from allowing an existing one,
and over-limit restored counters remain safely clamped instead of underflowing.
