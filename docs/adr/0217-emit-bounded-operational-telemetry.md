# 0217. Emit bounded operational telemetry

Date: 2026-08-11

## Status

Accepted; model token-exhaustion classification amended by
[ADR 0225](0225-classify-reasoning-token-exhaustion.md).

## Context

The standalone runtime now has fixed probes and graceful lifecycle behavior,
but operators cannot measure scheduler work or distinguish bounded external
outcomes without inspecting process state. Logging complete results would leak
observation, conversation, endpoint, or provider data and create uncontrolled
cardinality. Adding a generic diagnostics interface would weaken the product
boundary.

## Decision

Emit two fixed Telemetry stop events: one for the five runtime scheduler cycle
types and one for the three live external transports. Each event contains only
one native monotonic duration, a count of one, and application-owned finite
metadata dimensions for component, outcome, and stable error class. Validate
every dimension before emission and silently discard caller-selected event
names, metadata values, malformed results, and invalid timing values.

Emit a fixed structured Logger entry beside every accepted event. Normalize
bounded model and Discord HTTP responses before choosing an outcome; receiving
a non-success response is not a successful provider or publication outcome.
Use `info` for successful work and `warning` for other terminal outcomes. Keep
both messages constant and attach only the same finite metadata dimensions.
Never log a cycle result, request, response, exception, endpoint, credential,
prompt, observation, event, participant, or message. Telemetry or logging
failure must not change a runtime or transport result.

Format every production Logger event as one JSON object per line. The formatter
allowlists the timestamp, level, two fixed operational messages, and the finite
telemetry metadata values. It replaces arbitrary messages with `application
event` and drops all other metadata instead of serializing it. Formatter failure
returns one fixed JSON error object without inspecting the rejected value.

The events are measurement boundaries, not a generic exporter. Export and
retention policy remain deployment concerns, and an exporter must consume only
the documented event measurements and metadata. Do not add arbitrary event
names, user-selected tags, a metrics route to the fixed probe listener, or
dynamic logging callbacks.

## Consequences

Operators can derive bounded cycle and external request counts, outcome counts,
error counts, and duration distributions through a standard Telemetry handler.
The default release also emits immediately usable JSON lifecycle logs. Metric
dimensions have fixed cardinality and logs are independent of sensitive domain
values.

Successful cycles and requests produce logs, so volume follows the already
bounded scheduler cadence and conversation limits. A later exporter decision
may add a fixed private metrics surface without changing these event contracts.
