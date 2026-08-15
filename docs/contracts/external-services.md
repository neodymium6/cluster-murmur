# External service contracts

This page defines the narrow observer, model-provider, publication, clock,
randomness, and persistence boundaries. It is part of the normative
[MVP runtime contract](../mvp-contract.md).

## External dependency contracts

Domain and orchestration code use injected behaviours rather than concrete
clients:

```elixir
defmodule ClusterMurmur.Clock do
  @callback now() :: DateTime.t()
  @callback monotonic_time_ms() :: integer()
end

defmodule ClusterMurmur.Random do
  @callback uniform() :: float()
  @callback weighted_choice([{term(), number()}]) ::
              {:ok, term()} | :empty
end

defmodule ClusterMurmur.Observers.Client do
  @callback list_targets(term()) ::
              {:ok, [%{required(:id) => String.t()}]}
              | {:error, ClusterMurmur.ExternalError.t()}
  @callback observe_target(term(), String.t()) ::
              {:ok, ClusterMurmur.Observations.Observation.t()}
              | {:error, ClusterMurmur.ExternalError.t()}
end

defmodule ClusterMurmur.Generation.Provider do
  @callback generate(
              ClusterMurmur.Generation.PromptRequest.t(),
              ClusterMurmur.Generation.ProviderSettings.t(),
              (ClusterMurmur.Generation.OpenAICompatibleRequest.t() -> term())
            ) ::
              {:ok, String.t()} | {:error, ClusterMurmur.ExternalError.t()}
end

defmodule ClusterMurmur.Discord.Publisher do
  @callback publish(
              ClusterMurmur.Persistence.PublicationAttemptRecord.t(),
              ClusterMurmur.Discord.PublicationPlanner.Plan.t(),
              ClusterMurmur.Persistence.MessageRecord.t(),
              ClusterMurmur.Personas.Persona.t(),
              ClusterMurmur.Discord.WebhookSettings.t(),
              (ClusterMurmur.Discord.WebhookRequest.t() -> term())
            ) ::
              {:ok, String.t(), ClusterMurmur.Persistence.PublicationAttemptRecord.t()}
              | {:failed, ClusterMurmur.ExternalError.t(),
                 ClusterMurmur.Persistence.PublicationAttemptRecord.t()}
              | {:ambiguous, :interrupted,
                 ClusterMurmur.Persistence.PublicationAttemptRecord.t()}
              | {:error, atom()}
end
```

Tests must be able to replace every behaviour with a deterministic fake.
Persistence must similarly remain behind repository or store boundaries so
selection and conversation policy do not depend directly on Ecto queries.

The OpenAI-compatible provider adapter revalidates one fixed request before one
injected transport call. It performs no retry and returns only decoded content
or stable external error classes; raw provider responses and diagnostics remain
inside the adapter boundary. The fixed Chat Completions JSON maps the bounded
provider setting `max_output_tokens` to `max_completion_tokens`; callers cannot
select the deprecated token field or add unlisted provider parameters. One
optional closed `reasoning_effort` setting may add the corresponding request
field; omitting it preserves the endpoint's default request shape.

The live transport reconstructs the closed prompt projection and revalidates
the complete request against fixed settings, makes one deadline-bounded HTTP/1
POST, verifies TLS when selected, and bounds response headers, body bytes, and
total parser input. It provides no generic HTTP method, URL, header, retry,
redirect, proxy, or pooling interface.

Successful model responses may include one closed `finish_reason` and bounded
nonnegative `completion_tokens` and `reasoning_tokens` usage counts. These
values are validated inside the response boundary and are not returned or
logged. Null or blank message content with `finish_reason: "length"` returns
the stable `token_exhausted` class. Visible partial content remains eligible
for normalization; other blank content retains the existing normalization
fallback.

Discord publication claims one exact durable `started` attempt immediately
before invoking the injected transport. Only the compare-and-set winner may
dispatch. HTTP responses that prove rejection are known failures; malformed
successes, timeouts after dispatch, 5xx responses, and unknown transport
outcomes are ambiguous and must not be retried.

