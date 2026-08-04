# ADR 0013: Use Portable ASCII Configuration IDs

## Status

Accepted.

## Context

Configuration IDs become reference keys, persistence keys, and structured log
fields. Unrestricted Unicode permits canonically equivalent byte sequences,
bidirectional controls, zero-width characters, and visually empty identifiers.
Those values make duplicate detection, review, and incident correlation
ambiguous even when display text remains valid Unicode.

## Decision

Require machine-readable configuration IDs to start with an ASCII letter or
digit and contain only ASCII letters, digits, `.`, `_`, and `-`. Keep
human-facing Unicode text in fields such as `display_name` and prompt content.

## Consequences

ID equality is byte-stable across YAML parsing, persistence, logs, and external
tools without Unicode normalization or confusable-character policy. Operators
cannot use Unicode or whitespace in IDs and must use a separate display field
when a localized human-readable name is needed.
