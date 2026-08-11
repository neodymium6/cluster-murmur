defmodule ClusterMurmur.Runtime.OperationalRootSupervisorTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Runtime.{
    HealthServer,
    HealthSettings,
    ReadinessLease,
    ReadyMarker,
    RootSupervisor
  }

  defmodule BlockingRuntime do
    @moduledoc false
    use GenServer

    def start_link({test_pid, starts}) do
      attempt = :ets.update_counter(starts, :count, {2, 1}, {:count, 0})

      if attempt > 1 do
        send(test_pid, {:runtime_restarting, self()})

        receive do
          :continue_runtime_start -> :ok
        end
      end

      GenServer.start_link(__MODULE__, :ok)
    end

    @impl true
    def init(:ok) do
      :ok = ReadyMarker.acquire(self())
      {:ok, :running}
    end
  end

  defmodule BlockingScheduler do
    @moduledoc false
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid) do
      Process.flag(:trap_exit, true)
      {:ok, test_pid}
    end

    @impl true
    def handle_cast(:block, test_pid) do
      send(test_pid, {:scheduler_blocked, self()})

      receive do
        :release_scheduler -> :ok
      end

      {:noreply, test_pid}
    end
  end

  defmodule FailingScheduler do
    @moduledoc false
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}
  end

  defmodule ReadinessRuntime do
    @moduledoc false
    use Supervisor

    def start_link(test_pid), do: Supervisor.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid) do
      children = [
        significant(BlockingScheduler, test_pid, 5_000),
        significant(FailingScheduler, test_pid, 5_000),
        significant(ReadinessLease, ReadyMarker, 1_000)
      ]

      Supervisor.init(children, strategy: :one_for_one, auto_shutdown: :any_significant)
    end

    defp significant(module, argument, shutdown) do
      {module, argument}
      |> Supervisor.child_spec(restart: :temporary, shutdown: shutdown)
      |> Map.put(:significant, true)
    end
  end

  test "keeps liveness up and readiness down while runtime gates rerun" do
    port = available_port()
    starts = :ets.new(__MODULE__, [:set, :public])

    repository = %{
      id: :repository,
      start: {Agent, :start_link, [fn -> :ready end]}
    }

    children = [
      {HealthServer, %HealthSettings{port: port}},
      {ReadyMarker, :production},
      repository,
      {BlockingRuntime, {self(), starts}}
    ]

    assert {:ok, supervisor} = Supervisor.start_link(RootSupervisor, children)

    assert status(port, "readyz") == 200
    repository_pid = child_pid(supervisor, :repository)
    Process.exit(repository_pid, :kill)

    assert_receive {:runtime_restarting, root_supervisor}
    assert root_supervisor == supervisor
    assert status(port, "livez") == 200
    assert status(port, "readyz") == 503
    assert status(port, "startupz") == 503

    send(root_supervisor, :continue_runtime_start)
    assert eventually_status(port, "readyz", 200)
    Supervisor.stop(supervisor)
  end

  test "drops readiness before a blocked scheduler can delay sibling shutdown" do
    port = available_port()

    children = [
      {HealthServer, %HealthSettings{port: port}},
      {ReadyMarker, :production},
      {ReadinessRuntime, self()}
    ]

    assert {:ok, supervisor} = Supervisor.start_link(RootSupervisor, children)
    runtime = child_pid(supervisor, ReadinessRuntime)
    blocker = child_pid(runtime, BlockingScheduler)
    failing = child_pid(runtime, FailingScheduler)
    assert status(port, "readyz") == 200

    GenServer.cast(blocker, :block)
    assert_receive {:scheduler_blocked, ^blocker}
    Process.exit(failing, :kill)

    assert eventually_status(port, "readyz", 503)
    assert Process.alive?(blocker)
    assert Process.alive?(runtime)

    send(blocker, :release_scheduler)
    assert eventually_status(port, "readyz", 200)
    Supervisor.stop(supervisor)
  end

  defp child_pid(supervisor, id) do
    assert {^id, pid, _type, _modules} =
             supervisor
             |> Supervisor.which_children()
             |> Enum.find(&(elem(&1, 0) == id))

    pid
  end

  defp eventually_status(port, path, expected, attempts \\ 20)
  defp eventually_status(_port, _path, _expected, 0), do: false

  defp eventually_status(port, path, expected, attempts) do
    if status(port, path) == expected do
      true
    else
      Process.sleep(10)
      eventually_status(port, path, expected, attempts - 1)
    end
  end

  defp status(port, path) do
    assert {:ok, socket} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

    assert :ok = :gen_tcp.send(socket, "GET /#{path} HTTP/1.1\r\n\r\n")
    assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    :gen_tcp.close(socket)

    [status_line | _rest] = String.split(response, "\r\n")
    ["HTTP/1.1", status, _reason] = String.split(status_line, " ", parts: 3)
    String.to_integer(status)
  end

  defp available_port do
    assert {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    assert {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
