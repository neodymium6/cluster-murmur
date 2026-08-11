defmodule ClusterMurmur.Runtime.PollStarterCycle do
  @moduledoc """
  Runs one read-only observation poll through bounded starter dispatch.

  Reusable starter settings are validated before observation. After polling,
  the cycle derives a safe execution time and deterministic conversation IDs
  from the bounded plan, then immediately dispatches through the fixed concrete
  consumer. Only aggregate counts leave this boundary.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Observers.{Client, Poller}
  alias ClusterMurmur.Persistence.ObservationIngestionStore
  alias ClusterMurmur.Runtime.PersonaCooldownSnapshot
  alias ClusterMurmur.Runtime.ResponderTurnSchedule

  alias ClusterMurmur.Triggers.{
    AuthorizedConversationPipeline,
    AuthorizedConversationPipelineConsumer,
    AuthorizedStarterPipeline,
    AuthorizedStarterPipelineConsumer,
    EventConversationIdentity,
    PollEventTriggerDispatcher,
    PollEventTriggerPlanner
  }

  alias ClusterMurmur.Triggers.AuthorizedConversationPipeline.Input, as: ConversationInput

  alias ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumer.Context,
    as: ConversationConsumerContext

  alias ClusterMurmur.Triggers.AuthorizedConversationPipelineConsumer.Entry,
    as: ConversationConsumerEntry

  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Input, SharedInput}

  alias ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer.Context,
    as: StarterConsumerContext

  alias ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer.Entry,
    as: StarterConsumerEntry

  defmodule ConversationRuntime do
    @moduledoc false
    @derive {Inspect, only: [:schedule]}
    @enforce_keys [:schedule, :adapters]
    defstruct [:schedule, :adapters]

    @type t :: %__MODULE__{
            schedule: ClusterMurmur.Runtime.ResponderTurnSchedule.t(),
            adapters: ClusterMurmur.Triggers.AuthorizedConversationPipeline.Adapters.t()
          }
  end

  defmodule Context do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:shared_input, :adapters]
    defstruct [:shared_input, :adapters, conversation_runtime: nil]

    @type t :: %__MODULE__{
            shared_input: ClusterMurmur.Triggers.AuthorizedStarterPipeline.SharedInput.t(),
            adapters: ClusterMurmur.Triggers.AuthorizedStarterPipeline.Adapters.t(),
            conversation_runtime:
              ClusterMurmur.Runtime.PollStarterCycle.ConversationRuntime.t()
              | nil
          }
  end

  defmodule Result do
    @moduledoc false

    @derive {Inspect,
             only: [
               :target_count,
               :ingested_count,
               :event_count,
               :poll_failure_count,
               :match_count,
               :dispatched_count,
               :skipped_count,
               :dispatch_failure_count
             ]}
    @enforce_keys [
      :target_count,
      :ingested_count,
      :event_count,
      :poll_failure_count,
      :match_count,
      :dispatched_count,
      :skipped_count,
      :dispatch_failure_count
    ]
    defstruct [
      :target_count,
      :ingested_count,
      :event_count,
      :poll_failure_count,
      :match_count,
      :dispatched_count,
      :skipped_count,
      :dispatch_failure_count
    ]

    @type t :: %__MODULE__{
            target_count: non_neg_integer(),
            ingested_count: non_neg_integer(),
            event_count: non_neg_integer(),
            poll_failure_count: non_neg_integer(),
            match_count: non_neg_integer(),
            dispatched_count: non_neg_integer(),
            skipped_count: non_neg_integer(),
            dispatch_failure_count: non_neg_integer()
          }
  end

  @context_keys Context.__struct__() |> Map.keys()
  @context_key_count length(@context_keys)
  @conversation_runtime_keys ConversationRuntime.__struct__() |> Map.keys()
  @conversation_runtime_key_count length(@conversation_runtime_keys)
  @validation_at ~U[2026-01-01 00:00:00.000000Z]

  @type error :: :invalid_poll_starter_cycle | :poll_failed

  @doc "Validates reusable cycle dependencies without observing a target."
  @spec validate_runtime(term(), term()) :: :ok | {:error, :invalid_poll_starter_cycle}
  def validate_runtime(%Configuration{} = configuration, %Context{} = context) do
    with true <- exact_context?(context),
         true <- context.shared_input.configuration === configuration,
         :ok <-
           AuthorizedStarterPipeline.validate_shared_runtime(
             context.shared_input,
             context.adapters
           ),
         :ok <- validate_cooldown_store(context.adapters.cooldown_store),
         :ok <- validate_conversation_runtime(context) do
      :ok
    else
      _failure -> {:error, :invalid_poll_starter_cycle}
    end
  rescue
    _error -> {:error, :invalid_poll_starter_cycle}
  catch
    _kind, _reason -> {:error, :invalid_poll_starter_cycle}
  end

  def validate_runtime(_configuration, _context), do: {:error, :invalid_poll_starter_cycle}

  @doc "Runs one bounded poll and immediately consumes every authorized match."
  @spec run(Client.t(), Configuration.t(), term(), Context.t(), module()) ::
          {:ok, Result.t()} | {:error, error()}
  def run(
        observer_client,
        configuration,
        cycle_started_at,
        context,
        ingestion_store \\ ObservationIngestionStore
      )

  def run(
        %Client{} = observer_client,
        %Configuration{} = configuration,
        cycle_started_at,
        %Context{} = context,
        ingestion_store
      )
      when is_atom(ingestion_store) do
    with :ok <- preflight(configuration, cycle_started_at, context),
         {:ok, cooldowns} <-
           PersonaCooldownSnapshot.load(configuration, context.adapters.cooldown_store),
         context <- with_cooldowns(context, cooldowns),
         {:ok, poll_result} <-
           Poller.poll_once(observer_client, configuration.state_tracking, ingestion_store),
         executed_at <- safe_executed_at(cycle_started_at, poll_result.events),
         {:ok, plan} <- PollEventTriggerPlanner.plan(poll_result, configuration, executed_at),
         {:ok, consumer, consumer_context} <-
           build_consumer_context(plan, context, executed_at),
         {:ok, dispatch_result} <-
           PollEventTriggerDispatcher.dispatch(
             plan,
             poll_result,
             configuration,
             consumer,
             consumer_context
           ) do
      {:ok, summarize(poll_result, dispatch_result)}
    else
      {:error, reason}
      when reason in [
             :invalid_persona_cooldown_snapshot,
             :persona_cooldown_snapshot_failed
           ] ->
        {:error, :poll_failed}

      {:error, reason}
      when reason in [:invalid_poll, :invalid_observer_targets] or
             (is_tuple(reason) and tuple_size(reason) == 2 and elem(reason, 0) == :observer) ->
        {:error, :poll_failed}

      _failure ->
        {:error, :invalid_poll_starter_cycle}
    end
  rescue
    _error -> {:error, :invalid_poll_starter_cycle}
  catch
    _kind, _reason -> {:error, :invalid_poll_starter_cycle}
  end

  def run(_observer_client, _configuration, _cycle_started_at, _context, _ingestion_store),
    do: {:error, :invalid_poll_starter_cycle}

  defp preflight(configuration, cycle_started_at, context) do
    with :ok <- validate_runtime(configuration, context),
         :ok <- DateTimeValidator.validate_storage_utc(cycle_started_at) do
      :ok
    else
      _failure -> {:error, :invalid_poll_starter_cycle}
    end
  end

  defp with_cooldowns(context, cooldowns) do
    shared_input = %{context.shared_input | cooldowns: cooldowns}
    %{context | shared_input: shared_input}
  end

  defp validate_cooldown_store(store) do
    if is_atom(store) and Code.ensure_loaded?(store) and function_exported?(store, :fetch, 1),
      do: :ok,
      else: {:error, :invalid_poll_starter_cycle}
  end

  defp safe_executed_at(cycle_started_at, events) do
    Enum.reduce(events, cycle_started_at, fn event, latest ->
      latest
      |> later(event.occurred_at)
      |> later(event.observed_at)
    end)
  end

  defp later(left, nil), do: left
  defp later(left, right), do: if(DateTime.compare(left, right) == :lt, do: right, else: left)

  defp build_consumer_context(plan, context, executed_at) do
    with {:ok, inputs} <- build_inputs(plan.entries, context.shared_input, executed_at) do
      case context.conversation_runtime do
        nil ->
          build_starter_consumer_context(plan, inputs, context.adapters, executed_at)

        %ConversationRuntime{} = runtime ->
          build_conversation_consumer_context(plan, inputs, runtime, executed_at)

        _invalid ->
          {:error, :invalid_poll_starter_cycle}
      end
    end
  end

  defp build_inputs(entries, shared, executed_at) do
    entries
    |> expected_matches()
    |> Enum.reduce_while({:ok, []}, fn {event, trigger}, {:ok, inputs} ->
      case EventConversationIdentity.derive(event, trigger, executed_at) do
        {:ok, conversation_id} ->
          {:cont, {:ok, [build_input(shared, conversation_id, executed_at) | inputs]}}

        {:error, :invalid_event_conversation_identity} ->
          {:halt, {:error, :invalid_poll_starter_cycle}}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      {:error, :invalid_poll_starter_cycle} = error -> error
    end
  end

  defp build_starter_consumer_context(plan, inputs, adapters, executed_at) do
    matches = expected_matches(plan.entries)

    if length(inputs) == length(matches) do
      entries =
        inputs
        |> Enum.zip(matches)
        |> Enum.map(fn {input, {event, trigger}} ->
          %StarterConsumerEntry{
            input: input,
            event: event,
            trigger: trigger,
            executed_at: executed_at
          }
        end)

      {:ok, AuthorizedStarterPipelineConsumer,
       %StarterConsumerContext{entries: entries, adapters: adapters}}
    else
      {:error, :invalid_poll_starter_cycle}
    end
  end

  defp build_conversation_consumer_context(plan, inputs, runtime, executed_at) do
    with {:ok, turns} <- ResponderTurnSchedule.project(runtime.schedule, executed_at),
         matches <- expected_matches(plan.entries),
         true <- length(inputs) == length(matches) do
      entries =
        inputs
        |> Enum.zip(matches)
        |> Enum.map(fn {starter, {event, trigger}} ->
          %ConversationConsumerEntry{
            input: %ConversationInput{starter: starter, responder_turns: turns},
            event: event,
            trigger: trigger,
            executed_at: executed_at
          }
        end)

      {:ok, AuthorizedConversationPipelineConsumer,
       %ConversationConsumerContext{entries: entries, adapters: runtime.adapters}}
    else
      _failure -> {:error, :invalid_poll_starter_cycle}
    end
  end

  defp expected_matches(entries) do
    Enum.flat_map(entries, fn entry ->
      Enum.map(entry.triggers, fn trigger -> {entry.event, trigger} end)
    end)
  end

  defp build_input(%SharedInput{} = shared, conversation_id, executed_at) do
    %Input{
      authorization: nil,
      configuration: shared.configuration,
      cooldowns: shared.cooldowns,
      conversation_id: conversation_id,
      provider_settings: shared.provider_settings,
      webhook_settings: shared.webhook_settings,
      generated_at: executed_at,
      publication_started_at: executed_at,
      publication_completed_at: executed_at,
      generation_transport: shared.generation_transport,
      publication_transport: shared.publication_transport
    }
  end

  defp summarize(poll_result, dispatch_result) do
    %Result{
      target_count: poll_result.target_count,
      ingested_count: poll_result.ingested_count,
      event_count: poll_result.event_count,
      poll_failure_count: poll_result.failure_count,
      match_count: dispatch_result.match_count,
      dispatched_count: dispatch_result.dispatched_count,
      skipped_count: dispatch_result.skipped_count,
      dispatch_failure_count: dispatch_result.failure_count
    }
  end

  defp validate_conversation_runtime(%Context{conversation_runtime: nil}), do: :ok

  defp validate_conversation_runtime(%Context{
         shared_input: shared,
         adapters: starter_adapters,
         conversation_runtime: %ConversationRuntime{} = runtime
       }) do
    with true <- exact_conversation_runtime?(runtime),
         true <- runtime.adapters.starter === starter_adapters,
         {:ok, turns} <- ResponderTurnSchedule.project(runtime.schedule, @validation_at),
         starter = build_input(shared, "conversation-validation", @validation_at),
         input = %ConversationInput{starter: starter, responder_turns: turns},
         :ok <-
           AuthorizedConversationPipeline.validate_shared_runtime(
             input,
             runtime.adapters,
             @validation_at
           ) do
      :ok
    else
      _failure -> {:error, :invalid_poll_starter_cycle}
    end
  end

  defp validate_conversation_runtime(_context), do: {:error, :invalid_poll_starter_cycle}

  defp exact_context?(context) do
    map_size(context) == @context_key_count and
      Enum.all?(@context_keys, &Map.has_key?(context, &1))
  end

  defp exact_conversation_runtime?(runtime) do
    map_size(runtime) == @conversation_runtime_key_count and
      Enum.all?(@conversation_runtime_keys, &Map.has_key?(runtime, &1))
  end
end
