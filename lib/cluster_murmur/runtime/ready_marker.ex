defmodule ClusterMurmur.Runtime.ReadyMarker do
  @moduledoc """
  Tracks the lease held by the fully started production runtime.

  The marker service starts unavailable before persistence and runtime. The
  recovery-gated supervisor acquires its single lease only after every
  scheduler starts, and places that lease last so it disappears before any
  scheduler shutdown can block runtime replacement.
  """

  use GenServer

  @doc "Starts the fixed singleton ready marker."
  @spec start_link(:production) :: GenServer.on_start()
  def start_link(:production) do
    case GenServer.start_link(__MODULE__, :ok, name: __MODULE__) do
      {:ok, marker} -> {:ok, marker}
      _failure -> {:error, :invalid_ready_marker}
    end
  rescue
    _error -> {:error, :invalid_ready_marker}
  catch
    _kind, _reason -> {:error, :invalid_ready_marker}
  end

  def start_link(_options), do: {:error, :invalid_ready_marker}

  @doc "Acquires the single readiness lease for a live runtime process."
  @spec acquire(pid()) :: :ok | {:error, :invalid_ready_marker}
  def acquire(lease) when is_pid(lease) do
    GenServer.call(__MODULE__, {:acquire, lease}, 1_000)
  rescue
    _error -> {:error, :invalid_ready_marker}
  catch
    _kind, _reason -> {:error, :invalid_ready_marker}
  end

  def acquire(_lease), do: {:error, :invalid_ready_marker}

  @doc "Reports only whether a live production runtime holds the lease."
  @spec ready?() :: boolean()
  def ready? do
    GenServer.call(__MODULE__, :ready?, 50) === true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_call({:acquire, lease}, _from, nil) do
    acquire_live_lease(lease)
  end

  def handle_call({:acquire, lease}, _from, {current, reference} = state) do
    if Process.alive?(current) do
      {:reply, {:error, :invalid_ready_marker}, state}
    else
      Process.demonitor(reference, [:flush])
      acquire_live_lease(lease)
    end
  end

  def handle_call(:ready?, _from, {lease, reference} = state) do
    if Process.alive?(lease) do
      {:reply, true, state}
    else
      Process.demonitor(reference, [:flush])
      {:reply, false, nil}
    end
  end

  def handle_call(:ready?, _from, nil), do: {:reply, false, nil}

  @impl true
  def handle_info({:DOWN, reference, :process, lease, _reason}, {lease, reference}) do
    {:noreply, nil}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp acquire_live_lease(lease) do
    if Process.alive?(lease) do
      reference = Process.monitor(lease)
      {:reply, :ok, {lease, reference}}
    else
      {:reply, {:error, :invalid_ready_marker}, nil}
    end
  end
end
