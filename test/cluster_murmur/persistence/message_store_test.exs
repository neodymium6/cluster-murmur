defmodule ClusterMurmur.Persistence.MessageStoreTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.Conversations.Conversation
  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Messages.Message

  alias ClusterMurmur.Persistence.{
    ConversationRecord,
    ConversationStore,
    EventStore,
    MessageRecord,
    MessageStore
  }

  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    CreateConversations,
    CreateEvents,
    CreateMessages,
    CreateResponderGenerationClaims
  }

  @events_version 20_260_804_180_500
  @conversations_version 20_260_805_200_000
  @messages_version 20_260_805_220_000
  @responder_claims_version 20_260_808_060_000
  @max_safe_integer 9_007_199_254_740_991

  setup_all do
    migrate_up(@events_version, CreateEvents)
    migrate_up(@conversations_version, CreateConversations)
    migrate_up(@messages_version, CreateMessages)
    migrate_up(@responder_claims_version, CreateResponderGenerationClaims)

    on_exit(fn ->
      migrate_down(@responder_claims_version, CreateResponderGenerationClaims)
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

  test "atomically appends an unpublished message and advances conversation counters" do
    conversation = start_conversation!()
    message = message([])

    assert {:ok, {%MessageRecord{} = stored, %ConversationRecord{} = advanced}} =
             MessageStore.append(conversation, message)

    assert stored.id > 0
    assert stored.conversation_id == conversation.id
    assert stored.persona_id == message.persona_id
    assert stored.origin == :llm
    assert stored.content == message.content
    assert stored.discord_message_id == nil
    assert stored.inserted_at.microsecond == {0, 6}
    assert advanced.status == conversation.status
    assert advanced.turn_count == 1
    assert advanced.llm_call_count == 1
    assert Repo.aggregate(MessageRecord, :count) == 1
  end

  test "counts fallback messages as both a turn and an LLM call" do
    conversation = start_conversation!()

    assert {:ok, {_first, conversation}} = MessageStore.append(conversation, message([]))

    assert {:ok, {fallback, advanced}} =
             MessageStore.append(
               conversation,
               message(origin: :fallback, inserted_at: ~U[2026-08-05 12:02:00Z])
             )

    assert fallback.origin == :fallback
    assert advanced.turn_count == 2
    assert advanced.llm_call_count == 2
  end

  test "appends a reserved generation without counting its LLM call twice" do
    started = start_conversation!()
    assert {:ok, waiting} = ConversationStore.wait(started)
    assert {:ok, reserved} = ConversationStore.claim_generation(waiting, "caretaker")
    assert ConversationStore.consume_generation(reserved, "caretaker") == :ok

    assert reserved.status == :generating
    assert reserved.turn_count == 0
    assert reserved.llm_call_count == 1

    assert {:ok, {stored, advanced}} = MessageStore.append_reserved(reserved, message([]))
    assert stored.content == "A bounded fact."
    assert advanced.status == :generating
    assert advanced.turn_count == 1
    assert advanced.llm_call_count == 1
    assert {:ok, waiting_again} = ConversationStore.wait(advanced)
    assert waiting_again.status == :waiting

    assert MessageStore.append_reserved(
             reserved,
             message(content: "A replay.", inserted_at: ~U[2026-08-05 12:02:00Z])
           ) == {:error, :conversation_conflict}

    assert Repo.aggregate(MessageRecord, :count) == 1
  end

  test "rejects invalid, published, mismatched, and predating messages before storage" do
    conversation = start_conversation!()
    valid = message([])
    Repo.put_dynamic_repo(:missing_message_repo)

    for rejected <- [
          nil,
          Map.put(valid, :unexpected_private_value, "private"),
          %{valid | content: "hidden\tcontrol"},
          %{valid | discord_message_id: "12345"},
          %{valid | conversation_id: "another-conversation"},
          %{valid | inserted_at: ~U[2026-08-05 11:59:59.999999Z]}
        ] do
      assert MessageStore.append(conversation, rejected) == {:error, :invalid_message}
    end
  end

  test "requires an exact loaded active conversation before storage" do
    conversation = start_conversation!()

    invalid = [
      nil,
      %ConversationRecord{},
      Map.put(conversation, :unexpected_private_value, "private"),
      Ecto.put_meta(conversation, source: "events"),
      %{conversation | completed_at: ~U[2026-08-05 12:01:00.000000Z]}
    ]

    Repo.put_dynamic_repo(:missing_message_repo)

    for rejected <- invalid do
      assert MessageStore.append(rejected, message([])) ==
               {:error, :invalid_conversation_record}
    end
  end

  test "rejects stale conversation capabilities and rolls back the message" do
    conversation = start_conversation!()
    assert {:ok, {_stored, advanced}} = MessageStore.append(conversation, message([]))

    assert MessageStore.append(
             conversation,
             message(content: "A stale retry.", inserted_at: ~U[2026-08-05 12:02:00Z])
           ) == {:error, :conversation_conflict}

    assert Repo.aggregate(MessageRecord, :count) == 1
    assert Repo.get!(ConversationRecord, conversation.id) == advanced
  end

  test "rejects messages older than committed history without changing counters" do
    conversation = start_conversation!()

    assert {:ok, {_stored, advanced}} =
             MessageStore.append(
               conversation,
               message(inserted_at: ~U[2026-08-05 12:02:00Z])
             )

    assert MessageStore.append(
             advanced,
             message(content: "An older fact.", inserted_at: ~U[2026-08-05 12:01:59.999999Z])
           ) == {:error, :message_conflict}

    assert Repo.aggregate(MessageRecord, :count) == 1
    assert Repo.get!(ConversationRecord, conversation.id) == advanced
  end

  test "fails closed on invalid committed history" do
    conversation = start_conversation!()

    assert {:ok, {_result, advanced}} = MessageStore.append(conversation, message([]))

    assert {1, nil} =
             Repo.update_all(
               from(record in MessageRecord, where: record.conversation_id == ^conversation.id),
               set: [content: "hidden\tcontrol"]
             )

    assert MessageStore.append(
             advanced,
             message(content: "Another fact.", inserted_at: ~U[2026-08-05 12:02:00Z])
           ) == {:error, :invalid_message_record}

    assert Repo.aggregate(MessageRecord, :count) == 1
    assert Repo.get!(ConversationRecord, conversation.id) == advanced
  end

  test "rejects a valid but rewritten message and rolls back every write" do
    conversation = start_conversation!()
    other_conversation = start_conversation!("other-conversation")

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER rewrite_inserted_message
      AFTER INSERT ON messages
      BEGIN
        UPDATE messages
        SET conversation_id = 'other-conversation', content = 'Altered fact.'
        WHERE id = NEW.id;
      END
      """,
      [],
      log: false
    )

    try do
      assert MessageStore.append(conversation, message([])) ==
               {:error, :invalid_message_record}

      assert Repo.aggregate(MessageRecord, :count) == 0
      assert Repo.get!(ConversationRecord, conversation.id) == conversation
      assert Repo.get!(ConversationRecord, other_conversation.id) == other_conversation
    after
      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER rewrite_inserted_message", [], log: false)
    end
  end

  test "rejects a valid immutable conversation rewrite and rolls back every write" do
    conversation = start_conversation!()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      CREATE TRIGGER invalidate_conversation_after_message
      AFTER INSERT ON messages
      BEGIN
        UPDATE conversations
        SET started_at = '2026-08-05T11:58:00.000000Z'
        WHERE id = NEW.conversation_id;
      END
      """,
      [],
      log: false
    )

    try do
      assert MessageStore.append(conversation, message([])) ==
               {:error, :invalid_conversation_record}

      assert Repo.aggregate(MessageRecord, :count) == 0
      assert Repo.get!(ConversationRecord, conversation.id) == conversation
    after
      Ecto.Adapters.SQL.query!(
        Repo,
        "DROP TRIGGER invalidate_conversation_after_message",
        [],
        log: false
      )
    end
  end

  test "rejects exhausted storage counters before accessing storage" do
    conversation = start_conversation!()
    exhausted = %{conversation | turn_count: @max_safe_integer, llm_call_count: @max_safe_integer}
    Repo.put_dynamic_repo(:missing_message_repo)

    assert MessageStore.append(exhausted, message([])) == {:error, :conversation_limit}
  end

  test "returns a generic error for unavailable storage without exposing values" do
    conversation = start_conversation!()
    Repo.put_dynamic_repo(:missing_message_repo)

    result =
      MessageStore.append(
        conversation,
        message(content: "private-message", persona_id: "private-persona")
      )

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
  end

  defp start_conversation!(id \\ "conversation-1") do
    assert {:ok, _event} = EventStore.insert(event())
    assert {:ok, conversation} = ConversationStore.start(conversation(id))
    conversation
  end

  defp event do
    %Event{
      id: "event-1",
      type: "observation.failed",
      source: "example-observer",
      occurred_at: ~U[2026-08-05 11:59:59.000000Z]
    }
  end

  defp conversation(id) do
    %Conversation{
      id: id,
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
