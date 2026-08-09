# 0175. Integrate event sweeps into retention cycles

Date: 2026-08-09

## Status

Accepted

## Context

The retention cycle prunes expired dedupe markers, while the event sweep store
deletes unreferenced expired events through a separate plan call. Independent
callers could reverse those operations, use different cutoff facts, or retain
incompatible result shapes in scheduler status.

## Decision

Extend the fixed retention cycle to pass one exact plan first to the dedupe
marker store and then to the event sweep store. Marker pruning can make its
former event eligible in the immediately following sweep. Validate both store
results and return only marker, scanned-event, and deleted-event counts plus
the completed-pass flag.

Treat either stable storage failure or invalid persisted sweep as a redacted
retention failure. Fail closed on malformed results, rejected plans,
exceptions, exits, and adapters. Do not repeat either batch inside one cycle.

## Consequences

Each scheduler tick performs one fixed marker batch and one fixed event page in
a reviewable order using the same configuration and injected time. Referenced
lifecycle records remain unchanged and no cursor or event value reaches status.
