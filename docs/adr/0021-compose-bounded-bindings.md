# ADR 0021: Compose Bindings Before Resolving References

## Status

Accepted.

## Context

Binding files associate event groups with weighted persona candidates and may
be split across multiple included documents. Structural validation alone cannot
detect namespace collisions or ambiguous duplicate candidates, while resolving
references inside each file would make validation depend on include order.

## Decision

Require each version 1 binding document to contain exactly one `bindings`
array. Each binding has a portable ID, a closed group matcher, and between one
and 256 candidate entries. Candidates contain exactly a portable persona ID and
a non-negative weight.

Compile the category schema once, then combine documents in deterministic ID
order. Reject duplicate binding IDs across files, duplicate persona candidates
within a binding, and more than 256 bindings overall. Normalize candidates by
persona ID and return redacted immutable values with stable error atoms.

Keep group and persona IDs unresolved during category parsing. Full
configuration assembly validates those references after every category has
been parsed, so include order cannot affect validity.

## Consequences

Binding selection receives one bounded, deterministic namespace without
accidental double-weighting. Zero candidate weights remain valid as documented;
runtime selection may therefore produce no eligible starter. References to
missing groups or personas fail later during whole-configuration assembly.
