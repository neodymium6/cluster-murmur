defmodule ClusterMurmur.Triggers.StochasticSampler do
  @moduledoc """
  Samples a shifted-exponential wait from validated trigger parameters.

  The injected random source performs only the final uniform sample. This
  module owns input validation and the deterministic inverse-CDF calculation.
  """

  alias ClusterMurmur.Triggers.StochasticTrigger

  @max_interval_ms 365 * 86_400_000

  @type error :: :invalid_random_source | :invalid_random_value | :invalid_trigger

  @doc "Samples the next wait in whole milliseconds."
  @spec sample_wait(term(), module()) :: {:ok, non_neg_integer()} | {:error, error()}
  def sample_wait(trigger, random) do
    with {:ok, minimum, delay_mean} <- validate_trigger(trigger),
         {:ok, uniform} <- sample_uniform(random) do
      delay = trunc(-delay_mean * :math.log(1.0 - uniform))
      {:ok, minimum + delay}
    end
  end

  defp validate_trigger(%StochasticTrigger{
         distribution: :shifted_exponential,
         mean_interval_ms: mean,
         minimum_interval_ms: minimum
       })
       when is_integer(mean) and is_integer(minimum) and minimum > 0 and mean > minimum and
              mean <= @max_interval_ms and minimum <= @max_interval_ms,
       do: {:ok, minimum, mean - minimum}

  defp validate_trigger(_trigger), do: {:error, :invalid_trigger}

  defp sample_uniform(random) when is_atom(random) do
    if Code.ensure_loaded(random) == {:module, random} and function_exported?(random, :uniform, 0) do
      case random.uniform() do
        value when is_float(value) and value >= 0.0 and value < 1.0 -> {:ok, value}
        _value -> {:error, :invalid_random_value}
      end
    else
      {:error, :invalid_random_source}
    end
  rescue
    _error -> {:error, :invalid_random_source}
  catch
    _kind, _reason -> {:error, :invalid_random_source}
  end

  defp sample_uniform(_random), do: {:error, :invalid_random_source}
end
