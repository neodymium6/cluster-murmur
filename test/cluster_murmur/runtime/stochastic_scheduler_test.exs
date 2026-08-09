defmodule ClusterMurmur.Runtime.StochasticSchedulerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.{StochasticCycle, StochasticScheduler}
  alias ClusterMurmur.Runtime.StochasticScheduler.{Options, Status}
  alias ClusterMurmur.TestSupport.RuntimeFixture

  defmodule BlockingCycle do
    def run(_configuration, now, random) do
      test_pid = Process.whereis(:cluster_murmur_stochastic_scheduler_test)
      send(test_pid, {:cycle_started, self(), now, random})

      receive do
        :release_cycle ->
          {:ok,
           %StochasticCycle.Result{
             due_count: 1,
             executed_count: 1,
             skipped_count: 0,
             failure_count: 0
           }}
      end
    end
  end

  defmodule FixedClock do
    @behaviour ClusterMurmur.Runtime.Clock
    def utc_now, do: ~U[2026-08-08 14:30:00.000000Z]
  end

  defmodule InvalidClock do
    def utc_now, do: ~U[2026-08-08 14:30:00Z]
  end

  defmodule MalformedCycle do
    def run(_configuration, _now, _random), do: {:ok, :not_a_cycle_result}
  end

  defmodule MalformedResultCycle do
    def run(_configuration, _now, _random) do
      result = %StochasticCycle.Result{
        due_count: 1,
        executed_count: 1,
        skipped_count: 0,
        failure_count: 0
      }

      {:ok, Map.put(result, :private, "private cycle data")}
    end
  end

  defmodule RaisingCycle do
    def run(_configuration, _now, _random), do: raise("private cycle failure")
  end

  defmodule Random do
    def uniform, do: 0.5
  end

  test "runs one cycle at a time and schedules the next only after completion" do
    Process.register(self(), :cluster_murmur_stochastic_scheduler_test)
    options = options(self(), 1_000)
    scheduler = start_supervised!({StochasticScheduler, options})

    assert_receive {:cycle_started, ^scheduler, ~U[2026-08-08 14:30:00.000000Z], Random}

    send(scheduler, :stochastic_cycle)
    send(scheduler, {:stochastic_cycle, make_ref()})
    refute_receive {:cycle_started, ^scheduler, _now, Random}, 50

    send(scheduler, :release_cycle)

    assert {:ok, %Status{} = status} = StochasticScheduler.status(scheduler)
    assert status.cycle_count == 1
    assert status.last_error == nil
    assert status.last_result.executed_count == 1
    refute inspect(status) =~ "source_path"
    refute_receive {:cycle_started, ^scheduler, _now, Random}, 100
  end

  test "records invalid clocks and cycle results as redacted failures" do
    invalid_options = [
      %{options(self(), 1_000) | clock: InvalidClock},
      %{options(self(), 1_000) | cycle: MalformedCycle},
      %{options(self(), 1_000) | cycle: MalformedResultCycle},
      %{options(self(), 1_000) | cycle: RaisingCycle}
    ]

    for options <- invalid_options do
      assert {:ok, scheduler} = StochasticScheduler.start_link(options)
      assert {:ok, status} = await_cycle(scheduler, 50)
      assert status.cycle_count == 1
      assert status.last_result == nil
      assert status.last_error == :invalid_cycle
      refute inspect(status) =~ "private cycle failure"
      GenServer.stop(scheduler)
    end
  end

  test "rejects malformed dependencies before starting a timer" do
    valid = options(self(), 1_000)

    invalid = [
      %{valid | interval_ms: 0},
      %{valid | cycle: String},
      %{valid | clock: String},
      %{valid | random: String},
      %{valid | configuration: %{valid.configuration | version: 1.0}},
      Map.put(valid, :private, true)
    ]

    for options <- invalid do
      assert StochasticScheduler.start_link(options) ==
               {:error, :invalid_stochastic_scheduler}
    end

    refute_receive {:cycle_started, _scheduler, _now, _random}
  end

  defp options(_test_pid, interval_ms) do
    %Options{
      configuration: RuntimeFixture.configuration(),
      cycle: BlockingCycle,
      clock: FixedClock,
      random: Random,
      interval_ms: interval_ms,
      initial_delay_ms: 0
    }
  end

  defp await_cycle(_scheduler, 0), do: {:error, :timeout}

  defp await_cycle(scheduler, attempts) do
    case StochasticScheduler.status(scheduler) do
      {:ok, %Status{cycle_count: count} = status} when count > 0 ->
        {:ok, status}

      _not_yet ->
        Process.sleep(5)
        await_cycle(scheduler, attempts - 1)
    end
  end
end
