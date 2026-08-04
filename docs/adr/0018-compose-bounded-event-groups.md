# ADR 0018: Compose Event Groups Through a Bounded Semantic Stage

## Status

Accepted.

## Context

The manifest can include more than one file for a category. Structural schema
validation can close each document and constrain individual values, but it
cannot detect duplicate IDs between files or bound the combined configuration.
Returning detailed schema errors or source paths would also expose operator
configuration.

## Decision

Make event groups the first version 1 category implemented on top of the local
schema boundary. Require every event-group document to contain exactly one
`event_groups` mapping. Each group has a portable ID and exactly one
`reply_probability` in the inclusive range from zero to one.

Compile the application-owned schema once per category parse and reuse it for
every included document. After structural validation, apply the shared scalar
validators again while combining documents in deterministic ID order. Reject
duplicate IDs across files and limit the combined category to 256 groups.
Empty category lists and empty mappings remain valid; this stage does not
silently synthesize documented example groups.

Return a redacted event-group set and stable, value-free error atoms. Do not
include source paths, IDs, probabilities, or dependency error details in
validation failures.

## Consequences

Later configuration assembly can consume one normalized event-group namespace
and resolve trigger and route references against it. Operators can split that
namespace across files without changing semantics, but cannot override a group
by declaring it twice. Other categories remain unvalidated until their own
schema and semantic stages are added.
