# ADR 0020: Compose Personas With Bounded Prompt Loading

## Status

Accepted.

## Context

Persona configuration combines machine-readable selection values with prompt
text referenced from another file. Validation must close the YAML structure,
bound the combined namespace, and load prompts without exposing their contents
or allowing persona documents to grant new capabilities.

## Decision

Validate each version 1 persona document with an application-owned Draft 7
schema, then apply shared ID, weight, and duration validators in Elixir. Require
`id`, `display_name`, and `prompt_file`; default `enabled` to true and optional
maps to empty. Limit display names to 128 UTF-8 bytes, HTTPS avatar URLs to
2,048 bytes, interests to 256 entries per persona, and the combined namespace
to 256 personas. Reject duplicate persona IDs across files.

Read prompt text only through the bounded prompt-file boundary and retain it in
a redacted immutable persona value. Persona interests remain unresolved group
IDs until full configuration assembly. Non-empty `relationships` and
`metadata` are reserved until their version 1 semantics are specified; reject
them rather than accepting data the runtime cannot interpret.

Compile the schema once per category parse, process personas in deterministic
ID order, and return stable value-free errors. Prompt failures preserve only a
safe category and reason atom.

## Consequences

Later binding and conversation code receives normalized persona data and
bounded prompt text. Configuration can be split across files without enabling
overrides. Cross-category references still require a later assembly stage, and
future relationship or metadata shapes require an explicit contract change.
