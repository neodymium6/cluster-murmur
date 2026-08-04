# ADR 0015: Bound YAML Document Decoding

## Status

Accepted.

## Context

Configuration documents are operator-controlled but potentially sensitive.
Unrestricted YAML supports aliases and rich scalar types that can amplify a
small input, obscure its meaning, or produce values outside the public
configuration model. Parsing failures must not echo paths or document content.

## Decision

Decode configuration with yamerl's YAML 1.2 Core Schema and detailed node
representation. Require exactly one document with a mapping at its root and
string keys at every level. Convert only strings, nulls, booleans, integers,
finite floats, sequences, and mappings to ordinary Elixir values. Reject
duplicate keys, anchors, aliases, tag directives, YAML versions other than 1.2,
binary values, and non-finite floats.

Read at most 256 KiB from each file. Before constructing nodes, reject streams
with more than 4,096 nodes, collection nesting deeper than 16 levels, or an
individual scalar larger than 16 KiB. Return stable error atoms without source
paths, parser diagnostics, or input excerpts.

The include resolver's trusted, read-only configuration-tree requirement
continues through file reading. Decoding does not make a writable tree safe
against path replacement between resolution and opening a file.

## Consequences

Configuration loading has deterministic resource ceilings and a smaller YAML
surface than general-purpose YAML tooling. Operators cannot use aliases,
application-specific tags, binary scalars, multiple documents, or non-string
mapping keys. Large prompt text must remain in separately bounded prompt files
rather than YAML scalars.
