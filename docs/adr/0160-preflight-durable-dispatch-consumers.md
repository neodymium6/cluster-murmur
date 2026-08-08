# 0160. Preflight durable dispatch consumers

Date: 2026-08-08

## Status

Accepted

## Context

The bounded dispatch planner can prove a complete ordered event-trigger batch,
but the existing concrete starter and conversation consumers preflight only a
poll-specific plan. Building separate action pipelines for outbox work would
duplicate authorization handling and risk different safety checks for the same
conversation behavior.

## Decision

Allow the fixed starter-only and bounded-conversation consumers to preflight a
durable event-dispatch plan. Rebuild that plan from its claim-free candidates,
restored events, and complete current configuration before validating any
authorization-free action input.

Represent both consumer contexts as one entry per match carrying the input,
event, trigger, and execution instant. Apply the same exact context, stable
position, unique conversation ID, safe generation time, adapter, and
configuration correlation checks for poll and durable work. Recheck the
authorization against that exact entry before invoking either fixed pipeline.
Derive the retry-stable conversation ID from the exact event ID, trigger ID,
and execution instant through one shared pure boundary, and require every
nested starter input to carry that exact identity during preflight and consume.

Do not claim or complete an outbox entry, authorize a trigger during preflight,
invoke a provider, publish, or add a generic action callback.

## Consequences

Poll and durable outbox work can share the same concrete action consumers
without weakening their batch-before-mutation guarantee. Forged plans and
configuration drift fail before an authorization is created.

The bounded runtime that loads, claims, consumes, and completes outbox entries
remains separate reviewed work.
