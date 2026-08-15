defmodule ClusterMurmur.Persistence.MessageRecordValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.{MessageRecord, MessageRecordValidator}

  @max_sqlite_integer 9_223_372_036_854_775_807

  test "accepts exact loaded records with optional publication identity" do
    for record <- [
          loaded(:llm, "12345"),
          loaded(:fallback, nil),
          loaded(:llm, nil, id: @max_sqlite_integer)
        ] do
      assert MessageRecordValidator.validate(record) == :ok
    end
  end

  test "rejects forged metadata and shapes" do
    valid = loaded(:llm, nil)

    for record <- [
          nil,
          %MessageRecord{},
          Map.put(valid, :unexpected_private_value, "private"),
          Ecto.put_meta(valid, state: :built),
          Ecto.put_meta(valid, source: "events"),
          Ecto.put_meta(valid, prefix: "private")
        ] do
      assert MessageRecordValidator.validate(record) == {:error, :invalid_message_record}
    end
  end

  test "rejects invalid surrogate IDs and runtime values" do
    valid = loaded(:llm, nil)

    for record <- [
          %{valid | id: nil},
          %{valid | id: 0},
          %{valid | id: -1},
          %{valid | id: 1.0},
          %{valid | id: @max_sqlite_integer + 1},
          %{valid | conversation_id: "invalid id"},
          %{valid | persona_id: ""},
          %{valid | origin: :system},
          %{valid | content: "hidden\tcontrol"},
          %{valid | discord_message_id: "0"},
          %{valid | inserted_at: %{valid.inserted_at | hour: 24}},
          %{valid | inserted_at: %{valid.inserted_at | microsecond: {0, 0}}}
        ] do
      assert MessageRecordValidator.validate(record) == {:error, :invalid_message_record}
    end
  end

  test "keeps loaded values redacted" do
    record =
      loaded(:llm, nil,
        conversation_id: "private-conversation",
        persona_id: "private-persona",
        content: "private-message"
      )

    assert MessageRecordValidator.validate(record) == :ok

    inspected = inspect(record)
    assert inspected =~ "origin: :llm"
    refute inspected =~ "private"
    refute inspected =~ "2026"
  end

  defp loaded(origin, discord_message_id, overrides \\ []) do
    struct!(
      MessageRecord,
      Keyword.merge(
        [
          __meta__: Ecto.put_meta(%MessageRecord{}, state: :loaded).__meta__,
          id: 1,
          conversation_id: "conversation-1",
          persona_id: "observer",
          origin: origin,
          content: "A bounded fact.",
          discord_message_id: discord_message_id,
          inserted_at: ~U[2026-08-05 12:01:00.000000Z]
        ],
        overrides
      )
    )
  end
end
