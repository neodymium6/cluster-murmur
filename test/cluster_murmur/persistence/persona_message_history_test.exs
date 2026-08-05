defmodule ClusterMurmur.Persistence.PersonaMessageHistoryTest do
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
    AddPersonaMessageHistoryIndex,
    CreateConversations,
    CreateEvents,
    CreateMessages
  }

  @events_version 20_260_804_180_500
  @conversations_version 20_260_805_200_000
  @messages_version 20_260_805_220_000
  @persona_history_index_version 20_260_805_223_000

  setup_all do
    migrate_up(@events_version, CreateEvents)
    migrate_up(@conversations_version, CreateConversations)
    migrate_up(@messages_version, CreateMessages)
    migrate_up(@persona_history_index_version, AddPersonaMessageHistoryIndex)

    on_exit(fn ->
      migrate_down(@persona_history_index_version, AddPersonaMessageHistoryIndex)
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
    assert {:ok, _event} = EventStore.insert(event())
    :ok
  end

  test "returns published persona messages across conversations in chronological order" do
    first = start_conversation!("conversation-1")
    second = start_conversation!("conversation-2")
    {_first_record, _first} = append_published!(first, "observer", "First fact.", 1, "1")
    {_second_record, _second} = append_published!(second, "observer", "Second fact.", 2, "2")

    assert {:ok, messages} =
             MessageStore.list_for_persona("observer", "current-conversation", historical_time(3))

    assert Enum.map(messages, & &1.content) == ["First fact.", "Second fact."]
    assert Enum.all?(messages, &match?(%Message{discord_message_id: id} when is_binary(id), &1))
  end

  test "returns only the latest six messages with deterministic tie ordering" do
    conversation = start_conversation!("conversation-1")

    {_records, _conversation} =
      Enum.reduce(1..8, {[], conversation}, fn index, {records, current} ->
        {record, advanced} =
          append_published!(current, "observer", "Fact #{index}.", 1, Integer.to_string(index))

        {[record | records], advanced}
      end)

    assert {:ok, messages} =
             MessageStore.list_for_persona("observer", "current-conversation", historical_time(2))

    assert Enum.map(messages, & &1.content) == Enum.map(3..8, &"Fact #{&1}.")
  end

  test "excludes other personas, unpublished messages, and messages after the cutoff" do
    conversation = start_conversation!("conversation-1")
    {_record, conversation} = append_published!(conversation, "observer", "Included.", 1, "1")
    {_record, conversation} = append_published!(conversation, "other", "Other.", 2, "2")

    assert {:ok, {_unpublished, conversation}} =
             MessageStore.append(
               conversation,
               message("observer", "Unpublished.", historical_time(3), conversation.id)
             )

    {_future, _conversation} =
      append_published!(conversation, "observer", "Future.", 4, "4")

    assert {:ok, [%Message{content: "Included."}]} =
             MessageStore.list_for_persona(
               "observer",
               "current-conversation",
               historical_time(3)
             )
  end

  test "excludes the current conversation before applying the six-message limit" do
    previous = start_conversation!("previous-conversation")
    current = start_conversation!("current-conversation")

    {_previous, _conversation} =
      append_published!(previous, "observer", "Previous fact.", 1, "1")

    {_records, _conversation} =
      Enum.reduce(2..8, {[], current}, fn index, {records, conversation} ->
        {record, advanced} =
          append_published!(
            conversation,
            "observer",
            "Current fact #{index}.",
            index,
            Integer.to_string(index)
          )

        {[record | records], advanced}
      end)

    assert {:ok, [%Message{content: "Previous fact."}]} =
             MessageStore.list_for_persona(
               "observer",
               "current-conversation",
               historical_time(9)
             )
  end

  test "rejects invalid inputs before accessing storage" do
    Repo.put_dynamic_repo(:missing_persona_history_repo)

    for persona_id <- [nil, "", "invalid id", String.duplicate("a", 16 * 1_024 + 1)] do
      assert MessageStore.list_for_persona(
               persona_id,
               "current-conversation",
               historical_time(1)
             ) ==
               {:error, :invalid_persona_id}
    end

    for conversation_id <- [nil, "", "invalid id", String.duplicate("a", 16 * 1_024 + 1)] do
      assert MessageStore.list_for_persona("observer", conversation_id, historical_time(1)) ==
               {:error, :invalid_conversation_id}
    end

    for cutoff <- [nil, %{historical_time(1) | hour: 24}] do
      assert MessageStore.list_for_persona("observer", "current-conversation", cutoff) ==
               {:error, :invalid_datetime}
    end
  end

  test "fails closed when loaded persona history contains an invalid record" do
    conversation = start_conversation!("conversation-1")
    {_record, _conversation} = append_published!(conversation, "observer", "Fact.", 1, "1")

    assert {1, nil} =
             Repo.update_all(
               from(record in MessageRecord, where: record.persona_id == "observer"),
               set: [content: "https://example.com"]
             )

    assert MessageStore.list_for_persona(
             "observer",
             "current-conversation",
             historical_time(2)
           ) ==
             {:error, :invalid_message_record}
  end

  test "returns a generic storage error without exposing the persona" do
    Repo.put_dynamic_repo(:missing_persona_history_repo)

    result =
      MessageStore.list_for_persona(
        "private-persona",
        "private-conversation",
        historical_time(1)
      )

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
  end

  defp append_published!(conversation, persona_id, content, seconds, publication_id) do
    assert {:ok, {record, advanced}} =
             MessageStore.append(
               conversation,
               message(persona_id, content, historical_time(seconds), conversation.id)
             )

    assert {:ok, published} = MessageStore.record_publication(record, publication_id)
    {published, advanced}
  end

  defp start_conversation!(id) do
    assert {:ok, conversation} = ConversationStore.start(conversation(id))
    conversation
  end

  defp historical_time(seconds),
    do: DateTime.add(~U[2026-08-05 12:00:00.000000Z], seconds, :second)

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
      started_at: ~U[2026-08-05 12:00:00.000000Z],
      last_message_at: nil,
      turn_count: 0,
      llm_call_count: 0,
      participants: [],
      messages: []
    }
  end

  defp message(persona_id, content, inserted_at, conversation_id) do
    %Message{
      conversation_id: conversation_id,
      persona_id: persona_id,
      origin: :llm,
      content: content,
      discord_message_id: nil,
      inserted_at: inserted_at
    }
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
