# Runtime behavior

This page defines observation, trigger, conversation, generation, and Discord
publication behavior. It is part of the normative
[MVP runtime contract](../mvp-contract.md).

## Observation and event rules

An observation never publishes directly. State tracking first applies the
configured debounce and then compares the committed previous state:

| Previous | Current | Event |
| --- | --- | --- |
| unknown | healthy | none |
| unknown | unhealthy | `observation.failed` |
| healthy | healthy | none |
| healthy | unhealthy | `observation.failed` |
| unhealthy | unhealthy | none |
| unhealthy | healthy | `observation.recovered` |

The initial healthy observation is silent. The current entity state must still
be persisted when event publication is suppressed.

Every extracted event has a stable dedupe key, for example:

```text
observation.failed:example-target
observation.recovered:example-target
alert.activated:example-target:example-alert
```

Repeated keys within a configured dedupe window do not execute triggers again.
Suppression, including its reason, must be observable without logging complete
facts or source responses.

## Trigger and selection rules

Triggers are limited to event, schedule, and stochastic types. Correlation is
reserved for later work. Matchers use only the operators defined in the
configuration reference and never execute embedded code.

Starter candidates come from the matched binding. A candidate on cooldown is
normally excluded. With one eligible candidate, that persona is selected.
With multiple candidates, the selector computes a non-negative weight from:

```text
binding weight
+ event interest
+ ownership bonus
+ persona spontaneous weight
- recent speaker penalty
- cooldown penalty
```

The injected random behaviour performs only the final weighted sample. If no
candidate exists, the event remains persisted and no Discord message is sent.

A reply is first gated by the event group's reply probability. Responder
candidates exclude:

- disabled personas;
- the previous speaker when consecutive speech is disabled;
- personas on cooldown;
- personas absent from the binding;
- personas with zero relevance; and
- personas that have reached a conversation limit.

Eligible responder weights combine binding weight, event interest,
relationship with the previous speaker, reply weight, novelty, and recent
speaker penalties. The candidate set must always include weighted `no_reply`.
Weights are clamped or rejected before sampling so a negative weight never
reaches the random adapter.

## Conversation convergence

All conversations must enforce the configured limits for turns, participants,
duration, LLM calls, persona continuity, cooldowns, and re-entry. The default
limits are specified in the
[paths and runtime defaults reference](../configuration/paths-and-defaults.md).

The director checks the relevant budget before every generation, publication,
and continuation. An LLM response cannot extend a conversation. A terminal
conversation process must stop normally under the conversation
`DynamicSupervisor`.

At-least-once delivery or a process restart must not create an unbounded
conversation. A pure publication planner now skips records whose Discord ID is
already committed. Restart recovery classifies the ambiguous crash window
between Discord acceptance and recording the returned Discord message ID as an
ambiguous terminal publication and never retries it blindly.

## Generation contract

Prompt construction separates identity, facts, creative context, and bounded
conversation history. The logical input has this shape:

```json
{
  "persona": {
    "display_name": "Example Observer",
    "instructions": "Speak briefly and do not invent causes."
  },
  "facts": {
    "subject": "example-backup",
    "previous_state": "failed",
    "current_state": "healthy"
  },
  "creative_context": {
    "conversation_kind": "recovery",
    "mood": "relieved"
  },
  "conversation": [
    {
      "speaker": "Example Caretaker",
      "content": "The latest run completed."
    }
  ]
}
```

The LLM may add humor, metaphor, light irony, fictional emotion, or short
in-world dialogue. It must not invent a cause, measurement, repair, recovery,
credential, endpoint, or MCP action.

Before publication, deterministic validation must:

- reject empty output;
- enforce a configured character limit;
- suppress Discord user, role, and broadcast mentions;
- suppress URLs, domain-like forms, and IP addresses, including forms that use
  Unicode domain separators;
- remove control characters; and
- reduce redundant use of the speaker's own display name.

For domain detection, a complete line containing two or more closed Japanese
sentences made only from Japanese scripts and bounded Japanese punctuation may
use ideographic full stops as sentence boundaries. Latin characters, fixed
Japanese network-reference cues, inter-sentence whitespace, or path punctuation
keep the line under domain detection. All other ideographic, fullwidth, and
halfwidth dot forms remain equivalent to an ASCII dot for domain detection, and
every such form remains equivalent to an ASCII dot for URL and IP-address
detection. This narrow structural exception admits ordinary Japanese prose
without removing the default Unicode-dot rejection.

Provider failure, timeout, malformed response, or rejected output falls back
to a deterministic template generated only from confirmed facts. Fallbacks
consume conversation budgets and must pass the same output validator.

## Discord publication

The MVP is outbound-only. Each publication supplies content plus the selected
persona's display name and avatar override to a pre-created Discord Webhook.
Webhook URLs are read from mounted secret files and must never be returned in
errors or logs. Publication payloads always send an empty `allowed_mentions`
parse list so Discord cannot expand user, role, or broadcast mentions.

Discord Gateway ingestion and `discord.mentioned` event production are not MVP
features. The event type and `Questions.ToolPolicy` boundary remain reserved so
future question handling cannot grant tool choice directly to an LLM.
