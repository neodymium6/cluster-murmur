# Production architecture and evolution

This page explains configuration, OTP supervision, deployment, verification,
and bounded future evolution. It is part of the current
[system design](../../DESIGN.md).

## Configuration

Configuration uses YAML 1.2 with JSON Schema structural validation and Elixir
semantic validation. Unknown fields, duplicate IDs, unresolved persona,
binding, or event-group references, malformed durations, cron expressions, and
timezones are fatal at startup. Configuration loads once; hot reload is not an
MVP feature. Glob order has no semantic meaning. The implemented decoder
requires one mapping-rooted document, accepts only the Core Schema value subset,
and enforces byte, scalar, node-count, and nesting limits before later
configuration-specific validation.

Configuration is split into a top-level include file plus event groups,
routing, personas, bindings, triggers, and prompt files. Secret values never
appear in these files. Routing and provider configuration reference environment
variables that point to mounted secret files.

## OTP architecture

```text
ClusterMurmur.Supervisor
|-- HealthServer
|-- ReadyMarker
|-- ClusterMurmur.Repo
`-- RecoveredRuntimeSupervisor
    |-- PollScheduler
    |-- EventDispatchScheduler
    |-- RecurringScheduleScheduler
    |-- StochasticScheduler
    |-- EventRetentionScheduler
    `-- ReadinessLease
```

The root uses `:rest_for_one` so repository replacement also replaces every
dependent runtime worker. The recovered runtime runs recovery and schedule
initialization before starting any of its five significant schedulers. If one
scheduler terminates, the shared supervisor closes and its parent reruns all
startup gates before replacement. Readiness is leased only after those workers
start; liveness remains available around repository and runtime replacement.
Personas and conversations remain validated data and durable lifecycle records,
not dynamically selected supervision modules.

## Future question boundary

Mention support will resolve a persona, classify the question, obtain an
application-enforced allowlist from a tool-policy behaviour, execute bounded
MCP calls in Cluster Murmur, normalize facts, and only then ask the LLM to
express an answer. MCP connection details are never delegated to the LLM. Tool
use is disabled by default and will enforce limits on rounds, calls, time, and
parallelism.

## Deployment

The MVP deployment is one Kubernetes Deployment with an OCI container,
ConfigMap volume, Secret volume, and SQLite PVC. The standard connection to
`cluster-observer-mcp` is loopback HTTP in the same Pod; a bounded stdio child
process remains an alternative.

The container runs as non-root with a read-only root filesystem, all
capabilities dropped, graceful shutdown, health endpoints, a fixed public
configuration path, and only SQLite and temporary paths writable. A private
overlay owns credentials, concrete endpoints, routing, PVC details, and network
policy.

## Verification strategy

Unit tests cover matching, bindings, weighted choice, cooldowns, transitions,
dedupe, stochastic sampling, prompt construction, and output validation.
Integration tests cover the complete fake-observer to fake-Discord path and
restart restoration. Replay tests inject identical clocks and random sequences.
Property tests prove non-negative weights, empty-candidate behavior, hard
conversation bounds, cooldown exclusion, and the stochastic minimum interval.

CI includes formatting, warnings-as-errors compilation, tests, Credo, Dialyzer,
an OCI build with closure and metadata validation plus an extracted-entrypoint
smoke test against isolated temporary storage, and a dependency audit. The audit
runs Hex's pinned-dependency retirement and security-advisory check before the
remaining repository checks.
Credo enables correctness and safety warnings, including its opt-in
environment-leak, unsafe-atom, and unsafe-execution checks. It excludes the
same-value operation check because the bounded float validators intentionally
use self-comparison as a NaN guard. Dialyzer rejects new warnings and stale
baseline entries; every retained exact filter is classified in
[`docs/dialyzer-boundaries.md`](../dialyzer-boundaries.md). Style and
complexity policy and standalone schema/example fixtures remain later
incremental gates.

## Evolution and history

The standalone alpha implements the architecture described above. The
[changelog](../../CHANGELOG.md) and [release history](../history/README.md) record
shipped increments. The [ADR index](../adr/README.md) groups the material
decisions that produced the current design. Potential post-MVP extensions are
explicitly non-normative until a reviewed contract and ADR define their bounded
behavior.