The observer adapter exposes only named, bounded, read-only operations. A
concrete adapter maps those operations to MCP tools internally, validates
arguments, and normalizes responses without exposing tool names, arbitrary
argument maps, or raw responses to application code.
Application code then rejects target lists above 256 entries or 64 KiB of ID
text, duplicate or malformed identities, and nondeterministic response order
before making any per-target observation call.
One bounded poll lists targets once, observes every accepted target once in
stable order, requires normalized observation identity to match that target,
and delegates each accepted value to atomic ingestion. Per-target failures are
classified without stopping the remaining bounded batch or exposing target
data; catalog and startup-input failures stop before observation calls.
One matched event trigger can then be planned and durably authorized without
executing its action. Only an exact redacted started capability whose event,
trigger, execution instant, and cooldown projection still match the plan may
cross into later action orchestration.
For one event, matching triggers are selected from a bounded catalog and
authorized once in stable trigger-ID order. Per-trigger cooldown, repeated-pair,
and stable failure outcomes do not stop the remaining bounded batch, while only
validated durable authorizations for triggers still exactly present in the
supplied configuration cross into later action orchestration.
One authorized `start_conversation` action is then revalidated against the
complete runtime configuration before its exact binding is used. Starter
candidates are projected from only that binding, the configured persona map,
the authorization execution instant, and one supplied bounded cooldown
snapshot. Only the final weighted choice is delegated to injected randomness.
No eligible starter is an explicit no-action result. A successful choice
produces one fully redacted plan containing the exact authorization, binding,
configured starter, and a validated pristine conversation rooted in the same
event and execution instant. Planning does not persist the conversation,
finish the trigger execution, generate content, or publish.
Immediately before persistence, that complete plan is revalidated against the
same bounded configuration and cooldown inputs. One transaction inserts the
pristine conversation and compare-and-set completes the exact started trigger
execution, so an authorization can create at most one conversation even when a
later caller supplies another conversation ID. Only exact loaded conversation
and completed-execution records correlated with the authorized event and
planned start instant may cross into later generation orchestration.
For the first turn, that capability is projected into one exact redacted
generation plan containing only the selected persona's display identity and
instructions, allowlisted confirmed event facts, fixed application-owned
creative framing derived from the validated binding group, and empty
conversation history. The plan contains a
provider-neutral structured request and performs no external call.
Generation execution revalidates that plan and exact provider settings,
including exact provider, timeout, and output-token correlation with current
public configuration. It calls one injected provider exactly once and resolves
output under Discord's content limit. Accepted output becomes an unpublished
`llm` message. After response decoding, the pure result resolver distinguishes
accepted output, provider-failure fallback, and output-normalization fallback.
Normalization rejection uses only fixed content-free classes for blank output,
the character limit, invalid Unicode, or an otherwise invalid provider result.
It never returns rejected content or provider diagnostics. Every fallback class
still becomes the same fixed deterministic fallback message. Immediately after
successful resolution, generation
orchestration emits one fixed accepted-or-fallback decision event containing
only a count and the finite decision class. Rejected content and all provider
values remain outside its metric and structured log.
The returned redacted capability retains neither credentials nor transport
values and performs no persistence or publication.
Before publication, the generated capability is revalidated and its original
loaded conversation plus unpublished message are passed to one atomic append.
Only an exact loaded message equal to the generated facts and an exact active
conversation with both turn and LLM-call counters advanced by one may cross
into publication planning.
Publication planning revalidates that complete capability, resolves the exact
selected starter from current configuration, and combines it with current exact
webhook settings. Only the committed unpublished message, that persona's
bounded display identity, and a mention-disabled fixed payload cross into later
publication execution.
Before an external request, the complete publication plan is revalidated and an
exact durable `started` attempt is recorded for the committed message. Only a
loaded attempt correlated with that message and an injected start instant at or
after message insertion may cross into dispatch claiming.
Publication execution revalidates that complete capability and delegates one
durable dispatch claim plus one transport call to the fixed publisher boundary.
Only its exact correlated `dispatching` projection may be closed. A proven
success atomically records both the terminal attempt and Discord message ID; a
known rejection records a classified failure; and an unknowable effect records
an ambiguous terminal result that this boundary never retries. Returned
capabilities exclude request, response, diagnostic, and credential values.
After proven publication success, the durable completion instant is the
persona's authoritative spoken time. Its cooldown deadline is derived only by
adding the exact current persona's bounded configured cooldown, with an omitted
optional cooldown treated as zero. Only those three exact facts cross into the
monotonic persona-cooldown store. Failed and ambiguous publication outcomes do
not record a confirmed spoken fact.
After cooldown recording, the exact binding group crosses the existing reply
gate. An explicit reply leaves the conversation active for bounded responder
orchestration. An explicit no reply closes the exact conversation advanced by
the starter append at the durable publication completion instant; only its
unchanged counters and exact loaded terminal projection may cross the boundary.
The authorized-starter coordinator preflights its complete fixed input and
adapter contracts before its first mutation, then composes these capability
boundaries without retry. A SQLite integration test injects fake generation and
Discord transports and demonstrates exactly one external call at each boundary,
one published message, a succeeded attempt, a durable persona cooldown, trigger
authorization consumption, deterministic no reply, and terminal conversation.
Reusing the consumed input must stop before another external call.

`Clock.monotonic_time_ms/0` uses milliseconds. `Random.uniform/0` returns a
finite value in `[0.0, 1.0)`, and `Random.weighted_choice/1` returns `:empty`
when its input is empty or all weights are zero. Callers must reject non-finite
or negative weights before invoking the random adapter.
