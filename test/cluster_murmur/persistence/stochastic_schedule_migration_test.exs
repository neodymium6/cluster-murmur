defmodule ClusterMurmur.Persistence.StochasticScheduleMigrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    AddStochasticScheduleClaims,
    CreateStochasticSchedules
  }

  @claim_migration_version 20_260_804_160_000
  @schedule_migration_version 20_260_804_130_000

  test "migrates a constrained stochastic schedule table" do
    {root, database} = private_database_path()

    assert {:ok, pid} =
             Repo.start_link(
               name: nil,
               database: database,
               allow_in_memory: false,
               pool_size: 1
             )

    try do
      assert Ecto.Migrator.up(Repo, @schedule_migration_version, CreateStochasticSchedules,
               dynamic_repo: pid,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok

      assert table_columns(pid) == [
               "trigger_id",
               "next_run_at",
               "last_run_at",
               "daily_count",
               "daily_count_date"
             ]

      assert Enum.any?(indexes(pid), fn row ->
               "stochastic_schedules_next_run_at_index" in row
             end)

      assert {:ok, _result} =
               insert(pid, "ambient", "2026-08-04T14:00:00.000000Z", nil, 0, nil)

      assert_constraint(fn ->
        insert(pid, "invalid id", "2026-08-04T14:00:00.000000Z", nil, 0, nil)
      end)

      assert_constraint(fn ->
        insert(
          pid,
          "ambient\0 invalid",
          "2026-08-04T14:00:00.000000Z",
          nil,
          0,
          nil
        )
      end)

      assert_constraint(fn ->
        insert(pid, "negative", "2026-08-04T14:00:00.000000Z", nil, -1, nil)
      end)

      assert_constraint(fn ->
        insert(pid, "fractional", "2026-08-04T14:00:00.000000Z", nil, 1.5, ~D[2026-08-04])
      end)

      assert_constraint(fn ->
        insert(pid, "missing-date", "2026-08-04T14:00:00.000000Z", nil, 1, nil)
      end)

      for {trigger_id, next_run_at, last_run_at, daily_count_date} <- [
            {"invalid-next-text", "not-a-datetime", nil, nil},
            {"invalid-last-text", "2026-08-04T14:00:00.000000Z", "not-a-datetime", nil},
            {"invalid-date-text", "2026-08-04T14:00:00.000000Z", nil, "not-a-date"},
            {"invalid-next-month", "2026-13-04T14:00:00.000000Z", nil, nil},
            {"invalid-last-second", "2026-08-04T14:00:00.000000Z", "2026-08-04T12:00:60.000000Z",
             nil},
            {"invalid-date-month", "2026-08-04T14:00:00.000000Z", nil, "2026-13-04"},
            {"invalid-next-nul", "2026-08-04T14:00:00.000000Z\0private", nil, nil},
            {"invalid-last-nul", "2026-08-04T14:00:00.000000Z",
             "2026-08-04T12:00:00.000000Z\0private", nil},
            {"invalid-date-nul", "2026-08-04T14:00:00.000000Z", nil, "2026-08-04\0private"},
            {"invalid-next-blob", {:blob, "2026-08-04T14:00:00.000000Z"}, nil, nil},
            {"invalid-last-blob", "2026-08-04T14:00:00.000000Z",
             {:blob, "2026-08-04T12:00:00.000000Z"}, nil},
            {"invalid-date-blob", "2026-08-04T14:00:00.000000Z", nil, {:blob, "2026-08-04"}}
          ] do
        assert_constraint(fn ->
          insert(pid, trigger_id, next_run_at, last_run_at, 0, daily_count_date)
        end)
      end

      assert_constraint(fn ->
        insert(
          pid,
          "invalid-order",
          "2026-08-04T12:00:00.000000Z",
          "2026-08-04T12:00:00.000000Z",
          0,
          nil
        )
      end)
    after
      Supervisor.stop(pid)
      File.rm_rf!(root)
    end
  end

  test "adds paired constrained claim fields without replacing schedule state" do
    {root, database} = private_database_path()

    assert {:ok, pid} =
             Repo.start_link(
               name: nil,
               database: database,
               allow_in_memory: false,
               pool_size: 1
             )

    token = Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)

    try do
      assert Ecto.Migrator.up(Repo, @schedule_migration_version, CreateStochasticSchedules,
               dynamic_repo: pid,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok

      assert {:ok, _result} =
               insert(pid, "ambient", "2026-08-04T14:00:00.000000Z", nil, 0, nil)

      assert Ecto.Migrator.up(Repo, @claim_migration_version, AddStochasticScheduleClaims,
               dynamic_repo: pid,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok

      assert table_columns(pid) == [
               "trigger_id",
               "next_run_at",
               "last_run_at",
               "daily_count",
               "daily_count_date",
               "claim_token",
               "claim_started_at",
               "claim_expires_at"
             ]

      assert %{rows: [[nil, nil, nil]]} =
               Ecto.Adapters.SQL.query!(
                 pid,
                 "SELECT claim_token, claim_started_at, claim_expires_at FROM stochastic_schedules",
                 [],
                 log: false
               )

      assert {:ok, _result} =
               update_claim(
                 pid,
                 token,
                 "2026-08-04T14:00:00.000000Z",
                 "2026-08-04T14:01:00.000000Z"
               )

      for {rejected_token, rejected_start, rejected_expiry} <- [
            {"short", "2026-08-04T14:00:00.000000Z", "2026-08-04T14:01:00.000000Z"},
            {token, nil, "2026-08-04T14:01:00.000000Z"},
            {token, "2026-08-04T14:00:00.000000Z", nil},
            {nil, "2026-08-04T14:00:00.000000Z", "2026-08-04T14:01:00.000000Z"},
            {token, "not-a-datetime", "2026-08-04T14:01:00.000000Z"},
            {token, "2026-08-04T14:00:00.000000Z", "not-a-datetime"},
            {token, "2026-08-04T14:00:00.000000Z\0private", "2026-08-04T14:01:00.000000Z"},
            {token, "2026-08-04T14:00:00.000000Z", "2026-08-04T14:01:00.000000Z\0private"},
            {token, "2026-08-04T14:00:00.000000Z", "2026-08-04T14:00:00.000000Z"},
            {{:blob, token}, "2026-08-04T14:00:00.000000Z", "2026-08-04T14:01:00.000000Z"}
          ] do
        assert_constraint(fn ->
          update_claim(pid, rejected_token, rejected_start, rejected_expiry)
        end)
      end

      assert Ecto.Migrator.down(Repo, @claim_migration_version, AddStochasticScheduleClaims,
               dynamic_repo: pid,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok

      assert table_columns(pid) == [
               "trigger_id",
               "next_run_at",
               "last_run_at",
               "daily_count",
               "daily_count_date"
             ]
    after
      Supervisor.stop(pid)
      File.rm_rf!(root)
    end
  end

  defp table_columns(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(stochastic_schedules)", [])

    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp indexes(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo, "PRAGMA index_list(stochastic_schedules)", [])

    rows
  end

  defp insert(repo, trigger_id, next_run_at, last_run_at, daily_count, daily_count_date) do
    Ecto.Adapters.SQL.query(
      repo,
      """
      INSERT INTO stochastic_schedules
        (trigger_id, next_run_at, last_run_at, daily_count, daily_count_date)
      VALUES (?, ?, ?, ?, ?)
      """,
      [trigger_id, next_run_at, last_run_at, daily_count, daily_count_date],
      log: false
    )
  end

  defp assert_constraint(fun) do
    assert {:error, %Exqlite.Error{message: message}} = fun.()
    assert message =~ "constraint failed"
  end

  defp update_claim(repo, token, started_at, expires_at) do
    Ecto.Adapters.SQL.query(
      repo,
      """
      UPDATE stochastic_schedules
      SET claim_token = ?, claim_started_at = ?, claim_expires_at = ?
      """,
      [token, started_at, expires_at],
      log: false
    )
  end

  defp private_database_path do
    root =
      Path.join(
        System.tmp_dir!(),
        "cluster-murmur-migration-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    {root, Path.join(root, "migration.sqlite3")}
  end
end
