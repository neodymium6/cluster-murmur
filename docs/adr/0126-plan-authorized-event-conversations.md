# ADR 0126: Plan Authorized Event Conversations

## Context

Durable event-trigger authorizations, complete runtime configuration, starter
candidate projection, weighted selection, and pristine conversation validation
exist independently. Action orchestration needs one narrow pure boundary that
connects those facts before persistence can consume an authorization.

## Decision

Revalidate one exact authorization against the complete runtime configuration
and require its trigger to remain structurally identical in that configuration.
Resolve only the trigger's exact configured binding, then project candidates
from the configured persona map, authorization execution instant, and one
supplied bounded cooldown snapshot. Delegate only the final weighted choice to
an injected random source and return an explicit no-starter skip when no
positive candidate remains.

For a selected configured persona, build a fully redacted plan containing the
authorization, exact binding, exact starter, and one validated pristine
conversation whose root event and start instant match the authorization. Accept
the conversation ID as an already bounded orchestration input. Revalidation
proves configuration correlation and current starter eligibility; it does not
repeat or reinterpret the prior random choice.

Do not persist the conversation, finish or fail the trigger execution, generate
content, record a persona cooldown, publish, retry, or make an external call.

## Consequences

Later action execution can atomically consume a closed conversation plan
without reopening configuration or allowing an LLM to select participants.
Conversation persistence, trigger terminal transitions, identifier allocation,
generation, publication, and recovery remain separate reviewed decisions.
