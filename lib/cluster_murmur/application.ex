defmodule ClusterMurmur.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [ClusterMurmur.Repo]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: ClusterMurmur.Supervisor
    )
  end
end
