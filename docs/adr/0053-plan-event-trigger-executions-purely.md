# ADR 0053: Plan Event-Trigger Executions Purely

## Status

Accepted.

## Context

Event-trigger selection and cooldown calculation are pure, separate decisions.
Before a later durable transaction enables an action, orchestration needs one
safe boundary that rechecks the selected trigger against the event and combines
that factual match with the supplied cooldown projection.

## Decision

Build a fully redacted execution plan from one exact runtime-validated event
trigger, one bounded event, an optional persisted UTC cooldown deadline, and a
supplied canonical UTC execution instant. Re-evaluate the trigger matcher before
cooldown policy. A nonmatching trigger is skipped without inspecting cooldown
state. A matching trigger with an active cooldown is skipped. An eligible plan
retains the validated trigger and event plus the execution instant and newly
calculated cooldown deadline required by later orchestration.

Return only stable, value-free errors. Do not define durable execution statuses
or retry behavior, read a clock or repository, update cooldown state, choose a
persona, start a conversation, invoke an LLM, or publish externally.

## Consequences

Later persistence work can atomically deduplicate the trigger and event, compare
durable cooldown state, and record an explicit execution lifecycle before any
runtime action. Policy and event facts are rechecked at the last pure boundary,
while storage schema and failure semantics remain a separate decision.
