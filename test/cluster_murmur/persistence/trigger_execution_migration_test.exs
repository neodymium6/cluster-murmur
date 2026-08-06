defmodule ClusterMurmur.Persistence.TriggerExecutionMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.{CreateEvents, CreateTriggerExecutions}
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  @events_version 20_260_804_180_500
  @executions_version 20_260_804_200_000

  test "migrates a constrained trigger execution table" do
    {root, database} = private_database_path()

    assert {:ok, pid} =
             Repo.start_link(
               name: nil,
               database: database,
               allow_in_memory: false,
               pool_size: 1
             )

    try do
      migrate_up(pid, @events_version, CreateEvents)
      migrate_up(pid, @executions_version, CreateTriggerExecutions)

      assert table_columns(pid) == [
               "trigger_id",
               "event_id",
               "status",
               "executed_at",
               "cooldown_until",
               "error_class"
             ]

      index_rows = indexes(pid)
      assert Enum.any?(index_rows, &Enum.member?(&1, "trigger_executions_cooldown_until_index"))
      assert Enum.any?(index_rows, &Enum.member?(&1, "trigger_executions_executed_at_index"))

      assert {:ok, _result} = insert_event(pid)
      assert {:ok, _result} = insert_execution(pid, %{})

      for overrides <- [
            %{trigger_id: "invalid id"},
            %{event_id: "missing-event"},
            %{status: "queued"},
            %{executed_at: "not-a-datetime"},
            %{cooldown_until: "2026-08-04T11:59:59.000000Z"},
            %{status: "failed"},
            %{error_class: "provider.failure"},
            %{status: "failed", error_class: "Invalid Error"}
          ] do
        assert_constraint(fn -> insert_execution(pid, overrides) end)
      end

      assert {:ok, _result} =
               insert_execution(pid, %{
                 trigger_id: "failure-conversation-2",
                 status: "failed",
                 error_class: "provider.unavailable"
               })

      assert_constraint(fn -> insert_execution(pid, %{}) end)

      migrate_down(pid, @executions_version, CreateTriggerExecutions)
      refute "trigger_executions" in table_names(pid)
      migrate_down(pid, @events_version, CreateEvents)
    after
      Supervisor.stop(pid)
      File.rm_rf!(root)
    end
  end

  defp insert_event(repo) do
    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO events (id, type, source, facts, labels, occurred_at, inserted_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        "example-event",
        "observation.failed",
        "example-observer",
        "{}",
        "{}",
        "2026-08-04T11:59:59.000000Z",
        "2026-08-04T12:00:00.000000Z"
      ],
      log: false
    )
  end

  defp insert_execution(repo, overrides) do
    values =
      Map.merge(
        %{
          trigger_id: "failure-conversation",
          event_id: "example-event",
          status: "started",
          executed_at: "2026-08-04T12:00:00.000000Z",
          cooldown_until: "2026-08-04T12:01:00.000000Z",
          error_class: nil
        },
        overrides
      )

    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO trigger_executions
        (trigger_id, event_id, status, executed_at, cooldown_until, error_class)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        values.trigger_id,
        values.event_id,
        values.status,
        values.executed_at,
        values.cooldown_until,
        values.error_class
      ],
      log: false
    )
  end

  defp migrate_up(repo, version, migration) do
    assert Ecto.Migrator.up(Repo, version, migration,
             dynamic_repo: repo,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok
  end

  defp migrate_down(repo, version, migration) do
    assert Ecto.Migrator.down(Repo, version, migration,
             dynamic_repo: repo,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok
  end

  defp table_columns(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(trigger_executions)", [], log: false)

    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp indexes(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA index_list(trigger_executions)", [], log: false)

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
    root = PrivateTmpDir.create!("cluster-murmur-trigger-execution-migration")
    {root, Path.join(root, "migration.sqlite3")}
  end
end
