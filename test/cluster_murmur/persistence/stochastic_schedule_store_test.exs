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

  test "lists due schedules in deterministic order without returning future rows" do
    for {trigger_id, next_run_at} <- [
          {"later", ~U[2026-08-04 14:00:01.000000Z]},
          {"same-b", ~U[2026-08-04 14:00:00.000000Z]},
          {"same-a", ~U[2026-08-04 14:00:00.000000Z]},
          {"earlier", ~U[2026-08-04 13:59:59.000000Z]}
        ] do
      assert {:ok, _schedule} =
               StochasticScheduleStore.restore_or_initialize(trigger_id, next_run_at)
    end

    assert {:ok, schedules} =
             StochasticScheduleStore.list_due(~U[2026-08-04 14:00:00.000000Z])

    assert Enum.map(schedules, & &1.trigger_id) == ["earlier", "same-a", "same-b"]
    refute inspect(schedules) =~ "earlier"
    refute inspect(schedules) =~ "2026"
  end

  test "bounds each due-schedule read" do
    for number <- 0..100 do
      assert {:ok, _schedule} =
               StochasticScheduleStore.restore_or_initialize(
                 "trigger-#{String.pad_leading(Integer.to_string(number), 3, "0")}",
                 ~U[2026-08-04 14:00:00.000000Z]
               )
    end

    assert {:ok, schedules} =
             StochasticScheduleStore.list_due(~U[2026-08-04 14:00:00.000000Z])

    assert length(schedules) == 100
    assert hd(schedules).trigger_id == "trigger-000"
    assert List.last(schedules).trigger_id == "trigger-099"
  end

  test "rejects noncanonical due instants before reading storage" do
    Repo.put_dynamic_repo(:missing_stochastic_schedule_repo)

    invalid = [
      nil,
      DateTime.new!(Date.new!(10_000, 8, 4), ~T[14:00:00.000000], "Etc/UTC"),
      DateTime.new!(~D[2026-08-04], ~T[14:00:00.000000], "Asia/Tokyo"),
      %{~U[2026-08-04 14:00:00.000000Z] | hour: 24}
    ]

    for now <- invalid do
      assert StochasticScheduleStore.list_due(now) == {:error, :invalid_datetime}
    end
  end

  test "classifies unavailable due reads" do
    Repo.put_dynamic_repo(:missing_stochastic_schedule_repo)

    assert StochasticScheduleStore.list_due(~U[2026-08-04 14:00:00.000000Z]) ==
             {:error, :storage_unavailable}
  end

  test "records a completed due execution and advances its next run" do
    assert {:ok, _initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    assert {:ok, advanced} =
             StochasticScheduleStore.record_execution(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z],
               ~U[2026-08-04 14:00:01.000000Z],
               ~U[2026-08-04 18:00:00.000000Z],
               nil
             )

    assert %StochasticSchedule{
             last_run_at: ~U[2026-08-04 14:00:01.000000Z],
             next_run_at: ~U[2026-08-04 18:00:00.000000Z],
             daily_count: 0,
             daily_count_date: nil
           } = advanced
  end

  test "increments and rolls over local-date execution buckets" do
    assert {:ok, _initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    assert {:ok, first} =
             StochasticScheduleStore.record_execution(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z],
               ~U[2026-08-04 14:00:01.000000Z],
               ~U[2026-08-04 16:00:00.000000Z],
               ~D[2026-08-04]
             )

    assert first.daily_count == 1
    assert first.daily_count_date == ~D[2026-08-04]

    assert {:ok, second} =
             StochasticScheduleStore.record_execution(
               "ambient",
               ~U[2026-08-04 16:00:00.000000Z],
               ~U[2026-08-04 16:00:01.000000Z],
               ~U[2026-08-05 01:00:00.000000Z],
               ~D[2026-08-04]
             )

    assert second.daily_count == 2
    assert second.daily_count_date == ~D[2026-08-04]

    assert {:ok, third} =
             StochasticScheduleStore.record_execution(
               "ambient",
               ~U[2026-08-05 01:00:00.000000Z],
               ~U[2026-08-05 01:00:01.000000Z],
               ~U[2026-08-05 08:00:00.000000Z],
               ~D[2026-08-05]
             )

    assert third.daily_count == 1
    assert third.daily_count_date == ~D[2026-08-05]
  end

  test "does not mutate stale or not-yet-due schedule versions" do
    assert {:ok, initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    for {expected_next_run_at, executed_at} <- [
          {~U[2026-08-04 13:00:00.000000Z], ~U[2026-08-04 14:00:01.000000Z]},
          {~U[2026-08-04 14:00:00.000000Z], ~U[2026-08-04 13:59:59.000000Z]}
        ] do
      assert StochasticScheduleStore.record_execution(
               "ambient",
               expected_next_run_at,
               executed_at,
               ~U[2026-08-04 18:00:00.000000Z],
               nil
             ) == {:error, :schedule_conflict}
    end

    assert Repo.get!(StochasticSchedule, "ambient") == initial
  end

  test "refuses to overflow a persisted daily bucket" do
    assert {:ok, initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    assert {:ok, full_bucket} =
             initial
             |> StochasticSchedule.changeset(%{
               daily_count: 10_000,
               daily_count_date: ~D[2026-08-04]
             })
             |> Repo.update()

    assert StochasticScheduleStore.record_execution(
             "ambient",
             ~U[2026-08-04 14:00:00.000000Z],
             ~U[2026-08-04 14:00:01.000000Z],
             ~U[2026-08-04 18:00:00.000000Z],
             ~D[2026-08-04]
           ) == {:error, :daily_limit_reached}

    assert Repo.get!(StochasticSchedule, "ambient") == full_bucket
  end

  test "rejects invalid execution records before accessing storage" do
    Repo.put_dynamic_repo(:missing_stochastic_schedule_repo)

    invalid = [
      {"invalid id", ~U[2026-08-04 14:00:00.000000Z], ~U[2026-08-04 14:00:01.000000Z],
       ~U[2026-08-04 18:00:00.000000Z], nil},
      {"ambient", nil, ~U[2026-08-04 14:00:01.000000Z], ~U[2026-08-04 18:00:00.000000Z], nil},
      {"ambient", ~U[2026-08-04 14:00:00.000000Z], ~U[2026-08-04 14:00:01.000000Z],
       ~U[2026-08-04 14:00:01.000000Z], nil},
      {"ambient", ~U[2026-08-04 14:00:00.000000Z], ~U[2026-08-04 14:00:01.000000Z],
       ~U[2026-08-04 18:00:00.000000Z], %{~D[2026-08-04] | month: 13}},
      {"ambient", ~U[2026-08-04 14:00:00.000000Z], ~U[2026-08-04 14:00:01.000000Z],
       ~U[2026-08-04 18:00:00.000000Z], %{~D[2026-08-04] | month: :invalid}}
    ]

    for arguments <- invalid do
      assert apply(StochasticScheduleStore, :record_execution, Tuple.to_list(arguments)) ==
               {:error, :invalid_schedule}
    end
  end

  test "classifies unavailable execution writes" do
    Repo.put_dynamic_repo(:missing_stochastic_schedule_repo)

    assert StochasticScheduleStore.record_execution(
             "private-trigger",
             ~U[2026-08-04 14:00:00.000000Z],
             ~U[2026-08-04 14:00:01.000000Z],
             ~U[2026-08-04 18:00:00.000000Z],
             nil
           ) == {:error, :storage_unavailable}
  end
end
