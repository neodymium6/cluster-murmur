defmodule ClusterMurmur.Runtime.RootSupervisor do
  @moduledoc """
  Supervises persistence before every dependent runtime child.

  The rest-for-one strategy makes repository replacement stop all later
  runtime children. They restart only after the repository is available again,
  so the recovery-gated supervisor reruns every startup gate against the new
  repository process.
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
