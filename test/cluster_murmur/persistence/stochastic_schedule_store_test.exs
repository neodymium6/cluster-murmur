defmodule ClusterMurmur.Persistence.StochasticScheduleStoreTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Persistence.{StochasticSchedule, StochasticScheduleStore}
  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.CreateStochasticSchedules

  @migration_version 20_260_804_130_000

  setup_all do
    assert Ecto.Migrator.up(Repo, @migration_version, CreateStochasticSchedules,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @migration_version, CreateStochasticSchedules,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM stochastic_schedules", [], log: false)
    :ok
  end

  test "initializes one redacted durable schedule" do
    assert {:ok, schedule} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    assert %StochasticSchedule{
             trigger_id: "ambient",
             next_run_at: ~U[2026-08-04 14:00:00.000000Z],
             last_run_at: nil,
             daily_count: 0,
             daily_count_date: nil
           } = schedule

    assert Repo.aggregate(StochasticSchedule, :count) == 1
    refute inspect(schedule) =~ "ambient"
    refute inspect(schedule) =~ "2026"
  end

  test "restores existing state without replacing it with a new initial run" do
    assert {:ok, initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    assert {:ok, persisted} =
             initial
             |> StochasticSchedule.changeset(%{
               last_run_at: ~U[2026-08-04 14:00:00.000000Z],
               next_run_at: ~U[2026-08-04 18:00:00.000000Z],
               daily_count: 2,
               daily_count_date: ~D[2026-08-04]
             })
             |> Repo.update()

    assert StochasticScheduleStore.restore_or_initialize(
             "ambient",
             ~U[2026-08-05 09:00:00.000000Z]
           ) == {:ok, persisted}

    assert Repo.aggregate(StochasticSchedule, :count) == 1
  end

  test "rejects invalid inputs before touching storage" do
    for {trigger_id, next_run_at} <- [
          {"invalid id", ~U[2026-08-04 14:00:00.000000Z]},
          {"ambient", nil},
          {"ambient", DateTime.new!(Date.new!(10_000, 8, 4), ~T[14:00:00.000000], "Etc/UTC")}
        ] do
      assert StochasticScheduleStore.restore_or_initialize(trigger_id, next_run_at) ==
               {:error, :invalid_schedule}
    end

    assert Repo.aggregate(StochasticSchedule, :count) == 0
  end

  test "classifies unavailable storage without exposing schedule values" do
    Repo.put_dynamic_repo(:missing_stochastic_schedule_repo)

    result =
      StochasticScheduleStore.restore_or_initialize(
        "private-trigger",
        ~U[2026-08-04 14:00:00.000000Z]
      )

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
    refute inspect(result) =~ "2026"
  end
end
