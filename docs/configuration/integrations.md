# External integrations

This page defines fixed LLM, Discord, and observer integration settings. It is
part of the normative [configuration reference](../configuration.md).

## External event allowlists

The optional top-level `external_ingestion` mapping declares which normalized
events a later authenticated boundary may accept:

```yaml
external_ingestion:
  sources:
    alert-adapter:
      event_types:
        - component.failed
        - component.recovered
      groups:
        - operations
      subjects:
        - example-component
      fact_keys:
        - state
        - summary
      label_keys:
        - site
```

Omitting the mapping, or configuring an empty `sources` map, disables later
external ingestion. The mapping contains no listener address, secret, endpoint,
trigger, binding, persona, prompt, model, or publisher selection. It does not by
itself start a listener or make any network boundary available.

At most 32 sources are accepted. Each source has exactly the five allowlists
shown above, with at most 256 unique portable identifiers in each list. Event
types, groups, and subjects must be non-empty; fact and label key lists may be
empty. Every group must reference the existing event-group catalog. A normalized
event may contain only flat scalar facts and flat string labels whose keys are
allowed for its exact source. Severity is limited to `info`, `warning`, or
`critical`.

## LLM provider

The first provider uses an OpenAI-compatible API:

```yaml
llm:
  provider: openai_compatible
  base_url_env: CLUSTER_MURMUR_LLM_BASE_URL
  model_env: CLUSTER_MURMUR_LLM_MODEL
  api_key_file_env: CLUSTER_MURMUR_LLM_API_KEY_FILE
  timeout: 20s
  max_output_tokens: 32768
  reasoning_effort: low
```

`base_url_env` and `model_env` name environment variables containing deployment
values. `api_key_file_env` names an environment variable whose value is the
path to a mounted secret file. The API key itself is never accepted in YAML or
as a direct environment-variable value. The manifest parser requires the six
base fields shown above, supports only `openai_compatible`, bounds `timeout` to
1 through 120,000 milliseconds after duration parsing, and bounds
`max_output_tokens` to 1 through 32,768. `reasoning_effort` is optional and
accepts only `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`.
Supported effort values vary by model, so operators must select a value accepted
by their configured endpoint. Omitting it preserves the provider's default and
does not add the field to the request. The normalized redacted value enters the
complete startup configuration. The runtime settings boundary accepts it
directly, resolves the three deployment values with fixed bounds, and does not
make a provider connection.

The shipped live adapter appends only `/chat/completions`. Its fixed JSON shape
maps `max_output_tokens` to the current Chat Completions
`max_completion_tokens` field; it does not send the deprecated `max_tokens`
field. When configured, it maps the closed effort value to the Chat Completions
`reasoning_effort` field. The adapter reconstructs the closed prompt projection
and revalidates the settings and complete encoded request before dispatch. It
opens one HTTP/1 connection per generation. HTTPS uses operating-system CA and
hostname verification. Responses are limited to 16 KiB of headers, 64 KiB of
body, 96 KiB of total HTTP parser input, and the configured overall timeout.
The adapter does not follow redirects, retry, use deployment proxy settings,
pool connections, or expose arbitrary request values. For successful responses,
present finish reasons must be closed values and present completion and
reasoning token counts must be bounded nonnegative integers. A `length`
completion with no visible content becomes the stable `token_exhausted` error;
raw content, usage payloads, and provider diagnostics remain private.

## Discord routing

The MVP publishes through one pre-created webhook and therefore supports only
the default route:

```yaml
routing:
  default:
    webhook_secret_file_env: CLUSTER_MURMUR_DISCORD_WEBHOOK_FILE
```

The named environment variable contains the path to a mounted file, not the
webhook URL. Its name is a portable ASCII environment-variable identifier of at
most 128 bytes. Version 1 requires exactly one default routing document.
Group-specific routes are a post-MVP extension. Their future shape
is reserved as `routing.groups`, but version 1 validation must reject that field
until multi-channel routing is implemented and reviewed. The implemented
runtime settings boundary loads this file with fixed bounds and accepts only a
token-bearing HTTPS Discord incoming-webhook URL; it does not execute the
webhook.

Startup loads the observer, provider, and webhook boundaries into one redacted
runtime settings aggregate before constructing any external adapter. A failure
is identified only as a stable observer, provider, or webhook settings error;
deployment values and secret-file paths are never included in the aggregate's
inspection output or returned errors. This combined step still performs no
network call. The startup preparation boundary runs complete configuration
loading before this settings step and returns them together only after all
inputs validate. It does not start runtime workers or external transports.

## Observer MCP runtime settings

The standalone runtime resolves the fixed Cluster Observer connection inputs
from deployment-owned environment variables rather than public YAML:

- `CLUSTER_MURMUR_OBSERVER_MCP_URL` contains the exact MCP endpoint. It must be
  a normalized HTTPS URL whose path is exactly `/mcp`, without user information,
  query, or fragment. Plain HTTP is accepted only for `localhost`, `127.0.0.1`,
  or `::1` loopback sidecars.
- `CLUSTER_MURMUR_OBSERVER_MCP_TOKEN_FILE` contains an absolute path to a
  mounted file holding the bearer token. The shared bounded secret reader
  validates and reads the file; the token is never accepted directly in an
  environment variable.

The resulting settings value is redacted and returns only stable value-free
errors. Loading it does not connect to the observer or expose an arbitrary HTTP
request boundary. The observer request encoder combines only these settings and
the two application-selected read-only operations into MCP 2026-07-28
Streamable HTTP `tools/call` messages. It fixes the POST method, endpoint,
protocol metadata, bearer authorization, headers, JSON-RPC envelope, timeouts,
and response limit, and revalidates the complete value before later transport.
The paired response boundary accepts only bounded JSON or request-scoped SSE,
discards notifications and raw diagnostics, correlates the fixed JSON-RPC ID,
and projects only a complete non-error `structuredContent` value into the
existing observer decoder. Both boundaries still perform no network request.
The live observer transport consumes only these independently revalidated
values. It opens one passive HTTP/1 connection, verifies remote TLS against the
operating-system trust store and hostname, sends one POST, incrementally accepts
at most 64 KiB of body data, then closes the connection. It does not redirect,
retry, use a proxy, pool connections, or expose a generic HTTP interface.
The production application assembles this fixed transport after all startup
inputs validate; loading configuration alone still performs no network work.
