defmodule ClusterMurmur.Runtime.ProductionRecoveredRuntimeOptions do
  @moduledoc """
  Builds the fixed recovery-gated production runtime supervisor options.

  Construction combines five already validated scheduler option values with
  the application-owned schedule initializers and system clock. It validates
  module and cross-scheduler correlations without running recovery,
  initialization, a clock read, or a worker.
  """

  alias ClusterMurmur.Runtime.{
    ProductionBackgroundSchedulerOptions,
    ProductionConversationSchedulerOptions,
    RecoveredRuntimeSupervisor,
    RecurringScheduleInitializer,
    StochasticScheduleInitializer,
    SystemClock
  }

  alias ClusterMurmur.Startup
  alias ClusterMurmur.Startup.Prepared

  @doc "Builds one validated fixed production supervisor option value."
  @spec build(term()) ::
          {:ok, RecoveredRuntimeSupervisor.Options.t()}
          | {:error, :invalid_production_recovered_runtime_options}
  def build(%Prepared{} = prepared) do
    with :ok <- Startup.validate(prepared),
         {:ok, conversations} <- ProductionConversationSchedulerOptions.build(prepared),
         {:ok, background} <- ProductionBackgroundSchedulerOptions.build(prepared),
         options = %RecoveredRuntimeSupervisor.Options{
           poll_scheduler: conversations.poll,
           event_dispatch_scheduler: conversations.event_dispatch,
           recurring_schedule_scheduler: background.recurring,
           stochastic_scheduler: background.stochastic,
           event_retention_scheduler: background.event_retention,
           recurring_schedule_initializer: RecurringScheduleInitializer,
           stochastic_schedule_initializer: StochasticScheduleInitializer,
           clock: SystemClock
         },
         :ok <- RecoveredRuntimeSupervisor.validate(options) do
      {:ok, options}
    else
      _failure -> {:error, :invalid_production_recovered_runtime_options}
    end
  rescue
    _error -> {:error, :invalid_production_recovered_runtime_options}
  catch
    _kind, _reason -> {:error, :invalid_production_recovered_runtime_options}
  end

  def build(_prepared), do: {:error, :invalid_production_recovered_runtime_options}
end
