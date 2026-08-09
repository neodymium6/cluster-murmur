defmodule ClusterMurmur.Persistence.EventRetentionSweepMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.CreateEventRetentionSweeps
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  @version 20_260_809_051_500

  test "migrates one constrained event-retention sweep cursor" do
    root = PrivateTmpDir.create!("cluster-murmur-event-retention-sweep-migration")
    database = Path.join(root, "migration.sqlite3")

    assert {:ok, pid} =
             Repo.start_link(name: nil, database: database, allow_in_memory: false, pool_size: 1)

    try do
      migrate(pid, :up)

      assert columns(pid) == ["scope", "cursor_occurred_at", "cursor_event_id", "swept_at"]

      for overrides <- [
            %{scope: "other"},
            %{cursor_occurred_at: "2026-05-11T05:00:00.000000Z"},
            %{cursor_event_id: "example-event"},
            %{
              cursor_occurred_at: "2026-05-11T05:00:00.000000Z",
              cursor_event_id: "private\0event"
            },
            %{swept_at: "not-a-datetime"}
          ] do
        assert_constraint(fn -> insert(pid, overrides) end, Map.keys(overrides))
      end

      assert {:ok, _result} = insert(pid, %{})
      assert_constraint(fn -> insert(pid, %{}) end, [:duplicate_scope])

      assert {:ok, _result} =
               Ecto.Adapters.SQL.query(
                 pid,
                 """
                 UPDATE event_retention_sweeps
                 SET cursor_occurred_at = ?, cursor_event_id = ?, swept_at = ?
                 WHERE scope = 'events'
                 """,
                 [
                   "2026-05-11T05:00:00.000000Z",
                   "example-event",
                   "2026-08-09T05:15:00.000000Z"
                 ],
                 log: false
               )

      migrate(pid, :down)
      refute "event_retention_sweeps" in tables(pid)
    after
      Supervisor.stop(pid)
      File.rm_rf!(root)
    end
  end

  defp insert(repo, overrides) do
    values =
      Map.merge(
        %{
          scope: "events",
          cursor_occurred_at: nil,
          cursor_event_id: nil,
          swept_at: "2026-08-09T05:15:00.000000Z"
        },
        overrides
      )

    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO event_retention_sweeps
        (scope, cursor_occurred_at, cursor_event_id, swept_at)
      VALUES (?, ?, ?, ?)
      """,
      [values.scope, values.cursor_occurred_at, values.cursor_event_id, values.swept_at],
      log: false
    )
  end

  defp migrate(repo, direction) do
    assert apply(Ecto.Migrator, direction, [
             Repo,
             @version,
             CreateEventRetentionSweeps,
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
      Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(event_retention_sweeps)", [], log: false)

    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp tables(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "SELECT name FROM sqlite_master WHERE type = 'table'", [],
        log: false
      )

    List.flatten(rows)
  end

  defp assert_constraint(fun, fields) do
    case fun.() do
      {:error, %Exqlite.Error{message: message}} ->
        assert message =~ "constraint failed"

      _accepted ->
        flunk("accepted invalid sweep fields: #{inspect(fields)}")
    end
  end
end
