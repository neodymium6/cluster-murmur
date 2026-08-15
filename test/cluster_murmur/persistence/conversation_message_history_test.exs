defmodule ClusterMurmur.Persistence.ConversationMessageHistoryTest do
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

  test "returns empty history for an exact new conversation" do
    conversation = start_conversation!()
    assert MessageStore.list_for_conversation(conversation) == {:ok, []}
  end

  test "returns exact domain messages in chronological durable order" do
    conversation = start_conversation!()
    {records, conversation} = append_messages!(conversation, 3)
    [_first, second, _third] = records
    assert {:ok, _published} = MessageStore.record_publication(second, "12345")

    assert {:ok, messages} = MessageStore.list_for_conversation(conversation)
    assert Enum.map(messages, & &1.content) == ["Fact 1.", "Fact 2.", "Fact 3."]
    assert Enum.map(messages, & &1.discord_message_id) == [nil, "12345", nil]
    assert Enum.all?(messages, &match?(%Message{}, &1))
  end

  test "returns only the latest twelve messages with deterministic tie ordering" do
    conversation = start_conversation!()
    {_records, conversation} = append_messages!(conversation, 13, same_time?: true)

    assert {:ok, messages} = MessageStore.list_for_conversation(conversation)
    assert length(messages) == 12
    assert Enum.map(messages, & &1.content) == Enum.map(2..13, &"Fact #{&1}.")
    assert Enum.map(messages, & &1.inserted_at) == List.duplicate(historical_time(1), 12)
  end

  test "accepts an exact terminal conversation capability" do
    conversation = start_conversation!()
    {_records, conversation} = append_messages!(conversation, 1)

    assert {:ok, terminal} =
             ConversationStore.complete(conversation, ~U[2026-08-05 12:02:00.000000Z])

    assert {:ok, [%Message{content: "Fact 1."}]} =
             MessageStore.list_for_conversation(terminal)
  end

  test "rejects terminal history extending past conversation completion" do
    conversation = start_conversation!()
    {_records, conversation} = append_messages!(conversation, 1)

    assert {:ok, terminal} =
             ConversationStore.complete(conversation, ~U[2026-08-05 12:02:00.000000Z])

    assert {1, nil} =
             Repo.update_all(
               from(record in ConversationRecord, where: record.id == ^terminal.id),
               set: [completed_at: ~U[2026-08-05 12:00:00.000000Z]]
             )

    corrupted = Repo.get!(ConversationRecord, terminal.id)

    assert MessageStore.list_for_conversation(corrupted) ==
             {:error, :invalid_message_record}
  end

  test "rejects invalid and stale conversation capabilities before returning history" do
    conversation = start_conversation!()
    {_records, advanced} = append_messages!(conversation, 1)

    Repo.put_dynamic_repo(:missing_history_repo)

    for invalid <- [nil, %ConversationRecord{}, Ecto.put_meta(advanced, source: "events")] do
      assert MessageStore.list_for_conversation(invalid) ==
               {:error, :invalid_conversation_record}
    end

    Repo.put_dynamic_repo(Repo)

    assert MessageStore.list_for_conversation(conversation) ==
             {:error, :conversation_conflict}
  end

  test "fails closed when durable message counts diverge from conversation turns" do
    conversation = start_conversation!()
    {_records, advanced} = append_messages!(conversation, 1)

    assert {1, nil} =
             Repo.update_all(
               from(record in ConversationRecord, where: record.id == ^advanced.id),
               set: [turn_count: 2, llm_call_count: 2]
             )

    divergent = Repo.get!(ConversationRecord, advanced.id)

    assert MessageStore.list_for_conversation(divergent) ==
             {:error, :invalid_conversation_record}
  end

  test "fails closed when bounded loaded history contains an invalid record" do
    conversation = start_conversation!()
    {_records, advanced} = append_messages!(conversation, 1)

    assert {1, nil} =
             Repo.update_all(
               from(record in MessageRecord, where: record.conversation_id == ^conversation.id),
               set: [content: "hidden\tcontrol"]
             )

    assert MessageStore.list_for_conversation(advanced) ==
             {:error, :invalid_message_record}
  end

  test "returns a generic error for unavailable storage without exposing values" do
    conversation = start_conversation!()
    Repo.put_dynamic_repo(:missing_history_repo)

    result = MessageStore.list_for_conversation(conversation)
    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ conversation.id
  end

  defp start_conversation! do
    assert {:ok, _event} = EventStore.insert(event())
    assert {:ok, conversation} = ConversationStore.start(conversation())
    conversation
  end

  defp append_messages!(conversation, count, options \\ []) do
    Enum.reduce(1..count, {[], conversation}, fn index, {records, current} ->
      inserted_at =
        if options[:same_time?], do: historical_time(1), else: historical_time(index)

      assert {:ok, {record, advanced}} =
               MessageStore.append(
                 current,
                 message(content: "Fact #{index}.", inserted_at: inserted_at)
               )

      {[record | records], advanced}
    end)
    |> then(fn {records, advanced} -> {Enum.reverse(records), advanced} end)
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
