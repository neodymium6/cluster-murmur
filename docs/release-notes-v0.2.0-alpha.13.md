# Cluster Murmur v0.2.0-alpha.13

This release adds a supported authenticated path for reviewed sidecar adapters
to submit normalized external events. Those events enter the existing durable
trigger and conversation pipeline without giving callers direct control over
prompts, personas, tools, routing, or publication. It remains an alpha rather
than a production-support commitment or authorization to connect the software
to sensitive systems.

## Normalized event boundary

- The runtime may expose one fixed `POST /v1/events` route on IPv4 loopback,
  separate from its value-free health listener.
- A mounted Bearer secret authenticates requests before their body is read.
- Exact JSON decoding, source-scoped allowlists, and fixed header, body, input
  deadline, connection, and request-rate limits reject unbounded input.
- The provider-neutral envelope contains only an idempotency key, event type,
  source, subject, group, severity, UTC occurrence time, flat scalar facts, and
  flat string labels.

## Durable and bounded execution

- Application-derived event identity combines the configured source and
  idempotency key. Exact retries return the existing accepted result, while
  changed content under the same identity fails as a conflict.
- Each accepted event and its dispatch record are committed atomically before
  trigger evaluation. Storage failures do not become false retry conflicts.
- External events use the existing trigger matching, deduplication, cooldown,
  binding, generation, conversation-budget, no-reply, and publication controls.
  An ingestion request cannot start a conversation directly.
- Structured logs retain only fixed outcomes, stable error classes, and the
  application-derived hashed identity after acceptance; request bodies, facts,
  credentials, and source idempotency keys are excluded.

## Adapter operations

- Remote senders require a separately reviewed TLS-terminating adapter in the
  same Pod or equivalent trusted network namespace. Cluster Murmur's ingestion
  listener remains loopback-only and must not be exposed directly.
- The Kubernetes documentation includes a non-deployable sidecar patch with
  fake image and Secret placeholders. Source-specific alert interpretation and
  firing or resolved decisions remain adapter responsibilities.
- An isolated end-to-end test covers authenticated HTTP input, atomic dispatch,
  idempotent retries, trigger matching, publication, and durable cooldown
  preservation without contacting live infrastructure or Discord.

## Release artifacts

The release contains one digest-addressed `linux/amd64` OCI image with at most
20 layers, an SPDX SBOM, checksums, release metadata, and signed provenance and
SBOM attestations. No mutable version or `latest` image tag is published.

A version-matching tag runs the full repository gate and creates a draft
prerelease. Publishing that reviewed draft starts a separate public distribution
smoke workflow that verifies assets, checksums, metadata, image identity, and
attestations.

## Deployment boundary

The repository contains no live credentials, private endpoints, real
configuration, deployable overlays, or authorization to contact infrastructure,
a model provider, or Discord. Review the exact immutable image digest,
configuration, mounted secrets, adapter, network policy, storage, backup,
migration, rollback, probes, telemetry, and rollout settings before deployment.

See the [configuration reference](configuration.md),
[deployment and artifact guide](deployment.md),
[MVP runtime contract](mvp-contract.md), and [security policy](../SECURITY.md)
before evaluating a deployment.
