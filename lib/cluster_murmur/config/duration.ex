defmodule ClusterMurmur.Config.Duration do
  @moduledoc """
  Parses configuration durations into non-negative milliseconds.

  Version 1 accepts an ASCII integer followed immediately by `ms`, `s`, `m`,
  `h`, or `d`. This module parses syntax only; callers enforce contextual
  requirements such as a strictly positive conversation timeout.
  """

  @milliseconds_per_unit %{
    "ms" => 1,
    "s" => 1_000,
    "m" => 60_000,
    "h" => 3_600_000,
    "d" => 86_400_000
  }

  @type error :: :invalid_duration

  @spec parse(term()) :: {:ok, non_neg_integer()} | {:error, error()}
  def parse(value) when is_binary(value) do
    case Regex.run(~r/\A([0-9]+)(ms|s|m|h|d)\z/, value, capture: :all_but_first) do
      [amount, unit] ->
        {:ok, String.to_integer(amount) * Map.fetch!(@milliseconds_per_unit, unit)}

      nil ->
        {:error, :invalid_duration}
    end
  end

  def parse(_value), do: {:error, :invalid_duration}
end
