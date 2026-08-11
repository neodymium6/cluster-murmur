defmodule ClusterMurmur.Runtime.ProductionBackgroundSchedulerOptions do
  @moduledoc """
  Builds validated production options for background runtime schedulers.

  Recurring, stochastic, and retention first runs are delayed by their explicit
  recurring intervals. Construction starts no process or timer and performs no
  clock, randomness, persistence, or external operation.
  """

  alias ClusterMurmur.Runtime.{
    EventRetentionCycle,
    EventRetentionScheduler,
    RecurringScheduleCycle,
    RecurringScheduleScheduler,
    StochasticCycle,
    StochasticScheduler,
    SystemClock,
    SystemRandom
  }

  alias ClusterMurmur.Startup
  alias ClusterMurmur.Startup.Prepared

  @derive {Inspect, only: []}
  @enforce_keys [:recurring, :stochastic, :event_retention]
  defstruct [:recurring, :stochastic, :event_retention]

  @type t :: %__MODULE__{
          recurring: ClusterMurmur.Runtime.RecurringScheduleScheduler.Options.t(),
          stochastic: ClusterMurmur.Runtime.StochasticScheduler.Options.t(),
          event_retention: ClusterMurmur.Runtime.EventRetentionScheduler.Options.t()
        }

  @doc "Builds and validates all three fixed background scheduler option values."
  @spec build(term()) ::
          {:ok, t()} | {:error, :invalid_production_background_scheduler_options}
  def build(%Prepared{} = prepared) do
    with :ok <- Startup.validate(prepared),
         options <- assemble(prepared),
         :ok <- RecurringScheduleScheduler.validate(options.recurring),
         :ok <- StochasticScheduler.validate(options.stochastic),
         :ok <- EventRetentionScheduler.validate(options.event_retention) do
      {:ok, options}
    else
      _failure -> {:error, :invalid_production_background_scheduler_options}
    end
  rescue
    _error -> {:error, :invalid_production_background_scheduler_options}
  catch
    _kind, _reason -> {:error, :invalid_production_background_scheduler_options}
  end

  def build(_prepared), do: {:error, :invalid_production_background_scheduler_options}

  defp assemble(prepared) do
    configuration = prepared.configuration
    settings = prepared.scheduler_settings

    %__MODULE__{
      recurring: %RecurringScheduleScheduler.Options{
        configuration: configuration,
        cycle: RecurringScheduleCycle,
        clock: SystemClock,
        interval_ms: settings.recurring_interval_ms,
        initial_delay_ms: settings.recurring_interval_ms
      },
      stochastic: %StochasticScheduler.Options{
        configuration: configuration,
        cycle: StochasticCycle,
        clock: SystemClock,
        random: SystemRandom,
        interval_ms: settings.stochastic_interval_ms,
        initial_delay_ms: settings.stochastic_interval_ms
      },
      event_retention: %EventRetentionScheduler.Options{
        configuration: configuration,
        cycle: EventRetentionCycle,
        clock: SystemClock,
        interval_ms: settings.event_retention_interval_ms,
        initial_delay_ms: settings.event_retention_interval_ms
      }
    }
  end
end
