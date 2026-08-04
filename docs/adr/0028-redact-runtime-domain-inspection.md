# ADR 0028: Redact Runtime Domain Inspection

## Status

Accepted.

## Context

Normalized observations, events, and conversation state can contain complete
facts, labels, state snapshots, participants, and generated messages. Default
Elixir struct inspection exposes every field and can accidentally place those
values in logs, crash reports, or interactive diagnostics.

## Decision

Derive allowlisted `Inspect` implementations for observations, events, and
conversations. Expose only coarse operational state: observation state and
timestamp; event type, severity, and timestamp; and conversation status and
bounded counters. Hide source and subject identifiers, facts, labels, previous
and current state, dedupe and correlation keys, participants, and messages.

This is a logging safety default, not authorization to log every exposed field.
Production structured logging remains responsible for selecting the minimum
fields needed for each classified event.

## Consequences

Generic inspection no longer leaks runtime payloads by default. Operators can
still diagnose lifecycle state from coarse fields, while any richer diagnostic
export requires an explicit allowlist and redaction boundary.
