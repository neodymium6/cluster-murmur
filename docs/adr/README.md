# Architecture decision records

Architecture decision records (ADRs) preserve why material choices were made.
They are historical evidence, not the primary way to learn or operate Cluster
Murmur. Start with the [documentation index](../README.md), the
[system design](../../DESIGN.md), or the normative references linked there.

ADRs remain numbered in decision order so later records can amend earlier
ones without rewriting history. An accepted ADR may therefore describe an
older boundary; its **Status** section identifies known amendments. Current
source and normative documentation take precedence when an ADR has been
amended.

## Decision series

| Range | Area |
| --- | --- |
| 0001–0012 | Foundation, domain boundaries, dependencies, publication, persistence, and public/private separation |
| 0013–0035 | Configuration loading, validation, event policy, triggers, time, and deterministic selection |
| 0036–0060 | SQLite ownership, durable schedules, events, trigger execution, and recovery |
| 0061–0095 | Conversations, messages, cooldowns, generation, secrets, and publication planning |
| 0096–0127 | State tracking, observation ingestion, publication lifecycle, transports, and event authorization |
| 0128–0151 | Starter and responder generation, publication, and bounded conversation pipelines |
| 0152–0175 | Recovery gates, stochastic and dispatch cycles, deduplication, and event retention |
| 0176–0192 | Recurring schedules, runtime initialization, packaging, and unified scheduler startup |
| 0193–0223 | Fixed live transports, production assembly, operations, release publication, end-to-end verification, TLS startup, and provider compatibility |

File names describe the individual decision within each series. Use repository
search for a component or invariant rather than reading the directory in
numeric order.

## When to add an ADR

Add an ADR only for a material decision that changes architecture, public
boundaries, durable data, operational safety, or a hard-to-reverse interface.
Routine implementation steps, local refactors, and test-only changes belong in
code, tests, commit messages, or pull-request descriptions instead.

New ADRs must:

- state their status and context;
- record the selected decision and meaningful alternatives;
- explain safety and operational consequences; and
- identify any earlier ADRs they amend or supersede.
