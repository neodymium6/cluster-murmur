# ADR 0046: Validate Bounded Events Centrally

## Status

Accepted.

## Context

Events will cross matching, persistence, trigger, and generation boundaries.
The event struct is redacted from inspection, but forged or adapter-supplied
values could still contain unbounded collections, deeply nested data,
non-canonical timestamps, or values that cannot be represented safely as JSON.
Shallow validation in each consumer would produce inconsistent limits.

## Decision

Add one pure event validator and require matcher evaluation to use it. Require
non-empty bounded UTF-8 event identifiers without NUL bytes, canonical UTC
occurrence and optional observation instants in storage-supported years, map
shapes for facts and labels, and JSON-compatible previous, current, fact, and
label values.

Bound every collection to 256 entries, nesting to 8 levels, map keys to 512
bytes, individual strings to 16 KiB, the complete payload and identifiers to 64
KiB, and traversed nodes to 1,024. Restrict integers to the interoperable JSON
safe range and reject non-finite floats, structs, atoms, non-string map keys,
improper lists, invalid UTF-8, and embedded NUL bytes. Return only the stable
`:invalid_event` classification.

Do not extract facts, persist events, perform matching, construct prompts, log
payloads, or call external systems in this validation boundary.

## Consequences

Downstream event consumers can share one deterministic resource and shape
contract before inspecting potentially sensitive payloads. A later event store
can mirror these bounds at its persistence boundary without accepting a broader
domain than matching. Observation normalization and event construction still
require their own reviewed boundaries.
