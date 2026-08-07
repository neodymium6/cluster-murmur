# ADR 0133: Execute Starter Publications

## Context

A starter publication now crosses durable intent recording as an exact
`started` attempt. The outbound adapter already provides a one-use dispatch
claim and classifies transport results, while the attempt store provides atomic
terminal transitions. A runtime boundary must connect those contracts without
making an ambiguous remote effect retryable.

## Decision

Revalidate the complete started capability, current configuration, cooldown
facts, webhook settings, injected transport, and completion instant before
publication. Delegate the dispatch claim and external request to one injected
publisher call. Accept only the exact correlated `dispatching` projection of
the started attempt.

Record a proven success with the returned Discord message ID and the committed
message in one atomic store operation. Record a known rejection as `failed` and
an unknowable effect as `ambiguous`; never retry within this boundary. Accept
only exact terminal attempts at the injected completion instant, and on success
accept only the exact committed message with its publication ID added. Return a
redacted terminal capability without raw request, response, or secret values.

Do not update persona cooldowns, choose a reply, advance or close the
conversation, or perform recovery of interrupted work.

## Consequences

The first starter can now reach a durably classified fake publication outcome.
Only proven pre-send failures remain eligible for any future explicit retry
policy; ambiguous outcomes stay terminal and cannot duplicate a Discord post.
Later orchestration can consume an exact published capability without receiving
webhook credentials or transport diagnostics.
