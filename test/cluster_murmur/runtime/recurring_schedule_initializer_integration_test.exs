defmodule ClusterMurmur.Runtime.RecurringScheduleInitializerIntegrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Config.{EventGroups, Triggers}
  alias ClusterMurmur.Persistence.{EventDispatch, EventRecord, ScheduleState}
  alias ClusterMurmur.Repo

  alias ClusterMurmur.Runtime.{
    RecurringScheduleCycle,
    RecurringScheduleInitializer
  }

  alias ClusterMurmur.Runtime.RecurringScheduleCycle.Result, as: CycleResult
  alias ClusterMurmur.Runtime.RecurringScheduleInitializer.Result, as: InitializationResult
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.{EmittedEvent, ScheduleTrigger}

  alias ClusterMurmur.Repo.Migrations.{
    CreateEventDispatches,
    CreateEvents,
    CreateScheduleStates
  }

  @event_version 20_260_804_180_500
  @dispatch_version 20_260_808_150_000
  @schedule_version 20_260_809_062_000
  @first_start ~U[2026-08-10 10:30:00.000000Z]
  @restart ~U[2026-08-10 11:30:00.000000Z]

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

  test "retires a removed trigger before its stale due state can block the current batch" do
    assert {:ok, %InitializationResult{schedule_count: 2}} =
             RecurringScheduleInitializer.run(configuration(["active", "removed"]), @first_start)

    assert Repo.get!(ScheduleState, "active").next_run_at ==
             ~U[2026-08-10 11:00:00.000000Z]

    assert {:ok, %InitializationResult{schedule_count: 1}} =
             RecurringScheduleInitializer.run(configuration(["active"]), @restart)

    assert Repo.get(ScheduleState, "removed") == nil

    assert {:ok, %CycleResult{due_count: 1, executed_count: 1, failure_count: 0}} =
             RecurringScheduleCycle.run(configuration(["active"]), @restart)

    assert Repo.aggregate(EventRecord, :count) == 1
    assert Repo.aggregate(EventDispatch, :count) == 1

    assert Repo.get!(ScheduleState, "active").next_run_at ==
             ~U[2026-08-10 12:00:00.000000Z]
  end

  defp configuration(trigger_ids) do
    base = RuntimeFixture.configuration()

    triggers =
      Enum.reduce(trigger_ids, base.triggers.triggers, fn id, triggers ->
        Map.put(triggers, id, trigger(id))
      end)

    %{
      base
      | event_groups: %EventGroups{
          groups:
            Map.put(base.event_groups.groups, "social", %{
              id: "social",
              reply_probability: 0
            })
        },
        triggers: %Triggers{triggers: triggers}
    }
  end

  defp trigger(id) do
    {:ok, expression} = Crontab.CronExpression.Parser.parse("0 * * * *", false)

    %ScheduleTrigger{
      id: id,
      cron: expression,
      timezone: "Etc/UTC",
      action: :emit_event,
      event: %EmittedEvent{type: "schedule.fired", group: "social", subject: id}
    }
  end
end
