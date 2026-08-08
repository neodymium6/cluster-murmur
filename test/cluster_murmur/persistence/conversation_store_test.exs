defmodule ClusterMurmur.Persistence.ConversationStoreTest do
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
    AddIncompleteConversationIndex,
    CreateConversations,
    CreateEvents,
    CreateMessages
  }

  @events_version 20_260_804_180_500
  @conversations_version 20_260_805_200_000
  @incomplete_index_version 20_260_805_210_000
  @messages_version 20_260_805_220_000

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

    assert Ecto.Migrator.up(Repo, @incomplete_index_version, AddIncompleteConversationIndex,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    assert Ecto.Migrator.up(Repo, @messages_version, CreateMessages,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @messages_version, CreateMessages,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )

      Ecto.Migrator.down(Repo, @incomplete_index_version, AddIncompleteConversationIndex,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )

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
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM messages", [], log: false)
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

  test "finishes one exact active conversation in each terminal state" do
    for {index, active_status, operation, expected_status} <- [
          {1, :starting, &ConversationStore.complete/2, :completed},
          {2, :generating, &ConversationStore.cancel/2, :cancelled},
          {3, :waiting, &ConversationStore.fail/2, :failed}
        ] do
      started = start_conversation!("conversation-#{index}")

      if active_status != :starting do
        assert {1, nil} =
                 Repo.update_all(
                   from(record in ConversationRecord, where: record.id == ^started.id),
                   set: [status: active_status]
                 )
      end

      active = Repo.get!(ConversationRecord, started.id)
      completed_at = ~U[2026-08-05 12:01:00Z]

      assert {:ok, terminal} = operation.(active, completed_at)
      assert terminal.status == expected_status
      assert DateTime.compare(terminal.completed_at, completed_at) == :eq
      assert terminal.completed_at.microsecond == {0, 6}
      assert terminal.root_event_id == active.root_event_id
      assert terminal.turn_count == active.turn_count
      assert terminal.llm_call_count == active.llm_call_count
    end
  end

  test "allows only one terminal transition" do
    started = start_conversation!("one-way-conversation")
    completed_at = ~U[2026-08-05 12:01:00.000000Z]

    assert {:ok, completed} = ConversationStore.complete(started, completed_at)

    assert ConversationStore.cancel(started, completed_at) ==
             {:error, :conversation_conflict}

    assert ConversationStore.fail(completed, completed_at) ==
             {:error, :invalid_conversation_record}
  end

  test "atomically moves an exact conversation into waiting only once" do
    started = start_conversation!("waiting-conversation")

    assert {:ok, waiting} = ConversationStore.wait(started)
    assert waiting === %{started | status: :waiting}
    assert Repo.get!(ConversationRecord, started.id) === waiting

    assert ConversationStore.wait(started) == {:error, :conversation_conflict}
    assert ConversationStore.wait(waiting) == {:error, :conversation_conflict}
    assert Repo.get!(ConversationRecord, started.id) === waiting
  end

  test "moves an exact generating conversation into waiting without changing counters" do
    started = start_conversation!("generating-conversation")

    assert {1, nil} =
             Repo.update_all(
               from(record in ConversationRecord, where: record.id == ^started.id),
               set: [status: :generating, turn_count: 1, llm_call_count: 1]
             )

    generating = Repo.get!(ConversationRecord, started.id)
    assert {:ok, waiting} = ConversationStore.wait(generating)
    assert waiting === %{generating | status: :waiting}
  end

  test "claims one exact waiting conversation for generation only once" do
    started = start_conversation!("generation-claim")
    assert {:ok, waiting} = ConversationStore.wait(started)

    assert {:ok, generating} = ConversationStore.claim_generation(waiting)
    assert generating === %{waiting | status: :generating}
    assert Repo.get!(ConversationRecord, started.id) === generating

    assert ConversationStore.claim_generation(waiting) == {:error, :conversation_conflict}
    assert ConversationStore.claim_generation(generating) == {:error, :conversation_conflict}
  end

  test "requires the exact loaded active capability" do
    started = start_conversation!("exact-capability")

    invalid = [
      nil,
      %ConversationRecord{},
      Map.put(started, :unexpected_private_value, "private"),
      Ecto.put_meta(started, source: "events"),
      Ecto.put_meta(started, prefix: "private"),
      %{started | id: "invalid id"},
      %{started | started_at: %{started.started_at | microsecond: {0, 0}}}
    ]

    Repo.put_dynamic_repo(:missing_conversation_repo)

    for rejected <- invalid do
      assert ConversationStore.complete(rejected, ~U[2026-08-05 12:01:00.000000Z]) ==
               {:error, :invalid_conversation_record}
    end
  end

  test "rejects invalid or earlier completion instants before storage" do
    started = start_conversation!("invalid-completion")
    Repo.put_dynamic_repo(:missing_conversation_repo)

    for completed_at <- [
          nil,
          %{~U[2026-08-05 12:01:00Z] | hour: 24},
          ~U[2026-08-05 11:59:59.999999Z]
        ] do
      assert ConversationStore.complete(started, completed_at) == {:error, :invalid_datetime}
    end
  end

  test "rejects every terminal state before the latest committed message" do
    for {index, operation} <- [
          {1, &ConversationStore.complete/2},
          {2, &ConversationStore.cancel/2},
          {3, &ConversationStore.fail/2}
        ] do
      started = start_conversation!("bounded-terminal-#{index}")

      assert {:ok, {_message, advanced}} =
               MessageStore.append(
                 started,
                 message(
                   conversation_id: started.id,
                   inserted_at: ~U[2026-08-05 12:01:00.000000Z]
                 )
               )

      assert operation.(advanced, ~U[2026-08-05 12:00:59.999999Z]) ==
               {:error, :invalid_datetime}

      assert Repo.get!(ConversationRecord, started.id) == advanced
      assert Repo.aggregate(MessageRecord, :count) == index
    end
  end

  test "allows a terminal instant equal to the latest committed message" do
    started = start_conversation!("equal-terminal")
    inserted_at = ~U[2026-08-05 12:01:00.000000Z]

    assert {:ok, {_message, advanced}} =
             MessageStore.append(
               started,
               message(conversation_id: started.id, inserted_at: inserted_at)
             )

    assert {:ok, terminal} = ConversationStore.complete(advanced, inserted_at)
    assert terminal.status == :completed
    assert DateTime.compare(terminal.completed_at, inserted_at) == :eq
  end

  test "fails closed on invalid committed message history before terminal transition" do
    started = start_conversation!("invalid-terminal-history")

    assert {:ok, {_message, advanced}} =
             MessageStore.append(
               started,
               message(conversation_id: started.id)
             )

    assert {1, nil} =
             Repo.update_all(
               from(record in MessageRecord, where: record.conversation_id == ^started.id),
               set: [content: "https://example.com"]
             )

    assert ConversationStore.complete(advanced, ~U[2026-08-05 12:02:00.000000Z]) ==
             {:error, :invalid_message_record}

    assert Repo.get!(ConversationRecord, started.id).status == :starting
  end

  test "detects a stale active capability without overwriting durable state" do
    started = start_conversation!("stale-capability")
    stale = %{started | turn_count: 1}

    assert ConversationStore.fail(stale, ~U[2026-08-05 12:01:00.000000Z]) ==
             {:error, :conversation_conflict}

    assert Repo.get!(ConversationRecord, started.id).status == :starting
  end

  test "lists only active conversations at or before a supplied cutoff" do
    oldest = start_conversation!("oldest", ~U[2026-08-05 11:58:00.000000Z])
    completed = start_conversation!("completed", ~U[2026-08-05 11:59:00.000000Z])
    generating = start_conversation!("generating", ~U[2026-08-05 11:59:30.000000Z])
    boundary = start_conversation!("boundary", ~U[2026-08-05 12:00:00.000000Z])
    _later = start_conversation!("later", ~U[2026-08-05 12:00:00.000001Z])

    assert {1, nil} =
             Repo.update_all(
               from(record in ConversationRecord, where: record.id == ^generating.id),
               set: [status: :generating]
             )

    assert {:ok, _terminal} =
             ConversationStore.complete(completed, ~U[2026-08-05 12:00:30.000000Z])

    assert ConversationStore.list_active_before(~U[2026-08-05 12:00:00Z]) ==
             {:ok, [oldest, Repo.get!(ConversationRecord, generating.id), boundary]}
  end

  test "bounds and deterministically orders incomplete results" do
    for index <- 101..1//-1 do
      suffix = index |> Integer.to_string() |> String.pad_leading(3, "0")
      start_conversation!("recovery-#{suffix}", ~U[2026-08-05 12:00:00.000000Z])
    end

    assert {:ok, records} =
             ConversationStore.list_active_before(~U[2026-08-05 12:00:00.000000Z])

    assert length(records) == 100
    assert hd(records).id == "recovery-001"
    assert List.last(records).id == "recovery-100"
    assert Enum.map(records, & &1.id) == Enum.sort(Enum.map(records, & &1.id))
  end

  test "rejects invalid listing cutoffs before accessing storage" do
    Repo.put_dynamic_repo(:missing_conversation_repo)

    for cutoff <- [nil, %{~U[2026-08-05 12:00:00Z] | hour: 24}] do
      assert ConversationStore.list_active_before(cutoff) == {:error, :invalid_datetime}
    end
  end

  defp start_conversation!(id, started_at \\ ~U[2026-08-05 12:00:00Z]) do
    assert {:ok, _event_record} = EventStore.insert(event())

    assert {:ok, record} =
             ConversationStore.start(conversation(id: id, started_at: started_at))

    record
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
          inserted_at: ~U[2026-08-05 12:01:00.000000Z]
        ],
        overrides
      )
    )
  end
end
