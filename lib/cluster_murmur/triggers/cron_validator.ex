defmodule ClusterMurmur.Triggers.CronValidator do
  @moduledoc false

  @cron_keys Crontab.CronExpression.__struct__() |> Map.keys()
  @cron_key_count length(@cron_keys)

  @spec valid?(term()) :: boolean()
  def valid?(
        %Crontab.CronExpression{
          extended: false,
          reboot: false,
          on_ambiguity: [],
          second: [:*],
          minute: minute,
          hour: hour,
          day: day,
          month: month,
          weekday: weekday,
          year: [:*]
        } = expression
      ) do
    exact_keys?(expression) and valid_conditions?(minute, 0, 59) and
      valid_conditions?(hour, 0, 23) and
      valid_conditions?(day, 1, 31) and valid_conditions?(month, 1, 12) and
      valid_conditions?(weekday, 0, 7) and (day == [:*] or weekday == [:*])
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  def valid?(_expression), do: false

  defp valid_conditions?(conditions, minimum, maximum) do
    bounded_proper_conditions?(conditions, 0) and
      Enum.all?(conditions, &valid_condition?(&1, minimum, maximum))
  end

  defp bounded_proper_conditions?([], count), do: count > 0

  defp bounded_proper_conditions?([_condition | rest], count) when count < 256,
    do: bounded_proper_conditions?(rest, count + 1)

  defp bounded_proper_conditions?(_conditions, _count), do: false
  defp valid_condition?(:*, _minimum, _maximum), do: true

  defp valid_condition?(value, minimum, maximum) when is_integer(value),
    do: within?(value, minimum, maximum)

  defp valid_condition?({:-, first, last}, minimum, maximum),
    do: valid_range?(first, last, minimum, maximum)

  defp valid_condition?({:/, :*, divisor}, _minimum, _maximum),
    do: positive_divisor?(divisor)

  defp valid_condition?({:/, {:-, first, last}, divisor}, minimum, maximum),
    do: valid_range?(first, last, minimum, maximum) and positive_divisor?(divisor)

  defp valid_condition?(_condition, _minimum, _maximum), do: false

  defp valid_range?(first, last, minimum, maximum) do
    is_integer(first) and is_integer(last) and first <= last and
      within?(first, minimum, maximum) and within?(last, minimum, maximum)
  end

  defp within?(value, minimum, maximum), do: value >= minimum and value <= maximum
  defp positive_divisor?(divisor), do: is_integer(divisor) and divisor > 0

  defp exact_keys?(expression) do
    map_size(expression) == @cron_key_count and
      Enum.all?(@cron_keys, &Map.has_key?(expression, &1))
  end
end
