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

  @doc "Returns the sampled next run strictly after a supplied canonical UTC instant."
  @spec next_run(term(), term(), term()) :: {:ok, DateTime.t()} | {:error, error()}
  def next_run(
        %StochasticTrigger{} = trigger,
        %DateTime{time_zone: "Etc/UTC"} = datetime,
        random
      ) do
    with :ok <- DateTimeValidator.validate(datetime),
         {:ok, wait_ms} <- StochasticSampler.sample_wait(trigger, random) do
      add_wait(datetime, wait_ms)
    end
  end

  def next_run(%StochasticTrigger{}, _datetime, _random), do: {:error, :invalid_datetime}
  def next_run(_trigger, _datetime, _random), do: {:error, :invalid_trigger}

  defp add_wait(datetime, wait_ms) do
    {:ok, DateTime.add(datetime, wait_ms, :millisecond)}
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end
end
