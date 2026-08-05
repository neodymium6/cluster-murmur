defmodule ClusterMurmur.Persistence.EventRecordMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.CreateEvents

  @migration_version 20_260_804_180_500

  test "migrates a constrained bounded event table" do
    {root, database} = private_database_path()

    assert {:ok, pid} =
             Repo.start_link(
               name: nil,
               database: database,
               allow_in_memory: false,
               pool_size: 1
             )

    try do
      assert Ecto.Migrator.up(Repo, @migration_version, CreateEvents,
               dynamic_repo: pid,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok

      assert table_columns(pid) == [
               "id",
               "type",
               "source",
               "subject",
               "group",
               "severity",
               "previous",
               "current",
               "dedupe_key",
               "correlation_key",
               "facts",
               "labels",
               "occurred_at",
               "observed_at",
               "inserted_at"
             ]

      index_rows = indexes(pid)
      assert Enum.any?(index_rows, &(&1 |> Enum.member?("events_occurred_at_index")))
      assert Enum.any?(index_rows, &(&1 |> Enum.member?("events_dedupe_key_index")))

      assert {:ok, _result} = insert(pid, %{})

      for overrides <- [
            %{id: ""},
            %{id: {:blob, "event"}},
            %{source: "example\0private"},
            %{facts: "[]"},
            %{facts: "not-json"},
            %{labels: "null"},
            %{occurred_at: "2026-13-04T12:00:00.000000Z"},
            %{inserted_at: "not-a-datetime"}
          ] do
        assert_constraint(fn -> insert(pid, overrides) end)
      end

      oversized_json = ~s({"payload":"#{String.duplicate("a", 512 * 1_024)}"})
      assert_constraint(fn -> insert(pid, %{facts: oversized_json}) end)

      assert_constraint(fn -> insert(pid, %{id: "example-event"}) end)

      assert Ecto.Migrator.down(Repo, @migration_version, CreateEvents,
               dynamic_repo: pid,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok

      refute "events" in table_names(pid)
    after
      Supervisor.stop(pid)
      File.rm_rf!(root)
    end
  end

  defp insert(repo, overrides) do
    values =
      Map.merge(
        %{
          id: "example-event",
          type: "observation.failed",
          source: "example-observer",
          facts: ~s({"attempts":3}),
          labels: ~s({"category":"monitoring"}),
          occurred_at: "2026-08-04T12:00:00.000000Z",
          inserted_at: "2026-08-04T12:00:01.000000Z"
        },
        overrides
      )

    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO events (id, type, source, facts, labels, occurred_at, inserted_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        values.id,
        values.type,
        values.source,
        values.facts,
        values.labels,
        values.occurred_at,
        values.inserted_at
      ],
      log: false
    )
  end

  defp table_columns(repo) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(events)", [], log: false)
    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp indexes(repo) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(repo, "PRAGMA index_list(events)", [], log: false)
    rows
  end

  defp table_names(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT name FROM sqlite_master WHERE type = 'table'",
        [],
        log: false
      )

    List.flatten(rows)
  end

  defp assert_constraint(fun) do
    assert {:error, %Exqlite.Error{message: message}} = fun.()
    assert message =~ "constraint failed"
  end

  defp private_database_path do
    root =
      Path.join(
        System.tmp_dir!(),
        "cluster-murmur-event-migration-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    {root, Path.join(root, "migration.sqlite3")}
  end
end
