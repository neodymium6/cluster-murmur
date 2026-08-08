defmodule ClusterMurmur.Runtime.ResponderConversationRunner do
  @moduledoc """
  Runs an explicit finite schedule of responder turns until termination.

  The complete schedule is validated before the first durable selection. Each
  turn delegates to `ClusterMurmur.Runtime.ResponderTurnCycle`, and only an
  exact continuation returned by that boundary can seed the next turn. The
  runner performs no retries and returns a waiting continuation when its
  supplied schedule ends before the immutable conversation budget does.
  """

  alias ClusterMurmur.Conversations.ResponderContinuationPlanner
  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.Input, as: ContinuationInput
  alias ClusterMurmur.Conversations.{BudgetEvaluator, BudgetState, ResponderTurnFinisher}
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Runtime.ResponderTurnCycle
  alias ClusterMurmur.Runtime.ResponderTurnCycle.Adapters

  @max_scheduled_turns 256

  defmodule Turn do
    @moduledoc false
    @derive {Inspect,
             only: [
               :planned_at,
               :generated_at,
               :publication_started_at,
               :publication_completed_at
             ]}
    @enforce_keys [
      :planned_at,
      :generated_at,
      :publication_started_at,
      :publication_completed_at,
      :generation_transport,
      :publication_transport
    ]
    defstruct [
      :planned_at,
      :generated_at,
      :publication_started_at,
      :publication_completed_at,
      :generation_transport,
      :publication_transport
    ]

    @type t :: %__MODULE__{
            planned_at: DateTime.t(),
            generated_at: DateTime.t(),
            publication_started_at: DateTime.t(),
            publication_completed_at: DateTime.t(),
            generation_transport: function(),
            publication_transport: function()
          }
  end

  defmodule Input do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [:continuation, :provider_settings, :turns]
    defstruct [:continuation, :provider_settings, :turns]

    @type t :: %__MODULE__{
            continuation: ClusterMurmur.Conversations.ResponderContinuationPlanner.Input.t(),
            provider_settings: ClusterMurmur.Generation.ProviderSettings.t(),
            turns: [ClusterMurmur.Runtime.ResponderConversationRunner.Turn.t()]
          }
  end

  @turn_keys Turn.__struct__() |> Map.keys()
  @turn_key_count length(@turn_keys)
  @input_keys Input.__struct__() |> Map.keys()
  @input_key_count length(@input_keys)

  @type result ::
          {:ok, :no_reply, ResponderContinuationPlanner.Result.t()}
          | {:ok, ResponderTurnFinisher.Completed.t()}
          | {:continue, ResponderTurnFinisher.Continuation.t()}
          | {:failed, atom(), ClusterMurmur.Discord.ResponderPublicationExecutor.Outcome.t()}
          | {:ambiguous, :interrupted,
             ClusterMurmur.Discord.ResponderPublicationExecutor.Outcome.t()}
          | {:error, atom()}

  @doc "Runs at most the supplied bounded schedule without retrying a turn."
  @spec run(Input.t(), Adapters.t()) :: result()
  def run(%Input{} = input, %Adapters{} = adapters) do
    with :ok <- preflight(input, adapters) do
      run_turns(input.continuation, input.provider_settings, input.turns, adapters)
    else
      _failure -> {:error, :invalid_responder_conversation}
    end
  rescue
    _error -> {:error, :invalid_responder_conversation}
  catch
    _kind, _reason -> {:error, :invalid_responder_conversation}
  end

  def run(_input, _adapters), do: {:error, :invalid_responder_conversation}

  defp run_turns(continuation, provider_settings, [turn | remaining], adapters) do
    cycle_input = cycle_input(continuation, provider_settings, turn)

    case ResponderTurnCycle.run(cycle_input, adapters) do
      {:continue, %ResponderTurnFinisher.Continuation{} = next} when remaining != [] ->
        next_input = continuation_input(continuation, next, hd(remaining).planned_at)
        run_turns(next_input, provider_settings, remaining, adapters)

      {:continue, %ResponderTurnFinisher.Continuation{} = next} ->
        {:continue, next}

      {:ok, :no_reply, %ResponderContinuationPlanner.Result{}} = terminal ->
        terminal

      {:ok, %ResponderTurnFinisher.Completed{}} = terminal ->
        terminal

      {:failed, reason, outcome} when is_atom(reason) ->
        {:failed, reason, outcome}

      {:ambiguous, :interrupted, outcome} ->
        {:ambiguous, :interrupted, outcome}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _failure ->
        {:error, :invalid_responder_conversation}
    end
  end

  defp preflight(input, adapters) do
    with true <- exact_input?(input),
         %ContinuationInput{} <- input.continuation,
         true <- valid_turn_count?(input.turns),
         {:ok, deadline} <- duration_deadline(input.continuation),
         :ok <- validate_schedule(input.turns, input.continuation.planned_at, nil, deadline),
         first = hd(input.turns),
         :ok <-
           ResponderTurnCycle.validate_runtime(
             cycle_input(input.continuation, input.provider_settings, first),
             adapters
           ) do
      :ok
    else
      _failure -> {:error, :invalid_responder_conversation}
    end
  end

  defp validate_schedule([], _first_planned_at, _previous_completed_at, _deadline), do: :ok

  defp validate_schedule(
         [%Turn{} = turn | rest],
         first_planned_at,
         previous_completed_at,
         deadline
       ) do
    with true <- exact_turn?(turn),
         :ok <- DateTimeValidator.validate_storage_utc(turn.planned_at),
         :ok <- DateTimeValidator.validate_storage_utc(turn.generated_at),
         :ok <- DateTimeValidator.validate_storage_utc(turn.publication_started_at),
         :ok <- DateTimeValidator.validate_storage_utc(turn.publication_completed_at),
         true <- valid_schedule_start?(turn.planned_at, first_planned_at, previous_completed_at),
         true <- DateTime.compare(turn.generated_at, turn.planned_at) in [:eq, :gt],
         true <-
           DateTime.compare(turn.publication_started_at, turn.generated_at) in [:eq, :gt],
         true <-
           DateTime.compare(turn.publication_completed_at, turn.publication_started_at) in [
             :eq,
             :gt
           ],
         true <- valid_effect_window?(turn, deadline),
         true <- is_function(turn.generation_transport, 1),
         true <- is_function(turn.publication_transport, 1) do
      validate_schedule(rest, first_planned_at, turn.publication_completed_at, deadline)
    else
      _failure -> {:error, :invalid_responder_conversation}
    end
  end

  defp validate_schedule(_turns, _first_planned_at, _previous_completed_at, _deadline),
    do: {:error, :invalid_responder_conversation}

  defp duration_deadline(continuation) do
    conversation = continuation.conversation
    budget = continuation.budget

    with {:ok, %BudgetState{}} <-
           BudgetEvaluator.evaluate(conversation, budget, continuation.planned_at) do
      {:ok, DateTime.add(conversation.started_at, budget.max_duration_ms * 1_000, :microsecond)}
    else
      _failure -> {:error, :invalid_responder_conversation}
    end
  end

  defp valid_effect_window?(turn, deadline) do
    if DateTime.compare(turn.planned_at, deadline) == :lt do
      DateTime.compare(turn.generated_at, deadline) == :lt and
        DateTime.compare(turn.publication_started_at, deadline) == :lt
    else
      true
    end
  end

  defp valid_schedule_start?(planned_at, first_planned_at, nil),
    do: DateTime.compare(planned_at, first_planned_at) == :eq

  defp valid_schedule_start?(planned_at, _first_planned_at, previous_completed_at),
    do: DateTime.compare(planned_at, previous_completed_at) in [:eq, :gt]

  defp cycle_input(continuation, provider_settings, turn) do
    %ResponderTurnCycle.Input{
      continuation: continuation,
      provider_settings: provider_settings,
      generated_at: turn.generated_at,
      publication_started_at: turn.publication_started_at,
      publication_completed_at: turn.publication_completed_at,
      generation_transport: turn.generation_transport,
      publication_transport: turn.publication_transport
    }
  end

  defp continuation_input(previous, continuation, planned_at) do
    %ContinuationInput{
      continuation: continuation,
      configuration: previous.configuration,
      starter_cooldowns: previous.starter_cooldowns,
      current_cooldowns: continuation.current_cooldowns,
      webhook_settings: previous.webhook_settings,
      conversation: continuation.runtime,
      budget: previous.budget,
      planned_at: planned_at,
      policy: previous.policy,
      no_reply_weight: previous.no_reply_weight
    }
  end

  defp valid_turn_count?(turns), do: count_turns(turns, 0)

  defp count_turns([], count), do: count > 0
  defp count_turns([_turn | _rest], @max_scheduled_turns), do: false
  defp count_turns([_turn | rest], count), do: count_turns(rest, count + 1)
  defp count_turns(_turns, _count), do: false

  defp exact_turn?(turn),
    do: map_size(turn) == @turn_key_count and Enum.all?(@turn_keys, &Map.has_key?(turn, &1))

  defp exact_input?(input),
    do: map_size(input) == @input_key_count and Enum.all?(@input_keys, &Map.has_key?(input, &1))
end
