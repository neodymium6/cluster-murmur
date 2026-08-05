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

  defp plan!(event, executed_at) do
    assert {:ok, plan} = EventTriggerExecutionPlanner.plan(trigger(), event, nil, executed_at)
    plan
  end

  defp trigger do
    %EventTrigger{
      id: "failure-conversation",
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
