# 0164. Normalize bounded event lifecycle policy

Date: 2026-08-09

## Status

Accepted

## Context

Durable event dispatch now has a bounded opt-in runtime, but duplicate event
suppression and operational cleanup need one versioned application-owned policy.
Leaving durations implicit would let later stores or workers choose inconsistent
defaults. Adding enforcement in the same change would combine configuration,
storage query semantics, and deletion behavior in one review boundary.

## Decision

Add one optional exact `event_policy` mapping to the version 1 startup manifest.
Normalize `dedupe_window` and `retention` through the shared duration parser and
carry the resulting millisecond values into the complete runtime configuration.
Use fixed defaults of five minutes and 90 days. Require both values to be
positive and no greater than 365 days, and require retention to be at least the
dedupe window.

Revalidate exact normalized structs at the complete configuration boundary and
keep inspection limited to the two non-sensitive durations. Do not read, list,
suppress, delete, or otherwise mutate stored events in this change. Do not add a
generic storage, SQL, timer, or deployment interface.

## Consequences

Later durable dedupe and retention work can consume one validated policy without
inventing deployment-specific defaults. Existing version 1 manifests retain
their behavior through fixed defaults.

The policy is intentionally inert until separately reviewed persistence and
runtime changes enforce it. Operators must not treat configuring retention as
proof that stored events are currently deleted.
