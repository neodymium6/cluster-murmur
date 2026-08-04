# ADR 0030: Validate Schedule Triggers with Embedded Timezones

## Status

Accepted.

## Context

The configuration boundary accepts event triggers but rejects the documented
schedule variant. Schedule validation needs portable cron semantics and real
IANA timezone validation without depending on host files or making network
requests during startup. It must remain separate from runtime scheduling and
event execution.

## Decision

Accept schedule triggers alongside event triggers in the shared bounded trigger
namespace. Require a standard five-field cron expression, an IANA timezone, and
an `emit_event` action containing bounded portable type, group, and subject IDs.
Reject seconds, year fields, cron aliases, malformed expressions, unknown
timezones, unknown fields, duplicate IDs, and collections above 256 triggers.
Require either day-of-month or day-of-week to be the unrestricted wildcard so
the accepted grammar does not depend on incompatible OR and AND semantics.

Parse cron expressions into application domain values with `crontab`. Validate
timezone names and links against the IANA snapshot embedded by
`time_zone_info`, configured with runtime updates disabled. Do not consult host
zoneinfo or initiate downloads during configuration parsing. Resolve emitted
event groups during complete configuration assembly. Redact normalized schedule
and emitted-event values from generic inspection.

Do not execute schedules, calculate next runs, emit events, persist scheduler
state, or add arbitrary expression capabilities in this boundary.

## Consequences

Invalid schedules now fail before external connections, while accepted values
have deterministic cron and timezone semantics across supported hosts. Updating
timezone rules requires a reviewed dependency and release update. Runtime
scheduling and durable execution remain separate future work.
