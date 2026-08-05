defmodule ClusterMurmur.Persistence.EntityStateRecordValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observations.EntityState
  alias ClusterMurmur.Persistence.{EntityStateRecord, EntityStateRecordValidator}

  test "decodes an exact loaded record into validated bounded state" do
    record = loaded_record()

    assert {:ok, state} = EntityStateRecordValidator.decode(record)
    assert state == expected_state()
    assert EntityStateRecordValidator.validate(record) == :ok
  end

  test "rejects built, extended, malformed, and over-budget records" do
    valid = loaded_record()

    invalid = [
      %EntityStateRecord{valid | __meta__: Ecto.Schema.Metadata.__struct__()},
      Map.put(valid, :private, true),
      %EntityStateRecord{valid | facts: "[]"},
      %EntityStateRecord{valid | facts: ~s({"duplicate":1,"duplicate":2})},
      %EntityStateRecord{valid | labels: ~s({"value":1e999})},
      %EntityStateRecord{valid | facts: String.duplicate(" ", 128 * 1_024 + 1)}
    ]

    for record <- invalid do
      assert EntityStateRecordValidator.validate(record) ==
               {:error, :invalid_entity_state_record}

      assert EntityStateRecordValidator.decode(record) ==
               {:error, :invalid_entity_state_record}
    end
  end

  defp loaded_record do
    Ecto.put_meta(
      %EntityStateRecord{
        source: "example-observer",
        subject: "example-target",
        current_state: :healthy,
        pending_state: :unhealthy,
        consecutive_count: 2,
        last_observed_at: ~U[2026-08-05 12:00:00.000000Z],
        last_changed_at: ~U[2026-08-05 11:00:00.000000Z],
        facts: ~s({"attempts":2}),
        labels: ~s({"category":"monitoring"})
      },
      state: :loaded
    )
  end

  defp expected_state do
    %EntityState{
      source: "example-observer",
      subject: "example-target",
      current_state: :healthy,
      pending_state: :unhealthy,
      consecutive_count: 2,
      last_observed_at: ~U[2026-08-05 12:00:00.000000Z],
      last_changed_at: ~U[2026-08-05 11:00:00.000000Z],
      facts: %{"attempts" => 2},
      labels: %{"category" => "monitoring"}
    }
  end
end
