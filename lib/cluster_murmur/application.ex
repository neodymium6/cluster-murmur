defmodule ClusterMurmur.Application do
  @moduledoc false

  use Application

  alias ClusterMurmur.Runtime.{CACertificateStore, ProductionApplication, RootSupervisor}

  @impl true
  def start(_type, _args) do
    with {:ok, children} <- child_specs() do
      RootSupervisor.start_link(children)
    end
  end

  defp child_specs do
    case Application.fetch_env(:cluster_murmur, :standalone_runtime) do
      {:ok, true} ->
        with :ok <- CACertificateStore.initialize() do
          ProductionApplication.child_specs()
        end

      {:ok, false} ->
        {:ok, [ClusterMurmur.Repo]}

      _invalid ->
        {:error, :invalid_application}
    end
  end
end
