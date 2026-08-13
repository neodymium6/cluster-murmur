# Paths and runtime defaults

This page defines configuration and database paths plus normalized runtime
defaults. It is part of the normative
[configuration reference](../configuration.md).

## Root configuration path

The production application requires `CLUSTER_MURMUR_CONFIG_PATH` to contain the
absolute path of the root YAML document. It must be valid UTF-8, contain no NUL
byte, and be between 1 and 4,096 bytes. The existing configuration loader then
canonicalizes that document and applies the include and prompt-file containment
rules described above. Development and test application starts do not read this
variable because they retain the repository-only application tree.

Reading the root document, included public documents, and mounted secret files
prepares one redacted startup value before any worker, clock, recovery step, or
network transport runs. Missing or invalid inputs fail production startup with
a stable value-free error.

## Database path

The supervised SQLite repository uses an in-memory database only in the test
environment. Production requires `CLUSTER_MURMUR_DATABASE_PATH` to contain a
non-empty absolute path of at most 4,096 bytes. Development accepts the same
override and otherwise uses `.local/cluster-murmur.sqlite3` below the repository
root. `:memory:` is rejected outside tests even when supplied through the
environment.

At repository startup, the database's immediate parent directory must already
exist with mode `0700`; missing or more permissive directories are rejected.
A missing database file is created inside that private directory with mode
`0600`, while an existing file must already have that exact mode. An immediate
parent or database symlink and non-directory or non-regular targets are
rejected. The private directory also prevents other local users from accessing
SQLite WAL and shared-memory files created beside the database.

The complete path ancestry is trusted deployment input. Every ancestor must be
controlled by the operator, contain no symlink components, and be unwritable by
untrusted principals. The startup checks use pathname-based filesystem calls,
and the current SQLite adapter does not expose a race-safe no-follow open.
Consequently, these checks reject accidental unsafe configuration but do not
defend against a principal that can rename or replace an ancestor or path while
startup is in progress. Do not place the database below a shared writable
directory. Operators must prepare the private development or PVC mount
directory before startup.

Prepare the default development directory from the repository root with:

```bash
mkdir -p .local
chmod 0700 .local
MIX_ENV=prod mix release
CLUSTER_MURMUR_DATABASE_PATH="$PWD/.local/cluster-murmur.sqlite3" \
  _build/prod/rel/cluster_murmur/bin/cluster_murmur eval \
  'ClusterMurmur.Release.migrate!()'
```

The repository has one connection, uses immediate transactions, enables foreign
keys and WAL mode, and waits at most five seconds for a busy database. SQL query
logging and sensitive connection-error details are disabled. These connection
settings and the first stochastic-schedule schema and migration are implemented.
The first domain store transaction restores an existing stochastic schedule or
inserts its initial next run without replacing durable state. Its read-only due
query returns at most 100 available redacted records in deterministic order. A
separate immediate transaction can claim one exact due version through an
internally generated 256-bit capability with a fixed 60-second expiry. Only the
matching claim, executed and recorded within its lease interval, can clear the
lease, advance the next run, and update its local-date counter atomically. Lease
claim candidates are evaluated purely against active hours and a persisted
counter normalized to the calculated current local date. Renewal, early
release, external execution, exactly-once delivery, and automatic migration
execution remain outside this contract. A
separate bounded event store validates complete events before storage, inserts
immutable event IDs idempotently, and rejects conflicting reuse without
replacing committed facts. Its primary-key-only read restores at most one event
through the shared bounded validator. The startup configuration normalizes
bounded event retention and dedupe-window durations, and trigger authorization
enforces durable dedupe markers. Referenced-lifecycle retention remains outside
the conservative installed retention worker's contract. A
narrow observation-ingestion transaction restores prior entity state, applies
the pure debounce and event plan, and commits the next state with its optional
event atomically. It performs no observer call or trigger action.

The implemented poll runtime composes one fixed read-only observer poll, atomic
ingestion, deterministic event-trigger matching, durable authorization,
bounded starter generation, and claimed Discord publication. Its conversation
mode additionally projects a finite responder schedule from validated relative
offsets and runs only through correlated fixed adapters. The production
application constructs the fixed observer, transports, timing, and validated
scheduler options from startup inputs. Other Mix environments retain explicit
opt-in assembly. The scheduler completes one cycle before creating the next
timer and rejects stale or injected timer messages.

