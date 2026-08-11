defmodule ClusterMurmur.Runtime.RootSupervisorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.RootSupervisor

  test "restarts runtime only after a replaced repository is available" do
    test_pid = self()
    repository_registry = :ets.new(__MODULE__, [:set, :public])

    repository = %{
      id: :repository,
      start:
        {Agent, :start_link,
         [
           fn ->
             true = :ets.insert(repository_registry, {:repository, self()})
             send(test_pid, {:repository_started, self()})
             :ready
           end
         ]}
    }

    runtime = %{
      id: :runtime,
      start:
        {Agent, :start_link,
         [
           fn ->
             [{:repository, repository_pid}] =
               :ets.lookup(repository_registry, :repository)

             send(test_pid, {:runtime_started, self(), repository_pid})
             :ready
           end
         ]}
    }

    assert {:ok, supervisor} = Supervisor.start_link(RootSupervisor, [repository, runtime])
    assert_receive {:repository_started, first_repository}
    assert_receive {:runtime_started, first_runtime, ^first_repository}

    Process.exit(first_repository, :kill)

    assert_receive {:repository_started, second_repository}
    assert second_repository != first_repository
    assert_receive {:runtime_started, second_runtime, ^second_repository}
    assert second_runtime != first_runtime
    refute Process.alive?(first_runtime)

    Supervisor.stop(supervisor)
  end
end
