# ADR 0067: Persist Message Records

## Status

Accepted. Amended by [ADR 0229](0229-treat-generated-text-as-inert-content.md).

## Context

Typed runtime messages need a durable representation before publication and
conversation history can define narrow stores. Relying only on application
validation would allow direct database writes to create unbounded content,
unknown origins, malformed publication IDs, or messages detached from a
conversation.

## Decision

Add the MVP `messages` table with an integer surrogate key and a redacted Ecto
record. Require a durable conversation reference, portable persona ID, closed
`llm` or `fallback` origin, bounded nonblank content, an optional canonical
nonzero uint64 Discord message ID, and canonical UTC insertion time. Uniquely
index published Discord IDs and index conversation history by insertion time and
surrogate ID.

Construct changesets only from exact messages that pass the complete runtime
validator. Do not add generic repository access, publication, publication-ID
updates, prompt history loading, or retention deletion in this change.

## Consequences

Database constraints preserve the fixed shape, hard scalar bounds, and common
ASCII and Unicode blank-only encodings even for direct writes. Application
validation remains responsible for complete Unicode visible-content semantics,
normalization, and forbidden control-character rejection. Later stores must
translate SQLite foreign-key failures generically and validate loaded records
before returning them.
