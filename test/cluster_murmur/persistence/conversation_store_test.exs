defmodule ClusterMurmur.Persistence.ConversationStoreTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Conversations.Conversation
  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Persistence.{ConversationRecord, ConversationStore, EventStore}
  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.{CreateConversations, CreateEvents}

  @events_version 20_260_804_180_500
  @conversations_version 20_260_805_200_000

  setup_all do
    assert Ecto.Migrator.up(Repo, @events_version, CreateEvents,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    assert Ecto.Migrator.up(Repo, @conversations_version, CreateConversations,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @conversations_version, CreateConversations,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )

      Ecto.Migrator.down(Repo, @events_version, CreateEvents,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM conversations", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)
    :ok
  end

  test "atomically starts one conversation for its committed event" do
    assert {:ok, _event_record} = EventStore.insert(event())
    conversation = conversation()

    assert {:ok, %ConversationRecord{} = record} = ConversationStore.start(conversation)
    assert record.id == conversation.id
    assert record.root_event_id == conversation.root_event_id
    assert record.status == :starting
    assert record.turn_count == 0
    assert record.llm_call_count == 0
    assert DateTime.compare(record.started_at, conversation.started_at) == :eq
    assert record.started_at.microsecond == {0, 6}
    assert record.completed_at == nil
    assert Repo.aggregate(ConversationRecord, :count) == 1

    inspected = inspect(record)
    refute inspected =~ conversation.id
    refute inspected =~ conversation.root_event_id
    refute inspected =~ "2026"
  end

  test "requires a validated committed root event" do
    assert ConversationStore.start(conversation()) == {:error, :event_not_found}
    assert Repo.aggregate(ConversationRecord, :count) == 0
  end

  test "rejects every retry of a committed conversation ID" do
    assert {:ok, _event_record} = EventStore.insert(event())
    assert {:ok, first} = ConversationStore.start(conversation())

    assert ConversationStore.start(conversation()) == {:error, :conversation_conflict}
    assert Repo.get!(ConversationRecord, first.id) == first
    assert Repo.aggregate(ConversationRecord, :count) == 1
  end

  test "rejects invalid inputs before accessing storage" do
    valid = conversation()
    Repo.put_dynamic_repo(:missing_conversation_repo)

    for rejected <- [
          nil,
          Map.put(valid, :unexpected_private_value, "private"),
          %{valid | id: "invalid id"},
          %{valid | status: :generating},
          %{valid | turn_count: 1},
          %{valid | participants: ["observer"]}
        ] do
      assert ConversationStore.start(rejected) == {:error, :invalid_conversation}
    end
  end

  test "returns a generic error for unavailable storage without exposing values" do
    Repo.put_dynamic_repo(:missing_conversation_repo)

    result =
      ConversationStore.start(
        conversation(id: "private-conversation", root_event_id: "private-event")
      )

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
  end

  defp event do
    %Event{
      id: "event-1",
      type: "observation.failed",
      source: "example-observer",
      occurred_at: ~U[2026-08-05 11:59:59.000000Z]
    }
  end

  defp conversation(overrides \\ []) do
    struct!(
      Conversation,
      Keyword.merge(
        [
          id: "conversation-1",
          root_event_id: "event-1",
          status: :starting,
          started_at: ~U[2026-08-05 12:00:00Z],
          last_message_at: nil,
          turn_count: 0,
          llm_call_count: 0,
          participants: [],
          messages: []
        ],
        overrides
      )
    )
  end
end
