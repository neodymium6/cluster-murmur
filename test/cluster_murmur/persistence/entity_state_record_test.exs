defmodule ClusterMurmur.Persistence.EntityStateRecordTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observations.{EntityState, EntityStateValidator}
  alias ClusterMurmur.Persistence.EntityStateRecord

  test "builds a redacted changeset for committed and pending states" do
    states = [
      state([]),
      state(
        current_state: :unknown,
        pending_state: :healthy,
        consecutive_count: 1,
        last_changed_at: nil
      ),
      state(pending_state: :unhealthy, consecutive_count: 2)
    ]

    for value <- states do
      assert EntityStateValidator.validate(value) == :ok
      changeset = EntityStateRecord.changeset(%EntityStateRecord{}, value)
      assert changeset.valid?

      record = Ecto.Changeset.apply_changes(changeset)
      assert record.source == value.source
      assert record.current_state == value.current_state
      assert record.facts == ~s({"attempts":2})
      refute inspect(record) =~ value.source
      refute inspect(record) =~ "attempts"
    end
  end

  test "rejects invalid debounce and time invariants" do
    valid = state([])

    invalid = [
      nil,
      %{valid | current_state: :unknown, pending_state: nil, last_changed_at: nil},
      %{valid | pending_state: :healthy, consecutive_count: 1},
      %{valid | pending_state: :unhealthy, consecutive_count: 0},
      %{valid | consecutive_count: -1},
      %{valid | last_changed_at: DateTime.add(valid.last_observed_at, 1, :microsecond)},
      %{valid | facts: %{"invalid" => self()}},
      Map.put(valid, :private, true)
    ]

    for value <- invalid do
      assert EntityStateValidator.validate(value) == {:error, :invalid_entity_state}
      refute EntityStateRecord.changeset(%EntityStateRecord{}, value).valid?
    end
  end

  test "accepts only a pristine record" do
    assert EntityStateRecord.changeset(%EntityStateRecord{source: "existing"}, state([])).valid? ==
             false
  end

  test "rejects JSON escaping that exceeds the encoded storage boundary" do
    escaped = String.duplicate(<<1>>, 16 * 1_024)
    value = state(facts: %{"first" => escaped}, labels: %{"second" => escaped})

    assert EntityStateValidator.validate(value) == {:error, :invalid_entity_state}
    refute EntityStateRecord.changeset(%EntityStateRecord{}, value).valid?
  end

  defp state(overrides) do
    struct!(
      EntityState,
      Keyword.merge(
        [
          source: "example-observer",
          subject: "example-target",
          current_state: :healthy,
          pending_state: nil,
          consecutive_count: 0,
          last_observed_at: ~U[2026-08-05 12:00:00.000000Z],
          last_changed_at: ~U[2026-08-05 11:00:00.000000Z],
          facts: %{"attempts" => 2},
          labels: %{"category" => "monitoring"}
        ],
        overrides
      )
    )
  end
end
