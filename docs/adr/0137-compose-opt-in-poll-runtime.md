# ADR 0137: Compose an Opt-In Poll Runtime

## Status

Accepted; amended by ADR 0206.

## Context

The no-reply starter pipeline can complete one already authorized event, while
the read-only observer poll can atomically persist state transitions and events.
Composition must connect those boundaries without returning observation facts
or reusable authorizations from the cycle boundary, predicting dynamic matches
before a poll, overlapping cycles, installing live infrastructure defaults, or
retrying a publication whose outcome is unknown after interruption. The
generation boundary still supplies allowlisted event facts to the explicitly
configured model provider.

## Decision

Compose one poll cycle in application code. Validate reusable configuration,
provider and webhook settings, transports, cooldowns, and adapters before
observation. Poll and ingest through the fixed observer boundary, derive an
execution instant no earlier than any returned event, select a bounded trigger
plan, and construct deterministic per-match conversation IDs. Preflight the
complete generated starter batch before authorizing its first match. Consume
each authorization synchronously through the fixed starter pipeline and return
only aggregate counts.

Provide an opt-in GenServer scheduler with validated explicit dependencies and
intervals. Do not add it to the public application supervision tree or provide
live observer, provider, Discord, or routing defaults. Schedule the next cycle
only after the current cycle completes. Associate each timer with a private
unique token so stale or injected messages cannot multiply the cadence.

Provide explicit restart recovery that first loads and validates every bounded
abandoned trigger execution, active conversation, and open publication attempt.
Only after all three collections pass validation may it close records through
their existing compare-and-set stores. Mark open publication attempts ambiguous
without republishing, fail active conversations, and fail started trigger
executions. Continue across individual CAS races and report only aggregate
success and failure counts.

Verify the vertical path with real SQLite stores and fake observer, provider,
and Discord transports. Verify scheduler non-overlap and stale-message
rejection, and verify that invalid recovery records cause zero mutations.

## Consequences

The repository contains a bounded no-reply observation-to-publication runtime,
an explicitly supervised periodic driver, and a non-retrying restart policy.
Private deployment assembly remains responsible for choosing real transports,
secrets, interval, recovery cutoff, and whether to start the worker. Responder
continuation, event retention and dedupe windows, and stochastic external
execution remain separate work.
