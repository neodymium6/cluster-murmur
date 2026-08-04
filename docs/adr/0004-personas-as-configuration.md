# ADR 0004: Treat Personas as Configuration and Conversations as Processes

## Status

Accepted.

## Context

Personas are mostly immutable identity and behavior data. Conversations have a
short lifecycle, mutable counters, deadlines, and external calls.

## Decision

Store personas as validated read-only configuration. Run each active
conversation under a `DynamicSupervisor` and terminate it at completion.

## Consequences

The process topology reflects actual concurrency. Persona lookup stays cheap,
while conversation failures and timeouts are isolated.
