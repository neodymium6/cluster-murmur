defmodule ClusterMurmur.Runtime.RecurringScheduleCycleIntegrationTest do
  use ExUnit.Case, async: false

  alias ClusterMurmur.Config.{EventGroups, Triggers}

  alias ClusterMurmur.Persistence.{
    EventDispatch,
    EventRecord,
    ScheduleState,
    ScheduleStateStore
  }

  alias ClusterMurmur.Repo
  alias ClusterMurmur.Runtime.RecurringScheduleCycle
  alias ClusterMurmur.Runtime.RecurringScheduleCycle.Result
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
  @due ~U[2026-08-10 12:00:00.000000Z]
  @now ~U[2026-08-10 12:00:01.000000Z]

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

  test "runs the fixed stores as one durable recurring execution" do
    assert {:ok, _state} = ScheduleStateStore.restore_or_initialize("hourly", @due)

    assert {:ok, %Result{due_count: 1, executed_count: 1, failure_count: 0}} =
             RecurringScheduleCycle.run(configuration(), @now)

    assert Repo.aggregate(EventRecord, :count) == 1
    assert Repo.aggregate(EventDispatch, :count) == 1

    state = Repo.get!(ScheduleState, "hourly")
    assert state.last_run_at == @now
    assert state.next_run_at == ~U[2026-08-10 13:00:00.000000Z]
    assert state.claim_token == nil

    assert {:ok, %Result{due_count: 0, executed_count: 0, failure_count: 0}} =
             RecurringScheduleCycle.run(configuration(), @now)
  end

  defp configuration do
    base = RuntimeFixture.configuration()
    trigger = trigger()

    %{
      base
      | event_groups: %EventGroups{
          groups:
            Map.put(base.event_groups.groups, "social", %{
              id: "social",
              reply_probability: 0
            })
        },
        triggers: %Triggers{triggers: Map.put(base.triggers.triggers, trigger.id, trigger)}
    }
  end

  defp trigger do
    {:ok, expression} = Crontab.CronExpression.Parser.parse("0 * * * *", false)

    %ScheduleTrigger{
      id: "hourly",
      cron: expression,
      timezone: "Etc/UTC",
      action: :emit_event,
      event: %EmittedEvent{
        type: "schedule.fired",
        group: "social",
        subject: "hourly"
      }
    }
  end
end
