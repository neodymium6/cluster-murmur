# ADR 0068: Validate Loaded Message Records Centrally

## Status

Accepted.

## Context

Database constraints protect the stored message shape, but later store reads
still cross an adapter boundary. A corrupted, forged, or incorrectly decoded
record must not enter conversation history or become a publication capability.

## Decision

Add one fail-closed validator for exact loaded `MessageRecord` structs. Require
the expected Ecto metadata, a positive signed 64-bit SQLite surrogate ID, the
complete fixed record shape, six-digit loaded UTC precision, and a runtime
message projection that passes the shared message validator. Return only the stable
`invalid_message_record` classification.

Do not query storage, publish messages, update publication IDs, assemble prompt
history, or log record values in this boundary.

## Consequences

Every later message-store read can share the same exact validation and reject
untrusted loaded state without exposing content or identifiers. Persistence
creation remains separate because built records deliberately fail this loaded
record boundary.
