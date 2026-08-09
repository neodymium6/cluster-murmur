# 0176. Persist recurring schedule state separately

Date: 2026-08-09

## Status

Accepted

## Context

Validated cron schedule triggers can calculate their next UTC instant but have
no restart-safe due state. Reusing stochastic schedule storage would mix cron
facts with random sampling and daily-limit fields, weakening both contracts.

## Decision

Add a dedicated `schedule_states` table and redacted Ecto representation. Store
one portable trigger ID, exact next and optional previous UTC runs, and either
no claim or one complete opaque claim triple. Require the next run to remain
strictly after the previous run. Index deterministic due order and claim expiry.

Keep the table inert in this change. Do not calculate time, claim work, emit an
event, expose repository access, or share state with stochastic triggers.

## Consequences

Later fixed stores can restore, enumerate, and lease cron schedules without
conflating their deterministic recurrence with stochastic policy.