Restart recovery is also explicit. It loads at most 100 abandoned trigger
executions, active conversations, and open publication attempts per collection;
validates every record before the first mutation; then fails internal work and
marks uncertain publications ambiguous. It never retries a provider call or
Discord publication. Operators choose the UTC abandonment cutoff and completion
instant. The opt-in recovered poll supervisor reads one injected storage-UTC
instant, uses it for both values, and starts its fixed scheduler child only when
every bounded recovery mutation succeeds and no collection fills its 100-record
page. The complete recovered runtime supervisor validates poll, event-dispatch,
recurring, stochastic, and retention schedulers; their shared configuration and
clock; both schedule initializers; the stochastic random source; and exact
recovery stores before reading that clock once. It completes global recovery,
then reconciles recurring state, then reconciles stochastic state using that
same instant. Both returned counts must equal their configured trigger counts
before all five workers start. Termination of any worker closes the shared
supervisor and stops its siblings, so a parent-managed replacement cannot run
startup mutations against live work. A full recovery or retirement page
requires another startup pass to prove that no residual work remains. These
boundaries are installed by the production application after the repository.
Development and test builds retain explicit opt-in assembly.

`ClusterMurmur.Release.migrate!/0`, invoked after every application instance
using the database has stopped, is the only application migration operation. It
applies packaged migrations to the fixed configured repository, is safe to
repeat, and reports only a generic failure. It rejects a running application or
repository in its own evaluation VM; this local check cannot detect a separate
release VM. It does not perform rollback or accept caller-selected repositories
or paths. The bootstrap escript is version-only because native libraries and
migration files require an extracted release filesystem.

Generic Ecto URL configuration is rejected because URL parsing occurs after the
repository callback and could otherwise replace the validated database path or
connection bounds.

## Runtime defaults

Defaults belong to the versioned schema. Implementations must not silently
change them within configuration version 1.

```yaml
state_tracking:
  failures_required: 2
  successes_required: 2

conversation_defaults:
  max_turns: 3
  max_participants: 2
  max_duration: 5m
  max_llm_calls: 3
  allow_same_persona_consecutively: false
  allow_persona_reentry: true
  responder_selection:
    no_reply_weight: 1.0
    random_jitter: 0.2

event_policy:
  dedupe_window: 5m
  retention: 90d

memory:
  current_conversation_messages: 12
  recent_persona_messages: 6
  recent_channel_messages: 8
  maximum_context_tokens: 2000

retention:
  entity_states: forever
  conversations: 30d
  messages: 30d
  trigger_executions: 30d
  llm_payloads:
    enabled: false
    retention: 7d
```

`state_tracking.overrides` accepts at most 256 complete threshold mappings. A
source is required and a subject is optional. Selector strings are bounded,
nonempty UTF-8 without NUL bytes; duplicate selectors and partial or unknown
fields are rejected. Exact source-and-subject matches take precedence over a
source-only match, which takes precedence over the global counts. Selectors in
real deployments may reveal infrastructure inventory and belong in private
configuration. Normalized inspection omits them.

The startup manifest and complete configuration normalize the two fixed default
counts and every override before worker construction. A poll validates the
complete configuration before any observer call, then resolves the exact
source-and-subject, source-only, or default policy from each validated
observation before atomic ingestion. Resolution returns only the fixed runtime
debounce-policy shape.

The startup manifest and complete configuration also normalize the exact event
policy shown above. These values are application-owned limits; they do not add
storage passthrough or configure a cleanup worker. A pure evaluator defines the
dedupe decision and stable suppression reason, and a constrained table can hold
exact redacted markers. Trigger authorization atomically enforces marker
replacement with execution start across poll and durable dispatch. Poll results
retain the stable reason and durable dispatch reports a redacted aggregate
suppression count. The broader `retention` mapping remains an intended future
contract and does not duplicate the implemented event retention field.

The normalized event retention duration can be projected into one exact cutoff
from an injected canonical UTC instant. A fixed store operation can use only
that exact plan to delete at most 100 expired dedupe markers without returning
their values. An explicit runtime cycle validates the complete configuration
and injected instant before invoking one marker batch followed by one event
sweep from the same plan. It returns only aggregate counts and does not repeat
cleanup or read a clock. The retention scheduler supplies a validated UTC clock
and runs these cycles without overlap while retaining only redacted aggregate
status. Production installs that scheduler behind shared recovery gates;
development and test builds may supervise it explicitly.

The event table's retention order and every child-table event reference are
indexed for the bounded event-record cleanup store. These indexes support its
fixed queries but do not cascade related lifecycle records or expose stored
values. A constrained singleton sweep row retains a redacted ordered cursor
across restarts so referenced events cannot starve later cleanup candidates.
One fixed store transaction uses that cursor to scan at most 100 expired events
and delete only records with no trigger-execution, conversation, dispatch, or
dedupe-marker reference. Referenced records remain until a later
lifecycle-specific retention decision removes those references.

Complete LLM payload retention remains disabled by default. Enabling it does
not permit credentials, private endpoints, or unrelated source data to be
stored, and deployments must treat retained payloads as sensitive.
