# 0189. Provide production time and randomness

Date: 2026-08-11

## Status

Accepted

## Context

The bounded runtime accepts injected clock and random modules so tests and
replay can remain deterministic. Standalone assembly now needs fixed production
implementations, but adding those adapters must not create external transport
access or bypass the existing validated policy inputs.

The existing runtime system clock implements only the UTC scheduler callback.
Conversation policy also defines wall-time and monotonic-time callbacks. There
is no production implementation of the random contract used for stochastic
waits and bounded persona selection.

## Decision

Extend `ClusterMurmur.Runtime.SystemClock` to implement both clock contracts.
Use canonical UTC wall time and the VM monotonic millisecond clock without
introducing configurable clock sources.

Add `ClusterMurmur.Runtime.SystemRandom` as the production random contract.
Generate a 53-bit half-open unit sample directly from the Erlang cryptographic
entropy source. Accept at most 256 proper weighted entries, reject malformed or
negative weights, return `:empty` for zero total weight, and normalize positive
weights before selection to avoid overflowing the sampling interval. The
adapter chooses only among values supplied by already validated application
policy; it does not select actions, tools, endpoints, or facts.

Keep both modules dependency-free and deployment-neutral. Runtime assembly
remains separate and must inject these implementations explicitly.

## Consequences

Later standalone assembly has fixed production implementations for every
existing time and random callback while tests can continue to inject exact
fakes. Random samples do not depend on process-local pseudo-random state, and
malformed direct calls fail closed. This change starts no worker and performs
no network or deployment action.
