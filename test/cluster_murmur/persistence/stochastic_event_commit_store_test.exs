defmodule ClusterMurmur.Persistence.StochasticEventCommitStoreTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Persistence.{
    EventRecord,
    EventStore,
    StochasticEventCommitStore,
    StochasticSchedule,
    StochasticScheduleStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Triggers.{EmittedEvent, EmittedEventProjector}
  alias ClusterMurmur.Triggers.StochasticExecutionPlanner.Plan

  alias ClusterMurmur.Repo.Migrations.{
    AddStochasticScheduleClaims,
    CreateEvents,
    CreateStochasticSchedules
  }

  @schedule_version 20_260_804_130_000
  @claim_version 20_260_804_160_000
  @event_version 20_260_804_180_500
  @scheduled_at ~U[2026-08-08 13:00:00.000000Z]
  @executed_at ~U[2026-08-08 13:00:01.000000Z]
  @recorded_at ~U[2026-08-08 13:00:02.000000Z]
  @next_run_at ~U[2026-08-08 14:00:00.000000Z]

  setup_all do
    migrations = [
      {@schedule_version, CreateStochasticSchedules},
      {@claim_version, AddStochasticScheduleClaims},
      {@event_version, CreateEvents}
    ]

    for {version, migration} <- migrations do
      assert Ecto.Migrator.up(Repo, version, migration,
               log: false,
               log_migrations_sql: false,
               log_migrator_sql: false
             ) == :ok
    end

    on_exit(fn ->
      for {version, migration} <- Enum.reverse(migrations) do
        Ecto.Migrator.down(Repo, version, migration,
          log: false,
          log_migrations_sql: false,
          log_migrator_sql: false
        )
      end
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM stochastic_schedules", [], log: false)
    :ok
  end

  test "commits an idempotent event and claimed next run in one transaction" do
    {plan, event} = claimed_plan(template())

    assert {:ok, result} = StochasticEventCommitStore.commit(plan, event, @recorded_at)
    assert result.event.id == event.id
    assert result.schedule.next_run_at == @next_run_at
    assert result.schedule.last_run_at == @executed_at
    assert result.schedule.claim_token == nil
    assert Repo.aggregate(EventRecord, :count) == 1
    refute inspect(result) =~ "ambient"
    refute inspect(result) =~ "2026"
  end

  test "restores an identical precommitted event before advancing the schedule" do
    {plan, event} = claimed_plan(template())
    assert {:ok, existing} = EventStore.insert(event)

    assert {:ok, result} = StochasticEventCommitStore.commit(plan, event, @recorded_at)
    assert result.event == existing
    assert result.schedule.next_run_at == @next_run_at
    assert Repo.aggregate(EventRecord, :count) == 1
  end

  test "rolls back event insertion when schedule advancement conflicts" do
    {plan, event} = claimed_plan(template())
    stale_token = Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)
    stale_plan = %{plan | claim: %{plan.claim | token: stale_token}}

    assert StochasticEventCommitStore.commit(stale_plan, event, @recorded_at) ==
             {:error, :stochastic_event_conflict}

    assert Repo.aggregate(EventRecord, :count) == 0

    persisted = Repo.get!(StochasticSchedule, "ambient")
    assert persisted.next_run_at == @scheduled_at
    assert persisted.claim_token == plan.claim.token
  end

  test "rejects malformed nested plans and past next runs before insertion" do
    {plan, event} = claimed_plan(template())

    invalid = [
      %{plan | claim: nil},
      %{plan | claim: Map.put(plan.claim, :private, true)},
      %{plan | executed_at: nil},
      %{plan | next_run_at: @executed_at},
      %{plan | local_date: "2026-08-08"}
    ]

    for invalid_plan <- invalid do
      assert StochasticEventCommitStore.commit(invalid_plan, event, @recorded_at) ==
               {:error, :invalid_stochastic_event_commit}
    end

    assert Repo.aggregate(EventRecord, :count) == 0
  end

  test "does not advance a claim when template drift conflicts with an existing event" do
    {original_plan, original_event} = claimed_plan(template())
    assert {:ok, _record} = EventStore.insert(original_event)

    changed = %{template() | subject: "changed-ambient"}
    changed_plan = %{original_plan | event: changed}
    assert {:ok, changed_event} = project(changed_plan)
    assert changed_event.id == original_event.id

    assert StochasticEventCommitStore.commit(changed_plan, changed_event, @recorded_at) ==
             {:error, :stochastic_event_conflict}

    persisted = Repo.get!(StochasticSchedule, "ambient")
    assert persisted.next_run_at == @scheduled_at
    assert persisted.claim_token == original_plan.claim.token
  end

  defp claimed_plan(event_template) do
    assert {:ok, _schedule} =
             StochasticScheduleStore.restore_or_initialize("ambient", @scheduled_at)

    assert {:ok, claim} =
             StochasticScheduleStore.claim_due("ambient", @scheduled_at, @scheduled_at)

    plan = %Plan{
      claim: claim,
      event: event_template,
      executed_at: @executed_at,
      next_run_at: @next_run_at,
      local_date: nil
    }

    assert {:ok, event} = project(plan)
    {plan, event}
  end

  defp project(plan) do
    EmittedEventProjector.project(
      :stochastic,
      plan.claim.trigger_id,
      plan.event,
      plan.claim.expected_next_run_at
    )
  end

  defp template do
    %EmittedEvent{type: "stochastic.fired", group: "social", subject: "ambient"}
  end
end
