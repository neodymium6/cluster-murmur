# Runtime operations

This page defines scheduler, responder, probe, and secret settings. It is part
of the normative [configuration reference](../configuration.md).

## Runtime scheduler settings

The standalone runtime requires five explicit, non-secret scheduler intervals:

- `CLUSTER_MURMUR_POLL_INTERVAL`;
- `CLUSTER_MURMUR_EVENT_DISPATCH_INTERVAL`;
- `CLUSTER_MURMUR_RECURRING_INTERVAL`;
- `CLUSTER_MURMUR_STOCHASTIC_INTERVAL`; and
- `CLUSTER_MURMUR_EVENT_RETENTION_INTERVAL`.

Each value uses the same exact duration syntax as public configuration, such as
`30s`, `5m`, or `1h`. Poll, dispatch, recurring, and stochastic intervals must
be at least one second. Event retention must be at least one minute. All values
must remain within the shared maximum runtime interval. Missing, malformed,
oversized, or out-of-range values fail startup before a clock, store, external
service, or scheduler is used.

## Runtime responder schedule settings

Standalone conversation assembly requires four additional non-secret timing
values:

- `CLUSTER_MURMUR_RESPONDER_TURN_INTERVAL`;
- `CLUSTER_MURMUR_RESPONDER_GENERATION_DELAY`;
- `CLUSTER_MURMUR_RESPONDER_PUBLICATION_START_DELAY`; and
- `CLUSTER_MURMUR_RESPONDER_PUBLICATION_COMPLETE_DELAY`.

The turn interval must be at least one second. Delays are relative to each
planned responder turn and must be ordered from generation through publication
completion. Completion must not exceed the turn interval, which keeps adjacent
planned turns non-overlapping. All four values use the public duration syntax,
are bounded by the shared maximum runtime interval, and fail startup when
missing or invalid. They define planned timestamps; loading them does not wait,
start a conversation, or contact an external service.

Standalone assembly derives a finite responder schedule from these timings and
the versioned conversation defaults. The starter counts toward `max_turns`, so
the schedule normally contains `max_turns - 1` responder steps. A one-turn
conversation retains one non-effectful terminalization step for shared runtime
validation. Standalone assembly accepts at most 257 total turns, because the
runner permits at most 256 responder steps, and rejects schedules whose
relative offsets exceed the shared runtime interval or whose generation or
publication start would reach the conversation deadline. Schedule construction
is pure: it does not wait, read a clock, call a transport, or start a worker.

## Operational probe settings

The production application requires `CLUSTER_MURMUR_HEALTH_PORT` to contain one
base-10 TCP port from 1 through 65,535. No bind address, path, handler, response,
or probe timeout is deployment-selectable. The application listens on all IPv4
container interfaces for exactly `GET /livez`, `GET /readyz`, and `GET
/startupz` HTTP/1.1 requests. It accepts one bounded request per connection and
returns only fixed value-free text.

Liveness succeeds while the fixed probe listener is running. Readiness and
startup succeed only while the production readiness service holds the runtime's
monitored lease, acquired after the repository, recovery, both schedule
initializers, and all five schedulers have started. The lease is the final
runtime child and is released before remaining schedulers drain during runtime
replacement or graceful shutdown. Liveness remains available during runtime
replacement and the listener stops last. These signals do not test external
providers or observed infrastructure and expose no diagnostic information.

The probe port is an inbound interface but not a public service. Deployment
network policy must restrict it to the orchestrator. Do not route it through a
public Service or ingress.

## Secret handling

Public configuration may contain only environment-variable names and fake,
portable examples. The following values belong in mounted secret files or the
operator's private deployment repository:

- Discord webhook URLs;
- LLM API keys;
- MCP credentials;
- private endpoints and concrete source inventories;
- private persona prompts; and
- environment-specific channel routing.

Secret readers must impose file-size limits, reject empty values, avoid
following unsafe references, and never include file contents or resolved paths
in logs or validation errors. The shared mounted-secret reader accepts only an
absolute path from a validated named environment variable and a regular-file
target, reads at most 16 KiB, and returns a trimmed non-empty UTF-8 value.
Projected-volume symlinks are allowed when their final target is a regular
file. Secret-specific settings validate the returned opaque value before use.
