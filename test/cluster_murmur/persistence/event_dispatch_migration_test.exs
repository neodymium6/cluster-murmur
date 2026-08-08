defmodule ClusterMurmur.Persistence.EventDispatchMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.{CreateEventDispatches, CreateEvents}
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  @events_version 20_260_804_180_500
  @dispatches_version 20_260_808_150_000

  test "migrates a constrained lease-protected event dispatch table" do
    root = PrivateTmpDir.create!("cluster-murmur-event-dispatch-migration")
    database = Path.join(root, "migration.sqlite3")

    assert {:ok, pid} =
             Repo.start_link(name: nil, database: database, allow_in_memory: false, pool_size: 1)

    try do
      migrate(pid, @events_version, CreateEvents, :up)
      migrate(pid, @dispatches_version, CreateEventDispatches, :up)

      assert table_columns(pid) == [
               "event_id",
               "status",
               "enqueued_at",
               "claim_token",
               "claim_started_at",
               "claim_expires_at",
               "completed_at"
             ]

      index_names = indexes(pid)
      assert "event_dispatches_status_enqueued_at_event_id_index" in index_names
      assert "event_dispatches_claim_expires_at_index" in index_names

      insert_event(pid)
      assert {:ok, _result} = insert_pending(pid)

      for statement <- [
            "UPDATE event_dispatches SET status = 'claimed'",
            "UPDATE event_dispatches SET claim_token = 'invalid'",
            "UPDATE event_dispatches SET status = 'completed', completed_at = '2026-08-08T14:59:59.000000Z'",
            "UPDATE event_dispatches SET status = 'claimed', claim_token = '#{valid_token()}', claim_started_at = '2026-08-08T14:59:59.000000Z', claim_expires_at = '2026-08-08T15:00:59.000000Z'",
            "UPDATE event_dispatches SET status = 'claimed', claim_token = '#{valid_token()}', claim_started_at = '2026-08-08T15:00:01.000000Z', claim_expires_at = '2026-08-08T15:00:00.000000Z'"
          ] do
        assert_constraint(fn -> Ecto.Adapters.SQL.query(pid, statement, [], log: false) end)
      end

      nul_token = String.duplicate("A", 42) <> <<0>>

      assert_constraint(fn ->
        Ecto.Adapters.SQL.query(
          pid,
          """
          UPDATE event_dispatches
          SET status = 'claimed', claim_token = ?,
              claim_started_at = '2026-08-08T15:00:02.000000Z',
              claim_expires_at = '2026-08-08T15:01:02.000000Z'
          """,
          [nul_token],
          log: false
        )
      end)

      migrate(pid, @dispatches_version, CreateEventDispatches, :down)
      refute "event_dispatches" in table_names(pid)
      migrate(pid, @events_version, CreateEvents, :down)
    after
      Supervisor.stop(pid)
      File.rm_rf!(root)
    end
  end

  defp migrate(repo, version, module, direction) do
    assert apply(Ecto.Migrator, direction, [Repo, version, module, migration_options(repo)]) ==
             :ok
  end

  defp migration_options(repo) do
    [dynamic_repo: repo, log: false, log_migrations_sql: false, log_migrator_sql: false]
  end

  defp insert_event(repo) do
    Ecto.Adapters.SQL.query!(
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
        "2026-08-08T15:00:00.000000Z",
        "2026-08-08T15:00:01.000000Z"
      ],
      log: false
    )
  end

  defp insert_pending(repo) do
    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO event_dispatches (event_id, status, enqueued_at)
      VALUES (?, 'pending', ?)
      """,
      ["example-event", "2026-08-08T15:00:02.000000Z"],
      log: false
    )
  end

  defp table_columns(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(event_dispatches)", [], log: false)

    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp indexes(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA index_list(event_dispatches)", [], log: false)

    Enum.map(rows, &Enum.at(&1, 1))
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

  defp valid_token,
    do: <<7>> |> :binary.copy(32) |> Base.url_encode64(padding: false)
end
