defmodule ClusterMurmur.Runtime.EventDispatchScheduler do
  @moduledoc """
  Runs explicitly configured event-dispatch cycles without overlap.

  The worker has no live defaults and is not installed in the application
  supervision tree automatically. A deployment must construct validated
  options and supervise it explicitly. The next timer is created only after
  the current synchronous cycle has returned.
  """

  use GenServer

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Runtime.EventDispatchCycle
  alias ClusterMurmur.Runtime.EventDispatchCycle.{Adapters, Context}

  defmodule Options do
    @moduledoc false

    @derive {Inspect, only: [:interval_ms, :initial_delay_ms]}
    @enforce_keys [
      :configuration,
      :cycle_context,
      :cycle_adapters,
      :cycle,
      :clock,
      :interval_ms,
      :initial_delay_ms
    ]
    defstruct [
      :configuration,
      :cycle_context,
      :cycle_adapters,
      :cycle,
      :clock,
      :interval_ms,
      :initial_delay_ms
    ]

    @type t :: %__MODULE__{
            configuration: ClusterMurmur.Config.Configuration.t(),
            cycle_context: ClusterMurmur.Runtime.EventDispatchCycle.Context.t(),
            cycle_adapters: ClusterMurmur.Runtime.EventDispatchCycle.Adapters.t(),
            cycle: module(),
            clock: module(),
            interval_ms: pos_integer(),
            initial_delay_ms: non_neg_integer()
          }
  end

  defmodule Status do
    @moduledoc false

    @derive {Inspect, only: [:cycle_count, :last_error]}
    @enforce_keys [:cycle_count, :last_result, :last_error]
    defstruct [:cycle_count, :last_result, :last_error]

    @type t :: %__MODULE__{
            cycle_count: non_neg_integer(),
            last_result: ClusterMurmur.Runtime.EventDispatchCycle.Result.t() | nil,
            last_error: :dispatch_failed | :invalid_cycle | nil
          }
  end

  @option_keys Options.__struct__() |> Map.keys()
  @option_key_count length(@option_keys)
  @max_interval_ms DomainLimits.max_interval_ms()

  @doc "Starts one opt-in non-overlapping event-dispatch scheduler."
  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = options) do
    case validate(options) do
      :ok -> GenServer.start_link(__MODULE__, options)
      {:error, :invalid_event_dispatch_scheduler} = error -> error
    end
  end

  def start_link(_options), do: {:error, :invalid_event_dispatch_scheduler}

  @doc "Revalidates exact scheduler options without starting a worker."
  @spec validate(term()) :: :ok | {:error, :invalid_event_dispatch_scheduler}
  def validate(%Options{} = options), do: validate_options(options)
  def validate(_options), do: {:error, :invalid_event_dispatch_scheduler}

  @doc "Returns aggregate status without runtime configuration or event data."
  @spec status(GenServer.server()) :: {:ok, Status.t()} | {:error, :unavailable}
  def status(server) do
    {:ok, GenServer.call(server, :status)}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(options) do
    timer_token = schedule(options.initial_delay_ms)
    {:ok, {options, %Status{cycle_count: 0, last_result: nil, last_error: nil}, timer_token}}
  end

  @impl true
  def handle_call(:status, _from, {options, status, timer_token}),
    do: {:reply, status, {options, status, timer_token}}

  @impl true
  def handle_info({:event_dispatch_cycle, timer_token}, {options, status, timer_token}) do
    next_status = run_cycle(options, status)
    next_timer_token = schedule(options.interval_ms)
    {:noreply, {options, next_status, next_timer_token}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_cycle(options, status) do
    case current_time(options.clock) do
      {:ok, now} ->
        options.cycle
        |> apply(:run, [
          options.configuration,
          now,
          options.cycle_context,
          options.cycle_adapters
        ])
        |> next_status(status)

      {:error, :invalid_clock} ->
        failed_status(status, :invalid_cycle)
    end
  rescue
    _error -> failed_status(status, :invalid_cycle)
  catch
    _kind, _reason -> failed_status(status, :invalid_cycle)
  end

  defp next_status({:ok, %EventDispatchCycle.Result{} = result}, status) do
    case EventDispatchCycle.validate_result(result) do
      :ok -> %{status | cycle_count: status.cycle_count + 1, last_result: result, last_error: nil}
      {:error, :invalid_event_dispatch_cycle} -> failed_status(status, :invalid_cycle)
    end
  end

  defp next_status({:error, :event_dispatch_failed}, status),
    do: failed_status(status, :dispatch_failed)

  defp next_status(_failure, status), do: failed_status(status, :invalid_cycle)

  defp failed_status(status, error) do
    %{status | cycle_count: status.cycle_count + 1, last_result: nil, last_error: error}
  end

  defp validate_options(options) do
    with true <- exact_options?(options),
         true <- match?(%Context{}, options.cycle_context),
         true <- match?(%Adapters{}, options.cycle_adapters),
         :ok <-
           EventDispatchCycle.validate_runtime(
             options.configuration,
             options.cycle_context,
             options.cycle_adapters
           ),
         :ok <- validate_adapter(options.cycle, run: 4),
         :ok <- validate_adapter(options.clock, utc_now: 0),
         true <- valid_interval?(options.interval_ms),
         true <- valid_delay?(options.initial_delay_ms) do
      :ok
    else
      _failure -> {:error, :invalid_event_dispatch_scheduler}
    end
  rescue
    _error -> {:error, :invalid_event_dispatch_scheduler}
  catch
    _kind, _reason -> {:error, :invalid_event_dispatch_scheduler}
  end

  defp validate_adapter(adapter, callbacks) do
    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(adapter, name, arity) end),
       do: :ok,
       else: {:error, :invalid_event_dispatch_scheduler}
  end

  defp current_time(clock) do
    case clock.utc_now() do
      %DateTime{} = now ->
        if DateTimeValidator.validate_storage_utc(now) == :ok,
          do: {:ok, now},
          else: {:error, :invalid_clock}

      _failure ->
        {:error, :invalid_clock}
    end
  end

  defp valid_interval?(value), do: is_integer(value) and value in 1..@max_interval_ms
  defp valid_delay?(value), do: is_integer(value) and value in 0..@max_interval_ms

  defp exact_options?(options) do
    map_size(options) == @option_key_count and Enum.all?(@option_keys, &Map.has_key?(options, &1))
  end

  defp schedule(delay_ms) do
    timer_token = make_ref()
    Process.send_after(self(), {:event_dispatch_cycle, timer_token}, delay_ms)
    timer_token
  end
end
