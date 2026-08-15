# Runtime operations

This page defines container controls, single-writer storage, startup,
observability, and graceful termination. It is part of the
[deployment and operations guide](../deployment.md).

## Required container controls

A runtime must:

- make the root filesystem read-only;
- drop every Linux capability and disable privilege escalation;
- mount a size-bounded private tmpfs at `/tmp`, owned by `65532:65532`;
- mount private persistent storage at `/var/lib/cluster-murmur`, owned by
  `65532:65532`;
- set `CLUSTER_MURMUR_DATABASE_PATH` to an absolute path below that private
  storage; and
- apply least-privilege network policy for only the reviewed fixed transports.

For Docker-compatible runtimes, the hardening profile includes `--read-only`,
`--cap-drop=ALL`, `--security-opt=no-new-privileges`, and a bounded tmpfs such
as:

```text
--tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m,uid=65532,gid=65532,mode=0700
```

The database bind mount and all remaining runtime settings remain private
deployment inputs.

The [hardened Kubernetes example](../../deploy/kubernetes/README.md) defines the
supported one-replica `Recreate` shape, same-image migration init container,
non-root security context, private volume, bounded temporary storage, probe
configuration, default-deny network policy, and Cluster Observer sidecar
relationship. It contains deliberate placeholders and requires a private
reviewed overlay; it is not directly deployable.

The Kubernetes storage provisioner or private overlay must make the volume root
owned by `65532:65532` with exact mode `0700`. Do not use Pod `fsGroup` for this
volume: its permission widening can violate the repository's exact `0700`
directory and `0600` database-file checks.

## Single-writer rollout, backup, and rollback

Only one application or migration process may use a database volume at a time.
Keep one replica and use replacement rather than rolling overlap. Stop the old
runtime completely before the packaged forward migration runs, then wait for
startup and readiness before admitting dependent work.

Before every upgrade, stop all writers and migrators and take an atomic snapshot
of the complete persistent volume, including SQLite WAL and shared-memory files.
Record the application version, immutable image digest, migration set, snapshot
identity, and time without secrets. Restore into a new volume, validate it with
one isolated Pod and the recorded image, then change the production reference.
Never treat a copy of only the live main database file as a backup.

The release provides forward migrations but no downgrade command. Before a
migration, the old image and configuration can be selected again. After a
schema-incompatible migration, restore the pre-upgrade snapshot into a new
volume before starting the previous digest. Do not point an old image at a newer
schema unless that exact compatibility is documented.

Current event retention deletes only expired unreferenced events. Events still
owned by durable lifecycle records may outlive the configured retention window,
so monitor volume capacity and do not use manual SQL deletion to bypass those
references. Referenced-lifecycle compaction remains explicitly deferred.

## Start the standalone runtime

A production start requires `CLUSTER_MURMUR_CONFIG_PATH` to name the absolute
path of the root public YAML document. The path is UTF-8, NUL-free, and at most
4,096 bytes. Configuration includes and mounted secret-file paths retain their
separate documented bounds. The application fails closed when any startup
input, recovery step, or schedule initialization is invalid.

The deployment must provide:

- the validated public configuration path;
- `CLUSTER_MURMUR_OBSERVER_MCP_URL` set to the reviewed fixed `/mcp` endpoint;
- `CLUSTER_MURMUR_OBSERVER_MCP_TOKEN_FILE` and other mounted credential-file
  references;
- the provider, webhook, scheduler, and responder-timing environment values
  documented in the [configuration reference](../configuration.md);
- `CLUSTER_MURMUR_HEALTH_PORT` for the fixed private operational probe listener;
- orchestrator probe timing, metrics, logging, and restart integration; and
- platform-specific storage, network, and rollout policy.

Before constructing any standalone child, startup initializes the OTP CA
certificate store used by all three fixed HTTPS transports. When
`SSL_CERT_FILE` is set, it must name an absolute, UTF-8, NUL-free regular file
no larger than 4 MiB; startup loads that bundle explicitly and requires the
resulting store to contain at least one certificate. When the variable is
absent, the platform-provided OTP store must already produce at least one
certificate. Missing, unreadable, empty, oversized, or unusable configured
bundles fail startup with a stable error before any scheduler can consume work.

Startup binds the fixed probe listener, then orders the SQLite repository before
one recovery-gated supervisor. That supervisor completes global recovery and
recurring and stochastic schedule initialization before it starts poll,
event-dispatch, recurring, stochastic, and retention schedulers. Application
startup does not run database migrations; apply them first as described above.

