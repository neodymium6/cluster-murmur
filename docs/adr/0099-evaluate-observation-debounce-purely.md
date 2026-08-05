# ADR 0099: Evaluate observation debounce purely

## Status

Accepted

## Context

Validated observations must advance durable state only after a configured
number of consecutive samples. Combining this policy with storage or event
publication would make replay and boundary testing harder.

## Decision

Use a pure evaluator with explicit healthy and unhealthy thresholds. It accepts
an optional validated prior state and one strictly newer, identity-matched
observation. Matching committed samples clear pending progress; contrary samples
start or advance progress and commit only at their threshold. Latest bounded
facts and labels always follow the accepted observation.

The evaluator returns only the next validated entity state. It does not persist,
classify events, read a clock, or call an observer.

## Consequences

Debounce behavior is deterministic and replayable. Persistence can enforce
monotonic writes independently, and event extraction can compare committed
states in a later boundary.
