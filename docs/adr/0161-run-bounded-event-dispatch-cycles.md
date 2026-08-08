# 0161. Run bounded event dispatch cycles

Date: 2026-08-08

## Status

Accepted

## Context

Stochastic commits now create durable outbox handoffs, the store can lease them,
the pure planner can validate a bounded batch, and the fixed conversation
consumers can preflight durable plans. A runtime still needs to compose those
boundaries without claiming malformed work or completing partially dispatched
events.

## Decision

Add one explicit event-dispatch cycle. Validate the complete configuration,
canonical UTC instant, fixed persistence and authorizer adapters, and exact
starter or bounded-conversation runtime before storage access. List no more
than 100 available candidates, restore and positionally correlate every event,
cap the complete plan at 256 trigger matches, derive every authorization-free
consumer input, and preflight the concrete consumer before the first claim.

Process entries in durable order. Require each returned claim to correlate with
the candidate, injected instant, opaque 32-byte capability, and fixed 60-second
lease. Authorize and immediately consume matches in stable trigger order. Treat
successful dispatch, an already-terminal execution, and a durable cooldown
decision as terminal accepted outcomes. An existing started execution is still
in progress: leave its outbox claimed for lease expiry until recovery either
finishes or fails that execution. Complete the exact outbox claim at the
injected instant only when all matches are terminal; unmatched events complete
without authorization. Leave failed or uncorrelated work claimed for lease
expiry and continue the remaining prevalidated entries.

Return redacted aggregate counts only. Distinguish a storage read failure from
invalid runtime input, but collapse individual claim, authorization, consume,
and completion failures into bounded counts. Do not install a scheduler, scan
the event table, expose capabilities, or add generic action callbacks.

## Consequences

One call can drain a bounded available batch without a crash gap between event
discovery and durable retry policy. A partial match batch is retried after lease
expiry. Existing terminal trigger/event pairs make successful earlier matches
idempotent, while an existing started pair prevents premature outbox completion
until the separate recovery lifecycle makes it terminal.

Automatic scheduling, startup recovery ordering, and operational retention
policy remain separate reviewed work.
