defmodule ClusterMurmur.Persistence.MessagePublicationTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.Conversations.Conversation
  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Messages.Message

  alias ClusterMurmur.Persistence.{
    ConversationStore,
    EventStore,
    MessageRecord,
    MessageStore
  }

  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    CreateConversations,
    CreateEvents,
    CreateMessages
  }

  @events_version 20_260_804_180_500
  @conversations_version 20_260_805_200_000
  @messages_version 20_260_805_220_000

  setup_all do
    migrate_up(@events_version, CreateEvents)
    migrate_up(@conversations_version, CreateConversations)
    migrate_up(@messages_version, CreateMessages)

    on_exit(fn ->
      migrate_down(@messages_version, CreateMessages)
      migrate_down(@conversations_version, CreateConversations)
      migrate_down(@events_version, CreateEvents)
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM messages", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM conversations", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)
    :ok
  end

  test "records one canonical publication ID without changing message facts" do
    {unpublished, _conversation} = append_message!()

    assert {:ok, published} = MessageStore.record_publication(unpublished, "12345")
    assert published.id == unpublished.id
    assert published.conversation_id == unpublished.conversation_id
    assert published.persona_id == unpublished.persona_id
    assert published.origin == unpublished.origin
    assert published.content == unpublished.content
    assert published.inserted_at == unpublished.inserted_at
    assert published.discord_message_id == "12345"
    assert Repo.aggregate(MessageRecord, :count) == 1
  end

  test "allows only one publication transition" do
    {unpublished, _conversation} = append_message!()
    assert {:ok, published} = MessageStore.record_publication(unpublished, "12345")

    assert MessageStore.record_publication(unpublished, "12345") ==
             {:error, :publication_conflict}

    assert MessageStore.record_publication(unpublished, "67890") ==
             {:error, :publication_conflict}

    Repo.put_dynamic_repo(:missing_publication_repo)

    assert MessageStore.record_publication(published, "67890") ==
             {:error, :publication_conflict}
  end

  test "preserves global publication-ID uniqueness" do
    {first, conversation} = append_message!()

    assert {:ok, {second, _advanced}} =
             MessageStore.append(
               conversation,
               message(content: "A second fact.", inserted_at: ~U[2026-08-05 12:02:00Z])
             )

    assert {:ok, _published} = MessageStore.record_publication(first, "12345")

    assert MessageStore.record_publication(second, "12345") ==
             {:error, :publication_conflict}

    assert Repo.get!(MessageRecord, second.id).discord_message_id == nil
  end

  test "rejects invalid publication IDs before storage" do
    {unpublished, _conversation} = append_message!()
    Repo.put_dynamic_repo(:missing_publication_repo)

    for discord_message_id <- [
          nil,
          12_345,
          "",
          "0",
          "012345",
          "message-1",
          "18446744073709551616"
        ] do
      assert MessageStore.record_publication(unpublished, discord_message_id) ==
               {:error, :invalid_publication_id}
    end
  end

  test "requires an exact loaded message capability before storage" do
    {unpublished, _conversation} = append_message!()
    Repo.put_dynamic_repo(:missing_publication_repo)

    for record <- [
          nil,
          %MessageRecord{},
          Map.put(unpublished, :unexpected_private_value, "private"),
          Ecto.put_meta(unpublished, source: "events"),
          %{unpublished | id: 0}
        ] do
      assert MessageStore.record_publication(record, "12345") ==
               {:error, :invalid_message_record}
    end
  end

  test "rejects stale message capabilities without overwriting durable facts" do
    {unpublished, _conversation} = append_message!()

    assert {1, nil} =
             Repo.update_all(
               from(record in MessageRecord, where: record.id == ^unpublished.id),
               set: [content: "A changed fact."]
             )

    assert MessageStore.record_publication(unpublished, "12345") ==
             {:error, :publication_conflict}

    persisted = Repo.get!(MessageRecord, unpublished.id)
    assert persisted.content == "A changed fact."
    assert persisted.discord_message_id == nil
  end

  test "rejects a valid post-update rewrite and rolls back publication" do
    {unpublished, _conversation} = append_message!()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER rewrite_publication_id
      AFTER UPDATE OF discord_message_id ON messages
      BEGIN
        UPDATE messages
        SET discord_message_id = '67890'
        WHERE id = NEW.id;
      END
      """,
      [],
      log: false
    )

    try do
      assert MessageStore.record_publication(unpublished, "12345") ==
               {:error, :invalid_message_record}

      assert Repo.get!(MessageRecord, unpublished.id) == unpublished
    after
      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER rewrite_publication_id", [], log: false)
    end
  end

  test "returns a generic unavailable error without exposing values" do
    {unpublished, _conversation} = append_message!()
    Repo.put_dynamic_repo(:missing_publication_repo)

    result = MessageStore.record_publication(unpublished, "12345")
    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ unpublished.content
  end

  defp append_message! do
    assert {:ok, _event} = EventStore.insert(event())
    assert {:ok, conversation} = ConversationStore.start(conversation())
    assert {:ok, result} = MessageStore.append(conversation, message([]))
    result
  end

  defp event do
    %Event{
      id: "event-1",
      type: "observation.failed",
      source: "example-observer",
      occurred_at: ~U[2026-08-05 11:59:59.000000Z]
    }
  end

  defp conversation do
    %Conversation{
      id: "conversation-1",
      root_event_id: "event-1",
      status: :starting,
      started_at: ~U[2026-08-05 12:00:00Z],
      last_message_at: nil,
      turn_count: 0,
      llm_call_count: 0,
      participants: [],
      messages: []
    }
  end

  defp message(overrides) do
    struct!(
      Message,
      Keyword.merge(
        [
          conversation_id: "conversation-1",
          persona_id: "observer",
          origin: :llm,
          content: "A bounded fact.",
          discord_message_id: nil,
          inserted_at: ~U[2026-08-05 12:01:00Z]
        ],
        overrides
      )
    )
  end

  defp migrate_up(version, migration) do
    assert Ecto.Migrator.up(Repo, version, migration,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok
  end

  defp migrate_down(version, migration) do
    assert Ecto.Migrator.down(Repo, version, migration,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok
  end
end
