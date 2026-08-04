defmodule ClusterMurmur.Triggers.StochasticEligibility do
  @moduledoc """
  Combines active-hours and daily-limit policy for a stochastic trigger.

  The caller supplies the persisted execution count for the returned local
  calendar date. This module does not read or mutate scheduler state.
  """

  alias ClusterMurmur.Triggers.{ActiveHours, ActiveHoursEvaluator, StochasticTrigger}

  @max_interval_ms 365 * 86_400_000
  @max_daily_limit 10_000
  @time_zone_database TimeZoneInfo.TimeZoneDatabase

  defmodule Decision do
    @moduledoc false

    @derive {Inspect, only: [:eligible, :reason]}
    @enforce_keys [:eligible, :reason, :local_date]
    defstruct [:eligible, :reason, :local_date]

    @type reason :: :eligible | :outside_active_hours | :daily_limit_reached
    @type t :: %__MODULE__{
            eligible: boolean(),
            reason: reason(),
            local_date: Date.t() | nil
          }
  end

  @type error :: :invalid_datetime | :invalid_execution_count | :invalid_trigger

  @doc "Evaluates eligibility at an instant using an already-loaded daily count."
  @spec evaluate(term(), term(), term()) :: {:ok, Decision.t()} | {:error, error()}
  def evaluate(%StochasticTrigger{} = trigger, %DateTime{} = datetime, execution_count) do
    with :ok <- validate_trigger(trigger),
         {:ok, active?} <- active?(trigger.active_hours, datetime),
         {:ok, local_date} <- local_date(trigger.daily_limit, trigger.active_hours, datetime),
         {:ok, count} <-
           validate_execution_count(trigger.daily_limit, execution_count, local_date) do
      decide(active?, trigger.daily_limit, count, local_date)
    end
  end

  def evaluate(%StochasticTrigger{}, _datetime, _execution_count),
    do: {:error, :invalid_datetime}

  def evaluate(_trigger, _datetime, _execution_count), do: {:error, :invalid_trigger}

  defp validate_trigger(%StochasticTrigger{
         distribution: :shifted_exponential,
         mean_interval_ms: mean,
         minimum_interval_ms: minimum,
         active_hours: active_hours,
         daily_limit: daily_limit,
         action: :emit_event
       })
       when is_integer(mean) and is_integer(minimum) and minimum > 0 and mean > minimum and
              mean <= @max_interval_ms and minimum <= @max_interval_ms do
    validate_limit_shape(active_hours, daily_limit)
  end

  defp validate_trigger(_trigger), do: {:error, :invalid_trigger}

  defp validate_limit_shape(_active_hours, nil), do: :ok

  defp validate_limit_shape(%ActiveHours{}, daily_limit)
       when is_integer(daily_limit) and daily_limit > 0 and daily_limit <= @max_daily_limit,
       do: :ok

  defp validate_limit_shape(_active_hours, _daily_limit), do: {:error, :invalid_trigger}

  defp validate_execution_count(nil, nil, nil), do: {:ok, nil}

  defp validate_execution_count(daily_limit, {%Date{} = date, count}, local_date)
       when is_integer(daily_limit) and is_integer(count) and count >= 0 and
              count <= @max_daily_limit,
       do: if(date == local_date, do: {:ok, count}, else: {:error, :invalid_execution_count})

  defp validate_execution_count(_daily_limit, _count, _local_date),
    do: {:error, :invalid_execution_count}

  defp active?(active_hours, datetime) do
    case ActiveHoursEvaluator.active?(active_hours, datetime) do
      {:ok, active?} -> {:ok, active?}
      {:error, :invalid_datetime} -> {:error, :invalid_datetime}
      {:error, :invalid_active_hours} -> {:error, :invalid_trigger}
    end
  end

  defp local_date(nil, _active_hours, _datetime), do: {:ok, nil}

  defp local_date(daily_limit, %ActiveHours{timezone: timezone}, datetime)
       when is_integer(daily_limit) do
    case DateTime.shift_zone(datetime, timezone, @time_zone_database) do
      {:ok, local} -> {:ok, DateTime.to_date(local)}
      _failure -> {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end

  defp decide(false, _daily_limit, _count, local_date),
    do: {:ok, decision(false, :outside_active_hours, local_date)}

  defp decide(true, daily_limit, count, local_date)
       when is_integer(daily_limit) and count >= daily_limit,
       do: {:ok, decision(false, :daily_limit_reached, local_date)}

  defp decide(true, _daily_limit, _count, local_date),
    do: {:ok, decision(true, :eligible, local_date)}

  defp decision(eligible, reason, local_date),
    do: %Decision{eligible: eligible, reason: reason, local_date: local_date}
end
