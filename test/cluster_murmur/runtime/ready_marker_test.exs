defmodule ClusterMurmur.Runtime.ReadyMarkerTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Runtime.ReadyMarker

  test "reports readiness only while one live runtime holds the lease" do
    refute ReadyMarker.ready?()
    assert {:ok, marker} = ReadyMarker.start_link(:production)
    refute ReadyMarker.ready?()

    lease = spawn(fn -> Process.sleep(:infinity) end)
    assert ReadyMarker.acquire(lease) == :ok
    assert ReadyMarker.ready?()
    assert ReadyMarker.acquire(self()) == {:error, :invalid_ready_marker}
    assert ReadyMarker.start_link(:production) == {:error, :invalid_ready_marker}

    Process.exit(lease, :kill)
    refute eventually_ready?()
    GenServer.stop(marker)
    refute ReadyMarker.ready?()
  end

  test "rejects caller-selected marker options" do
    assert ReadyMarker.start_link(nil) == {:error, :invalid_ready_marker}
    assert ReadyMarker.acquire(nil) == {:error, :invalid_ready_marker}
  end

  test "replaces stale state before its monitor message is handled" do
    assert {:ok, marker} = ReadyMarker.start_link(:production)
    stale = spawn(fn -> :ok end)
    reference = make_ref()
    wait_until_dead(stale)

    :sys.replace_state(marker, fn nil -> {stale, reference} end)
    refute ReadyMarker.ready?()

    replacement = spawn(fn -> Process.sleep(:infinity) end)
    assert ReadyMarker.acquire(replacement) == :ok
    assert ReadyMarker.ready?()

    Process.exit(replacement, :kill)
    GenServer.stop(marker)
  end

  defp eventually_ready?(attempts \\ 20)
  defp eventually_ready?(0), do: ReadyMarker.ready?()

  defp eventually_ready?(attempts) do
    if ReadyMarker.ready?() do
      Process.sleep(10)
      eventually_ready?(attempts - 1)
    else
      false
    end
  end

  defp wait_until_dead(pid) do
    reference = Process.monitor(pid)
    assert_receive {:DOWN, ^reference, :process, ^pid, _reason}
  end
end
