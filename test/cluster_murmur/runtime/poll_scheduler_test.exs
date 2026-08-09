defmodule ClusterMurmur.Runtime.PollSchedulerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.StateTracking
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Observations.{IngestionPlanner, Observation}
  alias ClusterMurmur.Observers.Client
  alias ClusterMurmur.Runtime.{PollScheduler, PollStarterCycle}
  alias ClusterMurmur.Runtime.PollScheduler.{Options, Status}
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Adapters, SharedInput}

  @receive_timeout 5_000

  defmodule BlockingObserver do
    def list_targets(test_pid), do: {:ok, [%{id: observer_target(test_pid)}]}

    def observe_target(test_pid, "example-target") do
      send(test_pid, {:cycle_started, self()})

      receive do
        :release_cycle ->
          {:ok,
           %Observation{
             source: "example-observer",
             subject: "example-target",
             state: :unhealthy,
             observed_at: ~U[2026-08-07 01:59:59.000000Z],
             facts: %{"detail" => "private fact"},
             labels: %{"category" => "monitoring"}
           }}
      end
    end

    defp observer_target(test_pid) do
      send(test_pid, :listed_targets)
      "example-target"
    end
  end

  defmodule FakeIngestionStore do
    def ingest(observation, policy), do: IngestionPlanner.plan(nil, observation, policy)
  end

  defmodule FixedClock do
    @behaviour ClusterMurmur.Runtime.Clock
    def utc_now, do: ~U[2026-08-07 02:00:00.000000Z]
  end

  defmodule AdaptersStub do
    def consume(_plan), do: :unused
    def generate(_request, _settings, _transport), do: :unused
    def append(_message, _conversation), do: :unused
    def start(_message_id, _conversation_id, _persona_id, _started_at, _request_id), do: :unused
    def publish(_started, _settings, _completed_at, _transport, _publisher, _store), do: :unused
    def succeed(_id, _message_id, _completed_at, _external_id), do: :unused
    def fail(_id, _completed_at, _reason), do: :unused
    def mark_ambiguous(_id, _completed_at), do: :unused
    def record_spoken(_persona_id, _spoken_at, _cooldown_until), do: :unused
    def complete(_conversation_id, _completed_at), do: :unused
    def wait(_conversation), do: :unused
    def weighted_choice(_choices), do: :unused
    def uniform, do: :unused
  end

  test "runs one cycle at a time and schedules the next only after completion" do
    scheduler_delay_ms = DomainLimits.max_interval_ms()

    options =
      self()
      |> options(scheduler_delay_ms)
      |> Map.put(:initial_delay_ms, scheduler_delay_ms)

    scheduler = start_supervised!({PollScheduler, options})

    assert {^options, %Status{cycle_count: 0}, initial_timer_token} = :sys.get_state(scheduler)
    assert is_reference(initial_timer_token)

    send(scheduler, {:poll, initial_timer_token})

    assert_receive :listed_targets, @receive_timeout
    assert_receive {:cycle_started, ^scheduler}, @receive_timeout

    send(scheduler, :poll)
    send(scheduler, {:poll, make_ref()})
    send(scheduler, {:poll, make_ref()})

    refute_received {:cycle_started, ^scheduler}

    send(scheduler, :release_cycle)

    assert {:ok, %Status{} = status} = PollScheduler.status(scheduler)
    assert status.cycle_count == 1
    assert status.last_error == nil
    assert status.last_result.event_count == 0
    refute inspect(status) =~ "private fact"
    refute_received {:cycle_started, ^scheduler}

    send(scheduler, :poll)
    send(scheduler, {:poll, make_ref()})

    assert {:ok, ^status} = PollScheduler.status(scheduler)
    refute_received {:cycle_started, ^scheduler}

    assert {^options, ^status, next_timer_token} = :sys.get_state(scheduler)
    assert is_reference(next_timer_token)

    send(scheduler, {:poll, next_timer_token})

    assert_receive :listed_targets, @receive_timeout
    assert_receive {:cycle_started, ^scheduler}, @receive_timeout

    send(scheduler, :release_cycle)

    assert {:ok, %Status{cycle_count: 2, last_error: nil}} = PollScheduler.status(scheduler)
  end

  test "rejects malformed dependencies before starting observation" do
    valid = options(self(), 1_000)

    invalid = [
      %{valid | interval_ms: 0},
      %{valid | clock: String},
      %{valid | configuration: %{valid.configuration | version: 1.0}},
      Map.put(valid, :private, true)
    ]

    for options <- invalid do
      assert PollScheduler.start_link(options) == {:error, :invalid_poll_scheduler}
    end

    refute_receive :listed_targets
  end

  defp options(test_pid, interval_ms) do
    configuration =
      RuntimeFixture.configuration()
      |> Map.put(
        :state_tracking,
        %StateTracking{failures_required: 2, successes_required: 2}
      )

    {:ok, observer_client} = Client.new(BlockingObserver, test_pid)

    %Options{
      observer_client: observer_client,
      configuration: configuration,
      cycle_context: cycle_context(configuration),
      ingestion_store: FakeIngestionStore,
      clock: FixedClock,
      interval_ms: interval_ms,
      initial_delay_ms: 0
    }
  end

  defp cycle_context(configuration) do
    %PollStarterCycle.Context{
      shared_input: %SharedInput{
        configuration: configuration,
        cooldowns: %{},
        provider_settings: RuntimeFixture.provider_settings(),
        webhook_settings: RuntimeFixture.webhook_settings(),
        generation_transport: fn _request -> :unused end,
        publication_transport: fn _request -> :unused end
      },
      adapters: adapters()
    }
  end

  defp adapters do
    %Adapters{
      conversation_action_store: AdaptersStub,
      provider: AdaptersStub,
      message_store: AdaptersStub,
      publication_start_store: AdaptersStub,
      publisher: AdaptersStub,
      publication_terminal_store: AdaptersStub,
      cooldown_store: AdaptersStub,
      conversation_store: AdaptersStub,
      starter_random: AdaptersStub,
      reply_random: AdaptersStub
    }
  end
end
