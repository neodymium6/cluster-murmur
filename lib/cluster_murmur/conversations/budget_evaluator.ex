defmodule ClusterMurmur.Conversations.BudgetEvaluator do
  @moduledoc """
  Evaluates bounded conversation capacity from validated state and injected time.

  The projection is pure. It does not read clocks or storage and does not decide
  which persona may consume remaining participant capacity.
  """

  alias ClusterMurmur.{DateTimeValidator, DomainLimits}

  alias ClusterMurmur.Conversations.{
    Budget,
    BudgetState,
    Validator
  }

  @budget_keys Budget.__struct__() |> Map.keys()
  @budget_key_count length(@budget_keys)
  @active_statuses [:starting, :generating, :waiting]
  @max_participants 256
  @max_interval_ms DomainLimits.max_interval_ms()
  @max_safe_integer DomainLimits.max_safe_integer()

  @type error :: :invalid_conversation | :invalid_conversation_budget | :invalid_datetime

  @doc "Projects remaining capacity at one canonical UTC instant."
  @spec evaluate(term(), term(), term()) :: {:ok, BudgetState.t()} | {:error, error()}
  def evaluate(conversation, budget, now) do
    with :ok <- Validator.validate(conversation),
         :ok <- validate_budget(budget),
         :ok <- DateTimeValidator.validate_storage_utc(now),
         :ok <- require_not_before_start(now, conversation.started_at) do
      {:ok, project(conversation, budget, now)}
    end
  rescue
    _error -> {:error, :invalid_conversation_budget}
  catch
    _kind, _reason -> {:error, :invalid_conversation_budget}
  end

  defp validate_budget(%Budget{} = budget) do
    if exact_budget?(budget) and valid_counter_limit?(budget.max_turns) and
         valid_participant_limit?(budget.max_participants) and
         valid_duration_limit?(budget.max_duration_ms) and
         valid_counter_limit?(budget.max_llm_calls),
       do: :ok,
       else: {:error, :invalid_conversation_budget}
  end

  defp validate_budget(_budget), do: {:error, :invalid_conversation_budget}

  defp exact_budget?(budget) do
    map_size(budget) == @budget_key_count and Enum.all?(@budget_keys, &Map.has_key?(budget, &1))
  end

  defp valid_counter_limit?(value),
    do: is_integer(value) and value in 1..@max_safe_integer

  defp valid_participant_limit?(value),
    do: is_integer(value) and value in 1..@max_participants

  defp valid_duration_limit?(value),
    do: is_integer(value) and value in 1..@max_interval_ms

  defp require_not_before_start(now, started_at) do
    if DateTime.compare(now, started_at) in [:gt, :eq],
      do: :ok,
      else: {:error, :invalid_datetime}
  end

  defp project(conversation, budget, now) do
    turns_remaining = remaining(budget.max_turns, conversation.turn_count)

    participant_slots_remaining =
      remaining(budget.max_participants, length(conversation.participants))

    llm_calls_remaining = remaining(budget.max_llm_calls, conversation.llm_call_count)
    duration_remaining_ms = duration_remaining_ms(conversation.started_at, now, budget)
    active? = conversation.status in @active_statuses

    exhausted =
      []
      |> add_exhausted(not active?, :terminal)
      |> add_exhausted(turns_remaining == 0, :turns)
      |> add_exhausted(participant_slots_remaining == 0, :participants)
      |> add_exhausted(duration_remaining_ms == 0, :duration)
      |> add_exhausted(llm_calls_remaining == 0, :llm_calls)
      |> Enum.sort()

    core_exhausted? =
      not active? or turns_remaining == 0 or duration_remaining_ms == 0 or
        llm_calls_remaining == 0

    %BudgetState{
      open?: not core_exhausted?,
      exhausted: exhausted,
      turns_remaining: turns_remaining,
      participant_slots_remaining: participant_slots_remaining,
      duration_remaining_ms: duration_remaining_ms,
      llm_calls_remaining: llm_calls_remaining
    }
  end

  defp remaining(limit, consumed), do: max(limit - consumed, 0)

  defp duration_remaining_ms(started_at, now, budget) do
    elapsed_microseconds = DateTime.diff(now, started_at, :microsecond)
    remaining_microseconds = max(budget.max_duration_ms * 1_000 - elapsed_microseconds, 0)
    div(remaining_microseconds + 999, 1_000)
  end

  defp add_exhausted(reasons, true, reason), do: [reason | reasons]
  defp add_exhausted(reasons, false, _reason), do: reasons
end
