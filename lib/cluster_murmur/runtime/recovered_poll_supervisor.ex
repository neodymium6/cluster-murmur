defmodule ClusterMurmur.Runtime.RecoveredPollSupervisor do
  @moduledoc """
  Starts one explicit poll scheduler only after bounded restart recovery.

  The boundary validates every scheduler dependency before recovery, reads one
  injected clock instant, and uses that same instant as both the abandonment
  cutoff and recovery completion time. Any recovery error or incomplete
  mutation prevents the scheduler from starting. A full bounded recovery page
  also requires another startup pass to prove that no residual work remains.

  This supervisor has no live defaults and is not installed in the public
  application supervision tree automatically.
  """

  use Supervisor

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Runtime.{PollScheduler, Recovery}
  alias ClusterMurmur.Runtime.Recovery.{Result, Stores}

  defmodule Options do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:scheduler, :clock]
    defstruct [:scheduler, :clock]

    @type t :: %__MODULE__{
            scheduler: ClusterMurmur.Runtime.PollScheduler.Options.t(),
            clock: module()
          }
  end

  @option_keys Options.__struct__() |> Map.keys()
  @option_key_count length(@option_keys)

  @doc "Recovers abandoned work and starts one validated poll scheduler."
  @spec start_link(Options.t()) :: Supervisor.on_start()
  def start_link(%Options{} = options), do: start_link(options, nil)
  def start_link(_options), do: {:error, :invalid_recovered_poll_supervisor}

  @doc false
  @spec start_link(term(), Stores.t() | nil) :: Supervisor.on_start()
  def start_link(%Options{} = options, stores) do
    with :ok <- validate_options(options, stores),
         {:ok, started_at} <- current_time(options.clock),
         {:ok, %Result{failure_count: 0, saturated?: false}} <- recover(started_at, stores) do
      Supervisor.start_link(__MODULE__, options.scheduler)
    else
      _failure -> {:error, :invalid_recovered_poll_supervisor}
    end
  rescue
    _error -> {:error, :invalid_recovered_poll_supervisor}
  catch
    _kind, _reason -> {:error, :invalid_recovered_poll_supervisor}
  end

  def start_link(_options, _stores), do: {:error, :invalid_recovered_poll_supervisor}

  @impl true
  def init(scheduler) do
    case PollScheduler.validate(scheduler) do
      :ok ->
        child =
          {PollScheduler, scheduler}
          |> Supervisor.child_spec(restart: :temporary)
          |> Map.put(:significant, true)

        Supervisor.init([child],
          strategy: :one_for_one,
          auto_shutdown: :any_significant
        )

      {:error, :invalid_poll_scheduler} ->
        {:stop, :invalid_recovered_poll_supervisor}
    end
  end

  defp validate_options(options, stores) do
    with true <- exact_options?(options),
         :ok <- PollScheduler.validate(options.scheduler),
         :ok <- validate_clock(options.clock),
         true <- options.scheduler.clock == options.clock,
         true <- is_nil(stores) or match?(%Stores{}, stores) do
      :ok
    else
      _failure -> {:error, :invalid_recovered_poll_supervisor}
    end
  end

  defp validate_clock(clock) do
    if is_atom(clock) and Code.ensure_loaded?(clock) and function_exported?(clock, :utc_now, 0),
      do: :ok,
      else: {:error, :invalid_recovered_poll_supervisor}
  end

  defp current_time(clock) do
    case clock.utc_now() do
      %DateTime{} = now ->
        if DateTimeValidator.validate_storage_utc(now) == :ok,
          do: {:ok, now},
          else: {:error, :invalid_recovered_poll_supervisor}

      _failure ->
        {:error, :invalid_recovered_poll_supervisor}
    end
  end

  defp recover(started_at, nil), do: Recovery.run(started_at, started_at)
  defp recover(started_at, %Stores{} = stores), do: Recovery.run(started_at, started_at, stores)

  defp exact_options?(options) do
    map_size(options) == @option_key_count and Enum.all?(@option_keys, &Map.has_key?(options, &1))
  end
end
