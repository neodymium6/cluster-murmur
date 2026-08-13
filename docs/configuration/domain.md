# Domain configuration

This page defines event groups, personas, bindings, and trigger configuration.
It is part of the normative [configuration reference](../configuration.md).

## Event groups

Event groups separate conversation policy from event severity. A complete
example with common groups and reply probabilities is:

```yaml
event_groups:
  operations:
    reply_probability: 0.25
  recovery:
    reply_probability: 0.40
  social:
    reply_probability: 0.75
  user:
    reply_probability: 1.00
  system:
    reply_probability: 0.05
```

Operators may add groups. Every event-producing trigger and every group-based
route must resolve to a declared group. Event-group IDs must be unique across
all included files, and version 1 accepts at most 256 groups in total. Empty
event-group categories are valid; the validator does not synthesize the groups
shown above.

## Personas

A persona file contains reusable identity, machine-readable selection data,
and a reference to prompt material. It must not contain cluster-specific
service IDs or private operator information.

```yaml
personas:
  - id: observer
    display_name: Observer
    avatar: https://example.com/avatars/observer.png
    prompt_file: ../prompts/observer.md
    enabled: true
    interests:
      monitoring: 1.0
      recovery: 0.6
    behavior:
      spontaneous_weight: 0.3
      reply_weight: 0.8
      cooldown: 30m
    relationships: {}
    metadata: {}
```

Prompt files may describe personality, voice, world view, short examples,
forbidden expressions, desired message length, and attitudes toward other
personas. They do not grant tools or alter factual event decisions.

Persona IDs must be unique across all included files, and version 1 accepts at
most 256 personas. `id`, `display_name`, and `prompt_file` are required;
`enabled` defaults to true and optional maps default to empty. Display names are
limited to 128 UTF-8 bytes, avatar values must be HTTPS URLs no longer than
2,048 bytes, and interests contain at most 256 portable event-group IDs with
non-negative weights. Non-empty `relationships` and `metadata` are reserved
until their semantics are fixed and are rejected by version 1 validation.

## Bindings

Bindings associate events with weighted persona candidates independently from
persona identity:

```yaml
bindings:
  - id: monitoring-characters
    match:
      group: operations
    candidates:
      - persona: observer
        weight: 1.0
      - persona: caretaker
        weight: 0.4
```

Candidate persona references must exist and candidate weights must be
non-negative. A disabled persona may remain referenced but is excluded at
runtime. Binding IDs must be unique across all included files, and version 1
accepts at most 256 bindings with 1 to 256 candidates each. A persona may occur
only once within a binding. Binding and candidate order has no semantic meaning;
group and persona references are resolved after all categories are parsed.
The implemented catalog loader rejects bindings that reference an unknown group
or persona. Disabled personas remain valid references and are excluded later by
runtime selection.

## Triggers

### Event triggers

```yaml
triggers:
  - id: monitoring-failure
    event:
      match:
        all:
          - field: type
            operator: equals
            value: observation.failed
          - field: labels.category
            operator: equals
            value: monitoring
    action:
      type: start_conversation
      binding: monitoring-characters
    cooldown: 30m
```

`match.all` contains 1 to 32 conjunctive predicates. Fields are limited to
`type`, `source`, `subject`, `group`, `severity`, `labels.<id>`, and
`facts.<id>`. The dynamic `<id>` starts with an ASCII letter or digit and then
contains only ASCII letters, digits, `_`, or `-`. `equals` and `not_equals` take
a scalar `value`; `in` takes 1 to 32 distinct scalar `values`; `exists` takes no
operand; and `greater_than` and `less_than` take a numeric `value`. Scalar
strings are limited to 1,024 UTF-8 bytes. Configuration cannot contain
disjunctions, regular expressions, deeper paths, Elixir, Lua, JavaScript,
shell, SQL, PromQL, or arbitrary HTTP expressions.

Matcher evaluation is deterministic application code. All predicates are
conjunctive; a missing dynamic key never matches, `exists` requires a non-null
value, scalar comparisons require a scalar event value, and ordered comparisons
require a numeric event value. Integer and equivalent floating-point values
compare equally.

