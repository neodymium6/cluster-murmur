defmodule ClusterMurmur.Runtime.RecurringScheduleScheduler do
  @moduledoc """
  Runs explicitly configured recurring-schedule cycles without overlap.

  This worker has no live defaults. The production application constructs its
  validated options and starts it behind shared recovery gates; other uses must
  supervise it explicitly. The next timer is created only after the current
  synchronous cycle has returned.
  """

  use GenServer

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Runtime.RecurringScheduleCycle

  defmodule Options do
    @moduledoc false

    @derive {Inspect, only: [:interval_ms, :initial_delay_ms]}
    @enforce_keys [:configuration, :cycle, :clock, :interval_ms, :initial_delay_ms]
    defstruct [:configuration, :cycle, :clock, :interval_ms, :initial_delay_ms]

    @type t :: %__MODULE__{
            configuration: ClusterMurmur.Config.Configuration.t(),
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
            last_result: ClusterMurmur.Runtime.RecurringScheduleCycle.Result.t() | nil,
            last_error: :invalid_cycle | nil
          }
  end

  @option_keys Options.__struct__() |> Map.keys()
  @option_key_count length(@option_keys)
  @max_interval_ms DomainLimits.max_interval_ms()

  @doc "Starts one opt-in non-overlapping recurring-schedule scheduler."
  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = options) do
    case validate(options) do
      :ok -> GenServer.start_link(__MODULE__, options)
      {:error, :invalid_recurring_schedule_scheduler} = error -> error
    end
  end

  def start_link(_options), do: {:error, :invalid_recurring_schedule_scheduler}

  @doc "Revalidates exact scheduler options without starting a worker."
  @spec validate(term()) :: :ok | {:error, :invalid_recurring_schedule_scheduler}
  def validate(%Options{} = options), do: validate_options(options)
  def validate(_options), do: {:error, :invalid_recurring_schedule_scheduler}

  @doc "Returns aggregate status without configuration, claim, or event data."
  @spec status(GenServer.server()) :: {:ok, Status.t()} | {:error, :unavailable}
  def status(server) do
    {:ok, GenServer.call(server, :status)}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    timer_token = schedule(options.initial_delay_ms)
    {:ok, {options, %Status{cycle_count: 0, last_result: nil, last_error: nil}, timer_token}}
  end

  @impl true
  def handle_call(:status, _from, {options, status, timer_token}),
    do: {:reply, status, {options, status, timer_token}}

  @impl true
  def handle_info(
        {:recurring_schedule_cycle, timer_token},
        {options, status, timer_token}
      ) do
    next_status = run_cycle(options, status)
    next_timer_token = schedule(options.interval_ms)
    {:noreply, {options, next_status, next_timer_token}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_cycle(options, status) do
    case current_time(options.clock) do
      {:ok, now} ->
        options.cycle
        |> apply(:run, [options.configuration, now])
        |> next_status(status)

      {:error, :invalid_clock} ->
        failed_status(status)
    end
  rescue
    _error -> failed_status(status)
  catch
    _kind, _reason -> failed_status(status)
  end

  defp next_status({:ok, %RecurringScheduleCycle.Result{} = result}, status) do
    case RecurringScheduleCycle.validate_result(result) do
      :ok -> %{status | cycle_count: status.cycle_count + 1, last_result: result, last_error: nil}
      {:error, :invalid_recurring_schedule_cycle_result} -> failed_status(status)
    end
  end

  defp next_status(_failure, status), do: failed_status(status)

  defp failed_status(status) do
    %{status | cycle_count: status.cycle_count + 1, last_result: nil, last_error: :invalid_cycle}
  end

  defp validate_options(options) do
    with true <- exact_options?(options),
         :ok <- normalize_configuration(Configuration.validate(options.configuration)),
         :ok <- validate_adapter(options.cycle, run: 2),
         :ok <- validate_adapter(options.clock, utc_now: 0),
         true <- valid_interval?(options.interval_ms),
         true <- valid_delay?(options.initial_delay_ms) do
      :ok
    else
      _failure -> {:error, :invalid_recurring_schedule_scheduler}
    end
  rescue
    _error -> {:error, :invalid_recurring_schedule_scheduler}
  catch
    _kind, _reason -> {:error, :invalid_recurring_schedule_scheduler}
  end

  defp validate_adapter(adapter, callbacks) do
    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(adapter, name, arity) end),
       do: :ok,
       else: {:error, :invalid_recurring_schedule_scheduler}
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

  defp normalize_configuration(:ok), do: :ok
  defp normalize_configuration(_failure), do: {:error, :invalid_recurring_schedule_scheduler}

  defp valid_interval?(value), do: is_integer(value) and value in 1..@max_interval_ms
  defp valid_delay?(value), do: is_integer(value) and value in 0..@max_interval_ms

  defp exact_options?(options) do
    map_size(options) == @option_key_count and Enum.all?(@option_keys, &Map.has_key?(options, &1))
  end

  defp schedule(delay_ms) do
    timer_token = make_ref()
    Process.send_after(self(), {:recurring_schedule_cycle, timer_token}, delay_ms)
    timer_token
  end
end
