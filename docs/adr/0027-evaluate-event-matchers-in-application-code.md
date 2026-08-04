# ADR 0027: Evaluate Event Matchers in Application Code

## Status

Accepted.

## Context

Event matchers have a closed validated representation, but trigger execution
still needs deterministic comparison semantics. Delegating matching decisions
to an LLM, expression engine, or external query system would violate the factual
decision boundary and enlarge the execution surface.

## Decision

Evaluate matchers in application code as a conjunction of their 1 to 32
predicates. Resolve only the five allowlisted top-level event fields and one
exact `labels` or `facts` key. A missing dynamic key never matches. `exists`
requires a non-null resolved value, while `equals null` can match an explicitly
null value.

Use JSON-style numeric equality, so integer and equivalent floating-point
values compare equally. Equality and membership comparisons require a scalar
event value, and ordered comparisons require a numeric event value. Non-scalar
values and ordered-comparison type mismatches are ordinary non-matches. `exists`
accepts any non-null value. Reject forged matchers that violate the parser's
field, operator, operand, duplicate, or collection bounds, and reject malformed
event domain values with stable value-free errors.

## Consequences

Event-trigger decisions are reproducible, side-effect free, and cannot execute
configuration text. Missing data and type mismatches do not raise or become
implicit matches. Runtime orchestration can distinguish invalid internal values
from a valid matcher that simply does not match, without logging event facts.