Implemented event-trigger documents accept at most 256 triggers across all
included files. Trigger IDs must be unique, `action.type` is currently limited
to `start_conversation`, cooldowns use the duration grammar up to 365 days, and
binding references remain unresolved until complete configuration assembly.

The complete configuration loader resolves each event trigger's binding against
the assembled binding namespace and rejects unknown references. It validates
the single default route in the same startup value, but does not read its secret
file or connect to Discord.

### Schedule triggers

```yaml
triggers:
  - id: daily-summary
    schedule:
      cron: "0 21 * * *"
      timezone: Asia/Tokyo
    action:
      type: emit_event
      event:
        type: schedule.fired
        group: social
        subject: daily-summary
```

Schedule cron expressions contain exactly five space-delimited fields: minute,
hour, day of month, month, and day of week. Seconds, year fields, and special
aliases such as `@daily` are not accepted. Named months and weekdays, ranges,
lists, and steps follow standard cron syntax. Timezones must resolve within the
IANA snapshot embedded in the release; validation never consults host zoneinfo
or downloads timezone data at runtime.

At least one of day-of-month or day-of-week must be the unrestricted `*` field.
This avoids the incompatible OR and AND interpretations used by common cron
implementations when both fields are constrained.

The action is limited to `emit_event`. Event type, group, and subject are
portable IDs, and complete configuration assembly resolves the group against
the declared event-group namespace. Schedule and event trigger IDs share one
namespace and count toward the same version 1 limit of 256 triggers. Validation
does not execute schedules or emit events.

### Stochastic triggers

```yaml
triggers:
  - id: occasional-murmur
    stochastic:
      distribution: shifted_exponential
      mean_interval: 8h
      minimum_interval: 2h
      active_hours:
        start: "08:00"
        end: "23:00"
        timezone: Asia/Tokyo
      daily_limit: 3
    action:
      type: emit_event
      event:
        type: stochastic.fired
        group: social
        subject: ambient-conversation
```

Version 1 supports only `shifted_exponential`, sampled as the minimum interval
plus an exponential random delay whose mean is the difference between
`mean_interval` and `minimum_interval`. Both intervals must be positive, the
mean must be greater than the minimum, and neither may exceed 365 days.

`active_hours` and `daily_limit` are optional. Active-hour endpoints use strict
24-hour `HH:MM` notation, must differ, may define a window that crosses
midnight, and use an embedded IANA timezone. A daily limit is an integer from 1
through 10,000 and requires `active_hours` so its daily reset has an explicit
timezone. The action and event-group reference follow the schedule trigger
contract. Validation does not sample randomness, calculate a next run, persist
counters, or emit events.

The separate pure scheduling boundary calculates a next run by sampling one
wait and adding it to a caller-supplied canonical UTC instant. It does not read
a clock, inspect scheduler state, persist the result, or execute an action.

Claimed execution planning rechecks active-hours and daily-limit eligibility at
the supplied execution instant. Ineligible work is skipped without sampling a
new wait; an eligible plan contains only the configured event template and the
redacted values needed for a later completion record.

The shared pure emitted-event projector derives a complete bounded event from
the trigger kind, configured trigger ID, template, and scheduled UTC instant.
The same scheduled version and exact template produce the same immutable event
across retries. Template drift preserves the scheduled event ID so idempotent
persistence rejects changed facts instead of accepting a duplicate. Its fixed
labels contain only the configured trigger ID and kind; prompt fact projection
excludes both labels.

The constrained stochastic commit store reprojects that exact event and writes
it in the same SQLite transaction that advances the opaque claimed schedule to
its planned next run. An identical precommitted event is restored; template
drift or schedule conflict fails closed without advancing the claim. Worker
timing, due enumeration, and later event-trigger dispatch remain separate fixed
runtime boundaries assembled by the production application.

The explicit stochastic cycle performs that due enumeration. It traverses
cursor pages of at most 100 and validates and correlates no more than the
configuration maximum of 256 schedules before the first claim. This prevents
an ineligible first page from hiding eligible later work. It rejects duplicate
or out-of-order durable projections, leaves inactive or daily-limited entries
unclaimed, and continues a prevalidated batch after individual claim or commit
conflicts. Returned claims and typed commit results must correlate exactly with
their calls before execution is counted. Its result contains aggregate counts
only. Committed-event dispatch remains a separate runtime step handled by the
installed event-dispatch scheduler.

