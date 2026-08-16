defmodule ClusterMurmur.Triggers.StochasticScheduleCalculator do
  @moduledoc """
  Calculates a stochastic trigger's next UTC run from a supplied base instant.

  Each calculation samples exactly one wait through the injected random source.
  It does not read a clock, inspect scheduler state, or persist the result.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Triggers.{ActiveHours, ActiveHoursEvaluator}
  alias ClusterMurmur.Triggers.{StochasticSampler, StochasticTrigger}

  @time_zone_database TimeZoneInfo.TimeZoneDatabase
  @max_window_search_days 8

  @type error ::
          :invalid_datetime
          | :invalid_active_hours
          | :invalid_random_source
          | :invalid_random_value
          | :invalid_trigger
          | :already_active
          | :no_next_run

  @doc "Returns the sampled next run strictly after a supplied canonical UTC instant."
  @spec next_run(term(), term(), term()) :: {:ok, DateTime.t()} | {:error, error()}
  def next_run(
        %StochasticTrigger{} = trigger,
        %DateTime{time_zone: "Etc/UTC"} = datetime,
        random
      ) do
    with :ok <- validate_datetime(datetime),
         {:ok, wait_ms} <- StochasticSampler.sample_wait(trigger, random) do
      add_wait(datetime, wait_ms)
    end
  end

  def next_run(%StochasticTrigger{}, _datetime, _random), do: {:error, :invalid_datetime}
  def next_run(_trigger, _datetime, _random), do: {:error, :invalid_trigger}

  @doc "Samples one durable replacement strictly inside the next active window."
  @spec next_active_run(term(), term(), term()) ::
          {:ok, DateTime.t()} | {:error, error()}
  def next_active_run(
        %StochasticTrigger{active_hours: %ActiveHours{} = active_hours} = trigger,
        %DateTime{time_zone: "Etc/UTC"} = datetime,
        random
      ) do
    with :ok <- validate_datetime(datetime),
         {:ok, false} <- ActiveHoursEvaluator.active?(active_hours, datetime),
         {:ok, segments} <- next_active_segments(active_hours, datetime),
         {:ok, wait_ms} <- StochasticSampler.sample_wait(trigger, random),
         {:ok, next_run} <- fit_first_active(segments, trigger, wait_ms) do
      {:ok, next_run}
    else
      {:ok, true} -> {:error, :already_active}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :no_next_run}
  catch
    _kind, _reason -> {:error, :no_next_run}
  end

  def next_active_run(%StochasticTrigger{active_hours: %ActiveHours{}}, %DateTime{}, _random),
    do: {:error, :invalid_datetime}

  def next_active_run(%StochasticTrigger{}, %DateTime{}, _random),
    do: {:error, :invalid_trigger}

  def next_active_run(%StochasticTrigger{}, _datetime, _random),
    do: {:error, :invalid_datetime}

  def next_active_run(_trigger, _datetime, _random), do: {:error, :invalid_trigger}

  defp validate_datetime(datetime), do: DateTimeValidator.validate_storage_utc(datetime)

  defp add_wait(datetime, wait_ms) do
    case DateTime.add(datetime, wait_ms, :millisecond) do
      %DateTime{} = next_run ->
        case DateTimeValidator.validate_storage_utc(next_run) do
          :ok -> {:ok, next_run}
          {:error, :invalid_datetime} -> {:error, :no_next_run}
        end
    end
  rescue
    _error -> {:error, :no_next_run}
  catch
    _kind, _reason -> {:error, :no_next_run}
  end

  defp next_active_segments(
         %ActiveHours{
           start_minute: start_minute,
           end_minute: end_minute,
           timezone: timezone
         } = active_hours,
         datetime
       ) do
    with {:ok, local} <- DateTime.shift_zone(datetime, timezone, @time_zone_database),
         {:ok, opening_date} <- opening_date(local, start_minute, end_minute),
         {:ok, fold_segments} <-
           fold_reentry_segments(active_hours, local, end_minute, timezone, datetime),
         {:ok, segments} <-
           collect_segments(
             active_hours,
             opening_date,
             start_minute,
             end_minute,
             timezone,
             datetime,
             @max_window_search_days,
             []
           ),
         segments <- normalize_segments(fold_segments ++ segments),
         true <- segments != [] do
      {:ok, segments}
    else
      _failure -> {:error, :no_next_run}
    end
  end

  defp fold_reentry_segments(active_hours, local, end_minute, timezone, datetime) do
    local_minute = local.hour * 60 + local.minute

    if local_minute >= end_minute do
      with {:ok, closings} <-
             boundary_candidates(DateTime.to_date(local), end_minute, timezone, :closing) do
        closings
        |> Enum.filter(&(DateTime.compare(&1, datetime) == :gt))
        |> Enum.reduce_while({:ok, []}, fn closing, {:ok, segments} ->
          probe = DateTime.add(closing, -1, :microsecond)

          case ActiveHoursEvaluator.active?(active_hours, probe) do
            {:ok, true} ->
              case first_active_boundary(active_hours, datetime, probe) do
                {:ok, opening} -> {:cont, {:ok, [{opening, closing} | segments]}}
                _failure -> {:halt, {:error, :no_next_run}}
              end

            {:ok, false} ->
              {:cont, {:ok, segments}}

            _failure ->
              {:halt, {:error, :no_next_run}}
          end
        end)
      end
    else
      {:ok, []}
    end
  end

  defp first_active_boundary(active_hours, before, after_boundary) do
    if DateTime.diff(after_boundary, before, :microsecond) <= 1 do
      {:ok, after_boundary}
    else
      midpoint =
        DateTime.add(
          before,
          div(DateTime.diff(after_boundary, before, :microsecond), 2),
          :microsecond
        )

      case ActiveHoursEvaluator.active?(active_hours, midpoint) do
        {:ok, true} -> first_active_boundary(active_hours, before, midpoint)
        {:ok, false} -> first_active_boundary(active_hours, midpoint, after_boundary)
        _failure -> {:error, :no_next_run}
      end
    end
  end

  defp collect_segments(
         _active_hours,
         _opening_date,
         _start_minute,
         _end_minute,
         _timezone,
         _datetime,
         0,
         segments
       ) do
    if segments == [], do: {:error, :no_next_run}, else: {:ok, segments}
  end

  defp collect_segments(
         active_hours,
         opening_date,
         start_minute,
         end_minute,
         timezone,
         datetime,
         remaining,
         segments
       ) do
    with {:ok, daily_segments} <-
           segments_for_date(
             active_hours,
             opening_date,
             start_minute,
             end_minute,
             timezone,
             datetime
           ),
         {:ok, next_date} <- safe_date_add(opening_date, 1) do
      collect_segments(
        active_hours,
        next_date,
        start_minute,
        end_minute,
        timezone,
        datetime,
        remaining - 1,
        segments ++ daily_segments
      )
    else
      _failure -> if segments == [], do: {:error, :no_next_run}, else: {:ok, segments}
    end
  end

  defp segments_for_date(
         active_hours,
         opening_date,
         start_minute,
         end_minute,
         timezone,
         datetime
       ) do
    with {:ok, closing_date} <- closing_date(opening_date, start_minute, end_minute),
         {:ok, openings} <- boundary_candidates(opening_date, start_minute, timezone, :opening),
         {:ok, closings} <- boundary_candidates(closing_date, end_minute, timezone, :closing) do
      segments =
        openings
        |> pair_segments(closings, datetime)
        |> Enum.filter(&segment_starts_active?(active_hours, &1))

      {:ok, segments}
    end
  end

  defp opening_date(local, start_minute, end_minute) do
    minute = local.hour * 60 + local.minute
    local_date = DateTime.to_date(local)

    if start_minute < end_minute and minute >= end_minute,
      do: safe_date_add(local_date, 1),
      else: {:ok, local_date}
  end

  defp closing_date(opening_date, start_minute, end_minute) do
    if start_minute > end_minute,
      do: safe_date_add(opening_date, 1),
      else: {:ok, opening_date}
  end

  defp safe_date_add(date, days) do
    case Date.add(date, days) do
      %Date{} = shifted -> {:ok, shifted}
    end
  rescue
    _error -> {:error, :no_next_run}
  end

  defp boundary_candidates(date, minute, timezone, kind) do
    with {:ok, time} <- Time.new(div(minute, 60), rem(minute, 60), 0, {0, 0}) do
      case DateTime.new(date, time, timezone, @time_zone_database) do
        {:ok, datetime} -> utc_candidates([datetime])
        {:ambiguous, first, second} -> utc_candidates([first, second])
        {:gap, _before, after_gap} when kind == :opening -> utc_candidates([after_gap])
        {:gap, before_gap, _after} when kind == :closing -> utc_candidates([before_gap])
        _failure -> {:error, :no_next_run}
      end
    end
  end

  defp utc_candidates(datetimes) do
    datetimes
    |> Enum.reduce_while({:ok, []}, fn datetime, {:ok, candidates} ->
      case DateTime.shift_zone(datetime, "Etc/UTC", @time_zone_database) do
        {:ok, utc} -> {:cont, {:ok, [utc | candidates]}}
        _failure -> {:halt, {:error, :no_next_run}}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.sort(candidates, DateTime)}
      error -> error
    end
  end

  defp pair_segments(openings, closings, datetime) do
    openings
    |> Enum.filter(&(DateTime.compare(&1, datetime) == :gt))
    |> Enum.flat_map(fn opening ->
      case Enum.find(closings, &(DateTime.compare(&1, opening) == :gt)) do
        %DateTime{} = closing -> [{opening, closing}]
        nil -> []
      end
    end)
  end

  defp normalize_segments(segments) do
    segments
    |> Enum.uniq()
    |> Enum.sort_by(fn {opening, _closing} -> DateTime.to_unix(opening, :microsecond) end)
  end

  defp segment_starts_active?(active_hours, {opening, _closing}) do
    ActiveHoursEvaluator.active?(active_hours, opening) == {:ok, true}
  end

  defp fit_first_active([], _trigger, _wait_ms), do: {:error, :no_next_run}

  defp fit_first_active(
         [{opening, closing} | remaining],
         %StochasticTrigger{active_hours: active_hours, minimum_interval_ms: minimum_interval_ms} =
           trigger,
         wait_ms
       ) do
    with {:ok, next_run} <- fit_wait(opening, closing, minimum_interval_ms, wait_ms),
         {:ok, true} <- ActiveHoursEvaluator.active?(active_hours, next_run) do
      {:ok, next_run}
    else
      _failure -> fit_first_active(remaining, trigger, wait_ms)
    end
  end

  defp fit_wait(opening, closing, minimum_interval_ms, wait_ms) do
    duration_us = DateTime.diff(closing, opening, :microsecond)
    minimum_us = minimum_interval_ms * 1_000
    wait_us = wait_ms * 1_000

    if duration_us > 1 do
      offset_us =
        if minimum_us < duration_us do
          minimum_us + rem(wait_us - minimum_us, duration_us - minimum_us)
        else
          rem(wait_us, duration_us - 1) + 1
        end

      next_run = DateTime.add(opening, offset_us, :microsecond)

      if DateTime.compare(next_run, opening) == :gt and
           DateTime.compare(next_run, closing) == :lt and
           validate_datetime(next_run) == :ok,
         do: {:ok, next_run},
         else: {:error, :no_next_run}
    else
      {:error, :no_next_run}
    end
  end
end
