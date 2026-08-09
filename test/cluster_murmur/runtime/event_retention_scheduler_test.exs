defmodule ClusterMurmur.Runtime.EventRetentionSchedulerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.{EventRetentionCycle, EventRetentionScheduler}
  alias ClusterMurmur.Runtime.EventRetentionScheduler.{Options, Status}
  alias ClusterMurmur.TestSupport.RuntimeFixture

  defmodule BlockingCycle do
    def run(_configuration, now) do
      test_pid = Process.whereis(:cluster_murmur_event_retention_scheduler_test)
      send(test_pid, {:cycle_started, self(), now})

      receive do
        :release_cycle -> {:ok, %EventRetentionCycle.Result{pruned_marker_count: 37}}
      end
    end
  end

  defmodule FixedClock do
    @behaviour ClusterMurmur.Runtime.Clock
    def utc_now, do: ~U[2026-08-09 06:00:00.000000Z]
  end

  defmodule InvalidClock do
    def utc_now, do: ~U[2026-08-09 06:00:00Z]
  end

  defmodule RetentionFailedCycle do
    def run(_configuration, _now), do: {:error, :event_retention_failed}
  end

  defmodule MalformedCycle do
    def run(_configuration, _now), do: {:ok, :not_a_cycle_result}
  end

  defmodule MalformedResultCycle do
    def run(_configuration, _now) do
      result = %EventRetentionCycle.Result{pruned_marker_count: 1}
      {:ok, Map.put(result, :private, "private cycle data")}
    end
  end

  defmodule RaisingCycle do
    def run(_configuration, _now), do: raise("private cycle failure")
  end

  defmodule ExitingCycle do
    def run(_configuration, _now), do: exit("private cycle failure")
  end

  test "runs one cycle at a time and schedules the next only after completion" do
    Process.register(self(), :cluster_murmur_event_retention_scheduler_test)
    scheduler = start_supervised!({EventRetentionScheduler, options(BlockingCycle, 1_000)})

    assert_receive {:cycle_started, ^scheduler, ~U[2026-08-09 06:00:00.000000Z]}

    send(scheduler, :event_retention_cycle)
    send(scheduler, {:event_retention_cycle, make_ref()})
    refute_receive {:cycle_started, ^scheduler, _now}, 50

    send(scheduler, :release_cycle)

    assert {:ok, %Status{} = status} = EventRetentionScheduler.status(scheduler)
    assert status.cycle_count == 1
    assert status.last_error == nil
    assert status.last_result.pruned_marker_count == 37
    refute inspect(status) =~ "event_policy"
    refute_receive {:cycle_started, ^scheduler, _now}, 100
  end

  test "records storage failures separately from malformed cycles" do
    cases = [
      {RetentionFailedCycle, FixedClock, :retention_failed},
      {BlockingCycle, InvalidClock, :invalid_cycle},
      {MalformedCycle, FixedClock, :invalid_cycle},
      {MalformedResultCycle, FixedClock, :invalid_cycle},
      {RaisingCycle, FixedClock, :invalid_cycle},
      {ExitingCycle, FixedClock, :invalid_cycle}
    ]

    for {cycle, clock, expected_error} <- cases do
      options = %{options(cycle, 1_000) | clock: clock}
      assert {:ok, scheduler} = EventRetentionScheduler.start_link(options)
      assert {:ok, status} = await_cycle(scheduler, 50)
      assert status.cycle_count == 1
      assert status.last_result == nil
      assert status.last_error == expected_error
      refute inspect(status) =~ "private"
      GenServer.stop(scheduler)
    end
  end

  test "rejects malformed dependencies before starting a timer" do
    valid = options(BlockingCycle, 1_000)

    invalid = [
      %{valid | interval_ms: 0},
      %{valid | initial_delay_ms: -1},
      %{valid | cycle: String},
      %{valid | clock: String},
      %{valid | configuration: %{valid.configuration | version: 1.0}},
      Map.put(valid, :private, true),
      nil
    ]

    for candidate <- invalid do
      assert EventRetentionScheduler.start_link(candidate) ==
               {:error, :invalid_event_retention_scheduler}
    end

    refute_receive {:cycle_started, _scheduler, _now}
  end

  defp options(cycle, interval_ms) do
    %Options{
      configuration: RuntimeFixture.configuration(),
      cycle: cycle,
      clock: FixedClock,
      interval_ms: interval_ms,
      initial_delay_ms: 0
    }
  end

  defp await_cycle(_scheduler, 0), do: {:error, :timeout}

  defp await_cycle(scheduler, attempts) do
    case EventRetentionScheduler.status(scheduler) do
      {:ok, %Status{cycle_count: count} = status} when count > 0 ->
        {:ok, status}

      _not_yet ->
        Process.sleep(5)
        await_cycle(scheduler, attempts - 1)
    end
  end
end
