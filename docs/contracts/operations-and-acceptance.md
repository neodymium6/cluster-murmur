# Operations and acceptance

This page defines operational signals, shutdown behavior, verification, and MVP
acceptance criteria. It is part of the normative
[MVP runtime contract](../mvp-contract.md).

## Operational signals and shutdown

Production exposes only fixed value-free liveness, readiness, and startup probe
responses. After repository startup, recovery, both schedule initializations,
and startup of all five schedulers, the final runtime child acquires the
monitored readiness lease and both probes become successful. That child releases
the lease before remaining schedulers drain during replacement or graceful
shutdown. Liveness may stay available while only the runtime is replaced and
stops last during full application shutdown. Probe responses must not expose
application data, configuration, endpoints, credentials, prompts, external
responses, or diagnostics.

Normal shutdown removes readiness first, gives each scheduler its bounded OTP
child shutdown window, stops the five scheduler children sequentially before
SQLite, and stops liveness last. An interrupted SQLite transaction rolls back.
Interrupted provider work is not retried, and publication that may have crossed
the dispatch boundary is recovered as ambiguous rather than sent again.

The five scheduler types, three fixed live transports, and post-resolution
generation decision emit only three fixed Telemetry event names. Cycle and
transport measurements contain a native monotonic duration and a count of one;
the decision contains only a count of one. Metadata contains only finite
component, outcome, and stable error-class values. Matching structured logs use
constant messages and those same fields. Results, requests, responses,
exceptions, endpoints, credentials, prompts, observation data, events,
participants, and messages are excluded.

## Verification requirements

Unit tests cover event matching, binding resolution, weighted choice,
cooldowns, state transitions, dedupe, shifted exponential sampling, prompt
construction, and output validation.

Integration tests cover the path from a fake observer through event extraction,
triggering, fake generation, fake Discord publication, and SQLite persistence.
They also cover restoration after restart.

Replay tests feed the same event sequence, clock values, and random sequence to
produce the same decisions. Property tests establish at least these invariants:

- computed weights are never negative;
- an empty eligible set never selects a persona;
- conversations never exceed a configured budget;
- a persona on cooldown is not selected; and
- a stochastic run is never scheduled below its minimum interval.

## MVP acceptance criteria

The MVP is complete only when all of the following are demonstrated by
automated checks or a safe local integration test:

1. The application starts with valid configuration.
2. The application refuses to start with invalid configuration.
3. It retrieves normalized observations from `cluster-observer-mcp`.
4. It persists state changes as events.
5. Event triggers can be defined in configuration.
6. Shifted-exponential stochastic triggers can be defined in configuration.
7. It resolves personas related to an event through a binding.
8. It performs injected weighted selection when multiple candidates exist.
9. It generates persona-specific messages through an LLM provider.
10. It falls back to a deterministic template after an LLM failure.
11. It publishes with a persona-specific display name and avatar through a
    Discord Webhook adapter.
12. A different relevant persona can reply according to configured policy.
13. Every conversation terminates within all configured budgets.
14. State, cooldowns, and stochastic next-run times survive restart.
15. The OCI container runs as non-root with the documented filesystem and
    capability restrictions.
16. Formatting, tests, Credo, Dialyzer, configuration validation, and other
    mature CI checks documented in the
    [verification strategy](../design/production-and-evolution.md#verification-strategy)
    pass.

Acceptance testing must use fake adapters or an explicitly approved isolated
environment. It must not publish to Discord or connect to live infrastructure
without approval for the exact environment and revision.
