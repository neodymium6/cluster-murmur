# Persistence and sensitive data

This page defines durable records, logging, and sensitive-data handling. It is
part of the normative [MVP runtime contract](../mvp-contract.md).

## Persistence contract

Ecto with SQLite stores the following minimum fields. Migrations may add
surrogate keys, timestamps, constraints, and indexes without changing the
domain contract.

### `entity_states`

```text
source
subject
current_state
pending_state
consecutive_count
last_observed_at
last_changed_at
facts
labels
```

### `events`

```text
id
type
source
subject
group
severity
previous
current
dedupe_key
correlation_key
facts
labels
occurred_at
observed_at
inserted_at
```

### `trigger_executions`

```text
trigger_id
event_id
status
executed_at
cooldown_until
error_class
```

### `conversations`

```text
id
root_event_id
status
turn_count
llm_call_count
started_at
completed_at
```

### `messages`

```text
conversation_id
persona_id
origin
content
discord_message_id
inserted_at
```

### `persona_cooldowns`

```text
persona_id
cooldown_until
last_spoken_at
```

### `stochastic_schedules`

```text
trigger_id
next_run_at
last_run_at
daily_count
daily_count_date
claim_token
claim_started_at
claim_expires_at
```

Entity state changes, event insertion, and related trigger bookkeeping should
use transactions where a partial result would change a later decision.
Restart must restore committed entity state, trigger cooldowns, persona
cooldowns, incomplete conversation disposition, and stochastic next-run times.

## Logging and sensitive data

Production logs are structured JSON. They may record:

- observation success or classified failure;
- event creation or suppression;
- trigger match or skip decisions;
- selected persona IDs;
- conversation start and terminal status;
- classified LLM success or failure; and
- classified Discord publication success or failure.

Logs must not contain:

- API keys, bearer tokens, or webhook URLs;
- private endpoints or secret-file contents;
- complete LLM prompts;
- complete MCP responses; or
- unrelated user message content.

Observation data and generated prompts are potentially sensitive. Logging uses
field allowlists, redaction, response-size limits, and stable error classes
rather than raw exception payloads from external providers.

Generic inspection of observation, event, and conversation domain values is
allowlisted and excludes facts, labels, state snapshots, participants, and
messages. Structured logging must still choose only fields justified by the
specific lifecycle event.
