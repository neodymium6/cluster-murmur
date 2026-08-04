# ADR 0017: Keep Configuration Schema Validation Local and Value-Free

## Status

Accepted.

## Context

Category documents require structural validation before Elixir resolves IDs
and references. JSON Schema libraries can return rejected values and document
paths in detailed errors, and some can resolve `$ref` targets through the
filesystem or network. Those behaviors would weaken safe error handling and
the prohibition on arbitrary passthrough capabilities.

## Decision

Use application-owned JSON Schema Draft 7 maps for version 1 category
structure. Compile them through a small adapter around `ex_json_schema`. Reject
all schema `$ref` keywords and reference-rebasing `id` or `$id` keywords before
the library resolves the schema. Even a local reference could reinterpret an
annotation value as an executable schema, so version 1 schemas duplicate small
definitions instead. Schemas are trusted source code, not operator input, and
callers compile each schema once before using it for multiple documents.
Bind an inert validator for unknown `format` values when compiling so global
library configuration cannot receive document values through a callback.
Reject the `contentEncoding` and `contentMediaType` keywords because the
dependency exposes content decoding only through another global callback.
Inspect child schemas according to their Draft 7 positions rather than treating
keyword-shaped property names as annotations; ordinary properties such as
`default` remain supported and cannot hide a nested unsafe schema.

Validate only values already accepted by the bounded YAML decoder. Collapse
all instance validation details to `:schema_violation`, and redact compiled
schemas from normal inspection. Keep semantic ID, reference, and cross-file
validation in Elixir after this structural stage.

Before compilation, require the complete schema tree, including annotations,
to contain only JSON-compatible values and string map keys. Before each
validation, verify that the compiled root still contains the expected Draft 7
schema, no resolved references, the root location, and the adapter's inert
format callback. Re-resolve that schema and require the canonical root to match,
which rechecks the Draft 7 meta-schema and normalization. This rejects manually
constructed or modified compiled structs before document values reach the
dependency.

## Consequences

Schema validation cannot read files, contact endpoints, delegate unknown
formats, or decode embedded content, and rejected configuration content does
not cross the adapter boundary. Draft 7 is older than later JSON Schema drafts
but covers the closed version 1 structures and has a pure-Elixir
implementation. A future draft change requires a new configuration-version and
dependency decision.
