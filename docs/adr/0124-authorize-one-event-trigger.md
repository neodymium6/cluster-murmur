# ADR 0124: Authorize One Event Trigger

## Context

Event-trigger matching, pure execution planning, and atomic durable starts
exist independently. Later action orchestration needs one narrow boundary that
connects those decisions without performing an action or trusting a forged
store response.

## Decision

For one supplied trigger, event, and canonical execution instant, build the
pure plan without a speculative cooldown read and ask an injected fixed store
to start it. The store remains responsible for rechecking the committed event,
the trigger/event pair, and the latest durable cooldown in one transaction.

Return a fully redacted authorization containing the exact plan and validated
loaded started capability. Treat a repeated pair as an idempotent skip, retain
only stable store failures, and revalidate all returned correlations before any
later action may consume the authorization.

## Consequences

Later bounded dispatch can authorize matching triggers sequentially and act
only on durable capabilities. Trigger selection, batch partial-failure policy,
conversation creation, completion or failure transitions, retries, and all
external calls remain separate reviewed decisions.
