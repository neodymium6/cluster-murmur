defmodule ClusterMurmur.Persistence.PublicationAttemptMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    EventRecord,
    MessageRecord,
    PublicationAttemptRecord
  }

  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    AddPublicationAttemptDispatching,
    CreateConversations,
    CreateEvents,
    CreateMessages,
    CreatePublicationAttempts
  }

  @event_version 20_260_804_180_500
  @conversation_version 20_260_805_200_000
  @message_version 20_260_805_220_000
  @attempt_version 20_260_805_230_000
  @dispatching_version 20_260_805_231_000

  setup_all do
    for {version, migration} <- [
          {@event_version, CreateEvents},
          {@conversation_version, CreateConversations},
          {@message_version, CreateMessages},
          {@attempt_version, CreatePublicationAttempts},
          {@dispatching_version, AddPublicationAttemptDispatching}
        ] do
      assert Ecto.Migrator.up(Repo, version, migration,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok
    end

    on_exit(fn ->
      for {version, migration} <- [
            {@dispatching_version, AddPublicationAttemptDispatching},
            {@attempt_version, CreatePublicationAttempts},
            {@message_version, CreateMessages},
            {@conversation_version, CreateConversations},
            {@event_version, CreateEvents}
          ] do
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
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM publication_attempts", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM messages", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM conversations", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)

    Repo.insert!(%EventRecord{
      id: "event-1",
      type: "observation.failed",
      source: "example-observer",
      facts: "{}",
      labels: "{}",
      occurred_at: ~U[2026-08-05 12:00:00.000000Z],
      inserted_at: ~U[2026-08-05 12:00:00.000000Z]
    })

    Repo.insert!(%ConversationRecord{
      id: "conversation-1",
      root_event_id: "event-1",
      status: :generating,
      turn_count: 1,
      llm_call_count: 1,
      started_at: ~U[2026-08-05 12:00:00.000000Z]
    })

    message =
      Repo.insert!(%MessageRecord{
        conversation_id: "conversation-1",
        persona_id: "observer",
        origin: :llm,
        content: "A bounded confirmed fact.",
        inserted_at: ~U[2026-08-05 12:01:00.000000Z]
      })

    {:ok, message: message}
  end

  test "persists one attempt for each message", %{message: message} do
    assert {:ok, attempt} = Repo.insert(started(message.id))
    assert attempt.status == :started

    assert_raise Ecto.ConstraintError, fn -> Repo.insert!(started(message.id)) end

    Repo.delete_all(PublicationAttemptRecord)

    assert_raise Exqlite.Error, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO publication_attempts
          (message_id, status, started_at, completed_at, error_class)
        VALUES
          (NULL, 'started', '2026-08-05T12:02:00.000000Z', NULL, NULL)
        """,
        [],
        log: false
      )
    end
  end

  test "accepts only correlated terminal lifecycle shapes", %{message: message} do
    terminal = ~U[2026-08-05 12:03:00.000000Z]

    valid = [
      %{started(message.id) | status: :dispatching},
      %{started(message.id) | status: :succeeded, completed_at: terminal},
      %{started(message.id) | status: :failed, completed_at: terminal, error_class: :timeout},
      %{
        started(message.id)
        | status: :ambiguous,
          completed_at: terminal,
          error_class: :interrupted
      }
    ]

    for attempt <- valid do
      assert {:ok, _record} = Repo.insert(attempt)
      Repo.delete_all(PublicationAttemptRecord)
    end

    invalid = [
      %{started(message.id) | status: :started, completed_at: terminal},
      %{started(message.id) | status: :dispatching, completed_at: terminal},
      %{started(message.id) | status: :succeeded, completed_at: terminal, error_class: :timeout},
      %{started(message.id) | status: :failed, completed_at: terminal},
      %{
        started(message.id)
        | status: :failed,
          completed_at: terminal,
          error_class: :interrupted
      },
      %{started(message.id) | status: :ambiguous, completed_at: terminal, error_class: :timeout},
      %{
        started(message.id)
        | status: :failed,
          completed_at: ~U[2026-08-05 12:01:59.999999Z],
          error_class: :timeout
      }
    ]

    for attempt <- invalid do
      assert_raise Ecto.ConstraintError, fn -> Repo.insert!(attempt) end
    end
  end

  test "downgrade conservatively converts a dispatch claim to ambiguous", %{message: message} do
    assert {:ok, dispatching} = Repo.insert(%{started(message.id) | status: :dispatching})

    assert Ecto.Migrator.down(Repo, @dispatching_version, AddPublicationAttemptDispatching,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    try do
      assert %{rows: [["ambiguous", completed_at, "interrupted"]]} =
               Ecto.Adapters.SQL.query!(
                 Repo,
                 "SELECT status, completed_at, error_class FROM publication_attempts",
                 [],
                 log: false
               )

      assert completed_at == DateTime.to_iso8601(dispatching.started_at)
    after
      assert Ecto.Migrator.up(Repo, @dispatching_version, AddPublicationAttemptDispatching,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok
    end

    assert Repo.get!(PublicationAttemptRecord, message.id).status == :ambiguous
  end

  defp started(message_id) do
    %PublicationAttemptRecord{
      message_id: message_id,
      status: :started,
      started_at: ~U[2026-08-05 12:02:00.000000Z]
    }
  end
end
