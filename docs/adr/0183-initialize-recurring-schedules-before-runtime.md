# 0183. Initialize recurring schedules before runtime

Date: 2026-08-09

## Status

Accepted

## Context

The recurring cycle reads only durable state. A fresh deployment therefore
needs one state row per configured recurring trigger, while restart must retain
the previously committed next run instead of recalculating over missed work.

## Decision

Add a bounded startup initializer that accepts the complete validated
configuration, one injected UTC instant, and one fixed state-store adapter.
Select at most 256 recurring triggers in identifier order and calculate every
initial next run before the first storage mutation. Retire at most 100 durable
states absent from the active trigger set, requiring another startup pass when
that bounded page is saturated. Then call the fixed restore-or-initialize
operation for each trigger and correlate every returned claim-free state with
its trigger.

Existing durable state wins regardless of the newly calculated initial value.
Return only an aggregate schedule count or one stable initialization error. Do
not read a clock, start a scheduler, claim due work, emit events, or expose
generic persistence.

## Consequences

Deterministic configuration or recurrence failures cannot leave a partially
initialized set. Removed or renamed triggers cannot leave due states that block
future batches. A storage failure can follow bounded retirement or earlier
idempotent inserts, so a later startup may safely retry the complete initializer.
A recovered runtime composition must finish this boundary before starting the
recurring scheduler.
