defmodule ClusterMurmur.Runtime.PollStarterCycleTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.StateTracking
  alias ClusterMurmur.Observations.{IngestionPlanner, Observation}
  alias ClusterMurmur.Observers.Client
  alias ClusterMurmur.Runtime.PollStarterCycle
  alias ClusterMurmur.Runtime.PollStarterCycle.Result
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Runtime.PollStarterCycle.Context
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Adapters, SharedInput}

  @executed_at ~U[2026-08-07 02:00:00.000000Z]

  defmodule FakeObserver do
    def list_targets(:process_dictionary) do
      record(:list_targets)
      Process.get({__MODULE__, :targets}, {:ok, []})
    end

    def observe_target(:process_dictionary, target_id) do
      record({:observe_target, target_id})
      Process.get({__MODULE__, :observation})
    end

    defp record(call) do
      Process.put({__MODULE__, :calls}, Process.get({__MODULE__, :calls}, []) ++ [call])
    end
  end

  defmodule FakeIngestionStore do
    def ingest(observation, policy), do: IngestionPlanner.plan(nil, observation, policy)
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
    def weighted_choice(_choices), do: :unused
    def uniform, do: :unused
  end

  setup do
    Process.put({FakeObserver, :calls}, [])
    Process.put({FakeObserver, :targets}, {:ok, [%{id: "example-target"}]})

    Process.put(
      {FakeObserver, :observation},
      {:ok,
       %Observation{
         source: "example-observer",
         subject: "example-target",
         state: :unhealthy,
         observed_at: ~U[2026-08-07 01:59:59.000000Z],
         facts: %{"detail" => "private fact"},
         labels: %{"category" => "monitoring"}
       }}
    )

    :ok
  end

  test "composes one bounded poll with a no-event starter dispatch" do
    configuration = RuntimeFixture.configuration()

    configuration = %{
      configuration
      | state_tracking: %StateTracking{failures_required: 2, successes_required: 2}
    }

    assert {:ok, client} = Client.new(FakeObserver, :process_dictionary)

    assert {:ok, %Result{} = result} =
             PollStarterCycle.run(
               client,
               configuration,
               @executed_at,
               context(configuration),
               FakeIngestionStore
             )

    assert result.target_count == 1
    assert result.ingested_count == 1
    assert result.event_count == 0
    assert result.poll_failure_count == 0
    assert result.match_count == 0
    assert result.dispatched_count == 0
    assert result.skipped_count == 0
    assert result.dispatch_failure_count == 0

    assert Process.get({FakeObserver, :calls}) == [
             :list_targets,
             {:observe_target, "example-target"}
           ]

    refute inspect(result) =~ "example-target"
    refute inspect(result) =~ "private fact"
  end

  test "rejects invalid configuration before observing and collapses observer failures" do
    configuration = RuntimeFixture.configuration()
    assert {:ok, client} = Client.new(FakeObserver, :process_dictionary)
    context = context(configuration)

    assert PollStarterCycle.run(
             client,
             %{configuration | version: 1.0},
             @executed_at,
             context,
             FakeIngestionStore
           ) == {:error, :invalid_poll_starter_cycle}

    assert Process.get({FakeObserver, :calls}) == []

    Process.put({FakeObserver, :targets}, {:error, :unavailable})

    assert PollStarterCycle.run(
             client,
             configuration,
             @executed_at,
             context,
             FakeIngestionStore
           ) == {:error, :poll_failed}

    refute inspect(PollStarterCycle.run(client, nil, @executed_at, context, FakeIngestionStore)) =~
             "private"
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
      adapters: adapters()
    }
  end
end
