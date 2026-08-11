# 0206. Refresh cooldowns before polling

Date: 2026-08-11

## Status

Accepted; amends ADR 0137; amended by ADR 0207.

## Context

The poll runtime's reusable starter input contains a cooldown map, but durable
cooldowns advance whenever a starter or responder is published. Retaining the
map supplied when scheduler options were built would eventually select from
stale cooldown facts and could allow a persona to speak again too early.

## Decision

Require the poll cycle's existing narrow cooldown store to implement the
one-persona `fetch/1` boundary in addition to publication-time recording.
After validating every reusable dependency and the cycle instant, restore the
current bounded cooldown snapshot before the first observer call. Replace only
the cycle-local shared cooldown value before constructing starter or
conversation inputs.

Treat snapshot load failures as a stable poll failure and perform no
observation, ingestion, selection, generation, or publication in that cycle.
Do not retain the refreshed value in scheduler state; fetch it again on the
next cycle.

## Consequences

Every poll bases speaker selection on durable cooldowns current at the start of
that cycle. This adds at most 256 narrow local store reads before observation
and fails closed when the database cannot prove the current selection facts.

Durable event-dispatch cycles apply the corresponding independent refresh from
ADR 0207.
