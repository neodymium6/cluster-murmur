defmodule ClusterMurmur.Runtime.RecurringScheduleSchedulerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.{RecurringScheduleCycle, RecurringScheduleScheduler}
  alias ClusterMurmur.Runtime.RecurringScheduleScheduler.{Options, Status}
  alias ClusterMurmur.TestSupport.RuntimeFixture

  defmodule BlockingCycle do
    def run(_configuration, now) do
      test_pid = Process.whereis(:cluster_murmur_recurring_schedule_scheduler_test)
      send(test_pid, {:cycle_started, self(), now})

      receive do
        :release_cycle ->
          {:ok,
           %RecurringScheduleCycle.Result{
             due_count: 1,
             executed_count: 1,
             failure_count: 0
           }}
      end
    end
  end

  defmodule FixedClock do
    @behaviour ClusterMurmur.Runtime.Clock
    def utc_now, do: ~U[2026-08-10 14:30:00.000000Z]
  end

  defmodule InvalidClock do
    def utc_now, do: %{~U[2026-08-10 14:30:00.000000Z] | hour: 24}
  end

  defmodule SecondsClock do
    def utc_now, do: ~U[2026-08-10 14:30:00Z]
  end

  defmodule SuccessfulCycle do
    def run(_configuration, _now) do
      {:ok,
       %RecurringScheduleCycle.Result{
         due_count: 1,
         executed_count: 1,
         failure_count: 0
       }}
    end
  end

  defmodule MalformedCycle do
    def run(_configuration, _now), do: {:ok, :not_a_cycle_result}
  end

  defmodule MalformedResultCycle do
    def run(_configuration, _now) do
      result = %RecurringScheduleCycle.Result{
        due_count: 1,
        executed_count: 1,
        failure_count: 0
      }

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
    Process.register(self(), :cluster_murmur_recurring_schedule_scheduler_test)
    scheduler = start_supervised!({RecurringScheduleScheduler, options(BlockingCycle, 1_000)})

    assert_receive {:cycle_started, ^scheduler, ~U[2026-08-10 14:30:00.000000Z]}

    send(scheduler, :recurring_schedule_cycle)
    send(scheduler, {:recurring_schedule_cycle, make_ref()})
    refute_receive {:cycle_started, ^scheduler, _now}, 50

    send(scheduler, :release_cycle)

    assert {:ok, %Status{} = status} = RecurringScheduleScheduler.status(scheduler)
    assert status.cycle_count == 1
    assert status.last_error == nil
    assert status.last_result.executed_count == 1
    refute inspect(status) =~ "triggers"
    refute_receive {:cycle_started, ^scheduler, _now}, 100
  end

  test "records invalid clocks and cycle results as redacted failures" do
    cases = [
      {SuccessfulCycle, InvalidClock},
      {MalformedCycle, FixedClock},
      {MalformedResultCycle, FixedClock},
      {RaisingCycle, FixedClock},
      {ExitingCycle, FixedClock}
    ]

    for {cycle, clock} <- cases do
      options = %{options(cycle, 1_000) | clock: clock}
      assert {:ok, scheduler} = RecurringScheduleScheduler.start_link(options)
      assert {:ok, status} = await_cycle(scheduler, 50)
      assert status.cycle_count == 1
      assert status.last_result == nil
      assert status.last_error == :invalid_cycle
      refute inspect(status) =~ "private"
      GenServer.stop(scheduler)
    end
  end

  test "accepts a canonical second-precision UTC clock" do
    options = %{options(SuccessfulCycle, 1_000) | clock: SecondsClock}
    assert {:ok, scheduler} = RecurringScheduleScheduler.start_link(options)
    assert {:ok, status} = await_cycle(scheduler, 50)
    assert status.last_error == nil
    assert status.last_result.executed_count == 1
    GenServer.stop(scheduler)
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
      assert RecurringScheduleScheduler.start_link(candidate) ==
               {:error, :invalid_recurring_schedule_scheduler}
    end

    refute_receive {:cycle_started, _scheduler, _now}
  end

  test "validates options without starting a scheduler" do
    valid = options(BlockingCycle, 1_000)
    assert RecurringScheduleScheduler.validate(valid) == :ok

    assert RecurringScheduleScheduler.validate(%{valid | interval_ms: 0}) ==
             {:error, :invalid_recurring_schedule_scheduler}

    assert RecurringScheduleScheduler.validate(nil) ==
             {:error, :invalid_recurring_schedule_scheduler}

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
    case RecurringScheduleScheduler.status(scheduler) do
      {:ok, %Status{cycle_count: count} = status} when count > 0 ->
        {:ok, status}

      _not_yet ->
        Process.sleep(5)
        await_cycle(scheduler, attempts - 1)
    end
  end
end
