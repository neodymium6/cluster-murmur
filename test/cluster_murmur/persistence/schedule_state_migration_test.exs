defmodule ClusterMurmur.Persistence.ScheduleStateMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.CreateScheduleStates
  alias ClusterMurmur.TestSupport.PrivateTmpDir

  @version 20_260_809_062_000
  @token Base.url_encode64(<<0::256>>, padding: false)

  test "migrates constrained indexed recurring schedule state reversibly" do
    root = PrivateTmpDir.create!("cluster-murmur-schedule-state-migration")
    database = Path.join(root, "migration.sqlite3")

    assert {:ok, pid} =
             Repo.start_link(name: nil, database: database, allow_in_memory: false, pool_size: 1)

    try do
      migrate(pid, :up)

      assert columns(pid) == [
               "trigger_id",
               "next_run_at",
               "last_run_at",
               "claim_token",
               "claim_started_at",
               "claim_expires_at"
             ]

      assert index_columns(pid, "schedule_states_next_run_at_trigger_id_index") == [
               "next_run_at",
               "trigger_id"
             ]

      assert index_columns(pid, "schedule_states_claim_expires_at_index") == ["claim_expires_at"]

      for overrides <- [
            %{trigger_id: "bad id"},
            %{next_run_at: "2026-08-10T00:00:00Z"},
            %{last_run_at: "2026-08-10T00:00:00.000000Z"},
            %{claim_token: @token},
            %{
              claim_token: "short",
              claim_started_at: "2026-08-10T00:00:01.000000Z",
              claim_expires_at: "2026-08-10T00:01:01.000000Z"
            },
            %{
              claim_token: @token,
              claim_started_at: "2026-08-10T00:01:01.000000Z",
              claim_expires_at: "2026-08-10T00:01:01.000000Z"
            }
          ] do
        assert_constraint(fn -> insert(pid, overrides) end)
      end

      assert {:ok, _result} = insert(pid, %{})
      assert_constraint(fn -> insert(pid, %{}) end)

      assert {:ok, _result} =
               insert(pid, %{
                 trigger_id: "hourly-summary",
                 claim_token: @token,
                 claim_started_at: "2026-08-10T00:00:01.000000Z",
                 claim_expires_at: "2026-08-10T00:01:01.000000Z"
               })

      migrate(pid, :down)
      refute "schedule_states" in tables(pid)
    after
      Supervisor.stop(pid)
      File.rm_rf!(root)
    end
  end

  defp insert(repo, overrides) do
    values =
      Map.merge(
        %{
          trigger_id: "daily-summary",
          next_run_at: "2026-08-10T00:00:00.000000Z",
          last_run_at: nil,
          claim_token: nil,
          claim_started_at: nil,
          claim_expires_at: nil
        },
        overrides
      )

    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO schedule_states
        (trigger_id, next_run_at, last_run_at, claim_token, claim_started_at, claim_expires_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        values.trigger_id,
        values.next_run_at,
        values.last_run_at,
        values.claim_token,
        values.claim_started_at,
        values.claim_expires_at
      ],
      log: false
    )
  end

  defp migrate(repo, direction) do
    assert apply(Ecto.Migrator, direction, [
             Repo,
             @version,
             CreateScheduleStates,
             [
               dynamic_repo: repo,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ]
           ]) == :ok
  end

  defp columns(repo) do
    pragma(repo, "table_info(schedule_states)") |> Enum.map(&Enum.at(&1, 1))
  end

  defp index_columns(repo, index) do
    pragma(repo, "index_info(\"#{index}\")") |> Enum.map(&Enum.at(&1, 2))
  end

  defp pragma(repo, expression) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(repo, "PRAGMA #{expression}", [], log: false)
    rows
  end

  defp tables(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "SELECT name FROM sqlite_master WHERE type = 'table'", [],
        log: false
      )

    List.flatten(rows)
  end

  defp assert_constraint(fun) do
    assert {:error, %Exqlite.Error{message: message}} = fun.()
    assert message =~ "constraint failed"
  end
end
