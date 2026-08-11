# 0208. Load responder schedule settings

Date: 2026-08-11

## Status

Accepted.

## Context

The bounded conversation runtime requires a reusable relative responder turn
schedule. Standalone option assembly has validated provider and publication
transports, but startup does not yet contain the timing inputs needed to build
that schedule. Inventing fixed live timings in the assembler would introduce
an undocumented deployment default.

## Decision

Load a turn interval plus generation, publication-start, and
publication-completion delays from four fixed `CLUSTER_MURMUR_RESPONDER_*`
environment variables. Use the public duration syntax, bound encoded values to
32 bytes, require the turn interval to be at least one second, and preserve the
shared maximum runtime interval.

Require ordered non-negative delays, with publication completion no later than
the next turn interval. Return one exact inspect-safe
`ResponderScheduleSettings` value, include it in `Startup.Prepared`, and
revalidate it before later assembly. Loading performs no wait, clock read,
persistence access, external call, or worker start.

## Consequences

Deployments explicitly choose the planned timing of responder work, and later
runtime assembly can build a finite non-overlapping schedule without hidden
defaults. These values do not control provider or webhook network deadlines,
which remain independently bounded by their existing settings and transports.
