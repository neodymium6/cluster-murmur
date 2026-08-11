defmodule ClusterMurmur.Runtime.SystemRandom do
  @moduledoc """
  The production random source for bounded runtime policy decisions.

  Samples come directly from the Erlang cryptographic entropy source. Weighted
  choices are normalized before sampling so a validated finite aggregate does
  not overflow while it is converted to a sampling interval.
  """

  @behaviour ClusterMurmur.Random

  alias ClusterMurmur.DomainLimits

  @max_choices 256
  @max_float DomainLimits.max_float()
  @unit_scale 9_007_199_254_740_992

  @impl true
  def uniform do
    <<sample::unsigned-big-integer-size(53), _padding::size(3)>> =
      :crypto.strong_rand_bytes(7)

    sample / @unit_scale
  end

  @impl true
  def weighted_choice(choices) when is_list(choices) do
    with {:ok, positive, maximum} <- validate_choices(choices, [], 0, 0),
         true <- maximum > 0 do
      choose(positive, maximum)
    else
      _empty_or_invalid -> :empty
    end
  rescue
    _error -> :empty
  catch
    _kind, _reason -> :empty
  end

  def weighted_choice(_choices), do: :empty

  defp validate_choices([], positive, maximum, _count),
    do: {:ok, Enum.reverse(positive), maximum}

  defp validate_choices([_choice | _remaining], _positive, _maximum, @max_choices),
    do: :error

  defp validate_choices([{choice, weight} | remaining], positive, maximum, count) do
    if valid_weight?(weight) do
      next_positive = if weight > 0, do: [{choice, weight} | positive], else: positive
      validate_choices(remaining, next_positive, max(maximum, weight), count + 1)
    else
      :error
    end
  end

  defp validate_choices(_improper_tail, _positive, _maximum, _count), do: :error

  defp choose([{choice, _weight}], _maximum), do: {:ok, choice}

  defp choose(positive, maximum) do
    scaled = Enum.map(positive, fn {choice, weight} -> {choice, weight / maximum} end)
    total = Enum.reduce(scaled, 0.0, fn {_choice, weight}, sum -> sum + weight end)
    threshold = uniform() * total
    pick(scaled, threshold, List.last(positive) |> elem(0))
  end

  defp pick([{choice, weight} | _remaining], threshold, _fallback) when threshold < weight,
    do: {:ok, choice}

  defp pick([{_choice, weight} | remaining], threshold, fallback),
    do: pick(remaining, threshold - weight, fallback)

  defp pick([], _threshold, fallback), do: {:ok, fallback}

  defp valid_weight?(weight) when is_integer(weight),
    do: weight >= 0 and weight <= @max_float

  defp valid_weight?(weight) when is_float(weight),
    do: weight == weight and weight >= 0.0 and weight <= @max_float

  defp valid_weight?(_weight), do: false
end
