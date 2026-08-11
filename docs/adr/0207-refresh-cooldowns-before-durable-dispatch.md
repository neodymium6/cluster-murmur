# 0207. Refresh cooldowns before durable dispatch

Date: 2026-08-11

## Status

Accepted; amends ADR 0206.

## Context

A durable event can remain queued while starter or responder publication
advances a persona cooldown. The event-dispatch scheduler retains reusable
starter settings, so using their original cooldown map would make delayed
events select speakers from stale facts.

The durable path also lists and claims an outbox. A cooldown storage failure
must not allow those mutations to begin when current speaker eligibility
cannot be proven.

## Decision

After validating the complete runtime and cycle instant, restore the bounded
cooldown snapshot through the existing one-persona `fetch/1` store boundary.
Replace only the cycle-local shared cooldown value before listing outbox
candidates. Build both starter-only and bounded-conversation consumer inputs
from that refreshed value.

Map snapshot failures to the stable event-dispatch failure and perform no
outbox listing, event loading, claim, authorization, generation, or
publication. Do not retain the snapshot in scheduler state; restore it again
for every cycle.

## Consequences

Each durable dispatch cycle performs at most 256 stable-order local cooldown
reads, including cycles with no available events. In exchange, every claimed
event uses speaker eligibility current before the outbox batch begins, and
storage uncertainty fails before any outbox mutation.
