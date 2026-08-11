# ADR 0117: Load Startup Runtime Settings Together

## Status

Accepted; amended by ADR 0202.

## Context

The complete public startup configuration now contains normalized LLM and
Discord routing values. Their separate settings boundaries safely resolve
deployment values, but runtime construction still lacks one fail-closed step
that proves both settings are available before any external adapter starts.

## Decision

Load provider and webhook settings into one exact redacted runtime aggregate.
Accept only the complete version 1 configuration and one injected environment
reader. Revalidate every normalized category and cross-reference before reading
any environment or mounted-secret value. Delegate those reads to the existing
bounded settings modules, preserve a stable provider or webhook error label,
and revalidate both exact settings values before returning.

The aggregate performs no network connection, generation, or publication. Its
inspection output exposes neither credentials nor deployment endpoints.

## Consequences

Runtime construction can fail before external work when either dependency is
misconfigured, without reopening public configuration documents or passing raw
secret-reader diagnostics upward. Later supervision work must still decide how
validated settings and injected transports are provided to runtime workers.
