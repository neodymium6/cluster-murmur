# ADR 0022: Resolve Binding References After Category Parsing

## Status

Accepted.

## Context

Event groups, personas, and bindings form related namespaces, but their files
are discovered and parsed independently. Resolving a binding while reading its
file would make validity depend on include order and would blur structural,
semantic, and cross-category validation errors.

## Decision

Assemble the three implemented categories into a redacted version 1 catalog.
Parse every category completely before resolving references. Then require each
binding group to exist in the event-group namespace and every binding candidate
to exist in the persona namespace. Disabled personas remain valid references
and are filtered only during runtime selection.

Keep persona `interests` unresolved because version 1 has not yet defined them
as event-group references. Return stable reference errors without the missing
ID, source path, or configuration value. Expose this partial stage as
`Loader.load_catalog/1`; trigger and routing validation remain later stages.

## Consequences

Include order cannot change binding validity, and downstream trigger work can
consume a single validated character catalog. The catalog is not yet complete
startup configuration: triggers and routing must still be parsed and assembled
before external connections are allowed.
