defmodule ClusterMurmur.Runtime.EventDispatchSchedulerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.EventDispatchScheduler
  alias ClusterMurmur.Runtime.EventDispatchCycle.{Adapters, Context, Result}
  alias ClusterMurmur.Runtime.EventDispatchScheduler.{Options, Status}
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.SharedInput

  defmodule BlockingCycle do
    def run(configuration, now, context, adapters) do
      test_pid = Process.whereis(:cluster_murmur_event_dispatch_scheduler_test)
      send(test_pid, {:cycle_started, self(), configuration, now, context, adapters})

      receive do
        :release_cycle ->
          {:ok,
           %Result{
             candidate_count: 1,
             claimed_count: 1,
             completed_count: 1,
             candidate_failure_count: 0,
             planned_match_count: 1,
             attempted_match_count: 1,
             dispatched_count: 1,
             skipped_count: 0,
             dispatch_failure_count: 0
           }}
      end
    end
  end

  defmodule FixedClock do
    @behaviour ClusterMurmur.Runtime.Clock
    def utc_now, do: ~U[2026-08-08 18:00:00.000000Z]
  end

  defmodule InvalidClock do
    def utc_now, do: ~U[2026-08-08 18:00:00Z]
  end

  defmodule DispatchFailedCycle do
    def run(_configuration, _now, _context, _adapters),
      do: {:error, :event_dispatch_failed}
  end

  defmodule MalformedCycle do
    def run(_configuration, _now, _context, _adapters), do: {:ok, :not_a_result}
  end

  defmodule MalformedResultCycle do
    def run(_configuration, _now, _context, _adapters) do
      {:ok,
       %Result{
         candidate_count: 0,
         claimed_count: 0,
         completed_count: 0,
         candidate_failure_count: 0,
         planned_match_count: 1,
         attempted_match_count: 1,
         dispatched_count: 1,
         skipped_count: 0,
         dispatch_failure_count: 0
       }}
    end
  end

  defmodule UnattemptedResultCycle do
    def run(_configuration, _now, _context, _adapters) do
      {:ok,
       %Result{
         candidate_count: 1,
         claimed_count: 1,
         completed_count: 1,
         candidate_failure_count: 0,
         planned_match_count: 1,
         attempted_match_count: 0,
         dispatched_count: 0,
         skipped_count: 0,
         dispatch_failure_count: 0
       }}
    end
  end

  defmodule CompletedFailureResultCycle do
    def run(_configuration, _now, _context, _adapters) do
      {:ok,
       %Result{
         candidate_count: 2,
         claimed_count: 1,
         completed_count: 1,
         candidate_failure_count: 1,
         planned_match_count: 1,
         attempted_match_count: 1,
         dispatched_count: 0,
         skipped_count: 0,
         dispatch_failure_count: 1
       }}
    end
  end

  defmodule RaisingCycle do
    def run(_configuration, _now, _context, _adapters),
      do: raise("private event dispatch failure")
  end

  defmodule CycleAdapters do
    def list_available(_now), do: {:ok, []}
    def claim(_candidate, _now), do: :unused
    def complete(_claim, _now), do: :unused
    def fetch(_event_id), do: :unused
    def authorize(_trigger, _event, _now, _event_policy), do: :unused

    def consume(_plan), do: :unused
    def generate(_request, _settings, _transport), do: :unused
    def append(_message, _conversation), do: :unused
    def start(_message_id, _conversation_id, _persona_id, _started_at, _request_id), do: :unused
    def publish(_started, _settings, _completed_at, _transport, _publisher, _store), do: :unused
    def succeed(_id, _message_id, _completed_at, _external_id), do: :unused
    def fail(_id, _completed_at, _reason), do: :unused
    def mark_ambiguous(_id, _completed_at), do: :unused
    def record_spoken(_persona_id, _spoken_at, _cooldown_until), do: :unused
    def wait(_conversation), do: :unused
    def weighted_choice(_choices), do: :unused
    def uniform, do: :unused
  end

  test "runs one cycle at a time and schedules the next only after completion" do
    Process.register(self(), :cluster_murmur_event_dispatch_scheduler_test)
    options = options(BlockingCycle, FixedClock, 1_000)
    scheduler = start_supervised!({EventDispatchScheduler, options})

    assert_receive {:cycle_started, ^scheduler, configuration, ~U[2026-08-08 18:00:00.000000Z],
                    context, adapters}

    assert configuration === options.configuration
    assert context === options.cycle_context
    assert adapters === options.cycle_adapters

    send(scheduler, :event_dispatch_cycle)
    send(scheduler, {:event_dispatch_cycle, make_ref()})
    refute_receive {:cycle_started, ^scheduler, _configuration, _now, _context, _adapters}, 50

    send(scheduler, :release_cycle)

    assert {:ok, %Status{} = status} = EventDispatchScheduler.status(scheduler)
    assert status.cycle_count == 1
    assert status.last_error == nil
    assert status.last_result.dispatched_count == 1
    refute inspect(status) =~ "clearly-fake-api-key"
    refute inspect(options) =~ "clearly-fake-api-key"
    refute_receive {:cycle_started, ^scheduler, _configuration, _now, _context, _adapters}, 100
  end

  test "records bounded dispatch failures separately from invalid cycles" do
    for {cycle, clock, expected_error} <- [
          {DispatchFailedCycle, FixedClock, :dispatch_failed},
          {MalformedCycle, FixedClock, :invalid_cycle},
          {MalformedResultCycle, FixedClock, :invalid_cycle},
          {UnattemptedResultCycle, FixedClock, :invalid_cycle},
          {CompletedFailureResultCycle, FixedClock, :invalid_cycle},
          {RaisingCycle, FixedClock, :invalid_cycle},
          {BlockingCycle, InvalidClock, :invalid_cycle}
        ] do
      assert {:ok, scheduler} = EventDispatchScheduler.start_link(options(cycle, clock, 1_000))
      assert {:ok, status} = await_cycle(scheduler, 50)
      assert status.cycle_count == 1
      assert status.last_result == nil
      assert status.last_error == expected_error
      refute inspect(status) =~ "private event dispatch failure"
      GenServer.stop(scheduler)
    end
  end

  test "rejects malformed dependencies before starting a timer" do
    valid = options(BlockingCycle, FixedClock, 1_000)

    invalid = [
      %{valid | interval_ms: 0},
      %{valid | cycle: String},
      %{valid | clock: String},
      %{valid | cycle_adapters: %{valid.cycle_adapters | events: String}},
      %{valid | configuration: %{valid.configuration | version: 1.0}},
      %{valid | cycle_context: %{valid.cycle_context | shared_input: nil}},
      Map.put(valid, :private, true)
    ]

    for options <- invalid do
      assert EventDispatchScheduler.start_link(options) ==
               {:error, :invalid_event_dispatch_scheduler}
    end

    refute_receive {:cycle_started, _scheduler, _configuration, _now, _context, _adapters}
  end

  defp options(cycle, clock, interval_ms) do
    configuration = RuntimeFixture.configuration()

    %Options{
      configuration: configuration,
      cycle_context: context(configuration),
      cycle_adapters: %Adapters{
        dispatches: CycleAdapters,
        events: CycleAdapters,
        authorizer: CycleAdapters
      },
      cycle: cycle,
      clock: clock,
      interval_ms: interval_ms,
      initial_delay_ms: 0
    }
  end

  defp context(configuration) do
    %Context{
      shared_input: %SharedInput{
        configuration: configuration,
        cooldowns: %{},
        provider_settings: RuntimeFixture.provider_settings(),
        webhook_settings: RuntimeFixture.webhook_settings(),
        generation_transport: fn _request -> :unused end,
        publication_transport: fn _request -> :unused end
      },
      adapters: %AuthorizedStarterPipeline.Adapters{
        conversation_action_store: CycleAdapters,
        provider: CycleAdapters,
        message_store: CycleAdapters,
        publication_start_store: CycleAdapters,
        publisher: CycleAdapters,
        publication_terminal_store: CycleAdapters,
        cooldown_store: CycleAdapters,
        conversation_store: CycleAdapters,
        starter_random: CycleAdapters,
        reply_random: CycleAdapters
      }
    }
  end

  defp await_cycle(_scheduler, 0), do: {:error, :timeout}

  defp await_cycle(scheduler, attempts) do
    case EventDispatchScheduler.status(scheduler) do
      {:ok, %Status{cycle_count: count} = status} when count > 0 ->
        {:ok, status}

      _not_yet ->
        Process.sleep(5)
        await_cycle(scheduler, attempts - 1)
    end
  end
end
