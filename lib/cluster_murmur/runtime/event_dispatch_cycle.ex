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

  alias ClusterMurmur.Persistence.{
    EventDispatch,
    EventDispatchClaim,
    EventDispatchStore,
    EventStore
  }

  alias ClusterMurmur.Runtime.{
    EventDispatchBatchLoader,
    PersonaCooldownSnapshot,
    ResponderTurnSchedule
  }

  alias ClusterMurmur.Triggers.{
    AuthorizedConversationPipeline,
    AuthorizedConversationPipelineConsumer,
    AuthorizedStarterPipeline,
    AuthorizedStarterPipelineConsumer,
    EventConversationIdentity,
    EventDispatchPlanner,
    EventTriggerAuthorizer
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

  alias ClusterMurmur.Triggers.EventDispatchPlanner.Plan
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization

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
  @claim_lease_seconds 60
  @claim_token_bytes 32
  @validation_at ~U[2026-01-01 00:00:00.000000Z]
  @terminal_skip_reasons [:already_terminal, :cooldown, :dedupe_window]
  @nonterminal_skip_reasons [:execution_in_progress]
  @failure_reasons [
    :authorization_failed,
    :event_conflict,
    :event_not_found,
    :invalid_execution,
    :storage_unavailable
  ]
  @claim_keys EventDispatchClaim.__struct__() |> Map.keys()
  @claim_key_count length(@claim_keys)
  @dispatch_keys EventDispatch.__struct__() |> Map.keys()
  @dispatch_key_count length(@dispatch_keys)
  @context_keys Context.__struct__() |> Map.keys()
  @context_key_count length(@context_keys)
  @conversation_runtime_keys ConversationRuntime.__struct__() |> Map.keys()
  @conversation_runtime_key_count length(@conversation_runtime_keys)
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
         :ok <- validate_conversation_runtime(context) do
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
         {:ok, consumer, consumer_context} <- build_consumer_context(plan, context, now),
         :ok <- preflight_consumer(consumer, plan, configuration, consumer_context),
         result <-
           execute(
             plan,
             configuration.event_policy,
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

  defp build_consumer_context(plan, context, now) do
    with {:ok, inputs} <- build_inputs(plan.entries, context.shared_input, now) do
      case context.conversation_runtime do
        nil -> build_starter_context(plan, inputs, context.adapters, now)
        %ConversationRuntime{} = runtime -> build_conversation_context(plan, inputs, runtime, now)
        _invalid -> {:error, :invalid_event_dispatch_cycle}
      end
    end
  end

  defp build_inputs(entries, shared, now) do
    entries
    |> expected_matches()
    |> Enum.reduce_while({:ok, []}, fn {event, trigger}, {:ok, inputs} ->
      case EventConversationIdentity.derive(event, trigger, now) do
        {:ok, conversation_id} ->
          {:cont, {:ok, [build_input(shared, conversation_id, now) | inputs]}}

        _failure ->
          {:halt, {:error, :invalid_event_dispatch_cycle}}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      error -> error
    end
  end

  defp build_starter_context(plan, inputs, adapters, now) do
    matches = expected_matches(plan.entries)

    if length(inputs) == length(matches) do
      entries =
        Enum.zip_with(inputs, matches, fn input, {event, trigger} ->
          %StarterConsumerEntry{input: input, event: event, trigger: trigger, executed_at: now}
        end)

      {:ok, AuthorizedStarterPipelineConsumer,
       %StarterConsumerContext{entries: entries, adapters: adapters}}
    else
      {:error, :invalid_event_dispatch_cycle}
    end
  end

  defp build_conversation_context(plan, inputs, runtime, now) do
    with {:ok, turns} <- ResponderTurnSchedule.project(runtime.schedule, now),
         matches <- expected_matches(plan.entries),
         true <- length(inputs) == length(matches) do
      entries =
        Enum.zip_with(inputs, matches, fn starter, {event, trigger} ->
          %ConversationConsumerEntry{
            input: %ConversationInput{starter: starter, responder_turns: turns},
            event: event,
            trigger: trigger,
            executed_at: now
          }
        end)

      {:ok, AuthorizedConversationPipelineConsumer,
       %ConversationConsumerContext{entries: entries, adapters: runtime.adapters}}
    else
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  end

  defp expected_matches(entries) do
    Enum.flat_map(entries, fn entry ->
      Enum.map(entry.triggers, fn trigger -> {entry.event, trigger} end)
    end)
  end

  defp build_input(%SharedInput{} = shared, conversation_id, now) do
    %Input{
      authorization: nil,
      configuration: shared.configuration,
      cooldowns: shared.cooldowns,
      conversation_id: conversation_id,
      provider_settings: shared.provider_settings,
      webhook_settings: shared.webhook_settings,
      generated_at: now,
      publication_started_at: now,
      publication_completed_at: now,
      generation_transport: shared.generation_transport,
      publication_transport: shared.publication_transport
    }
  end

  defp preflight_consumer(consumer, plan, configuration, context) do
    case consumer.preflight(plan, configuration, context) do
      :ok -> :ok
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  rescue
    _error -> {:error, :invalid_event_dispatch_cycle}
  catch
    _kind, _reason -> {:error, :invalid_event_dispatch_cycle}
  end

  defp execute(plan, event_policy, now, consumer, consumer_context, adapters) do
    initial = %Result{
      candidate_count: plan.candidate_count,
      claimed_count: 0,
      completed_count: 0,
      candidate_failure_count: 0,
      planned_match_count: plan.match_count,
      attempted_match_count: 0,
      dispatched_count: 0,
      skipped_count: 0,
      dispatch_failure_count: 0,
      dedupe_suppressed_count: 0
    }

    {result, _next_index} =
      Enum.reduce(plan.entries, {initial, 0}, fn entry, {result, match_index} ->
        execute_entry(
          entry,
          match_index,
          result,
          event_policy,
          now,
          consumer,
          consumer_context,
          adapters
        )
      end)

    result
  end

  defp execute_entry(
         entry,
         match_index,
         result,
         event_policy,
         now,
         consumer,
         consumer_context,
         adapters
       ) do
    next_index = match_index + length(entry.triggers)

    case claim(adapters.dispatches, entry.candidate, now) do
      {:ok, claim} ->
        {result, terminal?} =
          dispatch_matches(
            entry,
            match_index,
            %{result | claimed_count: result.claimed_count + 1},
            event_policy,
            now,
            consumer,
            consumer_context,
            adapters.authorizer
          )

        result =
          if terminal? and complete(adapters.dispatches, claim, now) == :ok do
            %{result | completed_count: result.completed_count + 1}
          else
            %{result | candidate_failure_count: result.candidate_failure_count + 1}
          end

        {result, next_index}

      :error ->
        {%{result | candidate_failure_count: result.candidate_failure_count + 1}, next_index}
    end
  end

  defp dispatch_matches(
         entry,
         match_index,
         result,
         event_policy,
         now,
         consumer,
         context,
         authorizer
       ) do
    entry.triggers
    |> Enum.with_index(match_index)
    |> Enum.reduce({result, true}, fn {trigger, index}, {result, terminal?} ->
      case authorize_and_consume(
             authorizer,
             consumer,
             context,
             entry.event,
             trigger,
             event_policy,
             now,
             index
           ) do
        :dispatched ->
          {%{
             result
             | attempted_match_count: result.attempted_match_count + 1,
               dispatched_count: result.dispatched_count + 1
           }, terminal?}

        {:skipped, reason} ->
          {%{
             result
             | attempted_match_count: result.attempted_match_count + 1,
               skipped_count: result.skipped_count + 1,
               dedupe_suppressed_count:
                 result.dedupe_suppressed_count + if(reason == :dedupe_window, do: 1, else: 0)
           }, terminal?}

        :failed ->
          {%{
             result
             | attempted_match_count: result.attempted_match_count + 1,
               dispatch_failure_count: result.dispatch_failure_count + 1
           }, false}
      end
    end)
  end

  defp authorize_and_consume(
         authorizer,
         consumer,
         context,
         event,
         trigger,
         event_policy,
         now,
         index
       ) do
    case authorizer.authorize(trigger, event, now, event_policy) do
      {:ok, %Authorization{} = authorization} ->
        if valid_authorization?(authorization, event, trigger, event_policy, now),
          do: consume(consumer, authorization, index, context),
          else: :failed

      {:skip, reason} when reason in @terminal_skip_reasons ->
        {:skipped, reason}

      {:skip, reason} when reason in @nonterminal_skip_reasons ->
        :failed

      {:error, reason} when reason in @failure_reasons ->
        :failed

      _failure ->
        :failed
    end
  rescue
    _error -> :failed
  catch
    _kind, _reason -> :failed
  end

  defp consume(consumer, authorization, index, context) do
    case consumer.consume(authorization, index, context) do
      :ok -> :dispatched
      _failure -> :failed
    end
  rescue
    _error -> :failed
  catch
    _kind, _reason -> :failed
  end

  defp valid_authorization?(authorization, event, trigger, event_policy, now) do
    EventTriggerAuthorizer.validate(authorization) == :ok and
      authorization.plan.event === event and authorization.plan.trigger === trigger and
      authorization.plan.event_policy === event_policy and
      authorization.plan.executed_at === now
  end

  defp claim(dispatches, candidate, now) do
    case dispatches.claim(candidate, now) do
      {:ok, %EventDispatchClaim{} = claim} ->
        if valid_claim?(claim, candidate, now), do: {:ok, claim}, else: :error

      _failure ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp valid_claim?(claim, candidate, now) do
    map_size(claim) == @claim_key_count and Enum.all?(@claim_keys, &Map.has_key?(claim, &1)) and
      claim.event_id == candidate.event_id and
      same_datetime?(claim.enqueued_at, candidate.enqueued_at) and valid_token?(claim.token) and
      same_datetime?(claim.started_at, now) and
      DateTimeValidator.validate_storage_utc(claim.expires_at) == :ok and
      same_datetime?(claim.expires_at, DateTime.add(now, @claim_lease_seconds, :second))
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_token?(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} -> byte_size(decoded) == @claim_token_bytes
      :error -> false
    end
  end

  defp valid_token?(_token), do: false

  defp complete(dispatches, claim, now) do
    case dispatches.complete(claim, now) do
      {:ok, %EventDispatch{} = dispatch} ->
        if completed_dispatch?(dispatch, claim, now), do: :ok, else: :error

      _failure ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp completed_dispatch?(dispatch, claim, now) do
    map_size(dispatch) == @dispatch_key_count and
      Enum.all?(@dispatch_keys, &Map.has_key?(dispatch, &1)) and
      dispatch.event_id == claim.event_id and
      same_datetime?(dispatch.enqueued_at, claim.enqueued_at) and
      dispatch.status == :completed and dispatch.claim_token == nil and
      dispatch.claim_started_at == nil and dispatch.claim_expires_at == nil and
      same_datetime?(dispatch.completed_at, now)
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp validate_conversation_runtime(%Context{conversation_runtime: nil}), do: :ok

  defp validate_conversation_runtime(%Context{
         adapters: starter_adapters,
         shared_input: shared,
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
      _failure -> {:error, :invalid_event_dispatch_cycle}
    end
  end

  defp validate_conversation_runtime(_context),
    do: {:error, :invalid_event_dispatch_cycle}

  defp exact_context?(context) do
    map_size(context) == @context_key_count and
      Enum.all?(@context_keys, &Map.has_key?(context, &1))
  end

  defp exact_conversation_runtime?(runtime) do
    map_size(runtime) == @conversation_runtime_key_count and
      Enum.all?(@conversation_runtime_keys, &Map.has_key?(runtime, &1))
  end

  defp exact_adapters?(adapters) do
    map_size(adapters) == @adapter_key_count and
      Enum.all?(@adapter_keys, &Map.has_key?(adapters, &1))
  end

  defp exact_result?(result) do
    map_size(result) == @result_key_count and Enum.all?(@result_keys, &Map.has_key?(result, &1))
  end
end
