# Loading and validation

This page defines bounded configuration loading and validation. It is part of
the normative [configuration reference](../configuration.md).

## Loading model

Configuration uses YAML 1.2. Bounded document decoding, strict top-level
manifest validation, duration and common scalar validation, bounded include
resolution, composition of those manifest stages into a load plan, and bounded
decoding of the included YAML documents are implemented. A value-free Draft 7
validation adapter for application-owned schemas and bounded event-group, persona,
binding, routing, LLM-provider, and event-trigger validation, cross-category
character catalog assembly, and complete startup configuration assembly are
implemented. The top-level startup value also normalizes fixed state-tracking,
conversation, and event-policy defaults or one exact explicit mapping for each.
A fixed
top-level file includes files by category:

```text
config/
|-- cluster-murmur.yaml
|-- event-groups.yaml
|-- routing.yaml
|-- personas/
|   |-- observer.yaml
|   `-- caretaker.yaml
|-- bindings/
|   |-- monitoring.yaml
|   `-- social.yaml
|-- triggers/
|   |-- observations.yaml
|   |-- schedules.yaml
|   `-- stochastic.yaml
`-- prompts/
    |-- observer.md
    `-- caretaker.md
```

The top-level file declares the configuration version and includes:

```yaml
version: 1

state_tracking:
  failures_required: 2
  successes_required: 2
  overrides:
    - source: observer.example
      failures_required: 3
      successes_required: 3
    - source: observer.example
      subject: target-a
      failures_required: 4
      successes_required: 2

event_policy:
  dedupe_window: 5m
  retention: 90d

external_ingestion:
  sources: {}

presentation:
  timezone: Asia/Tokyo

llm:
  provider: openai_compatible
  base_url_env: CLUSTER_MURMUR_LLM_BASE_URL
  model_env: CLUSTER_MURMUR_LLM_MODEL
  api_key_file_env: CLUSTER_MURMUR_LLM_API_KEY_FILE
  timeout: 20s
  max_output_tokens: 32768
  reasoning_effort: low

includes:
  event_groups:
    - event-groups.yaml
  personas:
    - personas/*.yaml
  bindings:
    - bindings/*.yaml
  triggers:
    - triggers/*.yaml
  routing:
    - routing.yaml
```

The version 1 manifest requires exactly `version`, `llm`, and `includes`, and
optionally accepts exact `state_tracking`, `conversation_defaults`,
`event_policy`, `external_ingestion`, and `presentation` mappings. Omitting
`external_ingestion` uses an empty source allowlist and opens no ingestion
listener. A non-empty source map enables the separately configured authenticated
loopback listener described in [external integrations](integrations.md).
Omitting `presentation` uses
`Etc/UTC`. Its timezone must be an IANA name from the embedded database and
controls only prompt-facing timestamp representation. Omitting `event_policy` uses a five-minute dedupe
window and 90-day retention. Both event durations must be positive, no longer
than 365 days, and retention must be at least the dedupe window. Trigger
authorization enforces the dedupe window. Fixed bounded retention paths can
delete expired markers and unreferenced event records.
Omitting `state_tracking` uses the fixed two-failure and two-success defaults.
All five include categories must be present, even when a category has no
patterns. Every other field or category is invalid. Category values are lists
of strings. The 64-pattern limit applies to the sum across every category, not
separately to each resolver call.

Relative paths are resolved from the directory containing the top-level file.
Version 1 include paths use portable ASCII characters and support only
non-recursive `*` globs. Absolute paths, `..`, other glob operators, symlink
loops, non-file targets, and canonical targets outside the configuration root
are invalid. A top-level configuration may declare at most 64 include patterns;
each pattern is at most 512 bytes and must match at least one file; resolution
rejects after wildcard directory listings cumulatively return more than 1,024
entries, and the combined result is limited to 256 unique files. Erlang/OTP
materializes each individual directory listing before this check, so the
trusted configuration tree must not contain unbounded directories. Portable
filename rules also apply to canonical targets. Safe symlinks inside the root
are canonicalized with a limit of 40 symlink expansions per resolved path. The
configuration tree must be trusted and read-only until loading finishes.
Results are deduplicated and sorted, so glob expansion order has no semantic
meaning. Identical patterns are evaluated once when shared by categories. The
1,024 inspected-entry and 256 unique-file budgets apply across the complete
manifest, not independently to each category. The manifest loader first returns
the validated manifest and these canonical paths as a categorized load plan.
Its next stage decodes each unique included YAML file once, retains its source
path for later relative-reference handling, and preserves the category lists.
The generic document-loading stage does not apply category-specific schemas or
semantic validation. Event-group documents can then be structurally validated
and combined into a redacted configuration set. Failures
identify the top-level document, manifest, includes, or included-document stage
without including rejected values or paths. Configuration structs omit include
patterns, paths, and decoded values from their inspection output. Configuration
is loaded once at startup; hot reload is outside the MVP.

Each YAML file is limited to 256 KiB and must contain exactly one mapping-rooted
document. Keys must be strings. Decoding accepts only strings, nulls, booleans,
integers, finite floats, sequences, and mappings. It rejects duplicate keys,
anchors, aliases, tag directives, YAML versions other than 1.2, scalars larger
than 16 KiB, more than 4,096 nodes, or collection nesting deeper than 16 levels.
Prompt files are loaded separately from YAML. A prompt reference is a portable
relative path of at most 512 bytes, resolved from the canonical persona source
file. Parent components may address a sibling directory, but the canonical
regular-file target must remain inside the configuration root and use portable
ASCII path components. Prompt files must be non-empty, valid UTF-8, and no
larger than 64 KiB. Canonical resolution follows at most 40 symlinks. Prompt
errors do not include paths or contents.

## Validation

After the top-level manifest is decoded and validated, category configuration
validation has two fail-closed stages:

1. JSON Schema validates document structure and rejects unknown fields.
2. Elixir semantic validation resolves references and validates values that
   JSON Schema cannot safely establish.

Version 1 schemas use JSON Schema Draft 7, are compiled from application source,
and cannot use `$ref`, `id`, or `$id`. Operator configuration cannot supply a
schema, filesystem path, or schema resolver. Unknown formats are ignored
locally instead of invoking a globally configured callback. The
`contentEncoding` and `contentMediaType` keywords are unsupported because their
implementation delegates document data to a global decoder. Validation errors
never include the library's detailed paths or rejected values.
Schema source must be a proper JSON-compatible tree with string object keys,
and compiled validators are rechecked before use rather than trusting a public
struct value.

Startup must fail before external connections or publication when any of the
following is found:

- an unsupported configuration version;
- an unknown field;
- a duplicate ID within its ID namespace;
- a reference to an unknown persona, binding, or event group;
- a missing included file or an include that resolves to no required files;
- a malformed duration, cron expression, clock time, or IANA timezone;
- a negative weight or probability outside the inclusive range `0.0..1.0`;
- a stochastic mean interval that cannot produce a valid schedule;
- an unreadable, oversized, empty, or insecurely referenced secret file; or
- a configuration that would remove a required conversation bound.

IDs are portable ASCII strings of at most 16 KiB suitable for persistence keys.
They start with an ASCII letter or digit and continue with ASCII letters,
digits, `.`, `_`, or `-`. Human-facing fields such as `display_name` may use Unicode. Durations use
an integer followed by one of `ms`, `s`, `m`, `h`, or `d`. Times use 24-hour
`HH:MM` notation. Timezones use IANA names such as `Asia/Tokyo` or `Etc/UTC`.
