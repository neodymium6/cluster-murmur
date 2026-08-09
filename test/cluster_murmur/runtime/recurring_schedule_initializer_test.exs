defmodule ClusterMurmur.Runtime.RecurringScheduleInitializerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{EventGroups, Triggers}
  alias ClusterMurmur.Persistence.{ScheduleState, ScheduleStateRetirement}
  alias ClusterMurmur.Runtime.RecurringScheduleInitializer
  alias ClusterMurmur.Runtime.RecurringScheduleInitializer.{Adapters, Result}
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.{EmittedEvent, ScheduleTrigger}

  @initialized_at ~U[2026-08-10 12:30:00.000000Z]

  defmodule States do
    alias ClusterMurmur.Persistence.ScheduleStateRetirement
    alias ClusterMurmur.Runtime.RecurringScheduleInitializerTest, as: Test

    def retire_unconfigured(trigger_ids) do
      trace({:retire, trigger_ids})

      Process.get(
        {Test, :retirement},
        {:ok, %ScheduleStateRetirement{retired_count: 0, saturated?: false}}
      )
    end

    def restore_or_initialize(trigger_id, next_run_at) do
      trace({:restore, trigger_id, next_run_at})

      case Map.get(Process.get({Test, :responses}, %{}), trigger_id) do
        nil -> {:ok, Test.state(trigger_id, next_run_at)}
        response -> response
      end
    end

    defp trace(entry), do: Process.put({Test, :trace}, trace() ++ [entry])
    defp trace, do: Process.get({Test, :trace}, [])
  end

  setup do
    Process.put({__MODULE__, :trace}, [])
    Process.put({__MODULE__, :responses}, %{})

    Process.put(
      {__MODULE__, :retirement},
      {:ok, %ScheduleStateRetirement{retired_count: 0, saturated?: false}}
    )

    :ok
  end

  test "calculates every initial version before restoring in trigger order" do
    configuration =
      configuration([trigger("second", "30 * * * *"), trigger("first", "0 * * * *")])

    assert {:ok, %Result{schedule_count: 2} = result} =
             RecurringScheduleInitializer.run(configuration, @initialized_at, adapters())

    assert Process.get({__MODULE__, :trace}) == [
             {:retire, ["first", "second"]},
             {:restore, "first", ~U[2026-08-10 13:00:00Z]},
             {:restore, "second", ~U[2026-08-10 13:30:00Z]}
           ]

    refute inspect(result) =~ "first"
    refute inspect(result) =~ "2026"
  end

  test "accepts existing durable state without replacing its version" do
    existing = state("hourly", ~U[2026-08-01 01:00:00.000000Z])
    Process.put({__MODULE__, :responses}, %{"hourly" => {:ok, existing}})

    assert {:ok, %Result{schedule_count: 1}} =
             RecurringScheduleInitializer.run(
               configuration([trigger("hourly", "0 * * * *")]),
               @initialized_at,
               adapters()
             )

    assert Process.get({__MODULE__, :trace}) == [
             {:retire, ["hourly"]},
             {:restore, "hourly", ~U[2026-08-10 13:00:00Z]}
           ]
  end

  test "calculates the complete set before the first storage mutation" do
    initialized_at = ~U[9999-12-31 22:30:00.000000Z]

    configuration =
      configuration([
        trigger("a-hourly", "0 * * * *"),
        trigger("z-yearly", "0 0 1 1 *")
      ])

    assert RecurringScheduleInitializer.run(configuration, initialized_at, adapters()) ==
             {:error, :invalid_recurring_schedule_initialization}

    assert Process.get({__MODULE__, :trace}) == []
  end

  test "rejects malformed restored state and storage failures" do
    configuration = configuration([trigger("hourly", "0 * * * *")])

    failures = [
      {:ok, state("wrong", ~U[2026-08-10 13:00:00.000000Z])},
      {:ok, Map.put(state("hourly", ~U[2026-08-10 13:00:00.000000Z]), :private, true)},
      {:error, :storage_unavailable},
      {:ok, :not_a_state}
    ]

    for response <- failures do
      Process.put({__MODULE__, :trace}, [])
      Process.put({__MODULE__, :responses}, %{"hourly" => response})

      assert RecurringScheduleInitializer.run(configuration, @initialized_at, adapters()) ==
               {:error, :invalid_recurring_schedule_initialization}
    end
  end

  test "requires another startup pass after a saturated retirement page" do
    Process.put(
      {__MODULE__, :retirement},
      {:ok, %ScheduleStateRetirement{retired_count: 100, saturated?: true}}
    )

    assert RecurringScheduleInitializer.run(
             configuration([trigger("hourly", "0 * * * *")]),
             @initialized_at,
             adapters()
           ) == {:error, :invalid_recurring_schedule_initialization}

    assert Process.get({__MODULE__, :trace}) == [{:retire, ["hourly"]}]
  end

  test "rejects malformed dependencies before calculating or storing" do
    valid = configuration([trigger("hourly", "0 * * * *")])

    invalid = [
      {%{valid | version: 1.0}, @initialized_at, adapters()},
      {valid, %{@initialized_at | hour: 24}, adapters()},
      {valid, @initialized_at, %Adapters{states: String}},
      {valid, @initialized_at, Map.put(adapters(), :private, true)},
      {nil, @initialized_at, adapters()}
    ]

    for {configuration, initialized_at, adapters} <- invalid do
      assert RecurringScheduleInitializer.run(configuration, initialized_at, adapters) ==
               {:error, :invalid_recurring_schedule_initialization}
    end

    assert Process.get({__MODULE__, :trace}) == []
  end

  test "retires stale state even when no schedules remain configured" do
    assert {:ok, %Result{schedule_count: 0}} =
             RecurringScheduleInitializer.run(
               RuntimeFixture.configuration(),
               @initialized_at,
               adapters()
             )

    assert Process.get({__MODULE__, :trace}) == [{:retire, []}]
  end

  defp configuration(schedule_triggers) do
    base = RuntimeFixture.configuration()

    triggers =
      schedule_triggers
      |> Enum.reduce(base.triggers.triggers, &Map.put(&2, &1.id, &1))

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

  defp trigger(id, cron) do
    {:ok, expression} = Crontab.CronExpression.Parser.parse(cron, false)

    %ScheduleTrigger{
      id: id,
      cron: expression,
      timezone: "Etc/UTC",
      action: :emit_event,
      event: %EmittedEvent{type: "schedule.fired", group: "social", subject: id}
    }
  end

  defp adapters, do: %Adapters{states: States}

  @doc false
  def state(trigger_id, next_run_at) do
    %ScheduleState{
      trigger_id: trigger_id,
      next_run_at: next_run_at,
      last_run_at: nil,
      claim_token: nil,
      claim_started_at: nil,
      claim_expires_at: nil
    }
    |> Ecto.put_meta(state: :loaded)
  end
end
