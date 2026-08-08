defmodule ClusterMurmur.Runtime.PollScheduler do
  @moduledoc """
  Runs explicitly configured poll-starter cycles without overlap.

  This worker has no live defaults and is not installed in the application
  supervision tree automatically. A deployment must construct validated
  options and supervise it explicitly. The next timer is created only after
  the current synchronous cycle has returned.
  """

  use GenServer

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Observers.Client
  alias ClusterMurmur.Runtime.PollStarterCycle
  alias ClusterMurmur.Runtime.PollStarterCycle.Context

  defmodule Options do
    @moduledoc false

    @derive {Inspect, only: [:interval_ms, :initial_delay_ms]}
    @enforce_keys [
      :observer_client,
      :configuration,
      :cycle_context,
      :ingestion_store,
      :clock,
      :interval_ms,
      :initial_delay_ms
    ]
    defstruct [
      :observer_client,
      :configuration,
      :cycle_context,
      :ingestion_store,
      :clock,
      :interval_ms,
      :initial_delay_ms
    ]

    @type t :: %__MODULE__{
            observer_client: ClusterMurmur.Observers.Client.t(),
            configuration: ClusterMurmur.Config.Configuration.t(),
            cycle_context: ClusterMurmur.Runtime.PollStarterCycle.Context.t(),
            ingestion_store: module(),
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
            last_result: ClusterMurmur.Runtime.PollStarterCycle.Result.t() | nil,
            last_error: :invalid_cycle | :poll_failed | nil
          }
  end

  @option_keys Options.__struct__() |> Map.keys()
  @option_key_count length(@option_keys)
  @max_interval_ms DomainLimits.max_interval_ms()

  @doc "Starts one opt-in non-overlapping scheduler."
  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = options) do
    case validate_options(options) do
      :ok -> GenServer.start_link(__MODULE__, options)
      {:error, :invalid_poll_scheduler} -> {:error, :invalid_poll_scheduler}
    end
  end

  def start_link(_options), do: {:error, :invalid_poll_scheduler}

  @doc "Returns aggregate scheduler status without observation or prompt data."
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
  def handle_info({:poll, timer_token}, {options, status, timer_token}) do
    next_status = run_cycle(options, status)
    next_timer_token = schedule(options.interval_ms)
    {:noreply, {options, next_status, next_timer_token}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_cycle(options, status) do
    case current_time(options.clock) do
      {:ok, started_at} ->
        options.observer_client
        |> PollStarterCycle.run(
          options.configuration,
          started_at,
          options.cycle_context,
          options.ingestion_store
        )
        |> next_status(status)

      {:error, :invalid_clock} ->
        failed_status(status, :invalid_cycle)
    end
  rescue
    _error -> failed_status(status, :invalid_cycle)
  catch
    _kind, _reason -> failed_status(status, :invalid_cycle)
  end

  defp next_status({:ok, result}, status),
    do: %{status | cycle_count: status.cycle_count + 1, last_result: result, last_error: nil}

  defp next_status({:error, :poll_failed}, status), do: failed_status(status, :poll_failed)
  defp next_status(_failure, status), do: failed_status(status, :invalid_cycle)

  defp failed_status(status, error) do
    %{status | cycle_count: status.cycle_count + 1, last_result: nil, last_error: error}
  end

  defp validate_options(options) do
    with true <- exact_options?(options),
         :ok <- Client.validate(options.observer_client),
         :ok <- validate_configuration(options.configuration),
         true <- match?(%Context{}, options.cycle_context),
         :ok <- PollStarterCycle.validate_runtime(options.configuration, options.cycle_context),
         :ok <- validate_ingestion_store(options.ingestion_store),
         :ok <- validate_clock(options.clock),
         true <- valid_interval?(options.interval_ms),
         true <- valid_delay?(options.initial_delay_ms) do
      :ok
    else
      _failure -> {:error, :invalid_poll_scheduler}
    end
  rescue
    _error -> {:error, :invalid_poll_scheduler}
  catch
    _kind, _reason -> {:error, :invalid_poll_scheduler}
  end

  defp validate_configuration(configuration) do
    case Configuration.validate(configuration) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_poll_scheduler}
    end
  end

  defp validate_ingestion_store(store) do
    if is_atom(store) and Code.ensure_loaded?(store) and function_exported?(store, :ingest, 2),
      do: :ok,
      else: {:error, :invalid_poll_scheduler}
  end

  defp validate_clock(clock) do
    if is_atom(clock) and Code.ensure_loaded?(clock) and function_exported?(clock, :utc_now, 0),
      do: :ok,
      else: {:error, :invalid_poll_scheduler}
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
    Process.send_after(self(), {:poll, timer_token}, delay_ms)
    timer_token
  end
end
