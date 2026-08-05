# ADR 0063: Start Conversations Atomically

## Status

Accepted.

## Context

A valid conversation record changeset alone does not guarantee that its root
event remains available, that its ID is new under concurrent attempts, or that
adapter constraint failures are returned without diagnostics. In particular,
SQLite does not provide a stable foreign-key constraint name for changeset
mapping.

## Decision

Add one narrow transactional start operation. Revalidate the pristine runtime
conversation, require the root event to restore through its bounded store,
insert the conversation ID once with database conflict handling, restore the
exact loaded starting record, and validate its complete shape and metadata
before returning it. Loaded timestamps must retain storage precision 6; share
the record validator with later lifecycle consumers.

Classify a missing event and repeated conversation ID explicitly. Convert all
other repository exits, exceptions, foreign-key races, and adapter failures to
`storage_unavailable` without values. Do not select participants, invoke an
LLM, publish messages, or continue the conversation.

## Consequences

Only a committed bounded event can anchor a new durable conversation, and
concurrent reuse of an ID cannot overwrite its first lifecycle. The returned
record is a redacted capability for later exact transitions. Starting an
execution that requests a conversation remains a separate orchestration step.
