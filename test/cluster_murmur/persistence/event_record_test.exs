defmodule ClusterMurmur.Persistence.EventRecordTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Persistence.EventRecord

  test "encodes one validated event into a redacted persistence changeset" do
    event =
      event(
        previous: %{"state" => "healthy"},
        current: "unhealthy",
        facts: %{"attempts" => 3, "checks" => [true, nil]},
        labels: %{"category" => "monitoring"}
      )

    assert %{valid?: true} = changeset = EventRecord.changeset(%EventRecord{}, event)
    record = Ecto.Changeset.apply_changes(changeset)

    assert record.id == event.id
    assert record.type == event.type
    assert record.occurred_at == event.occurred_at
    assert decode_json(record.previous) == event.previous
    assert decode_json(record.current) == event.current
    assert decode_json(record.facts) == event.facts
    assert decode_json(record.labels) == event.labels
  end

  test "rejects invalid and forged events before retaining their payload" do
    forged = Map.put(event([]), :unexpected_private_payload, String.duplicate("x", 1024 * 1024))

    invalid = [
      nil,
      %{event([]) | id: ""},
      %{event([]) | facts: %{"private" => :not_json}},
      forged
    ]

    for rejected <- invalid do
      changeset = EventRecord.changeset(%EventRecord{}, rejected)
      refute changeset.valid?
      refute inspect(changeset) =~ "private"
    end
  end

  test "redacts encoded event records and changesets" do
    private = "private-event-value"
    event = event(id: private, facts: %{"secret" => private})
    changeset = EventRecord.changeset(%EventRecord{}, event)
    record = Ecto.Changeset.apply_changes(changeset)

    for inspected <- [inspect(record), inspect(changeset)] do
      refute inspected =~ private
      refute inspected =~ "secret"
      refute inspected =~ "2026"
    end
  end

  defp event(overrides) do
    struct!(
      Event,
      Keyword.merge(
        [
          id: "example-event",
          type: "observation.failed",
          source: "example-observer",
          subject: "example-target",
          group: "operations",
          severity: "warning",
          previous: nil,
          current: nil,
          occurred_at: ~U[2026-08-04 12:00:00.000000Z],
          observed_at: ~U[2026-08-04 12:00:01.000000Z],
          dedupe_key: "observation.failed:example-target",
          correlation_key: nil,
          facts: %{},
          labels: %{}
        ],
        overrides
      )
    )
  end

  defp decode_json(encoded), do: encoded |> :json.decode() |> denormalize_nulls()

  defp denormalize_nulls(:null), do: nil

  defp denormalize_nulls(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, denormalize_nulls(nested)} end)

  defp denormalize_nulls(value) when is_list(value), do: Enum.map(value, &denormalize_nulls/1)
  defp denormalize_nulls(value), do: value
end