Use `GET /startupz` as the startup probe and allow enough failures for bounded
recovery and schedule initialization. After startup succeeds, `GET /livez`
reports only listener liveness and `GET /readyz` reports whether the complete
recovery-gated runtime is currently running. All three successful responses are
fixed `200` values; readiness and startup return `503` while unavailable. The
runtime's monitored readiness lease is released before its schedulers drain
during shutdown or replacement, while the listener remains live during runtime
replacement and stops last during graceful application shutdown.

Do not expose this port through a public Service or ingress. Network policy must
limit it to orchestrator probes. The endpoint contains no metrics or diagnostics
and must not be extended with arbitrary handlers.

## Metrics and operational logs

The runtime emits `[:cluster_murmur, :runtime, :cycle, :stop]` for every poll,
event-dispatch, recurring, stochastic, and retention cycle. The three fixed live
transports emit `[:cluster_murmur, :external, :request, :stop]`. Both events
contain `count: 1` and `duration` in native monotonic time units. Their metadata
is limited to the documented finite `component`, `outcome`, and `error_class`
atoms. Convert durations with `System.convert_time_unit/3` in a trusted metrics
handler.

Cycle components are `poll`, `event_dispatch`, `recurring_schedule`,
`stochastic_schedule`, and `event_retention`; external components are
`observer_mcp`, `model_provider`, and `discord_webhook`. Outcomes are `ok`,
`error`, `rejected`, `not_sent`, and `unknown`. Error classes are absent on
success or are one of `invalid_cycle`, `poll_failed`, `dispatch_failed`,
`retention_failed`, `authentication_failed`, `invalid_request`, `rate_limited`,
`timeout`, `token_exhausted`, `unavailable`, `invalid_response`, and
`outcome_unknown`.

The release also emits `runtime cycle completed` and `external request
completed` through Logger with the same structured fields. Model and Discord
HTTP responses are classified before logging, so a non-success response is not
reported as `ok`. Successful outcomes use `info`; other terminal outcomes use
`warning`. A model response with blank content and a `length` finish reason is
reported as `outcome=error error_class=token_exhausted`; other output rejected
later by normalization retains the provider's `ok` transport outcome. Token
counts, finish reasons, and response bodies are not logged.

Production formats each log as one JSON object per line. The formatter retains
only time, level, the two fixed operational messages, and allowlisted telemetry
metadata. It replaces every other message with `application event` and drops
all other metadata rather than serializing it. No result, request, response,
exception, endpoint, credential, prompt, observation, event, participant, or
message is included. Attach only a reviewed bounded Telemetry exporter; the
health listener deliberately serves no metrics route.

## Graceful termination

Set the orchestrator termination grace period to at least 35 seconds. On normal
shutdown, readiness disappears first. Each scheduler then has its standard
five-second OTP child shutdown window to finish its current callback before it
is killed. The five schedulers stop sequentially in reverse order, so those
windows may consume 25 seconds in total. The repository remains available until
every runtime child has stopped, so an interrupted SQLite transaction rolls
back before the database process exits. The health listener stops last.

Shutdown does not retry a model request or Discord publication. If termination
interrupts internal conversation or trigger work, startup recovery marks that
work failed. If a Discord request may already have crossed the dispatch
boundary, recovery records the durable attempt as ambiguous rather than
publishing again. Operators must preserve the database and allow recovery to
complete before considering the replacement ready.

These inputs must not introduce generic shell, SSH, `kubectl`, SQL, arbitrary
PromQL, or arbitrary HTTP passthrough capabilities. See the
[public alpha boundary](../public-alpha.md) and [security policy](../../SECURITY.md)
before approving deployment configuration and rollout.

The shipped observer transport accepts plain HTTP only for an explicitly
configured loopback sidecar. Remote observer endpoints require HTTPS with
operating-system CA and hostname verification. It makes one request per
connection and does not follow redirects, retry, use deployment proxy settings,
or retain response bodies after bounded decoding.

The shipped OpenAI-compatible transport similarly opens one verified,
deadline-bounded request per connection and accepts only the request derived
from the configured provider settings and application-assembled prompt. Prefer
HTTPS for provider endpoints; plain HTTP remains the existing explicit
operator-owned choice for isolated local or private providers. The transport
does not follow redirects, retry, use deployment proxy settings, or retain raw
responses after bounded decoding.
