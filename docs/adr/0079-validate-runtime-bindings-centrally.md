# ADR 0079: Validate Runtime Bindings Centrally

## Status

Accepted.

## Context

Speaker selection consumes configured bindings after startup. Without a shared
runtime boundary, forged binding structs, improper or oversized candidate
lists, duplicate personas, and invalid numeric weights could reach later
selection code.

## Decision

Add one fail-closed validator for the exact version 1 `Binding` shape. Require
bounded portable binding and group IDs and one through 256 exact candidate maps.
Each candidate contains only a portable persona ID and a finite non-negative
weight, and persona IDs are unique within the binding.

Run each newly parsed binding through the validator before adding it to the
configuration collection. Preserve stable value-free errors and redacted
binding inspection.

## Consequences

Later starter and responder selection can revalidate complete binding
capabilities consistently. Configuration and runtime consumers share candidate
count, identity, uniqueness, and numeric boundaries.
