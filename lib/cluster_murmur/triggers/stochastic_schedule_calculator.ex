defmodule ClusterMurmur.Triggers.StochasticScheduleCalculator do
  @moduledoc """
  Calculates a stochastic trigger's next UTC run from a supplied base instant.

  The calculation samples exactly one wait through the injected random source.
  It does not read a clock, inspect scheduler state, or persist the result.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Triggers.{StochasticSampler, StochasticTrigger}

  @type error ::
          :invalid_datetime
          | :invalid_random_source
          | :invalid_random_value
          | :invalid_trigger
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
end
