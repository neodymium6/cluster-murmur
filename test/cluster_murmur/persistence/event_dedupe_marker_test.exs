defmodule ClusterMurmur.Persistence.EventDedupeMarkerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.DedupeEvaluator.Marker
  alias ClusterMurmur.Persistence.EventDedupeMarker

  @accepted_at ~U[2026-08-09 02:00:00.000000Z]

  test "builds one redacted pristine record from an exact marker" do
    changeset = EventDedupeMarker.changeset(%EventDedupeMarker{}, marker())
    assert changeset.valid?

    record = Ecto.Changeset.apply_changes(changeset)
    assert record.dedupe_key == "observation.failed:example-target"
    assert record.event_id == "example-event"
    assert record.accepted_at == @accepted_at

    for inspected <- [inspect(changeset), inspect(record)] do
      refute inspected =~ "example-target"
      refute inspected =~ "example-event"
      refute inspected =~ "2026"
    end
  end

  test "rejects malformed markers and non-pristine records without retaining values" do
    valid = marker()

    for {record, candidate} <- [
          {%EventDedupeMarker{}, nil},
          {%EventDedupeMarker{}, %{valid | dedupe_key: ""}},
          {%EventDedupeMarker{}, %{valid | event_id: "private\0event"}},
          {%EventDedupeMarker{}, %{valid | accepted_at: nil}},
          {%EventDedupeMarker{}, Map.put(valid, :private, "private-value")},
          {%EventDedupeMarker{dedupe_key: "prefilled"}, valid},
          {Ecto.put_meta(%EventDedupeMarker{}, state: :loaded), valid}
        ] do
      changeset = EventDedupeMarker.changeset(record, candidate)
      refute changeset.valid?
      assert changeset.changes == %{}
      refute inspect(changeset) =~ "private"
    end
  end

  defp marker do
    %Marker{
      dedupe_key: "observation.failed:example-target",
      event_id: "example-event",
      accepted_at: @accepted_at
    }
  end
end
