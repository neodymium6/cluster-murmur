# ADR 0121: Load State Tracking at Startup

## Context

The normalized state-tracking value exists independently, but observation
workers must receive the same validated debounce policy after every restart.
Leaving it outside the complete startup configuration would invite runtime
defaults or direct decoded-map access in later orchestration.

## Decision

Allow one optional `state_tracking` mapping in the version 1 top-level
manifest. Absence selects the fixed two-failure and two-success default;
presence must pass the exact normalized boundary. Carry the resulting value
through the manifest and complete public configuration, and revalidate it
before runtime settings or workers can be constructed.

The remaining `version`, `llm`, and `includes` fields stay required, and every
other top-level field remains invalid. This step reads no observations and
starts no worker or external connection.

## Consequences

Later observation orchestration can project one startup-owned debounce policy
without choosing defaults itself. Existing version 1 manifests retain the
documented fixed behavior when the optional field is absent. Per-source and
per-subject overrides remain a separate configuration decision.
