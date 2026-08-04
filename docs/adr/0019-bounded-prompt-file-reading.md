# ADR 0019: Read Persona Prompts Through a Bounded File Boundary

## Status

Accepted.

## Context

Persona documents refer to prompt material stored separately from YAML. An
unrestricted reference could read outside the selected configuration tree,
follow an unsafe symlink, load an unbounded file, or pass non-text data into a
later model request. Prompt contents and deployment paths may be sensitive.

## Decision

Resolve prompt references relative to the canonical path of the persona source
document. Accept only non-empty, portable ASCII relative paths of at most 512
bytes. Parent components are allowed because persona files commonly refer to a
sibling `prompts` directory, but the canonical target must remain inside the
canonical configuration root and every canonical path component must use the
portable filename grammar.

Share the include resolver's component-by-component canonicalization and limit
each path to 40 symlink expansions. Require a regular target file, read at most
64 KiB plus one detection byte, reject empty or invalid UTF-8 content, and
return only stable error atoms without paths or contents. The configuration
tree remains trusted and read-only from include resolution until prompt reads
finish; path-only checks do not eliminate replacement races in a writable tree.

## Consequences

Persona validation can load prompt text without adding arbitrary file access or
exposing rejected content. Portable relative references can traverse between
directories inside one configuration tree, and safe projected-volume symlinks
continue to work. Larger prompts, binary prompts, Unicode filenames, and prompt
files outside the selected root are unsupported in version 1.
