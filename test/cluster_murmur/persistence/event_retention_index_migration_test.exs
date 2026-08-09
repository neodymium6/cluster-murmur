defmodule ClusterMurmur.Persistence.EventRetentionIndexMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    AddEventDedupeMarkerPruneIndex,
    AddEventRetentionLookupIndexes,
    CreateEventDedupeMarkers,
    CreateEvents,
    CreateTriggerExecutions
  }

  alias ClusterMurmur.TestSupport.PrivateTmpDir

  @events_version 20_260_804_180_500
  @executions_version 20_260_804_200_000
  @markers_version 20_260_809_020_000
  @marker_prune_index_version 20_260_809_043_000
  @retention_indexes_version 20_260_809_050_000

  test "adds ordered event-retention and foreign-key lookup indexes reversibly" do
    root = PrivateTmpDir.create!("cluster-murmur-event-retention-index-migration")
    database = Path.join(root, "migration.sqlite3")

    assert {:ok, pid} =
             Repo.start_link(name: nil, database: database, allow_in_memory: false, pool_size: 1)

    try do
      migrate(pid, :up, @events_version, CreateEvents)
      migrate(pid, :up, @executions_version, CreateTriggerExecutions)
      migrate(pid, :up, @markers_version, CreateEventDedupeMarkers)

      migrate(
        pid,
        :up,
        @marker_prune_index_version,
        AddEventDedupeMarkerPruneIndex
      )

      assert index_columns(pid, "events_occurred_at_index") == ["occurred_at"]

      assert index_columns(pid, "event_dedupe_markers_accepted_at_dedupe_key_index") == [
               "accepted_at",
               "dedupe_key"
             ]

      refute has_index?(pid, "trigger_executions_event_id_index")
      refute has_index?(pid, "event_dedupe_markers_event_id_index")

      migrate(
        pid,
        :up,
        @retention_indexes_version,
        AddEventRetentionLookupIndexes
      )

      refute has_index?(pid, "events_occurred_at_index")
      assert index_columns(pid, "events_occurred_at_id_index") == ["occurred_at", "id"]
      assert index_columns(pid, "trigger_executions_event_id_index") == ["event_id"]
      assert index_columns(pid, "event_dedupe_markers_event_id_index") == ["event_id"]

      assert index_columns(pid, "event_dedupe_markers_accepted_at_dedupe_key_index") == [
               "accepted_at",
               "dedupe_key"
             ]

      migrate(
        pid,
        :down,
        @retention_indexes_version,
        AddEventRetentionLookupIndexes
      )

      assert index_columns(pid, "events_occurred_at_index") == ["occurred_at"]
      refute has_index?(pid, "events_occurred_at_id_index")
      refute has_index?(pid, "trigger_executions_event_id_index")
      refute has_index?(pid, "event_dedupe_markers_event_id_index")

      assert index_columns(pid, "event_dedupe_markers_accepted_at_dedupe_key_index") == [
               "accepted_at",
               "dedupe_key"
             ]
    after
      Supervisor.stop(pid)
      File.rm_rf!(root)
    end
  end

  defp migrate(repo, direction, version, module) do
    assert apply(Ecto.Migrator, direction, [
             Repo,
             version,
             module,
             [
               dynamic_repo: repo,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ]
           ]) == :ok
  end

  defp has_index?(repo, name), do: name in indexes(repo, table_for_index(name))

  defp table_for_index("events_" <> _suffix), do: "events"
  defp table_for_index("trigger_executions_" <> _suffix), do: "trigger_executions"
  defp table_for_index("event_dedupe_markers_" <> _suffix), do: "event_dedupe_markers"

  defp indexes(repo, table) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA index_list(\"#{table}\")", [], log: false)

    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp index_columns(repo, index) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA index_info(\"#{index}\")", [], log: false)

    Enum.map(rows, &Enum.at(&1, 2))
  end
end
