defmodule ClusterMurmur.Runtime.RecoveredRuntimeSupervisor do
  @moduledoc """
  Starts all bounded runtime schedulers after shared startup gates.

  All schedulers share one failure domain so none can run global recovery while
  another still owns live work. The boundary validates every scheduler,
  initializer, and recovery dependency before reading one clock instant. It
  uses that same instant for recovery and both schedule initializations.

  Any recovery or initialization error, incomplete mutation, or full bounded
  page prevents all five schedulers from starting. Termination of any scheduler
  closes the shared supervisor, requiring a parent-managed replacement to run
  every gate again before starting any worker. This opt-in boundary is not
  installed automatically.
  """

  use Supervisor

  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Runtime.{
    EventDispatchScheduler,
    EventRetentionScheduler,
    PollScheduler,
    RecurringScheduleInitializer,
    RecurringScheduleScheduler,
    Recovery,
    StochasticScheduleInitializer,
    StochasticScheduler
  }

  alias ClusterMurmur.Runtime.RecurringScheduleInitializer.Result, as: RecurringResult
  alias ClusterMurmur.Runtime.Recovery.{Result, Stores}
  alias ClusterMurmur.Runtime.StochasticScheduleInitializer.Result, as: StochasticResult
  alias ClusterMurmur.Triggers.{ScheduleTrigger, StochasticTrigger}

  @max_schedules 256

  defmodule Options do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [
      :poll_scheduler,
      :event_dispatch_scheduler,
      :recurring_schedule_scheduler,
      :stochastic_scheduler,
      :event_retention_scheduler,
      :recurring_schedule_initializer,
      :stochastic_schedule_initializer,
      :clock
    ]
    defstruct [
      :poll_scheduler,
      :event_dispatch_scheduler,
      :recurring_schedule_scheduler,
      :stochastic_scheduler,
      :event_retention_scheduler,
      :recurring_schedule_initializer,
      :stochastic_schedule_initializer,
      :clock
    ]

    @type t :: %__MODULE__{
            poll_scheduler: ClusterMurmur.Runtime.PollScheduler.Options.t(),
            event_dispatch_scheduler: ClusterMurmur.Runtime.EventDispatchScheduler.Options.t(),
            recurring_schedule_scheduler:
              ClusterMurmur.Runtime.RecurringScheduleScheduler.Options.t(),
            stochastic_scheduler: ClusterMurmur.Runtime.StochasticScheduler.Options.t(),
            event_retention_scheduler: ClusterMurmur.Runtime.EventRetentionScheduler.Options.t(),
            recurring_schedule_initializer: module(),
            stochastic_schedule_initializer: module(),
            clock: module()
          }
  end

  @option_keys Options.__struct__() |> Map.keys()
  @option_key_count length(@option_keys)

  @doc "Runs recovery and schedule initialization before all five schedulers."
  @spec start_link(Options.t()) :: Supervisor.on_start()
  def start_link(%Options{} = options), do: start_link(options, nil)
  def start_link(_options), do: {:error, :invalid_recovered_runtime_supervisor}

  @doc false
  @spec start_link(term(), Stores.t() | nil) :: Supervisor.on_start()
  def start_link(%Options{} = options, stores) do
    with :ok <- validate_options(options, stores),
         {:ok, started_at} <- current_time(options.clock),
         {:ok, %Result{failure_count: 0, saturated?: false}} <- recover(started_at, stores),
         :ok <- initialize_recurring(options, started_at),
         :ok <- initialize_stochastic(options, started_at) do
      Supervisor.start_link(__MODULE__, options)
    else
      _failure -> {:error, :invalid_recovered_runtime_supervisor}
    end
  rescue
    _error -> {:error, :invalid_recovered_runtime_supervisor}
  catch
    _kind, _reason -> {:error, :invalid_recovered_runtime_supervisor}
  end

  def start_link(_options, _stores),
    do: {:error, :invalid_recovered_runtime_supervisor}

  @impl true
  def init(options) do
    with :ok <- PollScheduler.validate(options.poll_scheduler),
         :ok <- EventDispatchScheduler.validate(options.event_dispatch_scheduler),
         :ok <- RecurringScheduleScheduler.validate(options.recurring_schedule_scheduler),
         :ok <- StochasticScheduler.validate(options.stochastic_scheduler),
         :ok <- EventRetentionScheduler.validate(options.event_retention_scheduler) do
      children = [
        significant_child(PollScheduler, options.poll_scheduler),
        significant_child(EventDispatchScheduler, options.event_dispatch_scheduler),
        significant_child(RecurringScheduleScheduler, options.recurring_schedule_scheduler),
        significant_child(StochasticScheduler, options.stochastic_scheduler),
        significant_child(EventRetentionScheduler, options.event_retention_scheduler)
      ]

      Supervisor.init(children,
        strategy: :one_for_one,
        auto_shutdown: :any_significant
      )
    else
      _failure -> {:stop, :invalid_recovered_runtime_supervisor}
    end
  end

  defp significant_child(module, options) do
    {module, options}
    |> Supervisor.child_spec(restart: :temporary)
    |> Map.put(:significant, true)
  end

  defp validate_options(options, stores) do
    with true <- exact_options?(options),
         :ok <- PollScheduler.validate(options.poll_scheduler),
         :ok <- EventDispatchScheduler.validate(options.event_dispatch_scheduler),
         :ok <- RecurringScheduleScheduler.validate(options.recurring_schedule_scheduler),
         :ok <- StochasticScheduler.validate(options.stochastic_scheduler),
         :ok <- EventRetentionScheduler.validate(options.event_retention_scheduler),
         :ok <- validate_initializer(options.recurring_schedule_initializer, 2),
         :ok <- validate_initializer(options.stochastic_schedule_initializer, 3),
         :ok <- validate_clock(options.clock),
         true <- options.poll_scheduler.clock == options.clock,
         true <- options.event_dispatch_scheduler.clock == options.clock,
         true <- options.recurring_schedule_scheduler.clock == options.clock,
         true <- options.stochastic_scheduler.clock == options.clock,
         true <- options.event_retention_scheduler.clock == options.clock,
         true <-
           options.poll_scheduler.configuration ===
             options.event_dispatch_scheduler.configuration,
         true <-
           options.poll_scheduler.configuration ===
             options.recurring_schedule_scheduler.configuration,
         true <-
           options.poll_scheduler.configuration === options.stochastic_scheduler.configuration,
         true <-
           options.poll_scheduler.configuration ===
             options.event_retention_scheduler.configuration,
         :ok <- validate_stores(stores) do
      :ok
    else
      _failure -> {:error, :invalid_recovered_runtime_supervisor}
    end
  rescue
    _error -> {:error, :invalid_recovered_runtime_supervisor}
  catch
    _kind, _reason -> {:error, :invalid_recovered_runtime_supervisor}
  end

  defp validate_stores(nil), do: Recovery.validate_stores()
  defp validate_stores(%Stores{} = stores), do: Recovery.validate_stores(stores)
  defp validate_stores(_stores), do: {:error, :invalid_recovered_runtime_supervisor}

  defp validate_clock(clock) do
    if is_atom(clock) and Code.ensure_loaded?(clock) and function_exported?(clock, :utc_now, 0),
      do: :ok,
      else: {:error, :invalid_recovered_runtime_supervisor}
  end

  defp validate_initializer(initializer, arity) do
    if is_atom(initializer) and Code.ensure_loaded?(initializer) and
         function_exported?(initializer, :run, arity),
       do: :ok,
       else: {:error, :invalid_recovered_runtime_supervisor}
  end

  defp current_time(clock) do
    case clock.utc_now() do
      %DateTime{} = now ->
        if DateTimeValidator.validate_storage_utc(now) == :ok,
          do: {:ok, now},
          else: {:error, :invalid_recovered_runtime_supervisor}

      _failure ->
        {:error, :invalid_recovered_runtime_supervisor}
    end
  end

  defp recover(started_at, nil), do: Recovery.run(started_at, started_at)
  defp recover(started_at, %Stores{} = stores), do: Recovery.run(started_at, started_at, stores)

  defp initialize_recurring(options, started_at) do
    configuration = options.recurring_schedule_scheduler.configuration

    with {:ok, expected_count} <- recurring_schedule_count(configuration),
         {:ok, %RecurringResult{} = result} <-
           options.recurring_schedule_initializer.run(configuration, started_at),
         :ok <- RecurringScheduleInitializer.validate_result(result),
         true <- result.schedule_count == expected_count do
      :ok
    else
      _failure -> {:error, :invalid_recovered_runtime_supervisor}
    end
  end

  defp initialize_stochastic(options, started_at) do
    configuration = options.stochastic_scheduler.configuration

    with {:ok, expected_count} <- schedule_count(configuration, StochasticTrigger),
         {:ok, %StochasticResult{} = result} <-
           options.stochastic_schedule_initializer.run(
             configuration,
             started_at,
             options.stochastic_scheduler.random
           ),
         :ok <- StochasticScheduleInitializer.validate_result(result),
         true <- result.schedule_count == expected_count do
      :ok
    else
      _failure -> {:error, :invalid_recovered_runtime_supervisor}
    end
  end

  defp recurring_schedule_count(configuration) do
    schedule_count(configuration, ScheduleTrigger)
  end

  defp schedule_count(configuration, trigger_module) do
    configuration.triggers.triggers
    |> Map.values()
    |> Enum.reduce_while(0, fn
      %{__struct__: ^trigger_module}, count when count < @max_schedules -> {:cont, count + 1}
      %{__struct__: ^trigger_module}, _count -> {:halt, :oversized}
      _other, count -> {:cont, count}
    end)
    |> case do
      count when is_integer(count) -> {:ok, count}
      :oversized -> {:error, :invalid_recovered_runtime_supervisor}
    end
  end

  defp exact_options?(options) do
    map_size(options) == @option_key_count and Enum.all?(@option_keys, &Map.has_key?(options, &1))
  end
end
