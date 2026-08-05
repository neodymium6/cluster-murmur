defmodule ClusterMurmur.Persistence.PersonaCooldownRecordValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.{PersonaCooldownRecord, PersonaCooldownRecordValidator}

  test "accepts an exact loaded bounded persona cooldown" do
    assert PersonaCooldownRecordValidator.validate(loaded_record()) == :ok

    assert PersonaCooldownRecordValidator.validate(
             loaded_record(cooldown_until: ~U[2026-08-05 12:00:00.000000Z])
           ) == :ok

    assert PersonaCooldownRecordValidator.validate(
             loaded_record(cooldown_until: ~U[2027-08-05 12:00:00.000000Z])
           ) == :ok
  end

  test "rejects non-records, pristine records, and forged metadata or shape" do
    for rejected <- [
          nil,
          %{},
          %PersonaCooldownRecord{},
          Ecto.put_meta(loaded_record(), state: :deleted),
          Ecto.put_meta(loaded_record(), source: "messages"),
          Ecto.put_meta(loaded_record(), prefix: "private"),
          Map.delete(loaded_record(), :cooldown_until),
          Map.put(loaded_record(), :unexpected_private_value, "private")
        ] do
      assert PersonaCooldownRecordValidator.validate(rejected) ==
               {:error, :invalid_persona_cooldown_record}
    end
  end

  test "rejects invalid IDs and loaded UTC precision" do
    valid = loaded_record()

    for rejected <- [
          %{valid | persona_id: "invalid id"},
          %{valid | persona_id: String.duplicate("a", 16 * 1_024 + 1)},
          %{valid | last_spoken_at: %{valid.last_spoken_at | hour: 24}},
          %{valid | cooldown_until: %{valid.cooldown_until | time_zone: "UTC"}},
          %{valid | last_spoken_at: %{valid.last_spoken_at | microsecond: {0, 0}}},
          %{valid | cooldown_until: %{valid.cooldown_until | microsecond: {0, 3}}}
        ] do
      assert PersonaCooldownRecordValidator.validate(rejected) ==
               {:error, :invalid_persona_cooldown_record}
    end
  end

  test "rejects reversed and overlong cooldown intervals" do
    valid = loaded_record()

    for deadline <- [
          DateTime.add(valid.last_spoken_at, -1, :microsecond),
          DateTime.add(valid.last_spoken_at, 365 * 86_400, :second)
          |> DateTime.add(1, :microsecond)
        ] do
      assert PersonaCooldownRecordValidator.validate(%{valid | cooldown_until: deadline}) ==
               {:error, :invalid_persona_cooldown_record}
    end
  end

  test "never exposes rejected values through its error" do
    result =
      loaded_record(persona_id: "private-persona")
      |> Map.put(:unexpected_private_value, "private-value")
      |> PersonaCooldownRecordValidator.validate()

    assert result == {:error, :invalid_persona_cooldown_record}
    refute inspect(result) =~ "private"
  end

  defp loaded_record(overrides \\ []) do
    record =
      struct!(
        PersonaCooldownRecord,
        Keyword.merge(
          [
            persona_id: "observer",
            cooldown_until: ~U[2026-08-05 12:30:00.000000Z],
            last_spoken_at: ~U[2026-08-05 12:00:00.000000Z]
          ],
          overrides
        )
      )

    Ecto.put_meta(record, state: :loaded)
  end
end
