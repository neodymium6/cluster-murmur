# ADR 0125: Authorize Matching Event Triggers

## Context

Deterministic event-trigger selection and one-trigger durable authorization now
exist independently. Runtime dispatch needs a bounded batch boundary before any
authorized action can be orchestrated.

## Decision

Validate one event and execution instant, select at most 256 matching triggers,
and pass each selected trigger exactly once in stable ID order to an injected
one-trigger authorizer. Continue through per-trigger skips and failures while
retaining only validated redacted authorizations and stable value-free outcome
classes.

Revalidate the complete exact result, bound every retained collection, and
require each authorization to preserve the supplied event, execution instant,
and a trigger that is still exactly present in the supplied original catalog.
Do not execute an action, start a conversation, call an LLM, publish, retry, or
introduce concurrency.

## Consequences

Later action orchestration can consume only durable started capabilities in
deterministic order. Batch timing, event dedupe-window policy, terminal result
recording, recovery, and action execution remain separate reviewed decisions.
