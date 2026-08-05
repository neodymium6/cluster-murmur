# ADR 0086: Validate Prompt Fact Projections

## Status

Accepted.

## Context

Generation must receive application-confirmed facts without implicitly exposing
event identity, routing metadata, labels, deduplication keys, or correlation
values. A valid event's text budget also does not by itself bound expansion when
control characters are JSON escaped.

## Decision

Add a redacted generation fact projection with exactly event type, subject,
group, severity, previous state, current state, application details, and the
occurred-at instant. Project only from a fully validated event. Deliberately omit
event ID, source, observed-at metadata, labels, deduplication key, and
correlation key.

Revalidate every projected scalar and nested JSON value through the bounded
event payload contract. Convert projections to one fixed string-keyed
prompt-data map, then apply the shared depth, collection, and node limits to that
actual outer tree. Calculate its UTF-8 JSON representation size, including
quotes, separators, and control-character escaping, and reject values above 64
KiB without constructing an unbounded encoded buffer.

## Consequences

Later prompt assembly receives a fixed fact-only data capability rather than a
complete event. Sensitive routing metadata cannot enter prompts accidentally,
and JSON escaping cannot expand an otherwise valid event beyond the generation
boundary.
