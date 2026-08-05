defmodule ClusterMurmur.Persistence.PublicationAttemptRecordTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.{MessageRecord, PublicationAttemptRecord}

  test "builds one redacted started attempt from a loaded unpublished message" do
    changeset =
      PublicationAttemptRecord.start_changeset(%PublicationAttemptRecord{}, message(), now())

    assert changeset.valid?

    attempt = Ecto.Changeset.apply_changes(changeset)
    assert attempt.message_id == message().id
    assert attempt.status == :started
    assert attempt.started_at == now()
    assert attempt.completed_at == nil
    assert attempt.error_class == nil
    refute inspect(attempt) =~ "2026"
    refute inspect(attempt) =~ Integer.to_string(message().id)
  end

  test "rejects invalid, published, forged, and prefilled inputs" do
    loaded = message()

    invalid_messages = [
      nil,
      %MessageRecord{},
      %{loaded | discord_message_id: "12345"},
      %{loaded | id: 0},
      Map.put(loaded, :private, true)
    ]

    for invalid <- invalid_messages do
      refute PublicationAttemptRecord.start_changeset(
               %PublicationAttemptRecord{},
               invalid,
               now()
             ).valid?
    end

    for invalid_time <- [nil, %{now() | hour: 24}] do
      refute PublicationAttemptRecord.start_changeset(
               %PublicationAttemptRecord{},
               loaded,
               invalid_time
             ).valid?
    end

    refute PublicationAttemptRecord.start_changeset(
             %PublicationAttemptRecord{status: :started},
             loaded,
             now()
           ).valid?
  end

  defp now, do: ~U[2026-08-05 12:02:00.000000Z]

  defp message do
    Ecto.put_meta(
      %MessageRecord{
        id: 42,
        conversation_id: "conversation-1",
        persona_id: "observer",
        origin: :llm,
        content: "A bounded confirmed fact.",
        discord_message_id: nil,
        inserted_at: ~U[2026-08-05 12:01:00.000000Z]
      },
      state: :loaded
    )
  end
end
