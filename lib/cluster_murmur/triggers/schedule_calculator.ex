defmodule ClusterMurmur.Triggers.ScheduleCalculator do
  @moduledoc """
  Calculates the next UTC run for a validated schedule trigger.

  Missing local times are skipped. Ambiguous local times use only their earlier
  occurrence, so a wall-clock schedule never runs twice during a DST fold.
  """

  alias ClusterMurmur.Triggers.{CronValidator, ScheduleTrigger}

  @max_search_steps 100_000
  @max_candidate_attempts 1_000
  @time_zone_database TimeZoneInfo.TimeZoneDatabase

  @type error :: :invalid_datetime | :invalid_trigger | :no_next_run

  @doc "Returns the first scheduled UTC datetime strictly after `datetime`."
  @spec next_run(term(), term()) :: {:ok, DateTime.t()} | {:error, error()}
  def next_run(%ScheduleTrigger{} = trigger, %DateTime{} = datetime) do
    with :ok <- validate_trigger(trigger),
         :ok <- validate_datetime(datetime),
         {:ok, local_datetime} <- shift_zone(datetime, trigger.timezone),
         {:ok, next_local} <-
           schedule(
             trigger.cron,
             trigger.timezone,
             local_datetime,
             DateTime.to_naive(local_datetime),
             @max_candidate_attempts
           ),
         {:ok, next_utc} <- shift_zone(next_local, "Etc/UTC") do
      {:ok, next_utc}
    end
  end

  def next_run(%ScheduleTrigger{}, _datetime), do: {:error, :invalid_datetime}
  def next_run(_trigger, _datetime), do: {:error, :invalid_trigger}

  defp validate_trigger(
         %ScheduleTrigger{
           cron: %Crontab.CronExpression{extended: false, reboot: false},
           timezone: timezone,
           action: :emit_event
         } = trigger
       )
       when is_binary(timezone) do
    if valid_timezone?(timezone) and CronValidator.valid?(trigger.cron),
      do: :ok,
      else: {:error, :invalid_trigger}
  end

  defp validate_trigger(_trigger), do: {:error, :invalid_trigger}

  defp valid_timezone?(timezone) do
    timezone in TimeZoneInfo.time_zones()
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp validate_datetime(datetime) do
    naive = DateTime.to_naive(datetime)

    case DateTime.from_naive(naive, datetime.time_zone, @time_zone_database) do
      {:ok, canonical} -> compare_datetime(canonical, datetime)
      {:ambiguous, earlier, later} -> compare_ambiguous_datetime(earlier, later, datetime)
      _failure -> {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end

  defp compare_ambiguous_datetime(earlier, later, datetime) do
    if same_datetime?(earlier, datetime) or same_datetime?(later, datetime),
      do: :ok,
      else: {:error, :invalid_datetime}
  end

  defp compare_datetime(canonical, datetime) do
    if same_datetime?(canonical, datetime), do: :ok, else: {:error, :invalid_datetime}
  end

  defp same_datetime?(canonical, datetime) do
    DateTime.compare(canonical, datetime) == :eq and canonical.zone_abbr == datetime.zone_abbr and
      canonical.utc_offset == datetime.utc_offset and canonical.std_offset == datetime.std_offset
  end

  defp shift_zone(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone, @time_zone_database) do
      {:ok, shifted} -> {:ok, shifted}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end

  defp schedule(_cron, _timezone, _datetime, _cursor, 0), do: {:error, :no_next_run}

  defp schedule(cron, timezone, datetime, cursor, attempts) do
    with {:ok, %NaiveDateTime{} = candidate} <- next_naive(cron, cursor) do
      resolve_candidate(cron, timezone, datetime, candidate, attempts)
    end
  rescue
    _error -> {:error, :no_next_run}
  catch
    _kind, _reason -> {:error, :no_next_run}
  end

  defp next_naive(cron, after_naive) do
    case Crontab.Scheduler.get_next_run_date(cron, after_naive, @max_search_steps) do
      {:ok, %NaiveDateTime{} = candidate} -> {:ok, candidate}
      _failure -> {:error, :no_next_run}
    end
  end

  defp resolve_candidate(cron, timezone, after_datetime, candidate, attempts) do
    case DateTime.from_naive(candidate, timezone, @time_zone_database) do
      {:ok, resolved} ->
        return_or_continue(cron, timezone, after_datetime, candidate, resolved, attempts)

      {:ambiguous, earlier, _later} ->
        return_or_continue(cron, timezone, after_datetime, candidate, earlier, attempts)

      {:gap, _before, after_gap} ->
        cursor = after_gap |> DateTime.to_naive() |> NaiveDateTime.add(-1, :microsecond)
        schedule(cron, timezone, after_datetime, cursor, attempts - 1)

      {:error, _reason} ->
        {:error, :no_next_run}
    end
  end

  defp return_or_continue(cron, timezone, after_datetime, candidate, resolved, attempts) do
    if DateTime.after?(resolved, after_datetime) do
      {:ok, resolved}
    else
      schedule(cron, timezone, after_datetime, advance_candidate(candidate), attempts - 1)
    end
  end

  defp advance_candidate(candidate), do: NaiveDateTime.add(candidate, 1, :minute)
end
