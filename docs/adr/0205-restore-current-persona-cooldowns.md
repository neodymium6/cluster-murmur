# 0205. Restore current persona cooldowns

Date: 2026-08-11

## Status

Accepted

## Context

Starter and responder selection consume a bounded persona cooldown map. The
existing opt-in runtime tests inject that snapshot, but standalone option
assembly cannot safely substitute an empty map: doing so would ignore durable
cooldowns after restart and could select a persona again too early.

The persistence boundary intentionally exposes only one-persona `fetch/1`, not
an arbitrary or unbounded list operation.

## Decision

Add a narrow loader that accepts one complete validated configuration and one
fixed cooldown store. Validate both dependencies before persistence access,
then fetch every configured persona exactly once in sorted ID order. The
configuration already bounds the catalog to 256 personas.

Omit absent records. Require every returned record to be an exact validated
loaded cooldown whose ID matches the requested configured persona. Return only
the bounded cooldown map or stable invalid-input and load-failure classes.

Do not list unrelated rows, read a clock, select a speaker, mutate a cooldown,
or expose store diagnostics.

## Consequences

Standalone runtime construction has a bounded way to recover durable cooldown
facts without adding generic repository access. A storage error or malformed
record fails the snapshot rather than silently treating the persona as
available.

Schedulers must refresh this snapshot for new work rather than retain one
startup copy indefinitely. Integrating that refresh into each event-producing
cycle remains a separate reviewed change.
