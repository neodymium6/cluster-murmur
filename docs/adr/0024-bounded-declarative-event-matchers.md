# ADR 0024: Use Bounded Conjunctive Event Matchers

## Status

Accepted.

## Context

Event triggers need to inspect a small subset of supplied event facts without
accepting arbitrary expressions, paths, query languages, or executable code.
The earlier configuration example showed equality shorthand but did not define
how the six promised operators were represented or bounded.

## Decision

Represent a version 1 matcher as `match.all`, a conjunction of 1 to 32
predicates. A predicate addresses one allowlisted top-level field (`type`,
`source`, `subject`, `group`, or `severity`) or one portable `labels.<id>` or
`facts.<id>` key. Matcher key components start with an ASCII letter or digit and
then contain only ASCII letters, digits, `_`, or `-`; dots are excluded so paths
cannot nest beyond that single map key. Complete paths are at most 512 bytes.

Support exactly these operator shapes:

- `equals` and `not_equals` take one JSON scalar `value`;
- `in` takes 1 to 32 distinct JSON scalar `values`;
- `exists` takes no operand; and
- `greater_than` and `less_than` take one numeric `value`.

String operands are valid UTF-8 and at most 1,024 bytes. Reject duplicate
predicates, unexpected operand fields, compound JSON values, and unknown
operators. Normalize predicates and membership values into deterministic order
and return redacted immutable values. Compile the application-owned schema once
when parsing multiple triggers.

## Consequences

Matcher configuration cannot execute code or traverse arbitrary event data.
All predicates are conjunctive in version 1; disjunction, negation of compound
expressions, regular expressions, and deeper paths require a future contract.
Application code remains responsible for deterministic matcher evaluation.
