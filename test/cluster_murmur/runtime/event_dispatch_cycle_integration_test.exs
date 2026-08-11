defmodule ClusterMurmur.Runtime.EventDispatchCycleIntegrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Persistence.{EventDispatch, EventDispatchStore, EventStore}
  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.{CreateEventDispatches, CreateEvents}
  alias ClusterMurmur.Runtime.EventDispatchCycle
  alias ClusterMurmur.Runtime.EventDispatchCycle.Context
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.SharedInput

  @event_version 20_260_804_180_500
  @dispatch_version 20_260_808_150_000
  @enqueued_at ~U[2026-08-08 17:30:00Z]

  defmodule PipelineAdapters do
    def consume(_plan), do: :unused
    def generate(_request, _settings, _transport), do: :unused
    def append(_message, _conversation), do: :unused
    def start(_message_id, _conversation_id, _persona_id, _started_at, _request_id), do: :unused
    def publish(_started, _settings, _completed_at, _transport, _publisher, _store), do: :unused
    def succeed(_id, _message_id, _completed_at, _external_id), do: :unused
    def fail(_id, _completed_at, _reason), do: :unused
    def mark_ambiguous(_id, _completed_at), do: :unused
    def fetch(_persona_id), do: {:ok, nil}
    def record_spoken(_persona_id, _spoken_at, _cooldown_until), do: :unused
    def complete(_conversation_id, _completed_at), do: :unused
    def wait(_conversation), do: :unused
    def weighted_choice(_choices), do: :unused
    def uniform, do: :unused
  end

  setup_all do
    migrations = [
      {@event_version, CreateEvents},
      {@dispatch_version, CreateEventDispatches}
    ]

    for {version, migration} <- migrations do
      assert Ecto.Migrator.up(Repo, version, migration,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok
    end

    on_exit(fn ->
      for {version, migration} <- Enum.reverse(migrations) do
        Ecto.Migrator.down(Repo, version, migration,
          log: false,
          log_migrations_sql: false,
          log_migrator_sql: false
        )
      end
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM event_dispatches", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)
    :ok
  end

  test "completes one unmatched outbox row through the real stores" do
    configuration = RuntimeFixture.configuration()

    event =
      RuntimeFixture.event(
        id: "event-a",
        type: "observation.recovered",
        occurred_at: DateTime.add(@enqueued_at, -1, :second)
      )

    assert {:ok, _record} = EventStore.insert(event)
    assert {:ok, _receipt} = EventDispatchStore.enqueue(event, @enqueued_at)

    assert {:ok, result} =
             EventDispatchCycle.run(
               configuration,
               DateTime.add(@enqueued_at, 1, :second),
               context(configuration)
             )

    assert result.candidate_count == 1
    assert result.claimed_count == 1
    assert result.completed_count == 1
    assert result.candidate_failure_count == 0
    assert result.planned_match_count == 0

    dispatch = Repo.get!(EventDispatch, event.id)
    assert dispatch.status == :completed
    assert dispatch.completed_at == ~U[2026-08-08 17:30:01.000000Z]
    assert dispatch.claim_token == nil
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
        conversation_action_store: PipelineAdapters,
        provider: PipelineAdapters,
        message_store: PipelineAdapters,
        publication_start_store: PipelineAdapters,
        publisher: PipelineAdapters,
        publication_terminal_store: PipelineAdapters,
        cooldown_store: PipelineAdapters,
        conversation_store: PipelineAdapters,
        starter_random: PipelineAdapters,
        reply_random: PipelineAdapters
      }
    }
  end
end
