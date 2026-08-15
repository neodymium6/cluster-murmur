# ADR 0230: Separate Presentation Time from Canonical Time

## Status

Accepted.

## Context

Events use canonical UTC timestamps for persistence, ordering, deduplication,
and deterministic identity. Schedule triggers interpret cron expressions in
their own IANA timezones and then return the selected instant to UTC. Generation
previously serialized that UTC value directly, so an operator could not choose
the local time representation spoken by personas. Reusing a schedule timezone
would not cover stochastic or observed events and would couple trigger
semantics to presentation.

## Decision

Add one optional deployment-wide `presentation.timezone` setting to the version
1 manifest. Validate it against the embedded IANA timezone database at startup
and default it to `Etc/UTC` for backwards-compatible operation.

Keep the canonical event timestamp unchanged throughout event validation,
persistence, ordering, deduplication, and trigger identity. Carry the selected
presentation timezone in the redacted generation fact projection. At the final
prompt projection boundary, shift the canonical instant with the embedded
timezone database and serialize an ISO 8601 offset timestamp together with the
IANA name in `occurred_at_timezone`.

Reconstruct and revalidate both values at the provider transport boundary. A
supplied offset must therefore match the configured IANA zone at that exact
instant, including daylight-saving transitions.

## Consequences

All schedule, stochastic, and observed events use one consistent prompt-facing
timezone without changing their domain identity. Existing configurations keep
UTC presentation. Operators can choose a local civil-time representation, and
the explicit IANA name preserves meaning that an offset alone cannot express.

The setting is deployment-wide rather than persona- or trigger-specific. More
granular localization would require a separate decision and must continue to
leave canonical event time untouched.
