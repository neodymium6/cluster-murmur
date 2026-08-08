defmodule ClusterMurmur.Triggers.AuthorizedStarterPipeline do
  @moduledoc """
  Runs one authorized event through the bounded starter-message vertical slice.

  All deployment settings, clocks, randomness, stores, providers, and transports
  are explicit inputs. The pipeline preflights their fixed contracts before its
  first persistence mutation, then composes the existing exact redacted
  capabilities. It does not observe infrastructure, authorize events, retry
  external effects, or handle a responder continuation.
  """

  alias ClusterMurmur.Config.{Configuration, Value}
  alias ClusterMurmur.Conversations.StarterReplyFinisher
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Discord.{
    StarterPublicationExecutor,
    StarterPublicationPlanner,
    StarterPublicationStarter,
    WebhookSettings
  }

  alias ClusterMurmur.Generation.{
    ProviderSettings,
    StarterGenerationPlanner,
    StarterGenerator,
    StarterMessagePersister
  }

  alias ClusterMurmur.Personas.{StarterCandidateProjector, StarterCooldownRecorder}

  alias ClusterMurmur.Triggers.{
    EventTriggerAuthorizer,
    EventTriggerConversationPlanner,
    EventTriggerConversationStarter
  }

  defmodule Input do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [
      :authorization,
      :configuration,
      :cooldowns,
      :conversation_id,
      :provider_settings,
      :webhook_settings,
      :generated_at,
      :publication_started_at,
      :publication_completed_at,
      :generation_transport,
      :publication_transport
    ]
    defstruct [
      :authorization,
      :configuration,
      :cooldowns,
      :conversation_id,
      :provider_settings,
      :webhook_settings,
      :generated_at,
      :publication_started_at,
      :publication_completed_at,
      :generation_transport,
      :publication_transport
    ]

    @type t :: %__MODULE__{
            authorization: ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization.t(),
            configuration: ClusterMurmur.Config.Configuration.t(),
            cooldowns: map(),
            conversation_id: String.t(),
            provider_settings: ClusterMurmur.Generation.ProviderSettings.t(),
            webhook_settings: ClusterMurmur.Discord.WebhookSettings.t(),
            generated_at: DateTime.t(),
            publication_started_at: DateTime.t(),
            publication_completed_at: DateTime.t(),
            generation_transport: function(),
            publication_transport: function()
          }
  end

  defmodule Adapters do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [
      :conversation_action_store,
      :provider,
      :message_store,
      :publication_start_store,
      :publisher,
      :publication_terminal_store,
      :cooldown_store,
      :conversation_store,
      :starter_random,
      :reply_random
    ]
    defstruct [
      :conversation_action_store,
      :provider,
      :message_store,
      :publication_start_store,
      :publisher,
      :publication_terminal_store,
      :cooldown_store,
      :conversation_store,
      :starter_random,
      :reply_random
    ]

    @type t :: %__MODULE__{
            conversation_action_store: module(),
            provider: module(),
            message_store: module(),
            publication_start_store: module(),
            publisher: module(),
            publication_terminal_store: module(),
            cooldown_store: module(),
            conversation_store: module(),
            starter_random: module(),
            reply_random: module()
          }
  end

  @input_keys Input.__struct__() |> Map.keys()
  @input_key_count length(@input_keys)
  @adapter_keys Adapters.__struct__() |> Map.keys()
  @adapter_key_count length(@adapter_keys)

  @type result ::
          {:ok, ClusterMurmur.Conversations.StarterReplyFinisher.Completed.t()}
          | {:continue, :reply, ClusterMurmur.Personas.StarterCooldownRecorder.Recorded.t()}
          | {:skip, :no_starter}
          | {:failed, atom(), ClusterMurmur.Discord.StarterPublicationExecutor.Outcome.t()}
          | {:ambiguous, :interrupted,
             ClusterMurmur.Discord.StarterPublicationExecutor.Outcome.t()}
          | {:error, atom()}

  @doc "Runs one exact authorization through starter completion or reply continuation."
  @spec run(term(), term()) :: result()
  def run(%Input{} = input, %Adapters{} = adapters) do
    with :ok <- preflight(input, adapters),
         {:ok, conversation_plan} <-
           EventTriggerConversationPlanner.plan(
             input.authorization,
             input.configuration,
             input.cooldowns,
             input.conversation_id,
             adapters.starter_random
           ),
         {:ok, started} <-
           EventTriggerConversationStarter.start(
             conversation_plan,
             input.configuration,
             input.cooldowns,
             adapters.conversation_action_store
           ),
         {:ok, generation_plan} <-
           StarterGenerationPlanner.plan(started, input.configuration, input.cooldowns),
         {:ok, generated} <-
           StarterGenerator.generate(
             generation_plan,
             input.configuration,
             input.cooldowns,
             input.provider_settings,
             input.generated_at,
             adapters.provider,
             input.generation_transport
           ),
         {:ok, persisted} <-
           StarterMessagePersister.persist(
             generated,
             input.configuration,
             input.cooldowns,
             adapters.message_store
           ),
         {:ok, publication_plan} <-
           StarterPublicationPlanner.plan(
             persisted,
             input.configuration,
             input.cooldowns,
             input.webhook_settings
           ),
         {:ok, publication_started} <-
           StarterPublicationStarter.start(
             publication_plan,
             input.configuration,
             input.cooldowns,
             input.webhook_settings,
             input.publication_started_at,
             adapters.publication_start_store
           ),
         {:ok, published} <-
           StarterPublicationExecutor.execute(
             publication_started,
             input.configuration,
             input.cooldowns,
             input.webhook_settings,
             input.publication_completed_at,
             input.publication_transport,
             adapters.publisher,
             adapters.publication_terminal_store
           ),
         {:ok, recorded} <-
           StarterCooldownRecorder.record(
             published,
             input.configuration,
             input.cooldowns,
             input.webhook_settings,
             adapters.cooldown_store
           ) do
      finish(recorded, input, adapters)
    else
      {:skip, :no_starter} = skip -> skip
      {:failed, _reason, _outcome} = failed -> failed
      {:ambiguous, :interrupted, _outcome} = ambiguous -> ambiguous
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _failure -> {:error, :invalid_starter_pipeline}
    end
  rescue
    _error -> {:error, :invalid_starter_pipeline}
  catch
    _kind, _reason -> {:error, :invalid_starter_pipeline}
  end

  def run(_input, _adapters), do: {:error, :invalid_starter_pipeline}

  @doc "Validates all starter inputs that do not depend on an authorization."
  @spec validate_shared_input(term(), term()) :: :ok | {:error, :invalid_starter_pipeline}
  def validate_shared_input(%Input{} = input, %Adapters{} = adapters) do
    with true <- exact_input?(input),
         true <- exact_adapters?(adapters),
         :ok <- Configuration.validate(input.configuration),
         :ok <- StarterCandidateProjector.validate_cooldowns(input.cooldowns),
         {:ok, _conversation_id} <- Value.id(input.conversation_id),
         :ok <- validate_provider_settings(input.provider_settings, input.configuration),
         :ok <- WebhookSettings.validate(input.webhook_settings),
         :ok <- validate_shared_times(input),
         :ok <- validate_transports(input),
         :ok <- validate_adapters(adapters) do
      :ok
    else
      _failure -> {:error, :invalid_starter_pipeline}
    end
  rescue
    _error -> {:error, :invalid_starter_pipeline}
  catch
    _kind, _reason -> {:error, :invalid_starter_pipeline}
  end

  def validate_shared_input(_input, _adapters), do: {:error, :invalid_starter_pipeline}

  defp finish(recorded, input, adapters) do
    case StarterReplyFinisher.finish(
           recorded,
           input.configuration,
           input.cooldowns,
           input.webhook_settings,
           adapters.reply_random,
           adapters.conversation_store
         ) do
      {:ok, completed} -> {:ok, completed}
      {:continue, :reply} -> {:continue, :reply, recorded}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _failure -> {:error, :invalid_starter_pipeline}
    end
  end

  defp preflight(input, adapters) do
    with :ok <- validate_shared_input(input, adapters),
         :ok <- EventTriggerAuthorizer.validate(input.authorization),
         :ok <- validate_authorization_times(input) do
      :ok
    else
      _failure -> {:error, :invalid_starter_pipeline}
    end
  end

  defp validate_provider_settings(settings, configuration) do
    llm = configuration.llm

    if ProviderSettings.validate(settings) == :ok and settings.provider === llm.provider and
         settings.timeout_ms === llm.timeout_ms and
         settings.max_output_tokens === llm.max_output_tokens,
       do: :ok,
       else: {:error, :invalid_starter_pipeline}
  end

  defp validate_shared_times(input) do
    with :ok <- DateTimeValidator.validate_storage_utc(input.generated_at),
         :ok <- DateTimeValidator.validate_storage_utc(input.publication_started_at),
         :ok <- DateTimeValidator.validate_storage_utc(input.publication_completed_at),
         true <-
           DateTime.compare(input.publication_started_at, input.generated_at) in [:gt, :eq],
         true <-
           DateTime.compare(input.publication_completed_at, input.publication_started_at) in [
             :gt,
             :eq
           ] do
      :ok
    else
      _failure -> {:error, :invalid_starter_pipeline}
    end
  end

  defp validate_authorization_times(input) do
    event = input.authorization.plan.event
    latest_event_at = latest_event_at(event)

    if DateTime.compare(input.generated_at, latest_event_at) in [:gt, :eq] and
         DateTime.compare(input.generated_at, input.authorization.plan.executed_at) in [:gt, :eq],
       do: :ok,
       else: {:error, :invalid_starter_pipeline}
  end

  defp validate_transports(input) do
    if is_function(input.generation_transport, 1) and
         is_function(input.publication_transport, 1),
       do: :ok,
       else: {:error, :invalid_starter_pipeline}
  end

  defp validate_adapters(adapters) do
    requirements = [
      {adapters.conversation_action_store, [consume: 1]},
      {adapters.provider, [generate: 3]},
      {adapters.message_store, [append: 2]},
      {adapters.publication_start_store, [start: 5]},
      {adapters.publisher, [publish: 6]},
      {adapters.publication_terminal_store, [succeed: 4, fail: 3, mark_ambiguous: 2]},
      {adapters.cooldown_store, [record_spoken: 3]},
      {adapters.conversation_store, [complete: 2]},
      {adapters.starter_random, [weighted_choice: 1]},
      {adapters.reply_random, [uniform: 0]}
    ]

    if Enum.all?(requirements, fn {module, functions} ->
         is_atom(module) and Code.ensure_loaded?(module) and
           Enum.all?(functions, fn {function, arity} ->
             function_exported?(module, function, arity)
           end)
       end),
       do: :ok,
       else: {:error, :invalid_starter_pipeline}
  end

  defp latest_event_at(%{observed_at: nil, occurred_at: occurred_at}), do: occurred_at

  defp latest_event_at(%{observed_at: observed_at, occurred_at: occurred_at}) do
    if DateTime.compare(observed_at, occurred_at) == :lt, do: occurred_at, else: observed_at
  end

  defp exact_input?(input) do
    map_size(input) == @input_key_count and Enum.all?(@input_keys, &Map.has_key?(input, &1))
  end

  defp exact_adapters?(adapters) do
    map_size(adapters) == @adapter_key_count and
      Enum.all?(@adapter_keys, &Map.has_key?(adapters, &1))
  end
end
