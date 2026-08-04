defmodule ClusterMurmur.Triggers.ActiveHoursEvaluator do
  @moduledoc """
  Evaluates a validated active-hours window at a supplied instant.

  Start is inclusive, end is exclusive, and crossing-midnight windows are
  evaluated in their configured IANA timezone.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Triggers.ActiveHours

  @time_zone_database TimeZoneInfo.TimeZoneDatabase
  @type error :: :invalid_active_hours | :invalid_datetime

  @doc "Returns whether the supplied instant is inside the local active window."
  @spec active?(ActiveHours.t() | nil, term()) :: {:ok, boolean()} | {:error, error()}
  def active?(nil, %DateTime{} = datetime) do
    with :ok <- DateTimeValidator.validate(datetime), do: {:ok, true}
  end

  def active?(%ActiveHours{} = active_hours, %DateTime{} = datetime) do
    with :ok <- validate_active_hours(active_hours),
         :ok <- DateTimeValidator.validate(datetime),
         {:ok, local} <- shift_zone(datetime, active_hours.timezone) do
      minute = local.hour * 60 + local.minute
      {:ok, inside?(minute, active_hours.start_minute, active_hours.end_minute)}
    end
  end

  def active?(%ActiveHours{}, _datetime), do: {:error, :invalid_datetime}
  def active?(nil, _datetime), do: {:error, :invalid_datetime}
  def active?(_active_hours, _datetime), do: {:error, :invalid_active_hours}

  defp validate_active_hours(%ActiveHours{
         start_minute: start_minute,
         end_minute: end_minute,
         timezone: timezone
       })
       when is_integer(start_minute) and start_minute in 0..1439 and is_integer(end_minute) and
              end_minute in 0..1439 and start_minute != end_minute and is_binary(timezone) do
    if valid_timezone?(timezone), do: :ok, else: {:error, :invalid_active_hours}
  end

  defp validate_active_hours(_active_hours), do: {:error, :invalid_active_hours}

  defp valid_timezone?(timezone) do
    timezone in TimeZoneInfo.time_zones()
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp shift_zone(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone, @time_zone_database) do
      {:ok, local} -> {:ok, local}
      _failure -> {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end

  defp inside?(minute, start_minute, end_minute) when start_minute < end_minute,
    do: minute >= start_minute and minute < end_minute

  defp inside?(minute, start_minute, end_minute),
    do: minute >= start_minute or minute < end_minute
end
