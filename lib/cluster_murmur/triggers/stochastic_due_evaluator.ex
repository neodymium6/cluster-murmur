defmodule ClusterMurmur.Triggers.StochasticDueEvaluator do
  @moduledoc """
  Evaluates one persisted due schedule against its stochastic trigger policy.

  This pure adapter validates the persistence projection, normalizes a previous
  local-date counter to zero for the current bucket, and delegates the factual
  policy decision to `StochasticEligibility`. It does not read storage, claim a
  schedule, sample randomness, or execute an action.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Persistence.StochasticSchedule
  alias ClusterMurmur.Triggers.{StochasticEligibility, StochasticTrigger}
  alias ClusterMurmur.Triggers.StochasticEligibility.Decision

  @type error ::
          :invalid_datetime
          | :invalid_schedule
          | :invalid_trigger
          | :schedule_not_due

  @doc "Evaluates one exact persisted schedule at a supplied canonical UTC instant."
  @spec evaluate(term(), term(), term()) :: {:ok, Decision.t()} | {:error, error()}
  def evaluate(%StochasticTrigger{} = trigger, %StochasticSchedule{} = schedule, now) do
    with :ok <- validate_now(now),
         {:ok, local_bucket} <- StochasticEligibility.local_bucket(trigger, now),
         :ok <- validate_schedule(trigger, schedule),
         :ok <- validate_due(schedule.next_run_at, now) do
      trigger
      |> StochasticEligibility.evaluate(now, execution_count(trigger, schedule, local_bucket))
      |> normalize_eligibility_error()
    end
  rescue
    _error -> {:error, :invalid_schedule}
  catch
    _kind, _reason -> {:error, :invalid_schedule}
  end

  def evaluate(%StochasticTrigger{}, _schedule, _now), do: {:error, :invalid_schedule}
  def evaluate(_trigger, _schedule, _now), do: {:error, :invalid_trigger}

  defp validate_now(%DateTime{time_zone: "Etc/UTC"} = now) do
    if DateTimeValidator.validate(now) == :ok,
      do: :ok,
      else: {:error, :invalid_datetime}
  end

  defp validate_now(_now), do: {:error, :invalid_datetime}

  defp validate_schedule(
         %StochasticTrigger{id: trigger_id},
         %StochasticSchedule{
           trigger_id: trigger_id,
           next_run_at: next_run_at,
           last_run_at: last_run_at,
           claim_token: nil,
           claim_started_at: nil,
           claim_expires_at: nil
         } = schedule
       ) do
    attributes =
      schedule
      |> Map.from_struct()
      |> Map.take([
        :trigger_id,
        :next_run_at,
        :last_run_at,
        :daily_count,
        :daily_count_date,
        :claim_token,
        :claim_started_at,
        :claim_expires_at
      ])

    if valid_storage_datetime?(next_run_at) and valid_optional_datetime?(last_run_at) and
         valid_daily_state?(schedule.daily_count, schedule.daily_count_date) and
         StochasticSchedule.changeset(%StochasticSchedule{}, attributes).valid? do
      :ok
    else
      {:error, :invalid_schedule}
    end
  end

  defp validate_schedule(%StochasticTrigger{}, %StochasticSchedule{}),
    do: {:error, :invalid_schedule}

  defp validate_due(next_run_at, now) do
    if DateTime.compare(next_run_at, now) in [:lt, :eq],
      do: :ok,
      else: {:error, :schedule_not_due}
  end

  defp execution_count(%StochasticTrigger{daily_limit: nil}, _schedule, nil), do: nil

  defp execution_count(
         %StochasticTrigger{daily_limit: daily_limit},
         %StochasticSchedule{daily_count_date: local_date, daily_count: count},
         local_date
       )
       when is_integer(daily_limit),
       do: {local_date, count}

  defp execution_count(%StochasticTrigger{daily_limit: daily_limit}, _schedule, local_date)
       when is_integer(daily_limit),
       do: {local_date, 0}

  defp valid_storage_datetime?(%DateTime{time_zone: "Etc/UTC"} = datetime),
    do: DateTimeValidator.validate(datetime) == :ok

  defp valid_storage_datetime?(_datetime), do: false

  defp valid_optional_datetime?(nil), do: true
  defp valid_optional_datetime?(datetime), do: valid_storage_datetime?(datetime)

  defp valid_daily_state?(count, nil) when is_integer(count) and count == 0, do: true

  defp valid_daily_state?(count, %Date{calendar: Calendar.ISO} = date)
       when is_integer(count) and count in 0..10_000 do
    case Date.new(date.year, date.month, date.day) do
      {:ok, canonical} -> canonical == date
      _failure -> false
    end
  end

  defp valid_daily_state?(_count, _date), do: false

  defp normalize_eligibility_error({:error, :invalid_execution_count}),
    do: {:error, :invalid_schedule}

  defp normalize_eligibility_error(result), do: result
end
