defmodule ClusterMurmur.Persistence.TriggerExecutionTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Events.{Event, Matcher}
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Persistence.{EventStore, TriggerExecution}
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

  test "builds a redacted started record from a complete eligible plan" do
    plan = plan!()

    assert %{valid?: true} =
             changeset = TriggerExecution.start_changeset(%TriggerExecution{}, plan)

    execution = Ecto.Changeset.apply_changes(changeset)

    assert execution.trigger_id == plan.trigger.id
    assert execution.event_id == plan.event.id
    assert execution.status == :started
    assert execution.executed_at == plan.executed_at
    assert execution.cooldown_until == plan.cooldown_until
    assert execution.error_class == nil
  end

  test "rejects malformed or forged plans without retaining their values" do
    valid = plan!()

    invalid = [
      nil,
      Map.put(valid, :unexpected_private_value, "private"),
      %{valid | trigger: %{valid.trigger | id: "invalid id"}},
      %{valid | event: %{valid.event | id: ""}},
      %{valid | event: %{valid.event | type: "observation.recovered"}},
      %{valid | executed_at: %{valid.executed_at | hour: 24}},
      %{valid | cooldown_until: valid.executed_at}
    ]

    for rejected <- invalid do
      changeset = TriggerExecution.start_changeset(%TriggerExecution{}, rejected)
      refute changeset.valid?
      refute inspect(changeset) =~ "private"
    end
  end

  test "redacts records and valid changesets" do
    plan = plan!()
    changeset = TriggerExecution.start_changeset(%TriggerExecution{}, plan)
    execution = Ecto.Changeset.apply_changes(changeset)

    for inspected <- [inspect(execution), inspect(changeset)] do
      refute inspected =~ plan.trigger.id
      refute inspected =~ plan.event.id
      refute inspected =~ "2026"
      refute inspected =~ "private"
    end
  end

  test "rejects loaded and prefilled records instead of restarting their lifecycle" do
    plan = plan!()

    loaded = %TriggerExecution{
      __meta__: %Ecto.Schema.Metadata{state: :loaded, source: "trigger_executions"},
      trigger_id: plan.trigger.id,
      event_id: plan.event.id,
      status: :completed,
      executed_at: plan.executed_at,
      cooldown_until: plan.cooldown_until
    }

    for execution <- [loaded, %TriggerExecution{status: :failed}] do
      changeset = TriggerExecution.start_changeset(execution, plan)
      refute changeset.valid?
      assert changeset.changes == %{}
    end
  end

  test "maps the adapter's composite primary-key name on an actual duplicate insert" do
    plan = plan!()
    assert {:ok, _event_record} = EventStore.insert(plan.event)

    assert {:ok, %TriggerExecution{}} =
             %TriggerExecution{}
             |> TriggerExecution.start_changeset(plan)
             |> Repo.insert()

    assert {:error, changeset} =
             %TriggerExecution{}
             |> TriggerExecution.start_changeset(plan)
             |> Repo.insert()

    assert {"has already been taken", _metadata} = changeset.errors[:trigger_id]
  end

  defp plan! do
    assert {:ok, plan} =
             EventTriggerExecutionPlanner.plan(
               trigger(),
               event(),
               nil,
               ~U[2026-08-04 12:00:00.000000Z]
             )

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

  defp event do
    %Event{
      id: "example-event",
      type: "observation.failed",
      source: "example-observer",
      occurred_at: ~U[2026-08-04 11:59:59.000000Z],
      facts: %{"detail" => "private"}
    }
  end
end
