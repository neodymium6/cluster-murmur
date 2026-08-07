defmodule ClusterMurmur.Generation.StarterMessagePersisterTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Generation.{StarterGenerator, StarterMessagePersister}
  alias ClusterMurmur.Generation.StarterMessagePersister.Persisted
  alias ClusterMurmur.Persistence.{ConversationRecord, MessageRecord}
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @inserted_at ~U[2026-08-07 02:00:01.000000Z]

  defmodule FakeProvider do
    def generate(_request, _settings, transport), do: transport.(:request)
  end

  defmodule FakeStore do
    def append(conversation, message) do
      Process.put({__MODULE__, :input}, {conversation, message})

      message_record =
        %MessageRecord{
          id: 1,
          conversation_id: message.conversation_id,
          persona_id: message.persona_id,
          origin: message.origin,
          content: message.content,
          discord_message_id: nil,
          inserted_at: message.inserted_at
        }
        |> Ecto.put_meta(state: :loaded)

      advanced =
        %ConversationRecord{
          conversation
          | turn_count: conversation.turn_count + 1,
            llm_call_count: conversation.llm_call_count + 1
        }

      {:ok, {message_record, advanced}}
    end
  end

  defmodule ConflictingStore do
    def append(_conversation, _message), do: {:error, :conversation_conflict}
  end

  defmodule MalformedStore do
    def append(_conversation, _message), do: {:ok, {%MessageRecord{}, %ConversationRecord{}}}
  end

  defmodule RaisingStore do
    def append(_conversation, _message), do: raise("private storage diagnostic")
  end

  setup do
    Process.delete({FakeStore, :input})
    :ok
  end

  test "appends one exact generated message and returns redacted loaded capabilities" do
    configuration = RuntimeFixture.configuration()
    generated = generated(configuration)

    assert {:ok, %Persisted{} = persisted} =
             StarterMessagePersister.persist(generated, configuration, %{}, FakeStore)

    assert Process.get({FakeStore, :input}) ===
             {generated.plan.started.conversation, generated.message}

    assert persisted.generated === generated
    assert persisted.message.content == generated.message.content
    assert persisted.conversation.turn_count == 1
    assert persisted.conversation.llm_call_count == 1
    assert StarterMessagePersister.validate(persisted, configuration, %{}) == :ok

    refute inspect(persisted) =~ generated.message.content
    refute inspect(persisted) =~ "conversation-1"
  end

  test "rejects forged generated capabilities before calling the store" do
    configuration = RuntimeFixture.configuration()
    generated = generated(configuration)
    forged = %{generated | message: %{generated.message | persona_id: "other"}}

    assert StarterMessagePersister.persist(forged, configuration, %{}, FakeStore) ==
             {:error, :invalid_starter_message}

    assert Process.get({FakeStore, :input}) == nil
  end

  test "preserves stable conflicts and contains malformed store outcomes" do
    configuration = RuntimeFixture.configuration()
    generated = generated(configuration)

    assert StarterMessagePersister.persist(generated, configuration, %{}, ConflictingStore) ==
             {:error, :conversation_conflict}

    assert StarterMessagePersister.persist(generated, configuration, %{}, MalformedStore) ==
             {:error, :invalid_message_record}

    result = StarterMessagePersister.persist(generated, configuration, %{}, RaisingStore)
    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
  end

  test "revalidates exact message and advanced conversation correlation" do
    configuration = RuntimeFixture.configuration()
    generated = generated(configuration)

    assert {:ok, persisted} =
             StarterMessagePersister.persist(generated, configuration, %{}, FakeStore)

    for forged <- [
          nil,
          Map.put(persisted, :private, true),
          %{persisted | message: %{persisted.message | content: "Different"}},
          %{persisted | conversation: %{persisted.conversation | turn_count: 2}},
          %{persisted | conversation: %{persisted.conversation | status: :waiting}}
        ] do
      assert StarterMessagePersister.validate(forged, configuration, %{}) ==
               {:error, :invalid_starter_message}
    end
  end

  defp generated(configuration) do
    plan = RuntimeFixture.generation_plan(configuration)

    {:ok, generated} =
      StarterGenerator.generate(
        plan,
        configuration,
        %{},
        RuntimeFixture.provider_settings(),
        @inserted_at,
        FakeProvider,
        fn :request -> {:ok, "A bounded fact."} end
      )

    generated
  end
end
