defmodule ClusterMurmur.Persistence.ConversationRecordMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    AddIncompleteConversationIndex,
    CreateConversations,
    CreateEvents
  }

  @events_version 20_260_804_180_500
  @conversations_version 20_260_805_200_000
  @incomplete_index_version 20_260_805_210_000

  test "migrates a constrained conversation lifecycle table" do
    {root, database} = private_database_path()

    assert {:ok, pid} =
             Repo.start_link(
               name: nil,
               database: database,
               allow_in_memory: false,
               pool_size: 2
             )

    try do
      migrate_up(pid, @events_version, CreateEvents)
      migrate_up(pid, @conversations_version, CreateConversations)
      migrate_up(pid, @incomplete_index_version, AddIncompleteConversationIndex)

      assert table_columns(pid) == [
               "id",
               "root_event_id",
               "status",
               "turn_count",
               "llm_call_count",
               "started_at",
               "completed_at"
             ]

      index_rows = indexes(pid)
      assert Enum.any?(index_rows, &Enum.member?(&1, "conversations_root_event_id_index"))
      refute Enum.any?(index_rows, &Enum.member?(&1, "conversations_status_started_at_index"))

      assert Enum.any?(
               index_rows,
               &Enum.member?(&1, "conversations_incomplete_started_at_id_index")
             )

      plan = incomplete_query_plan(pid)
      assert plan =~ "conversations_incomplete_started_at_id_index"
      refute plan =~ "USE TEMP B-TREE"

      assert {:ok, _result} = insert_event(pid)
      assert {:ok, _result} = insert_conversation(pid, %{})

      for overrides <- [
            %{id: "invalid id"},
            %{root_event_id: "missing-event"},
            %{status: "queued"},
            %{turn_count: -1},
            %{turn_count: 9_007_199_254_740_992},
            %{llm_call_count: 1.5},
            %{started_at: "not-a-datetime"},
            %{completed_at: "2026-08-05T12:01:00.000000Z"},
            %{status: "completed"},
            %{status: "failed", completed_at: "2026-08-05T11:59:59.000000Z"}
          ] do
        assert_constraint(fn -> insert_conversation(pid, overrides) end)
      end

      assert {:ok, _result} =
               insert_conversation(pid, %{
                 id: "conversation-2",
                 status: "completed",
                 completed_at: "2026-08-05T12:01:00.000000Z"
               })

      assert_constraint(fn -> insert_conversation(pid, %{}) end)

      migrate_down(pid, @incomplete_index_version, AddIncompleteConversationIndex)
      migrate_down(pid, @conversations_version, CreateConversations)
      refute "conversations" in table_names(pid)
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
        "event-1",
        "observation.failed",
        "example-observer",
        "{}",
        "{}",
        "2026-08-05T11:59:59.000000Z",
        "2026-08-05T12:00:00.000000Z"
      ],
      log: false
    )
  end

  defp insert_conversation(repo, overrides) do
    values =
      Map.merge(
        %{
          id: "conversation-1",
          root_event_id: "event-1",
          status: "starting",
          turn_count: 0,
          llm_call_count: 0,
          started_at: "2026-08-05T12:00:00.000000Z",
          completed_at: nil
        },
        overrides
      )

    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO conversations
        (id, root_event_id, status, turn_count, llm_call_count, started_at, completed_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        values.id,
        values.root_event_id,
        values.status,
        values.turn_count,
        values.llm_call_count,
        values.started_at,
        values.completed_at
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
      Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(conversations)", [], log: false)

    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp indexes(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA index_list(conversations)", [], log: false)

    rows
  end

  defp incomplete_query_plan(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        EXPLAIN QUERY PLAN
        SELECT id FROM conversations
        WHERE status IN ('starting', 'generating', 'waiting') AND started_at <= ?
        ORDER BY started_at ASC, id ASC
        LIMIT 100
        """,
        ["2026-08-05T12:00:00.000000Z"],
        log: false
      )

    rows |> List.flatten() |> Enum.filter(&is_binary/1) |> Enum.join("\n")
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
        "cluster-murmur-conversation-migration-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    {root, Path.join(root, "migration.sqlite3")}
  end
end
