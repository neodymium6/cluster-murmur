# ADR 0006: Use Configuration-Driven Triggers

## Status

Accepted.

## Context

Operators need to change event affinity, schedules, and social frequency
without recompiling the application, but embedded code would enlarge the
execution boundary.

## Decision

Define event, schedule, and stochastic triggers in strictly validated YAML.
Allow only a small declarative matcher vocabulary and reject arbitrary code.

## Consequences

Trigger behavior is auditable and portable. Schema and semantic validation are
startup-critical, and unsupported expressions require application changes.
