# ADR 0143: Finish Published Responder Turns

## Status

Accepted.

## Context

A proven responder publication and its monotonic persona cooldown establish one
completed conversation turn. The persisted conversation remains `generating`,
while the next bounded action requires an exact waiting state or a terminal
state when core capacity is exhausted.

## Decision

Rebuild the exact runtime conversation from the selection-time runtime state,
persisted responder delivery, and proven published message. Append the responder
once to the ordered participant set, append the bounded message projection, and
merge the new cooldown into the exact selection-time cooldown snapshot. Drop
cooldown entries for personas absent from the exact current configuration before
the merge, keeping the returned view within the persona catalog limit.
Keep runtime history as the latest twelve validated messages when appending the
new publication, matching the bounded persistence history window.

Evaluate the immutable conversation budget at the durable publication
completion instant. If turns, duration, and LLM-call capacity remain, atomically
move the exact persisted conversation from `generating` to `waiting` and return
a redacted continuation capability containing the updated runtime and cooldown
view. Otherwise complete the exact conversation at that same instant and return
a redacted terminal capability.

Do not select another responder, invoke an LLM, publish a message, retry an
external effect, or use participant-slot exhaustion alone to close a
conversation.

## Consequences

Every published responder turn reaches a durable lifecycle boundary before a
subsequent selection. The next driver can use one fully correlated runtime and
cooldown snapshot, while core budgets stop the conversation without another
random decision or external call.
