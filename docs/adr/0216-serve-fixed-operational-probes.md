# 0216. Serve fixed operational probes

Date: 2026-08-11

## Status

Accepted

## Context

The standalone production entry point can complete recovery and start bounded
runtime work, but an orchestrator cannot distinguish process liveness from
completed recovery and initialization. Erlang distribution is intentionally
disabled, the scratch image has no shell, and adding a generic management API
would weaken the product boundary. This decision amends the production root
child order recorded in ADR 0215 without changing its recovery ordering.

## Decision

Serve three exact unauthenticated HTTP/1.1 GET paths on one explicitly
configured port: `/livez`, `/readyz`, and `/startupz`. Fix the listener address,
paths, methods, parser and response bounds, timeouts, bodies, and readiness
source in application code. Responses contain only `ok`, `unavailable`, `not
found`, or `invalid`; they expose no configuration, application data, endpoint,
credential, prompt, external response, or diagnostic.

Accumulate segmented input only through the first complete header terminator,
with one 2 KiB limit and one 200 ms absolute receive deadline. Separate the
accept loop from at most 32 monitored connection workers. Close excess
connections instead of growing an unbounded task, process, queue, or buffer.

Order production root children as the probe listener, readiness state service,
SQLite repository, and recovery-gated runtime under rest-for-one supervision.
The listener and state service remain live during runtime replacement. The
runtime starts a monitored readiness lease last, only after recovery, recurring
initialization, stochastic initialization, and all five schedulers start. The
lease is the runtime supervisor's final child, so scheduler failure, repository
replacement, and graceful application shutdown release readiness before a
scheduler callback can delay the remaining shutdown. The listener stops last
during graceful application shutdown.

Have each scheduler trap its parent shutdown signal so its current synchronous
cycle may return within one explicit five-second child shutdown window; the
supervisor then kills it. The five children stop sequentially in reverse order,
so runtime shutdown may consume at most 25 seconds before supervisor overhead.
Keep SQLite running until all runtime children stop so an interrupted
transaction rolls back before repository shutdown. Do not retry interrupted
provider or publication calls. Existing recovery marks incomplete internal work
failed and treats a publication that may have crossed the dispatch boundary as
ambiguous on the next startup.

Do not add arbitrary handlers, metrics, debug state, caller-selected bind
addresses, TLS termination, or another inbound service. A deployment must keep
the port private and allow only its orchestrator probe path through network
policy.

## Consequences

An orchestrator can use startup probes to tolerate bounded initialization,
readiness probes to remove a replacing runtime from service, and liveness probes
to restart a failed application. Readiness is deliberately process-level: it
proves the reviewed runtime tree is running, not that external providers or
observed infrastructure are healthy.

The fixed endpoint is an inbound interface and therefore needs explicit
deployment network policy. It is unsuitable for public exposure and does not
replace later bounded metrics or structured operational logs.
