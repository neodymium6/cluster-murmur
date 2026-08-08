defmodule ClusterMurmur.Runtime.ResponderTurnCycle do
  @moduledoc """
  Runs one fully bounded responder decision through its durable lifecycle.

  Every clock, adapter, and transport is explicit and preflighted before the
  planner mutates conversation state. One invocation selects at most one
  responder, performs at most one LLM call and one Discord publication, and
  returns either a terminal result or one exact waiting continuation.
  """

  alias ClusterMurmur.Config.Configuration

  alias ClusterMurmur.Conversations.{
    BudgetEvaluator,
    BudgetState,
    ResponderContinuationPlanner,
    ResponderTurnFinisher
  }

  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.Result
  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Discord.{
    ResponderPublicationExecutor,
    ResponderPublicationPlanner,
    ResponderPublicationStarter
  }

  alias ClusterMurmur.Generation.{ProviderSettings, ResponderMessageConsumer}
  alias ClusterMurmur.Generation.ResponderMessageConsumer.ConsumerContext
  alias ClusterMurmur.Personas.ResponderCooldownRecorder

  defmodule Input do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [
      :continuation,
      :provider_settings,
      :generated_at,
      :publication_started_at,
      :publication_completed_at,
      :generation_transport,
      :publication_transport
    ]
    defstruct [
      :continuation,
      :provider_settings,
      :generated_at,
      :publication_started_at,
      :publication_completed_at,
      :generation_transport,
      :publication_transport
    ]

    @type t :: %__MODULE__{
            continuation: ClusterMurmur.Conversations.ResponderContinuationPlanner.Input.t(),
            provider_settings: ClusterMurmur.Generation.ProviderSettings.t(),
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
      :random,
      :conversation_store,
      :provider,
      :message_store,
      :publication_start_store,
      :publisher,
      :publication_terminal_store,
      :cooldown_store
    ]
    defstruct [
      :random,
      :conversation_store,
      :provider,
      :message_store,
      :publication_start_store,
      :publisher,
      :publication_terminal_store,
      :cooldown_store
    ]

    @type t :: %__MODULE__{
            random: module(),
            conversation_store: module(),
            provider: module(),
            message_store: module(),
            publication_start_store: module(),
            publisher: module(),
            publication_terminal_store: module(),
            cooldown_store: module()
          }
  end

  @input_keys Input.__struct__() |> Map.keys()
  @input_key_count length(@input_keys)
  @adapter_keys Adapters.__struct__() |> Map.keys()
  @adapter_key_count length(@adapter_keys)

  @type result ::
          {:ok, :no_reply, Result.t()}
          | {:ok, ResponderTurnFinisher.Completed.t()}
          | {:continue, ResponderTurnFinisher.Continuation.t()}
          | {:failed, atom(), ResponderPublicationExecutor.Outcome.t()}
          | {:ambiguous, :interrupted, ResponderPublicationExecutor.Outcome.t()}
          | {:error, atom()}

  @doc "Runs one responder decision without retries or implicit recursion."
  @spec run(Input.t(), Adapters.t()) :: result()
  def run(%Input{} = input, %Adapters{} = adapters) do
    with :ok <- validate_runtime(input, adapters),
         consumer_context = consumer_context(input, adapters),
         {:ok, %Result{} = selected} <-
           ResponderContinuationPlanner.dispatch(
             input.continuation,
             adapters.random,
             adapters.conversation_store,
             ResponderMessageConsumer,
             consumer_context
           ) do
      continue_selected(selected, input, adapters)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _failure -> {:error, :invalid_responder_turn_cycle}
    end
  rescue
    _error -> {:error, :invalid_responder_turn_cycle}
  catch
    _kind, _reason -> {:error, :invalid_responder_turn_cycle}
  end

  def run(_input, _adapters), do: {:error, :invalid_responder_turn_cycle}

  @doc "Validates one complete turn runtime without selecting or mutating state."
  @spec validate_runtime(term(), term()) ::
          :ok | {:error, :invalid_responder_turn_cycle}
  def validate_runtime(%Input{} = input, %Adapters{} = adapters) do
    case preflight(input, adapters) do
      :ok -> :ok
      _failure -> {:error, :invalid_responder_turn_cycle}
    end
  rescue
    _error -> {:error, :invalid_responder_turn_cycle}
  catch
    _kind, _reason -> {:error, :invalid_responder_turn_cycle}
  end

  def validate_runtime(_input, _adapters),
    do: {:error, :invalid_responder_turn_cycle}

  defp continue_selected(
         %Result{outcome: :no_reply, status: :dispatched} = result,
         _input,
         _adapters
       ),
       do: {:ok, :no_reply, result}

  defp continue_selected(
         %Result{outcome: :reply, status: :dispatched, delivery: delivery},
         input,
         adapters
       ) do
    continuation = input.continuation
    configuration = continuation.configuration
    cooldowns = continuation.current_cooldowns
    settings = continuation.webhook_settings

    with {:ok, publication_plan} <-
           ResponderPublicationPlanner.plan(delivery, configuration, cooldowns, settings),
         {:ok, started} <-
           ResponderPublicationStarter.start(
             publication_plan,
             configuration,
             cooldowns,
             settings,
             input.publication_started_at,
             adapters.publication_start_store
           ),
         {:ok, published} <-
           ResponderPublicationExecutor.execute(
             started,
             configuration,
             cooldowns,
             settings,
             input.publication_completed_at,
             input.publication_transport,
             adapters.publisher,
             adapters.publication_terminal_store
           ),
         {:ok, recorded} <-
           ResponderCooldownRecorder.record(
             published,
             configuration,
             cooldowns,
             settings,
             adapters.cooldown_store
           ) do
      finish(recorded, configuration, cooldowns, settings, adapters.conversation_store)
    else
      {:failed, _reason, _outcome} = failed -> failed
      {:ambiguous, :interrupted, _outcome} = ambiguous -> ambiguous
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _failure -> {:error, :invalid_responder_turn_cycle}
    end
  end

  defp continue_selected(%Result{status: :failed}, _input, _adapters),
    do: {:error, :responder_message_failed}

  defp continue_selected(_result, _input, _adapters),
    do: {:error, :invalid_responder_turn_cycle}

  defp finish(recorded, configuration, cooldowns, settings, store) do
    case ResponderTurnFinisher.finish(recorded, configuration, cooldowns, settings, store) do
      {:ok, completed} -> {:ok, completed}
      {:continue, continuation} -> {:continue, continuation}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _failure -> {:error, :invalid_responder_turn_cycle}
    end
  end

  defp preflight(input, adapters) do
    continuation = input.continuation

    with true <- exact_input?(input),
         true <- exact_adapters?(adapters),
         %ResponderContinuationPlanner.Input{} <- continuation,
         :ok <- Configuration.validate(continuation.configuration),
         :ok <- validate_provider_settings(input.provider_settings, continuation.configuration),
         :ok <- validate_times(input),
         :ok <- validate_duration_window(input),
         true <- is_function(input.generation_transport, 1),
         true <- is_function(input.publication_transport, 1),
         :ok <- validate_adapters(adapters),
         :ok <-
           ResponderMessageConsumer.preflight(continuation, consumer_context(input, adapters)) do
      :ok
    else
      _failure -> {:error, :invalid_responder_turn_cycle}
    end
  end

  defp validate_times(input) do
    planned_at = input.continuation.planned_at

    with :ok <- DateTimeValidator.validate_storage_utc(input.generated_at),
         :ok <- DateTimeValidator.validate_storage_utc(input.publication_started_at),
         :ok <- DateTimeValidator.validate_storage_utc(input.publication_completed_at),
         true <- DateTime.compare(input.generated_at, planned_at) in [:eq, :gt],
         true <-
           DateTime.compare(input.publication_started_at, input.generated_at) in [:eq, :gt],
         true <-
           DateTime.compare(input.publication_completed_at, input.publication_started_at) in [
             :eq,
             :gt
           ] do
      :ok
    else
      _failure -> {:error, :invalid_responder_turn_cycle}
    end
  end

  defp validate_provider_settings(%ProviderSettings{} = settings, configuration) do
    llm = configuration.llm

    if ProviderSettings.validate(settings) == :ok and settings.provider === llm.provider and
         settings.timeout_ms === llm.timeout_ms and
         settings.max_output_tokens === llm.max_output_tokens,
       do: :ok,
       else: {:error, :invalid_responder_turn_cycle}
  end

  defp validate_provider_settings(_settings, _configuration),
    do: {:error, :invalid_responder_turn_cycle}

  defp validate_duration_window(input) do
    continuation = input.continuation
    conversation = continuation.conversation
    budget = continuation.budget

    with {:ok, %BudgetState{} = budget_state} <-
           BudgetEvaluator.evaluate(conversation, budget, continuation.planned_at),
         deadline =
           DateTime.add(conversation.started_at, budget.max_duration_ms * 1_000, :microsecond),
         true <-
           not budget_state.open? or
             (DateTime.compare(input.generated_at, deadline) == :lt and
                DateTime.compare(input.publication_started_at, deadline) == :lt) do
      :ok
    else
      _failure -> {:error, :invalid_responder_turn_cycle}
    end
  end

  defp validate_adapters(adapters) do
    requirements = [
      {adapters.random, [weighted_choice: 1]},
      {adapters.conversation_store,
       [claim_generation: 2, consume_generation: 2, confirm_completed: 1, wait: 1, complete: 2]},
      {adapters.provider, [generate: 3]},
      {adapters.message_store, [append_reserved: 2]},
      {adapters.publication_start_store, [start: 5]},
      {adapters.publisher, [publish: 6]},
      {adapters.publication_terminal_store, [succeed: 4, fail: 3, mark_ambiguous: 2]},
      {adapters.cooldown_store, [record_spoken: 3]}
    ]

    if Enum.all?(requirements, fn {module, functions} ->
         is_atom(module) and Code.ensure_loaded?(module) and
           Enum.all?(functions, fn {name, arity} -> function_exported?(module, name, arity) end)
       end),
       do: :ok,
       else: {:error, :invalid_responder_turn_cycle}
  end

  defp consumer_context(input, adapters) do
    %ConsumerContext{
      input: input.continuation,
      provider_settings: input.provider_settings,
      inserted_at: input.generated_at,
      provider: adapters.provider,
      transport: input.generation_transport,
      conversation_store: adapters.conversation_store,
      message_store: adapters.message_store
    }
  end

  defp exact_input?(input),
    do: map_size(input) == @input_key_count and Enum.all?(@input_keys, &Map.has_key?(input, &1))

  defp exact_adapters?(adapters),
    do:
      map_size(adapters) == @adapter_key_count and
        Enum.all?(@adapter_keys, &Map.has_key?(adapters, &1))
end
