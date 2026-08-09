# 0186. Apply state-tracking overrides during polls

Date: 2026-08-09

## Status

Accepted

## Context

The normalized state-tracking configuration can resolve bounded source and
source-subject overrides, but the poller previously projected one global policy
before observing any target. Runtime selection must not let an observer choose
arbitrary thresholds or cause external access before configuration validation.

## Decision

Validate the complete state-tracking configuration before dependency checks or
observer calls. After one observation passes the existing exact validation and
target correlation checks, resolve its exact source-subject override, then its
source-only override, then the global default. Pass only that fixed debounce
policy and the correlated observation to the atomic ingestion store.

Keep selection inside the bounded sequential poll. Do not persist selectors,
expose them in poll results, allow observer-supplied thresholds, or add generic
policy lookup capabilities.

## Consequences

Different validated observation identities can use different application-owned
debounce thresholds in one poll. Invalid configuration still fails closed before
observer access, and partial observer or ingestion failures keep their existing
bounded redacted result classes.
