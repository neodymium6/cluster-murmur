defmodule ClusterMurmur.DateTimeValidator do
  @moduledoc false

  @time_zone_database TimeZoneInfo.TimeZoneDatabase
  @datetime_keys DateTime.__struct__() |> Map.keys()
  @datetime_key_count length(@datetime_keys)
  @storage_years 0..9999

  @spec validate(term()) :: :ok | {:error, :invalid_datetime}
  def validate(
        %DateTime{
          calendar: Calendar.ISO,
          year: year,
          month: month,
          day: day,
          hour: hour,
          minute: minute,
          second: second,
          microsecond: {microsecond, precision},
          time_zone: timezone,
          zone_abbr: zone_abbr,
          utc_offset: utc_offset,
          std_offset: std_offset
        } = datetime
      )
      when is_integer(microsecond) and microsecond in 0..999_999 and is_integer(precision) and
             precision in 0..6 and is_binary(timezone) and is_binary(zone_abbr) and
             is_integer(utc_offset) and is_integer(std_offset) do
    with {:ok, naive} <-
           NaiveDateTime.new(
             year,
             month,
             day,
             hour,
             minute,
             second,
             {microsecond, precision}
           ) do
      validate_period(naive, datetime)
    else
      _failure -> {:error, :invalid_datetime}
    end
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end

  def validate(_datetime), do: {:error, :invalid_datetime}

  @spec validate_storage_utc(term()) :: :ok | {:error, :invalid_datetime}
  def validate_storage_utc(%DateTime{time_zone: "Etc/UTC", year: year} = datetime)
      when year in @storage_years do
    if exact_datetime?(datetime),
      do: validate(datetime),
      else: {:error, :invalid_datetime}
  end

  def validate_storage_utc(_datetime), do: {:error, :invalid_datetime}

  defp validate_period(naive, datetime) do
    case DateTime.from_naive(naive, datetime.time_zone, @time_zone_database) do
      {:ok, canonical} -> compare_datetime(canonical, datetime)
      {:ambiguous, earlier, later} -> compare_ambiguous(earlier, later, datetime)
      _failure -> {:error, :invalid_datetime}
    end
  end

  defp compare_ambiguous(earlier, later, datetime) do
    if same_datetime?(earlier, datetime) or same_datetime?(later, datetime),
      do: :ok,
      else: {:error, :invalid_datetime}
  end

  defp compare_datetime(canonical, datetime) do
    if same_datetime?(canonical, datetime), do: :ok, else: {:error, :invalid_datetime}
  end

  defp same_datetime?(canonical, datetime) do
    DateTime.compare(canonical, datetime) == :eq and canonical.zone_abbr == datetime.zone_abbr and
      canonical.utc_offset == datetime.utc_offset and canonical.std_offset == datetime.std_offset and
      canonical.microsecond == datetime.microsecond
  end

  defp exact_datetime?(datetime) do
    map_size(datetime) == @datetime_key_count and
      Enum.all?(@datetime_keys, &Map.has_key?(datetime, &1))
  end
end
