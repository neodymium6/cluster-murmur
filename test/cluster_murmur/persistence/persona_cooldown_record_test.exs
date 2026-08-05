defmodule ClusterMurmur.Persistence.PersonaCooldownRecordTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.PersonaCooldownRecord

  test "builds a redacted record from one bounded cooldown projection" do
    last_spoken_at = ~U[2026-08-05 12:00:00.000000Z]
    cooldown_until = ~U[2026-08-05 12:30:00.000000Z]

    assert %{valid?: true} =
             changeset =
             PersonaCooldownRecord.changeset(
               %PersonaCooldownRecord{},
               "observer",
               last_spoken_at,
               cooldown_until
             )

    record = Ecto.Changeset.apply_changes(changeset)
    assert record.persona_id == "observer"
    assert record.last_spoken_at == last_spoken_at
    assert record.cooldown_until == cooldown_until
  end

  test "accepts a zero-duration cooldown" do
    spoken_at = ~U[2026-08-05 12:00:00.000000Z]

    assert %{valid?: true} =
             PersonaCooldownRecord.changeset(
               %PersonaCooldownRecord{},
               "observer",
               spoken_at,
               spoken_at
             )
  end

  test "rejects invalid facts without retaining their values" do
    spoken_at = ~U[2026-08-05 12:00:00.000000Z]
    cooldown_until = ~U[2026-08-05 12:30:00.000000Z]

    invalid = [
      {nil, spoken_at, cooldown_until},
      {"invalid id", spoken_at, cooldown_until},
      {String.duplicate("a", 16 * 1_024 + 1), spoken_at, cooldown_until},
      {"private-persona", nil, cooldown_until},
      {"private-persona", %{spoken_at | hour: 24}, cooldown_until},
      {"private-persona", spoken_at, %{cooldown_until | time_zone: "UTC"}},
      {"private-persona", spoken_at, DateTime.add(spoken_at, -1, :microsecond)},
      {"private-persona", spoken_at, DateTime.add(spoken_at, 365 * 86_400 + 1, :second)}
    ]

    for {persona_id, last_spoken_at, deadline} <- invalid do
      changeset =
        PersonaCooldownRecord.changeset(
          %PersonaCooldownRecord{},
          persona_id,
          last_spoken_at,
          deadline
        )

      refute changeset.valid?
      assert changeset.changes == %{}
      refute inspect(changeset) =~ "private"
    end
  end

  test "rejects loaded, prefilled, and forged records" do
    spoken_at = ~U[2026-08-05 12:00:00.000000Z]
    cooldown_until = ~U[2026-08-05 12:30:00.000000Z]

    for record <- [
          Ecto.put_meta(%PersonaCooldownRecord{}, state: :loaded),
          %PersonaCooldownRecord{persona_id: "observer"},
          Ecto.put_meta(%PersonaCooldownRecord{}, source: "messages"),
          Ecto.put_meta(%PersonaCooldownRecord{}, prefix: "private"),
          Map.put(%PersonaCooldownRecord{}, :unexpected_private_value, "private")
        ] do
      changeset =
        PersonaCooldownRecord.changeset(
          record,
          "observer",
          spoken_at,
          cooldown_until
        )

      refute changeset.valid?
      assert changeset.changes == %{}
    end
  end

  test "redacts records and valid changesets" do
    changeset =
      PersonaCooldownRecord.changeset(
        %PersonaCooldownRecord{},
        "private-persona",
        ~U[2026-08-05 12:00:00.000000Z],
        ~U[2026-08-05 12:30:00.000000Z]
      )

    record = Ecto.Changeset.apply_changes(changeset)

    for inspected <- [inspect(record), inspect(changeset)] do
      refute inspected =~ "private-persona"
      refute inspected =~ "2026"
    end
  end
end
