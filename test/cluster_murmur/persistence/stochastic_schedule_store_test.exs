defmodule ClusterMurmur.Persistence.StochasticScheduleStoreTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Persistence.{
    StochasticSchedule,
    StochasticScheduleClaim,
    StochasticScheduleRetirement,
    StochasticScheduleStore
  }

  alias ClusterMurmur.Repo

  alias ClusterMurmur.Repo.Migrations.{
    AddStochasticScheduleClaims,
    CreateStochasticSchedules
  }

  @claim_migration_version 20_260_804_160_000
  @schedule_migration_version 20_260_804_130_000

  setup_all do
    assert Ecto.Migrator.up(Repo, @schedule_migration_version, CreateStochasticSchedules,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    assert Ecto.Migrator.up(Repo, @claim_migration_version, AddStochasticScheduleClaims,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @claim_migration_version, AddStochasticScheduleClaims,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )

      Ecto.Migrator.down(Repo, @schedule_migration_version, CreateStochasticSchedules,
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
          {"ambient", %{~U[2026-08-04 14:00:00.000000Z] | hour: 24}},
          {"ambient",
           Map.put(
             ~U[2026-08-04 14:00:00.000000Z],
             :unexpected_private_value,
             "private"
           )},
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

  test "retires only schedules absent from the bounded active set" do
    for trigger_id <- ["active", "stale-a", "stale-b"] do
      assert {:ok, _schedule} =
               StochasticScheduleStore.restore_or_initialize(
                 trigger_id,
                 ~U[2026-08-04 14:00:00.000000Z]
               )
    end

    assert StochasticScheduleStore.retire_unconfigured(["active"]) ==
             {:ok, %StochasticScheduleRetirement{retired_count: 2, saturated?: false}}

    assert Repo.all(StochasticSchedule) |> Enum.map(& &1.trigger_id) == ["active"]
  end

  test "retires stale claimed schedules while preserving configured live claims" do
    for {trigger_id, next_run_at} <- [
          {"active", ~U[2026-08-04 14:00:00.000000Z]},
          {"stale-expired", ~U[2026-08-04 13:00:00.000000Z]},
          {"stale-live", ~U[2026-08-04 14:00:00.000000Z]}
        ] do
      assert {:ok, _schedule} =
               StochasticScheduleStore.restore_or_initialize(trigger_id, next_run_at)
    end

    active_claim =
      claim_due!(
        "active",
        ~U[2026-08-04 14:00:00.000000Z],
        ~U[2026-08-04 14:00:00.000000Z]
      )

    _expired_claim =
      claim_due!(
        "stale-expired",
        ~U[2026-08-04 13:00:00.000000Z],
        ~U[2026-08-04 13:00:00.000000Z]
      )

    _live_claim =
      claim_due!(
        "stale-live",
        ~U[2026-08-04 14:00:00.000000Z],
        ~U[2026-08-04 14:00:00.000000Z]
      )

    assert StochasticScheduleStore.retire_unconfigured(["active"]) ==
             {:ok, %StochasticScheduleRetirement{retired_count: 2, saturated?: false}}

    assert %StochasticSchedule{claim_token: token} = Repo.get!(StochasticSchedule, "active")
    assert token == active_claim.token
    assert Repo.get(StochasticSchedule, "stale-expired") == nil
    assert Repo.get(StochasticSchedule, "stale-live") == nil
  end

  test "retires one deterministic page and reports remaining stale schedules" do
    for number <- 0..100 do
      assert {:ok, _schedule} =
               StochasticScheduleStore.restore_or_initialize(
                 "stale-#{String.pad_leading(Integer.to_string(number), 3, "0")}",
                 ~U[2026-08-04 14:00:00.000000Z]
               )
    end

    assert StochasticScheduleStore.retire_unconfigured([]) ==
             {:ok, %StochasticScheduleRetirement{retired_count: 100, saturated?: true}}

    assert Repo.all(StochasticSchedule) |> Enum.map(& &1.trigger_id) == ["stale-100"]

    assert StochasticScheduleStore.retire_unconfigured([]) ==
             {:ok, %StochasticScheduleRetirement{retired_count: 1, saturated?: false}}
  end

  test "rejects malformed retirement allowlists before touching storage" do
    Repo.put_dynamic_repo(:missing_stochastic_schedule_repo)

    for active_ids <- [
          :private,
          ["invalid id"],
          ["duplicate", "duplicate"],
          ["valid" | :improper],
          Enum.map(0..256, &"trigger-#{&1}")
        ] do
      assert StochasticScheduleStore.retire_unconfigured(active_ids) ==
               {:error, :invalid_schedule}
    end
  end

  test "classifies unavailable retirement storage without exposing trigger IDs" do
    Repo.put_dynamic_repo(:missing_stochastic_schedule_repo)

    result = StochasticScheduleStore.retire_unconfigured(["private-trigger"])
    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
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

    assert {:ok, remaining} =
             StochasticScheduleStore.list_due_after(
               ~U[2026-08-04 14:00:00.000000Z],
               {~U[2026-08-04 14:00:00.000000Z], "trigger-099"}
             )

    assert Enum.map(remaining, & &1.trigger_id) == ["trigger-100"]
  end

  test "rejects malformed due-page cursors before reading storage" do
    Repo.put_dynamic_repo(:missing_stochastic_schedule_repo)

    assert StochasticScheduleStore.list_due_after(
             ~U[2026-08-04 14:00:00.000000Z],
             {~U[2026-08-04 14:00:00.000000Z], ""}
           ) == {:error, :invalid_schedule}

    assert StochasticScheduleStore.list_due_after(
             ~U[2026-08-04 14:00:00.000000Z],
             :not_a_cursor
           ) == {:error, :invalid_schedule}
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

  test "claims one due schedule with a redacted fixed lease" do
    assert {:ok, _initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    assert {:ok, claim} =
             StochasticScheduleStore.claim_due(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z],
               ~U[2026-08-04 14:00:01.000000Z]
             )

    assert %StochasticScheduleClaim{
             trigger_id: "ambient",
             expected_next_run_at: ~U[2026-08-04 14:00:00.000000Z],
             token: token,
             started_at: ~U[2026-08-04 14:00:01.000000Z],
             expires_at: ~U[2026-08-04 14:01:01.000000Z]
           } = claim

    assert {:ok, decoded_token} = Base.url_decode64(token, padding: false)
    assert byte_size(decoded_token) == 32
    refute inspect(claim) =~ "ambient"
    refute inspect(claim) =~ token
    refute inspect(claim) =~ "2026"

    claim_expires_at = claim.expires_at
    claim_started_at = claim.started_at

    assert %StochasticSchedule{
             claim_token: ^token,
             claim_started_at: ^claim_started_at,
             claim_expires_at: ^claim_expires_at
           } =
             Repo.get!(StochasticSchedule, "ambient")

    assert {:ok, restored} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-05 14:00:00.000000Z]
             )

    assert restored.claim_token == nil
    assert restored.claim_started_at == nil
    assert restored.claim_expires_at == nil

    assert %StochasticSchedule{
             claim_token: ^token,
             claim_started_at: ^claim_started_at,
             claim_expires_at: ^claim_expires_at
           } =
             Repo.get!(StochasticSchedule, "ambient")

    assert StochasticScheduleStore.list_due(~U[2026-08-04 14:01:00.999999Z]) == {:ok, []}

    assert {:ok, [available]} =
             StochasticScheduleStore.list_due(~U[2026-08-04 14:01:01.000000Z])

    assert available.trigger_id == "ambient"
    assert available.claim_token == nil
    assert available.claim_started_at == nil
    assert available.claim_expires_at == nil
  end

  test "atomically rejects duplicate claims and replaces only an expired lease" do
    assert {:ok, _initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    first =
      claim_due!("ambient", ~U[2026-08-04 14:00:00.000000Z], ~U[2026-08-04 14:00:00.000000Z])

    assert StochasticScheduleStore.claim_due(
             "ambient",
             ~U[2026-08-04 14:00:00.000000Z],
             ~U[2026-08-04 14:00:59.999999Z]
           ) == {:error, :schedule_conflict}

    assert {:ok, second} =
             StochasticScheduleStore.claim_due(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z],
               ~U[2026-08-04 14:01:00.000000Z]
             )

    refute second.token == first.token

    assert StochasticScheduleStore.record_execution(
             first,
             ~U[2026-08-04 14:00:30.000000Z],
             ~U[2026-08-04 14:00:30.000000Z],
             ~U[2026-08-04 18:00:00.000000Z],
             nil
           ) == {:error, :schedule_conflict}
  end

  test "authorizes only one of two concurrent claim attempts" do
    assert {:ok, _initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    attempts =
      for _attempt <- 1..2 do
        Task.async(fn ->
          StochasticScheduleStore.claim_due(
            "ambient",
            ~U[2026-08-04 14:00:00.000000Z],
            ~U[2026-08-04 14:00:00.000000Z]
          )
        end)
      end
      |> Task.await_many()

    assert Enum.count(attempts, &match?({:ok, %StochasticScheduleClaim{}}, &1)) == 1
    assert Enum.count(attempts, &(&1 == {:error, :schedule_conflict})) == 1
  end

  test "rejects invalid or unavailable claims before exposing values" do
    invalid = [
      {"invalid id", ~U[2026-08-04 14:00:00.000000Z], ~U[2026-08-04 14:00:00.000000Z]},
      {"ambient", nil, ~U[2026-08-04 14:00:00.000000Z]},
      {"ambient", ~U[2026-08-04 14:00:00.000000Z], nil},
      {"ambient", ~U[2026-08-04 14:00:00.000000Z],
       DateTime.new!(~D[9999-12-31], ~T[23:59:59.000000], "Etc/UTC")}
    ]

    for arguments <- invalid do
      assert apply(StochasticScheduleStore, :claim_due, Tuple.to_list(arguments)) ==
               {:error, :invalid_schedule}
    end

    Repo.put_dynamic_repo(:missing_stochastic_schedule_repo)

    result =
      StochasticScheduleStore.claim_due(
        "private-trigger",
        ~U[2026-08-04 14:00:00.000000Z],
        ~U[2026-08-04 14:00:00.000000Z]
      )

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
  end

  test "records a completed due execution and advances its next run" do
    assert {:ok, _initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    claim =
      claim_due!(
        "ambient",
        ~U[2026-08-04 14:00:00.000000Z],
        ~U[2026-08-04 14:00:00.000000Z]
      )

    assert {:ok, advanced} =
             StochasticScheduleStore.record_execution(
               claim,
               ~U[2026-08-04 14:00:01.000000Z],
               ~U[2026-08-04 14:00:01.000000Z],
               ~U[2026-08-04 18:00:00.000000Z],
               nil
             )

    assert %StochasticSchedule{
             last_run_at: ~U[2026-08-04 14:00:01.000000Z],
             next_run_at: ~U[2026-08-04 18:00:00.000000Z],
             daily_count: 0,
             daily_count_date: nil,
             claim_token: nil,
             claim_started_at: nil,
             claim_expires_at: nil
           } = advanced
  end

  test "increments and rolls over local-date execution buckets" do
    assert {:ok, _initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    first_claim =
      claim_due!(
        "ambient",
        ~U[2026-08-04 14:00:00.000000Z],
        ~U[2026-08-04 14:00:00.000000Z]
      )

    assert {:ok, first} =
             StochasticScheduleStore.record_execution(
               first_claim,
               ~U[2026-08-04 14:00:01.000000Z],
               ~U[2026-08-04 14:00:01.000000Z],
               ~U[2026-08-04 16:00:00.000000Z],
               ~D[2026-08-04]
             )

    assert first.daily_count == 1
    assert first.daily_count_date == ~D[2026-08-04]

    second_claim =
      claim_due!(
        "ambient",
        ~U[2026-08-04 16:00:00.000000Z],
        ~U[2026-08-04 16:00:00.000000Z]
      )

    assert {:ok, second} =
             StochasticScheduleStore.record_execution(
               second_claim,
               ~U[2026-08-04 16:00:01.000000Z],
               ~U[2026-08-04 16:00:01.000000Z],
               ~U[2026-08-05 01:00:00.000000Z],
               ~D[2026-08-04]
             )

    assert second.daily_count == 2
    assert second.daily_count_date == ~D[2026-08-04]

    third_claim =
      claim_due!(
        "ambient",
        ~U[2026-08-05 01:00:00.000000Z],
        ~U[2026-08-05 01:00:00.000000Z]
      )

    assert {:ok, third} =
             StochasticScheduleStore.record_execution(
               third_claim,
               ~U[2026-08-05 01:00:01.000000Z],
               ~U[2026-08-05 01:00:01.000000Z],
               ~U[2026-08-05 08:00:00.000000Z],
               ~D[2026-08-05]
             )

    assert third.daily_count == 1
    assert third.daily_count_date == ~D[2026-08-05]
  end

  test "does not claim stale or not-yet-due schedule versions" do
    assert {:ok, initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    for {expected_next_run_at, claimed_at} <- [
          {~U[2026-08-04 13:00:00.000000Z], ~U[2026-08-04 14:00:01.000000Z]},
          {~U[2026-08-04 14:00:00.000000Z], ~U[2026-08-04 13:59:59.000000Z]}
        ] do
      assert StochasticScheduleStore.claim_due(
               "ambient",
               expected_next_run_at,
               claimed_at
             ) == {:error, :schedule_conflict}
    end

    assert Repo.get!(StochasticSchedule, "ambient") == initial
  end

  test "rejects execution before claim and completion recorded after expiry" do
    assert {:ok, _initial} =
             StochasticScheduleStore.restore_or_initialize(
               "ambient",
               ~U[2026-08-04 14:00:00.000000Z]
             )

    claim =
      claim_due!(
        "ambient",
        ~U[2026-08-04 14:00:00.000000Z],
        ~U[2026-08-04 14:00:00.000000Z]
      )

    claimed_schedule = Repo.get!(StochasticSchedule, "ambient")

    for {executed_at, recorded_at} <- [
          {~U[2026-08-04 13:59:59.999999Z], ~U[2026-08-04 14:00:01.000000Z]},
          {~U[2026-08-04 14:00:30.000000Z], ~U[2026-08-04 14:01:00.000000Z]}
        ] do
      assert StochasticScheduleStore.record_execution(
               claim,
               executed_at,
               recorded_at,
               ~U[2026-08-04 18:00:00.000000Z],
               nil
             ) == {:error, :schedule_conflict}
    end

    assert Repo.get!(StochasticSchedule, "ambient") == claimed_schedule
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

    claim =
      claim_due!(
        "ambient",
        ~U[2026-08-04 14:00:00.000000Z],
        ~U[2026-08-04 14:00:00.000000Z]
      )

    claimed_schedule = Repo.get!(StochasticSchedule, "ambient")

    assert StochasticScheduleStore.record_execution(
             claim,
             ~U[2026-08-04 14:00:01.000000Z],
             ~U[2026-08-04 14:00:01.000000Z],
             ~U[2026-08-04 18:00:00.000000Z],
             ~D[2026-08-04]
           ) == {:error, :daily_limit_reached}

    refute claimed_schedule == full_bucket
    assert Repo.get!(StochasticSchedule, "ambient") == claimed_schedule
  end

  test "rejects invalid execution records before accessing storage" do
    Repo.put_dynamic_repo(:missing_stochastic_schedule_repo)
    claim = claim_fixture()
    executed_at = ~U[2026-08-04 14:00:01.000000Z]
    next_run_at = ~U[2026-08-04 18:00:00.000000Z]

    invalid = [
      {nil, executed_at, executed_at, next_run_at, nil},
      {%{claim | trigger_id: "invalid id"}, executed_at, executed_at, next_run_at, nil},
      {%{claim | token: "invalid"}, executed_at, executed_at, next_run_at, nil},
      {claim, nil, executed_at, next_run_at, nil},
      {claim, executed_at, nil, next_run_at, nil},
      {claim, executed_at, executed_at, executed_at, nil},
      {claim, executed_at, executed_at, next_run_at, %{~D[2026-08-04] | month: 13}},
      {claim, executed_at, executed_at, next_run_at, %{~D[2026-08-04] | month: :invalid}}
    ]

    for arguments <- invalid do
      assert apply(StochasticScheduleStore, :record_execution, Tuple.to_list(arguments)) ==
               {:error, :invalid_schedule}
    end
  end

  test "classifies unavailable execution writes" do
    Repo.put_dynamic_repo(:missing_stochastic_schedule_repo)

    assert StochasticScheduleStore.record_execution(
             claim_fixture("private-trigger"),
             ~U[2026-08-04 14:00:01.000000Z],
             ~U[2026-08-04 14:00:01.000000Z],
             ~U[2026-08-04 18:00:00.000000Z],
             nil
           ) == {:error, :storage_unavailable}
  end

  defp claim_due!(trigger_id, expected_next_run_at, claimed_at) do
    assert {:ok, claim} =
             StochasticScheduleStore.claim_due(trigger_id, expected_next_run_at, claimed_at)

    claim
  end

  defp claim_fixture(trigger_id \\ "ambient") do
    %StochasticScheduleClaim{
      trigger_id: trigger_id,
      expected_next_run_at: ~U[2026-08-04 14:00:00.000000Z],
      token: Base.url_encode64(:binary.copy(<<1>>, 32), padding: false),
      started_at: ~U[2026-08-04 14:00:00.000000Z],
      expires_at: ~U[2026-08-04 14:01:00.000000Z]
    }
  end
end
