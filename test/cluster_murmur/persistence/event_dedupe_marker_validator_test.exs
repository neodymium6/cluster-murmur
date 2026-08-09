defmodule ClusterMurmur.Persistence.EventDedupeMarkerValidatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Persistence.{EventDedupeMarker, EventDedupeMarkerValidator}

  test "accepts only exact loaded bounded markers" do
    assert EventDedupeMarkerValidator.validate(loaded()) == :ok

    valid = loaded()

    for rejected <- [
          nil,
          %EventDedupeMarker{},
          %{valid | dedupe_key: ""},
          %{valid | event_id: "private\0event"},
          %{valid | accepted_at: %{valid.accepted_at | microsecond: {0, 0}}},
          Ecto.put_meta(valid, state: :deleted),
          Ecto.put_meta(valid, prefix: "private"),
          Map.put(valid, :private, "private-value")
        ] do
      result = EventDedupeMarkerValidator.validate(rejected)
      assert result == {:error, :invalid_event_dedupe_marker}
      refute inspect(result) =~ "private"
    end
  end

  defp loaded do
    %EventDedupeMarker{
      dedupe_key: "observation.failed:example-target",
      event_id: "example-event",
      accepted_at: ~U[2026-08-09 02:00:00.000000Z]
    }
    |> Ecto.put_meta(state: :loaded)
  end
end
