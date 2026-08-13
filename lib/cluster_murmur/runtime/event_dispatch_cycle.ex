defmodule ClusterMurmur.Runtime.EventDispatchCycle do
  @moduledoc """
  Runs one bounded durable event-dispatch batch through fixed conversations.

  Current durable cooldowns and the complete candidate, event, trigger, and
  authorization-free consumer batch are validated before the first outbox
  claim. Each claimed entry is completed only after all of its planned matches
  reach a terminal accepted outcome.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Persistence.{EventDispatchStore, EventStore}

  alias ClusterMurmur.Runtime.{
    EventDispatchBatchLoader,
    EventDispatchConsumerContext,
    EventDispatchExecutor,
    PersonaCooldownSnapshot
  }

  alias ClusterMurmur.Triggers.{
    AuthorizedStarterPipeline,
    EventDispatchPlanner,
    EventTriggerAuthorizer
  }

  alias ClusterMurmur.Triggers.EventDispatchPlanner.Plan

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
              ClusterMurmur.Runtime.EventDispatchCycle.ConversationRuntime.t() | nil
          }
  end

  defmodule Adapters do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [:dispatches, :events, :authorizer]
    defstruct [:dispatches, :events, :authorizer]

    @type t :: %__MODULE__{
            dispatches: module(),
            events: module(),
            authorizer: module()
          }
  end

  defmodule Result do
    @moduledoc false

    @derive {
      Inspect,
      only: [
        :candidate_count,
        :claimed_count,
        :completed_count,
        :candidate_failure_count,
        :planned_match_count,
        :attempted_match_count,
        :dispatched_count,
        :skipped_count,
        :dedupe_suppressed_count,
        :dispatch_failure_count
      ]
    }
    @enforce_keys [
      :candidate_count,
      :claimed_count,
      :completed_count,
      :candidate_failure_count,
      :planned_match_count,
      :attempted_match_count,
      :dispatched_count,
      :skipped_count,
      :dispatch_failure_count
    ]
    defstruct [
      :candidate_count,
      :claimed_count,
      :completed_count,
      :candidate_failure_count,
      :planned_match_count,
      :attempted_match_count,
      :dispatched_count,
      :skipped_count,
      :dispatch_failure_count,
      dedupe_suppressed_count: 0
    ]

    @type t :: %__MODULE__{
            candidate_count: non_neg_integer(),
            claimed_count: non_neg_integer(),
            completed_count: non_neg_integer(),
            candidate_failure_count: non_neg_integer(),
            planned_match_count: non_neg_integer(),
            attempted_match_count: non_neg_integer(),
            dispatched_count: non_neg_integer(),
            skipped_count: non_neg_integer(),
            dedupe_suppressed_count: non_neg_integer(),
            dispatch_failure_count: non_neg_integer()
          }
  end

  @max_candidates 100
  @max_matches 256
  @context_keys Context.__struct__() |> Map.keys()
  @context_key_count length(@context_keys)
  @adapter_keys Adapters.__struct__() |> Map.keys()
  @adapter_key_count length(@adapter_keys)
  @result_keys Result.__struct__() |> Map.keys()
  @result_key_count length(@result_keys)

  @type error :: :event_dispatch_failed | :invalid_event_dispatch_cycle

  @doc "Validates reusable dispatch dependencies without reading the outbox."
  @spec validate_runtime(term(), term(), term()) ::
          :ok | {:error, :invalid_event_dispatch_cycle}
  def validate_runtime(
        configuration,
        context,
        adapters \\ %Adapters{
          dispatches: EventDispatchStore,
          events: EventStore,
          authorizer: EventTriggerAuthorizer
        }
      )

  def validate_runtime(
        %Configuration{} = configuration,
        %Context{} = context,
        %Adapters{} = adapters
      ) do
    with true <- exact_context?(context),
         true <- context.shared_input.configuration === configuration,
         :ok <- validate_adapters(adapters),
         :ok <-
           AuthorizedStarterPipeline.validate_shared_runtime(
             context.shared_input,
             context.adapters
           ),
         :ok <- validate_cooldown_store(context.adapters.cooldown_store),
         :ok <- EventDispatchConsumerContext.validate_conversation_runtime(context) do
      :ok
    else
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  rescue
    _error -> {:error, :invalid_event_dispatch_cycle}
  catch
    _kind, _reason -> {:error, :invalid_event_dispatch_cycle}
  end

  def validate_runtime(_configuration, _context, _adapters),
    do: {:error, :invalid_event_dispatch_cycle}

  @doc "Runs one available outbox batch through a fixed bounded consumer."
  @spec run(term(), term(), term(), term()) :: {:ok, Result.t()} | {:error, error()}
  def run(
        configuration,
        now,
        context,
        adapters \\ %Adapters{
          dispatches: EventDispatchStore,
          events: EventStore,
          authorizer: EventTriggerAuthorizer
        }
      )

  def run(
        %Configuration{} = configuration,
        %DateTime{} = now,
        %Context{} = context,
        %Adapters{} = adapters
      ) do
    with :ok <- preflight(configuration, now, context, adapters),
         {:ok, cooldowns} <-
           PersonaCooldownSnapshot.load(configuration, context.adapters.cooldown_store),
         context <- with_cooldowns(context, cooldowns),
         {:ok, candidates, events} <-
           EventDispatchBatchLoader.load(adapters.dispatches, adapters.events, now),
         {:ok, %Plan{} = plan} <- plan(candidates, events, configuration, now),
         {:ok, consumer, consumer_context} <-
           EventDispatchConsumerContext.prepare(plan, configuration, context, now),
         result <-
           EventDispatchExecutor.execute(
             plan,
             configuration,
             now,
             consumer,
             consumer_context,
             adapters
           ),
         :ok <- validate_result(result) do
      {:ok, result}
    else
      {:error, reason}
      when reason in [
             :invalid_persona_cooldown_snapshot,
             :persona_cooldown_snapshot_failed
           ] ->
        {:error, :event_dispatch_failed}

      {:error, :event_dispatch_failed} = error ->
        error

      _failure ->
        {:error, :invalid_event_dispatch_cycle}
    end
  rescue
    _error -> {:error, :invalid_event_dispatch_cycle}
  catch
    _kind, _reason -> {:error, :invalid_event_dispatch_cycle}
  end

  def run(_configuration, _now, _context, _adapters),
    do: {:error, :invalid_event_dispatch_cycle}

  @doc "Validates one redacted aggregate result."
  @spec validate_result(term()) :: :ok | {:error, :invalid_event_dispatch_cycle}
  def validate_result(%Result{} = result) do
    counts = Map.take(result, @result_keys -- [:__struct__]) |> Map.values()

    if exact_result?(result) and
         Enum.all?(counts, &(is_integer(&1) and &1 in 0..@max_matches)) and
         result.candidate_count <= @max_candidates and
         result.claimed_count <= result.candidate_count and
         result.completed_count <= result.claimed_count and
         result.candidate_count == result.completed_count + result.candidate_failure_count and
         result.planned_match_count <= @max_matches and
         (result.candidate_count > 0 or result.planned_match_count == 0) and
         result.attempted_match_count <= result.planned_match_count and
         (result.claimed_count > 0 or result.attempted_match_count == 0) and
         (result.claimed_count < result.candidate_count or
            result.attempted_match_count == result.planned_match_count) and
         result.attempted_match_count ==
           result.dispatched_count + result.skipped_count + result.dispatch_failure_count and
         result.dedupe_suppressed_count <= result.skipped_count and
         (result.completed_count < result.claimed_count or result.dispatch_failure_count == 0) do
      :ok
    else
      {:error, :invalid_event_dispatch_cycle}
    end
  rescue
    _error -> {:error, :invalid_event_dispatch_cycle}
  catch
    _kind, _reason -> {:error, :invalid_event_dispatch_cycle}
  end

  def validate_result(_result), do: {:error, :invalid_event_dispatch_cycle}

  defp preflight(configuration, now, context, adapters) do
    with :ok <- validate_runtime(configuration, context, adapters),
         :ok <- DateTimeValidator.validate_storage_utc(now) do
      :ok
    else
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  end

  defp with_cooldowns(context, cooldowns) do
    shared_input = %{context.shared_input | cooldowns: cooldowns}
    %{context | shared_input: shared_input}
  end

  defp validate_cooldown_store(store) do
    if is_atom(store) and Code.ensure_loaded?(store) and function_exported?(store, :fetch, 1),
      do: :ok,
      else: {:error, :invalid_event_dispatch_cycle}
  end

  defp validate_adapters(adapters) do
    with true <- exact_adapters?(adapters),
         true <- valid_module?(adapters.dispatches, list_available: 1, claim: 2, complete: 2),
         true <- valid_module?(adapters.events, fetch: 1),
         true <- valid_module?(adapters.authorizer, authorize: 4) do
      :ok
    else
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  end

  defp valid_module?(module, functions) do
    is_atom(module) and Code.ensure_loaded?(module) and
      Enum.all?(functions, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  defp plan(candidates, events, configuration, now) do
    case EventDispatchPlanner.plan(candidates, events, configuration, now) do
      {:ok, %Plan{} = plan} -> {:ok, plan}
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  end

  defp exact_context?(context) do
    map_size(context) == @context_key_count and
      Enum.all?(@context_keys, &Map.has_key?(context, &1))
  end

  defp exact_adapters?(adapters) do
    map_size(adapters) == @adapter_key_count and
      Enum.all?(@adapter_keys, &Map.has_key?(adapters, &1))
  end

  defp exact_result?(result) do
    map_size(result) == @result_key_count and Enum.all?(@result_keys, &Map.has_key?(result, &1))
  end
end
