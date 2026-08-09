defmodule ClusterMurmur.Persistence.EventDedupeMarkerMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    AddEventDedupeMarkerPruneIndex,
    CreateEventDedupeMarkers,
    CreateEvents
  }

  alias ClusterMurmur.TestSupport.PrivateTmpDir

  @events_version 20_260_804_180_500
  @marker_version 20_260_809_020_000
  @prune_index_version 20_260_809_043_000

  test "migrates a constrained event dedupe marker table" do
    root = PrivateTmpDir.create!("cluster-murmur-event-dedupe-marker-migration")
    database = Path.join(root, "migration.sqlite3")

    assert {:ok, pid} =
             Repo.start_link(name: nil, database: database, allow_in_memory: false, pool_size: 1)

    try do
      migrate(pid, :up, @events_version, CreateEvents)
      migrate(pid, :up, @marker_version, CreateEventDedupeMarkers)
      insert_event(pid)

      assert columns(pid) == ["dedupe_key", "event_id", "accepted_at"]
      assert "event_dedupe_markers_accepted_at_index" in indexes(pid)
      assert {:ok, _result} = insert_marker(pid, %{})

      for overrides <- [
            %{dedupe_key: ""},
            %{dedupe_key: "private\0key"},
            %{event_id: "missing-event"},
            %{accepted_at: "not-a-datetime"}
          ] do
        assert_constraint(fn -> insert_marker(pid, overrides) end)
      end

      assert_constraint(fn -> insert_marker(pid, %{}) end)

      migrate(pid, :up, @prune_index_version, AddEventDedupeMarkerPruneIndex)

      refute "event_dedupe_markers_accepted_at_index" in indexes(pid)

      assert index_columns(pid, "event_dedupe_markers_accepted_at_dedupe_key_index") ==
               ["accepted_at", "dedupe_key"]

      migrate(pid, :down, @prune_index_version, AddEventDedupeMarkerPruneIndex)

      assert "event_dedupe_markers_accepted_at_index" in indexes(pid)
      refute "event_dedupe_markers_accepted_at_dedupe_key_index" in indexes(pid)

      migrate(pid, :down, @marker_version, CreateEventDedupeMarkers)
      refute "event_dedupe_markers" in tables(pid)
    after
      Supervisor.stop(pid)
      File.rm_rf!(root)
    end
  end

  defp insert_event(repo) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      INSERT INTO events
        (id, type, source, facts, labels, occurred_at, inserted_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "example-event",
        "observation.failed",
        "example-observer",
        "{}",
        "{}",
        "2026-08-09T01:59:59.000000Z",
        "2026-08-09T02:00:00.000000Z"
      ],
      log: false
    )
  end

  defp insert_marker(repo, overrides) do
    values =
      Map.merge(
        %{
          dedupe_key: "observation.failed:example-target",
          event_id: "example-event",
          accepted_at: "2026-08-09T02:00:00.000000Z"
        },
        overrides
      )

    Ecto.Adapters.SQL.query(
      repo,
      "INSERT INTO event_dedupe_markers (dedupe_key, event_id, accepted_at) VALUES (?, ?, ?)",
      [values.dedupe_key, values.event_id, values.accepted_at],
      log: false
    )
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

  defp columns(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(event_dedupe_markers)", [], log: false)

    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp tables(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "SELECT name FROM sqlite_master WHERE type = 'table'", [],
        log: false
      )

    List.flatten(rows)
  end

  defp indexes(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA index_list(event_dedupe_markers)", [], log: false)

    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp index_columns(repo, index) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA index_info(\"#{index}\")", [], log: false)

    Enum.map(rows, &Enum.at(&1, 2))
  end

  defp assert_constraint(fun) do
    assert {:error, %Exqlite.Error{message: message}} = fun.()
    assert message =~ "constraint failed"
  end
end
