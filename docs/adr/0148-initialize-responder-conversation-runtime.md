# ADR 0148: Initialize Responder Conversation Runtime

## Status

Accepted.

## Context

A published starter continuation contains the durable facts needed to begin
responder orchestration, while versioned configuration now contains its
immutable budget and continuity policy. Runtime assembly must not reconstruct
these capabilities ad hoc or accept policy from deployment-specific input.

## Decision

Add a pure initializer that validates the exact starter continuation against
the original cooldown snapshot, current configuration, and webhook settings.
Project its published starter message into the first bounded runtime history,
prune cooldowns to configured personas, insert the proven starter cooldown,
and derive budget, responder policy, and no-reply weight only from normalized
conversation defaults.

Require a non-empty responder turn schedule whose first planning instant is not
before the starter publication completion. Return the exact input accepted by
the bounded responder conversation runner without selecting a persona,
mutating persistence, or invoking either external transport.

## Consequences

The starter and responder vertical slices now share one explicit, validated
capability handoff. Deployment assembly supplies clocks and transports through
the already bounded turn schedule, but cannot replace application-owned
conversation policy or message history.
