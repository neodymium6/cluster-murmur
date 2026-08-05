# ADR 0097: Validate and store loaded entity state monotonically

## Status

Accepted

## Context

The entity-state record defines bounded durable debounce facts, but consumers
still need a fail-closed read boundary and a narrow update operation. Concurrent
or replayed observations must not replace newer committed facts.

## Decision

Decode every loaded record through the shared bounded JSON decoder, reconstruct
the exact domain value, and reapply the complete entity-state validator. Expose
only composite-identity reads and monotonic replacements. Equal observation
times are idempotent only when every persisted fact is identical; older or
different equal-time writes are conflicts. Newer writes use compare-and-set and
revalidate the durable result. One compare-and-set miss reloads the intervening
state and retries once, so progress is bounded under contention.

The store accepts already-decided debounce state. It does not perform an
observation, classify a transition, or emit an event.

## Consequences

Corrupt or unexpectedly rewritten durable state fails closed. Observation
ingestion can safely restore the latest bounded state, while debounce and event
policy remain independently testable application decisions.
