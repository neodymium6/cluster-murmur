defmodule ClusterMurmur.Runtime.ReadinessLease do
  @moduledoc false

  use GenServer

  @spec start_link(module()) :: GenServer.on_start()
  def start_link(marker) when is_atom(marker) do
    GenServer.start_link(__MODULE__, marker)
  end

  def start_link(_marker), do: {:error, :invalid_readiness_lease}

  @impl true
  def init(marker) do
    case marker.acquire(self()) do
      :ok -> {:ok, marker}
      _failure -> {:stop, :invalid_readiness_lease}
    end
  rescue
    _error -> {:stop, :invalid_readiness_lease}
  catch
    _kind, _reason -> {:stop, :invalid_readiness_lease}
  end
end
