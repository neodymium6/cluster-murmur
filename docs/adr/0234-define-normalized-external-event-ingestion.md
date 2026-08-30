# ADR 0234: Define Normalized External Event Ingestion

## Status

Accepted. Amends
[ADR 0002](0002-separate-observation-and-conversation.md),
[ADR 0005](0005-keep-facts-outside-llm.md), and
[ADR 0016](0016-versioned-configuration-manifest.md).

## Context

The fixed observer polling boundary can produce events only from its own
application-derived state transitions. Reviewed adapters for Alertmanager or
other read-only signals need a narrow way to supply an already normalized
event without receiving an observer tool, trigger, persona, prompt, provider,
publisher, endpoint, or credential capability.

Accepting a raw alert schema would couple the core domain to one producer and
move grouping and alert-lifecycle interpretation into Cluster Murmur. Treating
all external signals as observations would also require a second state-tracking
contract before direct firing and resolved events could enter the event
pipeline.

## Decision

Define one provider-neutral external event envelope containing exactly an
idempotency key, type, source, subject, group, severity, canonical UTC
occurrence time, facts, and labels. The envelope represents a direct event:
the reviewed adapter owns source-specific normalization and Cluster Murmur does
not infer Alertmanager or infrastructure semantics from it.

Add an optional version 1 `external_ingestion` manifest mapping. Its `sources`
map is empty by default, which disables later ingestion. Each configured source
has separate allowlists for event types, groups, subjects, fact keys, and label
keys. Referenced groups must already exist in the event-group catalog. Allow at
most 32 sources and 256 unique values per allowlist; portable identifiers are
at most 256 bytes at this boundary.

Require event facts to be flat JSON scalars and labels to be flat string maps.
Reuse the existing bounded event validator for aggregate text, node, numeric,
and storage-UTC validation. Accept only the fixed severities `info`, `warning`,
and `critical`. The idempotency key is a portable identifier of at most 256
bytes and is data for later application-owned identity derivation, not a caller
chosen durable event ID.

This decision defines no HTTP listener, authentication mechanism, secret,
rate limiter, persistence operation, trigger execution, or publication path.
Those capabilities require later independently reviewed boundaries.

## Consequences

Later transport and persistence work can depend on one small, pure contract
without embedding Alertmanager semantics or widening the general Event type.
Existing configurations remain valid and keep ingestion disabled.

The adapter becomes a trusted factual producer for its explicitly allowlisted
source. Authentication, transport security, deterministic identity,
idempotent atomic storage, and dispatch still need to fail closed before this
contract can become externally reachable.
