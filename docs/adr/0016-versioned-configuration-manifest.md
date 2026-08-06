# ADR 0016: Use a Closed, Versioned Configuration Manifest

## Status

Accepted. The version 1 top-level field set is amended by ADR 0116 to require
the closed `llm` mapping in addition to `version` and `includes`.

## Context

The top-level configuration document determines which files enter each later
validation pipeline. Permissive fields or categories can silently ignore
misspellings, blur ownership between schemas, or let callers evade include
limits by resolving each category independently.

## Decision

Require the top-level manifest to contain exactly `version`, `llm`, and
`includes`. Version 1 requires the five include categories `event_groups`,
`personas`, `bindings`, `triggers`, and `routing`, and rejects every other
category. Each category is a proper list of string patterns. Categories must be
present but may be empty so later assembly can apply category-specific
requirements. ADR 0116 defines the closed `llm` mapping.

Bound the sum of patterns across all categories to 64. Preserve pattern order
and duplicates in the validated manifest; bounded include resolution remains
responsible for path grammar, matching, canonicalization, and file deduplication.
Return only stable error atoms without rejected field names or values.

## Consequences

Typos and unsupported extensions fail before filesystem traversal, and callers
cannot multiply the include-pattern budget by resolving categories separately.
Adding a manifest field or include category requires a configuration-version
decision. Later loaders still need to require content for categories that are
mandatory at startup.
