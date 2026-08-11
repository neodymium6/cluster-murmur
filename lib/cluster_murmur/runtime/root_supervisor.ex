defmodule ClusterMurmur.Runtime.RootSupervisor do
  @moduledoc """
  Supervises operational health, persistence, and dependent runtime children.

  The fixed production order keeps liveness available while the runtime is
  replaced. The readiness service remains unavailable until its later runtime
  lease is acquired. Repository replacement stops the runtime lease and all
  schedulers; they restart only after the repository is available again, so
  every startup gate reruns against the new process.
  """

  use Supervisor

  @doc "Starts the named application root supervisor."
  @spec start_link([Supervisor.child_spec() | {module(), term()} | module()]) ::
          Supervisor.on_start()
  def start_link(children) when is_list(children) do
    Supervisor.start_link(__MODULE__, children, name: ClusterMurmur.Supervisor)
  end

  def start_link(_children), do: {:error, :invalid_root_supervisor}

  @impl true
  def init(children) when is_list(children) do
    Supervisor.init(children, strategy: :rest_for_one)
  end

  def init(_children), do: {:stop, :invalid_root_supervisor}
end
