defmodule ClusterMurmur.Runtime.RecoveredRuntimeSupervisor do
  @moduledoc """
  Starts poll and event-dispatch schedulers after one bounded recovery gate.

  Both schedulers share one failure domain so neither can run global recovery
  while the other still owns live work. The boundary validates every scheduler
  and recovery dependency before reading one clock instant. It uses that same
  instant as both the abandonment cutoff and recovery completion time.

  Any recovery error, incomplete mutation, or full bounded page prevents both
  schedulers from starting. Termination of either scheduler closes the shared
  supervisor, requiring a parent-managed replacement to recover again before
  starting either worker. This opt-in boundary is not installed automatically.
  """

  use Supervisor

  alias ClusterMurmur.DateTimeValidator

  alias ClusterMurmur.Runtime.{
    EventDispatchScheduler,
    PollScheduler,
    Recovery
  }

  alias ClusterMurmur.Runtime.Recovery.{Result, Stores}

  defmodule Options do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:poll_scheduler, :event_dispatch_scheduler, :clock]
    defstruct [:poll_scheduler, :event_dispatch_scheduler, :clock]

    @type t :: %__MODULE__{
            poll_scheduler: ClusterMurmur.Runtime.PollScheduler.Options.t(),
            event_dispatch_scheduler: ClusterMurmur.Runtime.EventDispatchScheduler.Options.t(),
            clock: module()
          }
  end

  @option_keys Options.__struct__() |> Map.keys()
  @option_key_count length(@option_keys)

  @doc "Recovers abandoned work before starting both validated schedulers."
  @spec start_link(Options.t()) :: Supervisor.on_start()
  def start_link(%Options{} = options), do: start_link(options, nil)
  def start_link(_options), do: {:error, :invalid_recovered_runtime_supervisor}

  @doc false
  @spec start_link(term(), Stores.t() | nil) :: Supervisor.on_start()
  def start_link(%Options{} = options, stores) do
    with :ok <- validate_options(options, stores),
         {:ok, started_at} <- current_time(options.clock),
         {:ok, %Result{failure_count: 0, saturated?: false}} <- recover(started_at, stores) do
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
         :ok <- EventDispatchScheduler.validate(options.event_dispatch_scheduler) do
      children = [
        significant_child(PollScheduler, options.poll_scheduler),
        significant_child(EventDispatchScheduler, options.event_dispatch_scheduler)
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
         :ok <- validate_clock(options.clock),
         true <- options.poll_scheduler.clock == options.clock,
         true <- options.event_dispatch_scheduler.clock == options.clock,
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

  defp exact_options?(options) do
    map_size(options) == @option_key_count and Enum.all?(@option_keys, &Map.has_key?(options, &1))
  end
end
