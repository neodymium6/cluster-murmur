defmodule ClusterMurmur.Persistence.EventStoreTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Persistence.{EventRecord, EventStore}
  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.CreateEvents

  @migration_version 20_260_804_180_500

  setup_all do
    assert Ecto.Migrator.up(Repo, @migration_version, CreateEvents,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @migration_version, CreateEvents,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)
    :ok
  end

  test "persists one validated event as a redacted record" do
    event = event(facts: %{"attempts" => 3}, labels: %{"category" => "monitoring"})

    assert {:ok, %EventRecord{} = record} = EventStore.insert(event)
    assert record.id == event.id
    assert record.occurred_at == event.occurred_at
    assert %DateTime{} = record.inserted_at
    assert Repo.aggregate(EventRecord, :count) == 1

    inspected = inspect(record)
    refute inspected =~ event.id
    refute inspected =~ "attempts"
    refute inspected =~ "2026"
  end

  test "returns the first committed record for an identical retry" do
    event = event([])

    assert {:ok, first} = EventStore.insert(event)
    assert {:ok, second} = EventStore.insert(event)

    assert second == first
    assert Repo.aggregate(EventRecord, :count) == 1
  end

  test "restores one bounded domain event by its complete ID" do
    original =
      event(
        previous: %{"state" => "healthy"},
        current: ["unhealthy", nil],
        facts: %{"attempts" => 3, "latency" => 1.5, "ready" => true},
        labels: %{"category" => "monitoring"}
      )

    assert {:ok, _record} = EventStore.insert(original)
    assert EventStore.fetch(original.id) == {:ok, original}

    assert {:ok, restored} = EventStore.fetch(original.id)
    refute inspect(restored) =~ "attempts"
    refute inspect(restored) =~ "example-target"
  end

  test "classifies missing and invalid IDs before exposing storage" do
    assert EventStore.fetch("missing-event") == {:error, :event_not_found}

    Repo.put_dynamic_repo(:missing_event_repo)

    for invalid <- [nil, "", <<255>>, "private\0event", String.duplicate("x", 16 * 1_024 + 1)] do
      assert EventStore.fetch(invalid) == {:error, :invalid_event_id}
    end
  end

  test "rejects database-valid rows outside every recursive event budget" do
    assert {:ok, record} = EventStore.insert(event([]))

    too_deep = Enum.reduce(1..9, true, fn _level, nested -> %{"nested" => nested} end)
    too_many_entries = Map.new(1..257, &{"key-#{&1}", true})
    too_many_nodes = Map.new(1..256, &{"key-#{&1}", [1, 2, 3, 4]})
    too_much_text = %{"payload" => String.duplicate("x", 64 * 1_024 + 1)}

    for invalid_facts <- [too_deep, too_many_entries, too_many_nodes, too_much_text] do
      encoded_facts = invalid_facts |> :json.encode() |> IO.iodata_to_binary()

      assert {1, nil} =
               Repo.update_all(
                 from(stored in EventRecord, where: stored.id == ^record.id),
                 set: [facts: encoded_facts]
               )

      assert EventStore.fetch(record.id) == {:error, :invalid_event_record}
    end
  end

  test "rejects noncanonical top-level JSON null for optional values" do
    assert {:ok, record} = EventStore.insert(event(previous: nil))

    assert {1, nil} =
             Repo.update_all(
               from(stored in EventRecord, where: stored.id == ^record.id),
               set: [previous: "null"]
             )

    assert EventStore.fetch(record.id) == {:error, :invalid_event_record}
  end

  test "rejects reuse of an event ID when any immutable content differs" do
    assert {:ok, original} = EventStore.insert(event([]))

    conflicting_overrides = [
      type: "observation.recovered",
      source: "other-observer",
      subject: nil,
      group: nil,
      severity: "critical",
      previous: %{"state" => "healthy"},
      current: "healthy",
      dedupe_key: nil,
      correlation_key: "example-correlation",
      facts: %{"attempts" => 3},
      labels: %{"category" => "monitoring"},
      occurred_at: ~U[2026-08-04 12:00:00.000001Z],
      observed_at: nil
    ]

    for override <- conflicting_overrides do
      assert EventStore.insert(event([override])) == {:error, :event_conflict}
    end

    assert Repo.get!(EventRecord, original.id) == original
    assert Repo.aggregate(EventRecord, :count) == 1
  end

  test "rejects invalid and forged events before opening storage" do
    Repo.put_dynamic_repo(:missing_event_repo)

    forged = Map.put(event([]), :unexpected_private_payload, String.duplicate("x", 1024 * 1024))

    for rejected <- [nil, %{event([]) | id: ""}, forged] do
      assert EventStore.insert(rejected) == {:error, :invalid_event}
    end
  end

  test "classifies unavailable storage without exposing event values" do
    Repo.put_dynamic_repo(:missing_event_repo)

    result = EventStore.insert(event(id: "private-event", facts: %{"secret" => "private"}))

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"

    assert EventStore.fetch("private-event") == {:error, :storage_unavailable}
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
          previous: "healthy",
          current: "unhealthy",
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
end
