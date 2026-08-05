# ADR 0084: Gate Responder Replies Explicitly

## Status

Accepted.

## Context

Event-group reply probability is a separate policy decision from responder
eligibility and weighted selection. Hiding this decision in candidate weights
would make a no-reply outcome ambiguous and harder to test or observe.

## Decision

Add a pure reply gate that revalidates one exact bounded event-group projection
and returns a redacted explicit `reply` or `no_reply` decision. Probability zero
always returns no reply and probability one always returns reply without
sampling. Intermediate probabilities consume exactly one finite uniform sample
from an injected random adapter and allow reply only when the sample is strictly
below the configured probability.

Reject missing adapters, exceptions, and values outside the half-open
`[0.0, 1.0)` interval with stable value-free errors. Do not project responder
candidates or perform weighted selection in this gate.

## Consequences

Probability gating is replayable and cannot silently alter responder weights.
The director can stop immediately on explicit no reply, while later selection
still includes its own weighted no-reply candidate as a distinct convergence
path.
