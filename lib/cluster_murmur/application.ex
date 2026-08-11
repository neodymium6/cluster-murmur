defmodule ClusterMurmur.Application do
  @moduledoc false

  use Application

  alias ClusterMurmur.Runtime.{ProductionApplication, RootSupervisor}

  @impl true
  def start(_type, _args) do
    with {:ok, children} <- child_specs() do
      RootSupervisor.start_link(children)
    end
  end

  defp child_specs do
    case Application.fetch_env(:cluster_murmur, :standalone_runtime) do
      {:ok, true} -> ProductionApplication.child_specs()
      {:ok, false} -> {:ok, [ClusterMurmur.Repo]}
      _invalid -> {:error, :invalid_application}
    end
  end
end
