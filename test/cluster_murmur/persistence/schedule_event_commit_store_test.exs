defmodule ClusterMurmur.Persistence.ScheduleEventCommitStoreTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Persistence.{
    EventDispatch,
    EventDispatchStore,
    EventRecord,
    EventStore,
    ScheduleEventCommitStore,
    ScheduleState,
    ScheduleStateStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Triggers.{EmittedEvent, EmittedEventProjector}
  alias ClusterMurmur.Triggers.ScheduleExecutionPlanner.Plan

  alias ClusterMurmur.Repo.Migrations.{
    CreateEventDispatches,
    CreateEvents,
    CreateScheduleStates
  }

  @schedule_version 20_260_809_062_000
  @event_version 20_260_804_180_500
  @dispatch_version 20_260_808_150_000
  @scheduled_at ~U[2026-08-10 13:00:00.000000Z]
  @executed_at ~U[2026-08-10 13:00:01.000000Z]
  @recorded_at ~U[2026-08-10 13:00:02.000000Z]
  @next_run_at ~U[2026-08-10 14:00:00Z]

  setup_all do
    migrations = [
      {@event_version, CreateEvents},
      {@dispatch_version, CreateEventDispatches},
      {@schedule_version, CreateScheduleStates}
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
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM event_dispatches", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM schedule_states", [], log: false)
    :ok
  end

  test "commits an idempotent event, dispatch handoff, and next state atomically" do
    {plan, event} = claimed_plan(template())

    assert {:ok, result} = ScheduleEventCommitStore.commit(plan, event, @recorded_at)
    assert result.event.id == event.id
    assert result.dispatch.event_id == event.id
    assert result.dispatch.status == :pending
    assert result.dispatch.enqueued_at == @recorded_at
    refute Map.has_key?(result.dispatch, :claim_token)
    assert DateTime.compare(result.state.next_run_at, @next_run_at) == :eq
    assert result.state.last_run_at == @executed_at
    assert result.state.claim_token == nil
    assert Repo.aggregate(EventRecord, :count) == 1
    assert Repo.aggregate(EventDispatch, :count) == 1
    refute inspect(result) =~ "daily-summary"
    refute inspect(result) =~ plan.claim.token
    refute inspect(result) =~ "2026"
  end

  test "restores identical precommitted event and dispatch before advancing" do
    {plan, event} = claimed_plan(template())
    assert {:ok, existing} = EventStore.insert(event)
    assert {:ok, existing_dispatch} = EventDispatchStore.enqueue(event, @recorded_at)

    assert {:ok, result} = ScheduleEventCommitStore.commit(plan, event, @recorded_at)
    assert result.event == existing
    assert result.dispatch == existing_dispatch
    assert DateTime.compare(result.state.next_run_at, @next_run_at) == :eq
    assert Repo.aggregate(EventRecord, :count) == 1
    assert Repo.aggregate(EventDispatch, :count) == 1
  end

  test "accepts a canonical second-precision record instant" do
    {plan, event} = claimed_plan(template())
    recorded_at = ~U[2026-08-10 13:00:02Z]

    assert {:ok, result} = ScheduleEventCommitStore.commit(plan, event, recorded_at)
    assert DateTime.compare(result.dispatch.enqueued_at, recorded_at) == :eq
    assert DateTime.compare(result.state.last_run_at, @executed_at) == :eq
  end

  test "rolls back new event and dispatch when schedule completion conflicts" do
    {plan, event} = claimed_plan(template())
    stale_token = Base.url_encode64(<<7::256>>, padding: false)
    stale_plan = %{plan | claim: %{plan.claim | token: stale_token}}

    assert ScheduleEventCommitStore.commit(stale_plan, event, @recorded_at) ==
             {:error, :schedule_event_conflict}

    assert Repo.aggregate(EventRecord, :count) == 0
    assert Repo.aggregate(EventDispatch, :count) == 0
    persisted = Repo.get!(ScheduleState, "daily-summary")
    assert persisted.next_run_at == @scheduled_at
    assert persisted.claim_token == plan.claim.token
  end

  test "does not advance when an existing dispatch has another enqueue instant" do
    {plan, event} = claimed_plan(template())
    later = DateTime.add(@recorded_at, 1, :second)
    assert {:ok, _record} = EventStore.insert(event)
    assert {:ok, _dispatch} = EventDispatchStore.enqueue(event, later)

    assert ScheduleEventCommitStore.commit(plan, event, @recorded_at) ==
             {:error, :schedule_event_conflict}

    assert Repo.aggregate(EventRecord, :count) == 1
    assert Repo.aggregate(EventDispatch, :count) == 1
    assert Repo.get!(EventDispatch, event.id).enqueued_at == later
    persisted = Repo.get!(ScheduleState, "daily-summary")
    assert persisted.next_run_at == @scheduled_at
    assert persisted.claim_token == plan.claim.token
  end

  test "rejects malformed plans, events, and record times before insertion" do
    {plan, event} = claimed_plan(template())

    invalid = [
      {%{plan | claim: nil}, event, @recorded_at},
      {%{plan | claim: Map.put(plan.claim, :private, true)}, event, @recorded_at},
      {%{plan | claim: %{plan.claim | token: String.duplicate("A", 1_000_000)}}, event,
       @recorded_at},
      {%{plan | executed_at: nil}, event, @recorded_at},
      {%{plan | next_run_at: @executed_at}, event, @recorded_at},
      {Map.put(plan, :private, true), event, @recorded_at},
      {plan, %{event | subject: "changed"}, @recorded_at},
      {plan, event, plan.claim.expires_at}
    ]

    for arguments <- invalid do
      assert apply(ScheduleEventCommitStore, :commit, Tuple.to_list(arguments)) ==
               {:error, :invalid_schedule_event_commit}
    end

    assert Repo.aggregate(EventRecord, :count) == 0
    assert Repo.aggregate(EventDispatch, :count) == 0
  end

  test "does not advance when template drift conflicts with an existing event" do
    {original_plan, original_event} = claimed_plan(template())
    assert {:ok, _record} = EventStore.insert(original_event)

    changed = %{template() | subject: "changed-summary"}
    changed_plan = %{original_plan | event: changed}
    assert {:ok, changed_event} = project(changed_plan)
    assert changed_event.id == original_event.id

    assert ScheduleEventCommitStore.commit(changed_plan, changed_event, @recorded_at) ==
             {:error, :schedule_event_conflict}

    persisted = Repo.get!(ScheduleState, "daily-summary")
    assert persisted.next_run_at == @scheduled_at
    assert persisted.claim_token == original_plan.claim.token
  end

  defp claimed_plan(event_template) do
    assert {:ok, _state} =
             ScheduleStateStore.restore_or_initialize("daily-summary", @scheduled_at)

    assert {:ok, claim} =
             ScheduleStateStore.claim_due("daily-summary", @scheduled_at, @scheduled_at)

    plan = %Plan{
      claim: claim,
      event: event_template,
      executed_at: @executed_at,
      next_run_at: @next_run_at
    }

    assert {:ok, event} = project(plan)
    {plan, event}
  end

  defp project(plan) do
    EmittedEventProjector.project(
      :schedule,
      plan.claim.trigger_id,
      plan.event,
      plan.claim.expected_next_run_at
    )
  end

  defp template do
    %EmittedEvent{
      type: "schedule.fired",
      group: "social",
      subject: "daily-summary"
    }
  end
end
