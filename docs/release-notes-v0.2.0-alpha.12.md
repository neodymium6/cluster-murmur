# Cluster Murmur v0.2.0-alpha.12

This release makes ambient conversations character-driven instead of turning
their internal activation metadata into a status report. It also strengthens
stochastic event timing and active-window recovery. It remains an alpha rather
than a production-support commitment or authorization to connect the software
to sensitive systems.

## Conversation-first ambient dialogue

- Stochastic activation metadata, including the event type, trigger subject,
  routing group, severity, timestamp, and details, no longer enters the model
  request.
- Ambient starters and responders receive fixed application-owned creative
  framing and may produce bounded persona-driven fictional topics, opinions,
  feelings, relationships, disagreement, humor, and metaphor.
- Confirmed operational facts remain authoritative when present, but are
  optional grounding rather than material every message must repeat.
- Stochastic provider failures use a neutral dialogue opener instead of an
  event-report fallback.
- Generation still receives only bounded allowlisted context and cannot claim
  real tool use, credential access, configuration changes, or external side
  effects. Conversation, request, output, and publication limits remain in
  application code.

## Stochastic occurrence time

- The durable sampled schedule instant remains the stable identity used for
  claims, deduplication, and restart recovery.
- A fired stochastic event now records the later validated execution instant as
  `occurred_at`, accurately representing when the occurrence was observed.
- Recurring schedule events retain their scheduled occurrence semantics.

## Active-window recovery

- An overdue stochastic schedule outside its active window is resampled into a
  future eligible window instead of being repeatedly reclaimed and skipped.
- Rescheduling uses an exact conditional claim so concurrent or stale workers
  cannot replace a newer schedule.
- Recovery preserves daily limits and last-occurrence history and handles
  cross-midnight windows, daylight-saving gaps, folds, and restart timing.

## Release artifacts

The release contains one digest-addressed `linux/amd64` OCI image with at most
20 layers, an SPDX SBOM, checksums, release metadata, and signed provenance and
SBOM attestations. No mutable version or `latest` image tag is published.

A reviewed version-matching tag runs the full repository gate and creates a
draft prerelease. Publishing that reviewed draft starts a separate public
distribution smoke workflow that verifies the asset set, checksums, metadata,
image identity, and attestations.

## Deployment boundary

The repository does not contain live credentials, private endpoints, real
configuration, deployable overlays, or authorization to contact infrastructure,
a model provider, or Discord. Before any deployment, review the exact immutable
image digest, configuration, mounted secrets, network policy, storage, backup,
migration, rollback, probes, telemetry, and rollout settings in the operator's
private repository.

See the [configuration reference](configuration.md),
[deployment and artifact guide](deployment.md),
[MVP runtime contract](mvp-contract.md), and [security policy](../SECURITY.md)
before evaluating a deployment.
