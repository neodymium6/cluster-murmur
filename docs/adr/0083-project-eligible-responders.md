# ADR 0083: Project Eligible Responders

## Status

Accepted.

## Context

Responder selection must enforce conversation convergence and continuity before
any reply probability or random choice. Hidden storage, clock, or prompt access
inside eligibility would make that policy difficult to replay and audit.

## Decision

Add a pure responder projector that revalidates one binding, bounded persona
and loaded cooldown snapshots, the runtime conversation, its configured budget,
an injected UTC instant, and an exact two-flag continuity policy.

Require a validated previous message. Exclude disabled personas, active
cooldowns, candidates with zero event-group interest, disallowed consecutive
speakers, disallowed returning participants, and new participants when no slot
remains. Existing participants remain eligible at a full participant limit when
continuity policy permits them. Return no candidates when a core conversation
budget is closed.

Project stable redacted binding, event-interest, reserved relationship, and
reply-weight components. Relationship weight is zero while version 1 persona
relationships remain reserved and empty. Reject a combined configured weight
outside the shared finite non-negative boundary. Do not gate reply probability,
add `no_reply`, apply novelty or recent-speaker penalties, or sample here.

## Consequences

Responder eligibility is deterministic and separated from expression and
randomness. The next selection stages can add an explicit no-reply path and
bounded dynamic weight adjustments without reopening configuration, cooldown,
or continuity decisions.
