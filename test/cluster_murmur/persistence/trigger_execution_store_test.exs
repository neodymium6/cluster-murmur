defmodule ClusterMurmur.Persistence.TriggerExecutionStoreTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Events.{Event, Matcher}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Persistence.{EventStore, TriggerExecution, TriggerExecutionStore}
  alias ClusterMurmur.Repo
  alias ClusterMurmur.Repo.Migrations.{CreateEvents, CreateTriggerExecutions}
  alias ClusterMurmur.Triggers.{EventTrigger, EventTriggerExecutionPlanner}

  @events_version 20_260_804_180_500
  @executions_version 20_260_804_200_000

  setup_all do
    assert Ecto.Migrator.up(Repo, @events_version, CreateEvents,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    assert Ecto.Migrator.up(Repo, @executions_version, CreateTriggerExecutions,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) == :ok

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @executions_version, CreateTriggerExecutions,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )

      Ecto.Migrator.down(Repo, @events_version, CreateEvents,
        log: false,
        log_migrations_sql: false,
        log_migrator_sql: false
      )
    end)

    :ok
  end

  setup do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM trigger_executions", [], log: false)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM events", [], log: false)
    :ok
  end

  test "atomically starts one plan for its committed immutable event" do
    plan = plan!(event(), ~U[2026-08-04 12:00:00.000000Z])
    assert {:ok, _event_record} = EventStore.insert(plan.event)

    assert {:ok, %TriggerExecution{} = execution} = TriggerExecutionStore.start(plan)
    assert execution.trigger_id == plan.trigger.id
    assert execution.event_id == plan.event.id
    assert execution.status == :started
    assert execution.executed_at == plan.executed_at
    assert execution.cooldown_until == plan.cooldown_until
    assert Repo.aggregate(TriggerExecution, :count) == 1

    refute inspect(execution) =~ plan.event.id
    refute inspect(execution) =~ "2026"
  end

  test "requires the event to exist with identical bounded facts" do
    original = event()
    plan = plan!(original, ~U[2026-08-04 12:00:00.000000Z])

    assert TriggerExecutionStore.start(plan) == {:error, :event_not_found}

    different = %{original | source: "different-example-observer"}
    assert {:ok, _event_record} = EventStore.insert(different)
    assert TriggerExecutionStore.start(plan) == {:error, :event_conflict}
    assert Repo.aggregate(TriggerExecution, :count) == 0
  end

  test "compares event instants after storage precision normalization" do
    for {id, occurred_at, executed_at} <- [
          {"precision-0", ~U[2026-08-04 11:59:59Z], ~U[2026-08-04 12:00:00.000000Z]},
          {"precision-3", ~U[2026-08-04 11:59:59.123Z], ~U[2026-08-04 12:01:00.000000Z]}
        ] do
      event = event(id: id, occurred_at: occurred_at, observed_at: occurred_at)
      plan = plan!(event, executed_at)

      assert {:ok, _event_record} = EventStore.insert(event)
      assert {:ok, %TriggerExecution{event_id: ^id}} = TriggerExecutionStore.start(plan)
    end
  end

  test "preserves strict numeric identity in nested event values" do
    planned = event(facts: %{"attempts" => 1})
    persisted = %{planned | facts: %{"attempts" => 1.0}}
    plan = plan!(planned, ~U[2026-08-04 12:00:00.000000Z])

    assert {:ok, _event_record} = EventStore.insert(persisted)
    assert TriggerExecutionStore.start(plan) == {:error, :event_conflict}
    assert Repo.aggregate(TriggerExecution, :count) == 0
  end

  test "rejects a repeated trigger and event pair" do
    plan = plan!(event(), ~U[2026-08-04 12:00:00.000000Z])
    assert {:ok, _event_record} = EventStore.insert(plan.event)
    assert {:ok, _execution} = TriggerExecutionStore.start(plan)

    assert TriggerExecutionStore.start(plan) == {:error, :execution_conflict}
    assert Repo.aggregate(TriggerExecution, :count) == 1
  end

  test "rechecks the latest durable cooldown for every new event" do
    first = event(id: "event-1")
    second = event(id: "event-2")
    third = event(id: "event-3")

    for persisted <- [first, second, third] do
      assert {:ok, _event_record} = EventStore.insert(persisted)
    end

    assert {:ok, _execution} =
             first
             |> plan!(~U[2026-08-04 12:00:00.000000Z])
             |> TriggerExecutionStore.start()

    assert second
           |> plan!(~U[2026-08-04 12:00:59.999999Z])
           |> TriggerExecutionStore.start() == {:skip, :cooldown}

    assert {:ok, execution} =
             third
             |> plan!(~U[2026-08-04 12:01:00.000000Z])
             |> TriggerExecutionStore.start()

    assert execution.event_id == "event-3"
    assert Repo.aggregate(TriggerExecution, :count) == 2
  end

  test "rejects malformed plans before accessing storage" do
    valid = plan!(event(), ~U[2026-08-04 12:00:00.000000Z])
    Repo.put_dynamic_repo(:missing_trigger_execution_repo)

    for rejected <- [
          nil,
          Map.put(valid, :unexpected_private_value, "private"),
          %{valid | event: %{valid.event | id: ""}},
          %{valid | executed_at: %{valid.executed_at | hour: 24}}
        ] do
      assert TriggerExecutionStore.start(rejected) == {:error, :invalid_execution}
    end
  end

  test "marks one exact started execution completed" do
    started = start_execution!()

    assert {:ok, %TriggerExecution{} = completed} =
             TriggerExecutionStore.complete(started)

    assert completed.status == :completed
    assert completed.error_class == nil
    assert completed.executed_at == started.executed_at
    assert completed.cooldown_until == started.cooldown_until

    assert Repo.get_by!(TriggerExecution,
             trigger_id: started.trigger_id,
             event_id: started.event_id
           ).status == :completed
  end

  test "marks one exact started execution failed with a stable error class" do
    started = start_execution!()

    assert {:ok, %TriggerExecution{} = failed} =
             TriggerExecutionStore.fail(started, "provider.unavailable")

    assert failed.status == :failed
    assert failed.error_class == "provider.unavailable"
    assert failed.executed_at == started.executed_at
    assert failed.cooldown_until == started.cooldown_until

    inspected = inspect(failed)
    refute inspected =~ "provider"
    refute inspected =~ started.event_id
  end

  test "allows only one terminal transition" do
    started = start_execution!()
    assert {:ok, completed} = TriggerExecutionStore.complete(started)

    assert TriggerExecutionStore.complete(started) == {:error, :execution_conflict}

    assert TriggerExecutionStore.fail(started, "provider.unavailable") ==
             {:error, :execution_conflict}

    assert TriggerExecutionStore.fail(completed, "provider.unavailable") ==
             {:error, :invalid_execution}
  end

  test "requires the exact loaded started capability before storage access" do
    started = start_execution!()
    forged_source = Ecto.put_meta(started, source: "events")
    forged_prefix = Ecto.put_meta(started, prefix: "private")
    stale = %{started | cooldown_until: DateTime.add(started.cooldown_until, 1, :second)}

    forged_precision = %{
      started
      | executed_at: %{started.executed_at | microsecond: {0, 0}}
    }

    for rejected <- [
          nil,
          %TriggerExecution{},
          Map.put(started, :unexpected_private_value, "private"),
          forged_source,
          forged_prefix,
          forged_precision,
          %{started | status: :completed},
          %{started | trigger_id: "invalid id"},
          %{started | executed_at: %{started.executed_at | hour: 24}}
        ] do
      assert TriggerExecutionStore.complete(rejected) == {:error, :invalid_execution}
    end

    assert TriggerExecutionStore.complete(stale) == {:error, :execution_conflict}
  end

  test "rejects invalid failure classes before accessing storage" do
    started = start_execution!()
    Repo.put_dynamic_repo(:missing_trigger_execution_repo)

    for error_class <- [
          nil,
          :unavailable,
          "",
          "Invalid.Error",
          "provider error",
          "private\0error",
          String.duplicate("a", 129)
        ] do
      assert TriggerExecutionStore.fail(started, error_class) ==
               {:error, :invalid_execution}
    end
  end

  test "lists only started executions at or before a supplied cutoff" do
    oldest =
      start_execution!(
        event(id: "oldest-event"),
        ~U[2026-08-04 11:58:00.000000Z],
        "oldest-trigger"
      )

    completed =
      start_execution!(
        event(id: "completed-event"),
        ~U[2026-08-04 11:59:00.000000Z],
        "completed-trigger"
      )

    failed =
      start_execution!(
        event(id: "failed-event"),
        ~U[2026-08-04 11:59:30.000000Z],
        "failed-trigger"
      )

    boundary =
      start_execution!(
        event(id: "boundary-event"),
        ~U[2026-08-04 12:00:00.000000Z],
        "boundary-trigger"
      )

    _later =
      start_execution!(
        event(id: "later-event"),
        ~U[2026-08-04 12:00:00.000001Z],
        "later-trigger"
      )

    assert {:ok, _completed} = TriggerExecutionStore.complete(completed)
    assert {:ok, _failed} = TriggerExecutionStore.fail(failed, "runtime.interrupted")

    assert TriggerExecutionStore.list_started_before(~U[2026-08-04 12:00:00Z]) ==
             {:ok, [oldest, boundary]}
  end

  test "bounds and deterministically orders recovery results" do
    for index <- 101..1//-1 do
      suffix = index |> Integer.to_string() |> String.pad_leading(3, "0")

      start_execution!(
        event(id: "recovery-event-#{suffix}"),
        ~U[2026-08-04 12:00:00.000000Z],
        "recovery-trigger-#{suffix}"
      )
    end

    assert {:ok, executions} =
             TriggerExecutionStore.list_started_before(~U[2026-08-04 12:00:00.000000Z])

    assert length(executions) == 100
    assert hd(executions).trigger_id == "recovery-trigger-001"
    assert List.last(executions).trigger_id == "recovery-trigger-100"

    assert Enum.map(executions, & &1.trigger_id) ==
             Enum.sort(Enum.map(executions, & &1.trigger_id))
  end

  test "rejects invalid recovery cutoffs before accessing storage" do
    Repo.put_dynamic_repo(:missing_trigger_execution_repo)

    for cutoff <- [nil, %{~U[2026-08-04 12:00:00Z] | hour: 24}] do
      assert TriggerExecutionStore.list_started_before(cutoff) ==
               {:error, :invalid_datetime}
    end
  end

  defp start_execution!(
         event \\ event(),
         executed_at \\ ~U[2026-08-04 12:00:00.000000Z],
         trigger_id \\ "failure-conversation"
       ) do
    plan = plan!(event, executed_at, trigger_id)
    assert {:ok, _event_record} = EventStore.insert(event)
    assert {:ok, execution} = TriggerExecutionStore.start(plan)
    execution
  end

  defp plan!(event, executed_at, trigger_id \\ "failure-conversation") do
    assert {:ok, plan} =
             EventTriggerExecutionPlanner.plan(trigger(trigger_id), event, nil, executed_at)

    plan
  end

  defp trigger(id) do
    %EventTrigger{
      id: id,
      matcher: %Matcher{
        predicates: [%Predicate{field: "type", operator: :equals, value: "observation.failed"}]
      },
      action: :start_conversation,
      binding: "characters",
      cooldown_ms: 60_000
    }
  end

  defp event(overrides \\ []) do
    struct!(
      Event,
      Keyword.merge(
        [
          id: "example-event",
          type: "observation.failed",
          source: "example-observer",
          occurred_at: ~U[2026-08-04 11:59:59.000000Z]
        ],
        overrides
      )
    )
  end
end
