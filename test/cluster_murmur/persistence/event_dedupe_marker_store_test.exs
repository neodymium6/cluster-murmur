defmodule ClusterMurmur.Persistence.EventDedupeMarkerStoreTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias ClusterMurmur.Config.EventPolicy
  alias ClusterMurmur.Events.{DedupeEvaluator, Event, RetentionPlanner}

  alias ClusterMurmur.Persistence.{
    EventDedupeMarker,
    EventDedupeMarkerStore,
    EventRecord,
    EventStore
  }

  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    AddEventDedupeMarkerPruneIndex,
    CreateEventDedupeMarkers,
    CreateEvents
  }

  @events_version 20_260_804_180_500
  @markers_version 20_260_809_020_000
  @prune_index_version 20_260_809_043_000
  @planned_at ~U[2026-08-09 04:00:00.000000Z]

  setup_all do
    assert Ecto.Migrator.up(Repo, @events_version, CreateEvents,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    assert Ecto.Migrator.up(Repo, @markers_version, CreateEventDedupeMarkers,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    assert Ecto.Migrator.up(Repo, @prune_index_version, AddEventDedupeMarkerPruneIndex,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @prune_index_version, AddEventDedupeMarkerPruneIndex,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )

      Ecto.Migrator.down(Repo, @markers_version, CreateEventDedupeMarkers,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )

      Ecto.Migrator.down(Repo, @events_version, CreateEvents,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM event_dedupe_markers", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)
    :ok
  end

  test "prunes only markers at or before the exact retention boundary" do
    cutoff = retention_plan().cutoff

    insert_marker!("older-key", "older-event", DateTime.add(cutoff, -1, :microsecond))
    insert_marker!("boundary-key", "boundary-event", cutoff)
    insert_marker!("newer-key", "newer-event", DateTime.add(cutoff, 1, :microsecond))

    assert EventDedupeMarkerStore.prune(retention_plan()) == {:ok, 2}
    assert marker_keys() == ["newer-key"]
    assert Repo.aggregate(EventRecord, :count) == 3
  end

  test "prunes one deterministic fixed batch without returning marker values" do
    cutoff = retention_plan().cutoff

    for index <- 0..101 do
      suffix = index |> Integer.to_string() |> String.pad_leading(3, "0")
      accepted_at = DateTime.add(cutoff, -102 + index, :microsecond)
      insert_marker!("key-#{suffix}", "event-#{suffix}", accepted_at)
    end

    assert result = EventDedupeMarkerStore.prune(retention_plan())
    assert result == {:ok, 100}
    assert marker_keys() == ["key-100", "key-101"]

    for hidden <- ["key-000", "event-000", "2026"] do
      refute inspect(result) =~ hidden
    end

    assert EventDedupeMarkerStore.prune(retention_plan()) == {:ok, 2}
    assert EventDedupeMarkerStore.prune(retention_plan()) == {:ok, 0}
  end

  test "rejects malformed and uncorrelated plans before deletion" do
    insert_marker!("retained-key", "retained-event", retention_plan().cutoff)
    plan = retention_plan()

    invalid = [
      nil,
      %{plan | cutoff: DateTime.add(plan.cutoff, 1, :microsecond)},
      Map.put(plan, :private, "private-value")
    ]

    for candidate <- invalid do
      result = EventDedupeMarkerStore.prune(candidate)
      assert result == {:error, :invalid_retention_plan}
      refute inspect(result) =~ "private"
    end

    assert marker_keys() == ["retained-key"]
  end

  defp retention_plan do
    policy = %EventPolicy{dedupe_window_ms: 300_000, retention_ms: 86_400_000}
    {:ok, plan} = RetentionPlanner.plan(policy, @planned_at)
    plan
  end

  defp insert_marker!(dedupe_key, event_id, accepted_at) do
    assert {:ok, _record} = EventStore.insert(event(event_id, dedupe_key, accepted_at))

    marker = %DedupeEvaluator.Marker{
      dedupe_key: dedupe_key,
      event_id: event_id,
      accepted_at: accepted_at
    }

    %EventDedupeMarker{}
    |> EventDedupeMarker.changeset(marker)
    |> Repo.insert!()
  end

  defp event(id, dedupe_key, occurred_at) do
    %Event{
      id: id,
      type: "observation.failed",
      source: "example-observer",
      subject: "example-target",
      group: "operations",
      severity: "warning",
      previous: "healthy",
      current: "unhealthy",
      occurred_at: occurred_at,
      observed_at: occurred_at,
      dedupe_key: dedupe_key,
      correlation_key: nil,
      facts: %{},
      labels: %{}
    }
  end

  defp marker_keys do
    Repo.all(
      from marker in EventDedupeMarker,
        order_by: [asc: marker.dedupe_key],
        select: marker.dedupe_key
    )
  end
end
