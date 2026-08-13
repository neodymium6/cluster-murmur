# Boundaries and design principles

This page defines project identity, responsibilities, exclusions, and design
principles. It is part of the current [system design](../../DESIGN.md).

## Overview

Cluster Murmur is an event-driven character conversation orchestrator. It
periodically consumes normalized, read-only observations, extracts meaningful
state changes, selects configured personas, generates short expressions, and
publishes bounded conversations to Discord.

```text
Kubernetes / Prometheus / Alertmanager / Flux / HTTP / TCP / DNS
                              |
                              v
                   cluster-observer-mcp
                    read-only observations
                              | MCP
                              v
                      cluster-murmur
         observation -> event -> trigger -> conversation
                              |
                              v
                           Discord
```

Cluster Murmur does not monitor or diagnose infrastructure itself. A separate
read-only source such as `cluster-observer-mcp` owns that boundary.

## Project identity

| Item | Value |
| --- | --- |
| Repository | `cluster-murmur` |
| Elixir application | `:cluster_murmur` |
| Root module | `ClusterMurmur` |
| CLI | `cluster-murmur` |
| Runtime | Elixir on Erlang/OTP |
| Persistence | Ecto with SQLite |
| Deployment | OCI container on Kubernetes |
| License | Apache-2.0 |

## Responsibilities

The MVP owns:

1. Periodic observation retrieval from `cluster-observer-mcp`.
2. Event extraction from the difference between current and persisted state.
3. Configuration-driven event, schedule, and stochastic triggers.
4. Binding-based persona candidate resolution and weighted speaker selection.
5. Persona-specific message generation through an LLM provider.
6. Discord Webhook publication with per-persona username and avatar overrides.
7. Short probabilistic replies from another relevant persona.
8. Low-frequency spontaneous conversations sampled from a shifted exponential
   distribution.
9. SQLite persistence for state, events, conversations, cooldowns, and future
   stochastic runs.
10. Strict configuration validation that prevents startup on invalid input.

The following are explicit non-goals:

- infrastructure creation, update, deletion, or autonomous remediation;
- generic shell, SSH, `kubectl`, SQL, URL, or PromQL execution;
- unbounded MCP tool access controlled by an LLM;
- automatic assertion of an unobserved root cause;
- unbounded persona conversations or storage of complete Discord history; and
- persistent emotional or relationship changes between personas.

Discord mention responses, question-scoped MCP tools, temporary persona mood,
summarized memory, multiple channels, additional observation sources, multiple
LLM providers, and correlation events are post-MVP extensions.

## Design principles

### Separate facts from expression

Application code determines observations, state transitions, failures,
recoveries, severity, and trigger decisions. The LLM only expresses confirmed
facts in a persona's voice. It never decides whether an incident exists, who
speaks, whether the conversation continues, or which MCP tool may run.

### Separate personas, events, and bindings

A persona defines identity and expression. An event defines what happened. A
binding associates an event with candidate personas. Cluster-specific service
identifiers stay out of reusable persona definitions.

### Abstract external dependencies

MCP clients, LLM providers, Discord publishers, clocks, random generators, and
persistent stores are accessed through Elixir behaviours. Domain code must not
depend directly on a specific provider or transport.

### Guarantee convergence

Every conversation is bounded by maximum turns, participants, duration, LLM
calls, per-persona limits, and cooldowns. Consecutive messages from the same
persona are disabled by default, and `no_reply` is always a valid outcome.