An opt-in stochastic scheduler can invoke that cycle repeatedly without
overlap. It requires an explicit validated configuration, cycle module, UTC
clock, random source, interval, and initial delay; no live defaults are
provided. The next timer is scheduled only after the synchronous cycle returns,
and only an exact bounded, correlated aggregate result is retained. Status
inspection excludes configuration and event details. The production application
installs it behind shared recovery and initialization gates.

Recurring cron triggers have a separate constrained durable state table for
ordered next/previous runs and one opaque claim lease. A fixed store can restore
or initialize state, list at most 100 due schedules in deterministic cursor
order without claim material, and atomically grant one fixed 60-second opaque
lease for an exact due version. It can complete only that exact live claim,
recording the execution, advancing the next run, and clearing the lease in one
transaction. The store itself does not calculate recurrence, execute actions,
or emit events. A pure planner can
correlate a claim with its exact trigger and
claim-free due projection, preserve only application-supplied event facts, and
calculate the next cron run strictly after an injected execution instant. It
does not perform persistence or I/O. Stochastic state is not reused.

A fixed recurring commit boundary re-projects the expected application-owned
event and atomically inserts or restores that event, enqueues its pending
dispatch handoff, and completes the exact live schedule claim. Any conflict
rolls back all new event, outbox, and schedule changes. It does not dispatch the
event or execute external actions.

A recurring-schedule cycle prevalidates and correlates at most 256 due states
with the exact current configuration before taking its first claim. It then
claims, plans, projects, and atomically commits each state in durable order,
continuing after individual conflicts and returning aggregate counts only. The
cycle reads no clock and performs no external action. Production runs it only
through the recovery-gated recurring scheduler.

An opt-in recurring-schedule scheduler can invoke that cycle repeatedly without
overlap. It requires an explicit validated configuration, cycle module, UTC
clock, interval, and initial delay. The next timer is created only after the
synchronous cycle returns, and status retains only exact aggregate results or a
stable redacted failure. No live defaults are supplied.

Before recurring runtime starts, a bounded initializer calculates every
configured trigger's initial next run from one injected UTC instant, then
retires a bounded page of state absent from the active trigger set, and restores
or initializes active state in identifier order. A saturated retirement page
requires another startup pass. All recurrence calculations finish before the
first write, existing active durable state always wins, and the result contains
only the number of correlated states. The initializer does not read a clock or
start workers.

The persistence layer also provides a dedicated event-dispatch outbox for the
crash-safe handoff that follows event commit. It accepts only exact immutable
events already in the event store and returns a claim-free enqueue receipt. It
lists at most 100 pending or expired entries without claim data, grants one
opaque fixed 60-second lease, and completes only that exact live claim. A
stochastic commit inserts its immutable event, enqueues this claim-free
handoff, and advances the claimed schedule in one transaction. The outbox does
not perform external I/O. A pure planner can correlate its ordered batch
with restored immutable events and cap current trigger matches before any
claim. Existing fixed starter and bounded-conversation consumers can preflight
the resulting durable plan without authorizing work. An explicit bounded cycle
then claims entries in order, immediately consumes matching fixed pipelines,
and completes only unmatched or fully terminal handoffs. Production runs it
through the recovery-gated event-dispatch scheduler.

An opt-in event-dispatch scheduler can invoke that cycle repeatedly without
overlap. It requires an explicit validated configuration, dispatch context,
fixed persistence and authorizer adapters, cycle module, UTC clock, interval,
and initial delay. The next timer is scheduled only after the synchronous cycle
returns. Status retains only a validated redacted aggregate result or a stable
failure class. The scheduler supplies no live defaults; the production
application constructs its exact options from validated startup inputs.

Active windows include their start minute and exclude their end minute. A
crossing-midnight window is active from its start through local midnight and
from midnight up to its end. Both instants in a repeated DST wall-clock minute
have the same active-hours status.

Daily limits use the trigger timezone's local calendar date. For a window that
crosses midnight, executions after midnight count toward the new calendar date,
not the date on which the window began. Active-hours exclusion takes precedence
over a reached daily limit in the eligibility reason.
Runtime eligibility requires the loaded execution count to be tagged with this
calculated local date and rejects mismatched buckets.
