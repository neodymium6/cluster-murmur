# ADR 0026: Assemble a Complete Startup Configuration

## Status

Accepted.

## Context

The character catalog, event triggers, and default routing destination can be
validated independently, but runtime construction needs one value that proves
all implemented categories and cross-category references are valid. Replacing
the existing partial catalog would remove a useful staged validation boundary.

## Decision

Keep `Catalog` as the event-group, persona, and binding assembly stage. Add a
redacted `Configuration` value that contains the flattened catalog categories,
event triggers, and default routing. Parse every category before requiring each
event trigger's binding ID to exist in the assembled binding namespace.

Expose the complete boundary as `Loader.load_configuration/1`. Preserve stable,
value-free errors annotated by the failing catalog, trigger, routing, or final
reference stage. Do not read routing secrets or connect to any external system
during configuration assembly.

## Consequences

Callers can require one complete startup value before constructing observers,
generation providers, persistence, or Discord adapters. Include order cannot
change reference validity, and partial manifest/document/catalog APIs remain
available for focused tooling and diagnostics. Routing secret-file reads and
all live connections remain separate, explicitly authorized runtime steps.
