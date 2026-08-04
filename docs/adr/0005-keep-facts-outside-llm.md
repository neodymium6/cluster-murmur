# ADR 0005: Keep Factual Decisions Outside the LLM

## Status

Accepted.

## Context

Language models can produce engaging expression but cannot be trusted to decide
whether an observed failure, recovery, measurement, or remediation occurred.

## Decision

Application code determines facts, events, speakers, continuation, and tool
policy. LLMs receive explicit facts and may only produce persona-specific text.
All output passes deterministic validation.

## Consequences

Prompts have a strict fact/expression boundary. The application needs explicit
event extraction and conversation policy, plus a deterministic fallback.
