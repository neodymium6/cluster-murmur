defmodule ClusterMurmur.Persistence.ScheduleStateStoreTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Persistence.{ScheduleState, ScheduleStateClaim, ScheduleStateStore}
  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.CreateScheduleStates

  @migration_version 20_260_809_062_000
  @due ~U[2026-08-10 00:00:00.000000Z]

  setup_all do
    assert Ecto.Migrator.up(Repo, @migration_version, CreateScheduleStates,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @migration_version, CreateScheduleStates,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM schedule_states", [], log: false)
    :ok
  end

  test "initializes redacted state and restores durable state without exposing its claim" do
    assert {:ok, initial} = ScheduleStateStore.restore_or_initialize("daily-summary", @due)

    assert %ScheduleState{
             trigger_id: "daily-summary",
             next_run_at: @due,
             last_run_at: nil,
             claim_token: nil,
             claim_started_at: nil,
             claim_expires_at: nil
           } = initial

    token = Base.url_encode64(<<1::256>>, padding: false)
    claim_started_at = DateTime.add(@due, 1, :second)
    claim_expires_at = DateTime.add(@due, 61, :second)
    next_run_at = DateTime.add(@due, 1, :hour)

    assert {:ok, persisted} =
             initial
             |> ScheduleState.changeset(%{
               last_run_at: @due,
               next_run_at: next_run_at,
               claim_token: token,
               claim_started_at: claim_started_at,
               claim_expires_at: claim_expires_at
             })
             |> Repo.update()

    assert {:ok, restored} =
             ScheduleStateStore.restore_or_initialize(
               "daily-summary",
               DateTime.add(@due, 2, :hour)
             )

    assert restored.last_run_at == @due
    assert restored.next_run_at == next_run_at
    assert restored.claim_token == nil
    assert restored.claim_started_at == nil
    assert restored.claim_expires_at == nil
    assert Repo.get!(ScheduleState, "daily-summary") == persisted
    refute inspect(restored) =~ "daily-summary"
    refute inspect(restored) =~ "2026"
    refute inspect(restored) =~ token
  end

  test "rejects invalid initialization before accessing storage" do
    Repo.put_dynamic_repo(:missing_schedule_state_repo)

    for {trigger_id, next_run_at} <- [
          {"bad id", @due},
          {"daily-summary", nil},
          {"daily-summary", %{@due | hour: 24}},
          {String.duplicate("a", 20_000), @due}
        ] do
      assert ScheduleStateStore.restore_or_initialize(trigger_id, next_run_at) ==
               {:error, :invalid_schedule}
    end

    assert ScheduleStateStore.restore_or_initialize("daily-summary", @due) ==
             {:error, :storage_unavailable}
  end

  test "lists due states in deterministic bounded cursor order" do
    for number <- 0..100 do
      assert {:ok, _state} =
               ScheduleStateStore.restore_or_initialize(
                 "trigger-#{String.pad_leading(Integer.to_string(number), 3, "0")}",
                 @due
               )
    end

    assert {:ok, _future} =
             ScheduleStateStore.restore_or_initialize("future", DateTime.add(@due, 1, :second))

    assert {:ok, first_page} = ScheduleStateStore.list_due(@due)
    assert length(first_page) == 100
    assert hd(first_page).trigger_id == "trigger-000"
    assert List.last(first_page).trigger_id == "trigger-099"

    assert Enum.all?(first_page, fn state ->
             state.claim_token == nil and state.claim_started_at == nil and
               state.claim_expires_at == nil
           end)

    assert {:ok, next_page} =
             ScheduleStateStore.list_due_after(@due, {@due, "trigger-099"})

    assert Enum.map(next_page, & &1.trigger_id) == ["trigger-100"]
    refute inspect(first_page) =~ "trigger-000"
    refute inspect(first_page) =~ "2026"
  end

  test "validates due instants and cursors before accessing storage" do
    Repo.put_dynamic_repo(:missing_schedule_state_repo)

    for invalid_now <- [nil, %{@due | month: 13}, DateTime.add(@due, 0, :second)] do
      invalid_now =
        if match?(%DateTime{}, invalid_now),
          do: %{invalid_now | time_zone: "Asia/Tokyo"},
          else: invalid_now

      assert ScheduleStateStore.list_due(invalid_now) == {:error, :invalid_datetime}
    end

    assert ScheduleStateStore.list_due_after(@due, {@due, "bad id"}) ==
             {:error, :invalid_schedule}

    assert ScheduleStateStore.list_due_after(@due, :invalid) == {:error, :invalid_schedule}
    assert ScheduleStateStore.list_due(@due) == {:error, :storage_unavailable}
  end

  test "claims one exact due version with a redacted fixed lease" do
    assert {:ok, _state} = ScheduleStateStore.restore_or_initialize("daily-summary", @due)

    assert {:ok, claim} = ScheduleStateStore.claim_due("daily-summary", @due, @due)

    assert %ScheduleStateClaim{
             trigger_id: "daily-summary",
             expected_next_run_at: @due,
             token: token,
             started_at: @due,
             expires_at: expires_at
           } = claim

    assert expires_at == DateTime.add(@due, 60, :second)
    assert {:ok, decoded} = Base.url_decode64(token, padding: false)
    assert byte_size(decoded) == 32
    refute inspect(claim) =~ "daily-summary"
    refute inspect(claim) =~ token
    refute inspect(claim) =~ "2026"

    persisted = Repo.get!(ScheduleState, "daily-summary")
    assert persisted.claim_token == token
    assert persisted.claim_started_at == @due
    assert persisted.claim_expires_at == expires_at

    assert ScheduleStateStore.list_due(DateTime.add(expires_at, -1, :microsecond)) == {:ok, []}
    assert {:ok, [available]} = ScheduleStateStore.list_due(expires_at)
    assert available.trigger_id == "daily-summary"
    assert available.claim_token == nil
    assert available.claim_started_at == nil
    assert available.claim_expires_at == nil
  end

  test "rejects live, stale, and future claims and replaces an expired lease" do
    assert {:ok, _state} = ScheduleStateStore.restore_or_initialize("daily-summary", @due)
    assert {:ok, first} = ScheduleStateStore.claim_due("daily-summary", @due, @due)

    assert ScheduleStateStore.claim_due(
             "daily-summary",
             @due,
             DateTime.add(@due, 59, :second)
           ) == {:error, :schedule_conflict}

    assert {:ok, replacement} =
             ScheduleStateStore.claim_due("daily-summary", @due, DateTime.add(@due, 60, :second))

    refute replacement.token == first.token

    assert ScheduleStateStore.claim_due(
             "daily-summary",
             DateTime.add(@due, -1, :second),
             DateTime.add(@due, 120, :second)
           ) == {:error, :schedule_conflict}

    assert {:ok, _future} =
             ScheduleStateStore.restore_or_initialize("future", DateTime.add(@due, 1, :second))

    assert ScheduleStateStore.claim_due("future", DateTime.add(@due, 1, :second), @due) ==
             {:error, :schedule_conflict}
  end

  test "authorizes only one concurrent claimant" do
    assert {:ok, _state} = ScheduleStateStore.restore_or_initialize("daily-summary", @due)

    attempts =
      1..2
      |> Enum.map(fn _attempt ->
        Task.async(fn -> ScheduleStateStore.claim_due("daily-summary", @due, @due) end)
      end)
      |> Task.await_many()

    assert Enum.count(attempts, &match?({:ok, %ScheduleStateClaim{}}, &1)) == 1
    assert Enum.count(attempts, &(&1 == {:error, :schedule_conflict})) == 1
  end

  test "records one exact claimed execution and clears its lease" do
    assert {:ok, _state} = ScheduleStateStore.restore_or_initialize("daily-summary", @due)
    assert {:ok, claim} = ScheduleStateStore.claim_due("daily-summary", @due, @due)

    executed_at = DateTime.add(@due, 1, :second)
    recorded_at = DateTime.add(@due, 2, :second)
    next_run_at = DateTime.add(@due, 1, :hour)

    assert {:ok, completed} =
             ScheduleStateStore.record_execution(claim, executed_at, recorded_at, next_run_at)

    assert %ScheduleState{
             trigger_id: "daily-summary",
             last_run_at: ^executed_at,
             next_run_at: ^next_run_at,
             claim_token: nil,
             claim_started_at: nil,
             claim_expires_at: nil
           } = completed

    assert Repo.get!(ScheduleState, "daily-summary") == completed
    refute inspect(completed) =~ "daily-summary"
    refute inspect(completed) =~ claim.token
    refute inspect(completed) =~ "2026"

    assert ScheduleStateStore.record_execution(claim, executed_at, recorded_at, next_run_at) ==
             {:error, :schedule_conflict}
  end

  test "normalizes valid second-precision query and completion inputs" do
    due = DateTime.truncate(@due, :second)
    assert {:ok, _state} = ScheduleStateStore.restore_or_initialize("daily-summary", due)
    assert {:ok, [_available]} = ScheduleStateStore.list_due(due)
    assert {:ok, []} = ScheduleStateStore.list_due_after(due, {due, "daily-summary"})
    assert {:ok, claim} = ScheduleStateStore.claim_due("daily-summary", due, due)

    assert claim.expected_next_run_at.microsecond == {0, 6}
    assert claim.started_at.microsecond == {0, 6}
    assert claim.expires_at.microsecond == {0, 6}

    executed_at = DateTime.add(due, 1, :second)
    recorded_at = DateTime.add(due, 2, :second)
    next_run_at = DateTime.add(due, 1, :hour)

    assert {:ok, completed} =
             ScheduleStateStore.record_execution(claim, executed_at, recorded_at, next_run_at)

    assert completed.last_run_at.microsecond == {0, 6}
    assert completed.next_run_at.microsecond == {0, 6}
  end

  test "authorizes only one concurrent completion" do
    assert {:ok, _state} = ScheduleStateStore.restore_or_initialize("daily-summary", @due)
    assert {:ok, claim} = ScheduleStateStore.claim_due("daily-summary", @due, @due)
    executed_at = DateTime.add(@due, 1, :second)
    recorded_at = DateTime.add(@due, 2, :second)
    next_run_at = DateTime.add(@due, 1, :hour)

    attempts =
      1..2
      |> Enum.map(fn _attempt ->
        Task.async(fn ->
          ScheduleStateStore.record_execution(claim, executed_at, recorded_at, next_run_at)
        end)
      end)
      |> Task.await_many()

    assert Enum.count(attempts, &match?({:ok, %ScheduleState{}}, &1)) == 1
    assert Enum.count(attempts, &(&1 == {:error, :schedule_conflict})) == 1
  end

  test "prevents an expired claim from completing a replacement lease" do
    assert {:ok, _state} = ScheduleStateStore.restore_or_initialize("daily-summary", @due)
    assert {:ok, first} = ScheduleStateStore.claim_due("daily-summary", @due, @due)

    assert {:ok, replacement} =
             ScheduleStateStore.claim_due("daily-summary", @due, DateTime.add(@due, 60, :second))

    assert ScheduleStateStore.record_execution(
             first,
             DateTime.add(@due, 1, :second),
             DateTime.add(@due, 2, :second),
             DateTime.add(@due, 1, :hour)
           ) == {:error, :schedule_conflict}

    persisted = Repo.get!(ScheduleState, "daily-summary")
    assert persisted.claim_token == replacement.token
    assert persisted.claim_started_at == replacement.started_at
    assert persisted.claim_expires_at == replacement.expires_at
  end

  test "rejects invalid completions before storage and classifies unavailable writes" do
    Repo.put_dynamic_repo(:missing_schedule_state_repo)
    claim = claim_fixture()
    executed_at = DateTime.add(@due, 1, :second)
    recorded_at = DateTime.add(@due, 2, :second)
    next_run_at = DateTime.add(@due, 1, :hour)

    invalid = [
      {nil, executed_at, recorded_at, next_run_at},
      {%{claim | trigger_id: "bad id"}, executed_at, recorded_at, next_run_at},
      {%{claim | token: "invalid"}, executed_at, recorded_at, next_run_at},
      {%{claim | token: String.duplicate("A", 1_000_000)}, executed_at, recorded_at, next_run_at},
      {%{claim | started_at: %{@due | hour: 24}}, executed_at, recorded_at, next_run_at},
      {%{claim | expires_at: DateTime.add(@due, 59, :second)}, executed_at, recorded_at,
       next_run_at},
      {%{claim | expected_next_run_at: DateTime.add(@due, 1, :second)}, executed_at, recorded_at,
       next_run_at},
      {Map.put(claim, :private, "private"), executed_at, recorded_at, next_run_at},
      {claim, nil, recorded_at, next_run_at},
      {claim, DateTime.add(@due, -1, :second), recorded_at, next_run_at},
      {claim, executed_at, @due, next_run_at},
      {claim, executed_at, executed_at, executed_at},
      {claim, executed_at, claim.expires_at, next_run_at}
    ]

    for arguments <- invalid do
      assert apply(ScheduleStateStore, :record_execution, Tuple.to_list(arguments)) ==
               {:error, :invalid_schedule}
    end

    result =
      ScheduleStateStore.record_execution(claim, executed_at, recorded_at, next_run_at)

    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "daily-summary"
    refute inspect(result) =~ claim.token
  end

  test "rejects invalid claims before storage and classifies unavailable writes" do
    Repo.put_dynamic_repo(:missing_schedule_state_repo)

    for {trigger_id, expected_next_run_at, claimed_at} <- [
          {"bad id", @due, @due},
          {"daily-summary", nil, @due},
          {"daily-summary", @due, nil},
          {"daily-summary", @due, ~U[9999-12-31 23:59:59.000000Z]}
        ] do
      assert ScheduleStateStore.claim_due(trigger_id, expected_next_run_at, claimed_at) ==
               {:error, :invalid_schedule}
    end

    result = ScheduleStateStore.claim_due("private-trigger", @due, @due)
    assert result == {:error, :storage_unavailable}
    refute inspect(result) =~ "private"
  end

  defp claim_fixture do
    %ScheduleStateClaim{
      trigger_id: "daily-summary",
      expected_next_run_at: @due,
      token: Base.url_encode64(<<1::256>>, padding: false),
      started_at: @due,
      expires_at: DateTime.add(@due, 60, :second)
    }
  end
end
