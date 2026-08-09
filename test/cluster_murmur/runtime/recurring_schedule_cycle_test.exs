defmodule ClusterMurmur.Runtime.RecurringScheduleCycleTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{EventGroups, Triggers}

  alias ClusterMurmur.Persistence.{
    EventDispatchReceipt,
    EventRecord,
    ScheduleState,
    ScheduleStateClaim
  }

  alias ClusterMurmur.Persistence.ScheduleEventCommitStore.Result, as: CommitResult
  alias ClusterMurmur.Runtime.RecurringScheduleCycle
  alias ClusterMurmur.Runtime.RecurringScheduleCycle.{Adapters, Result}
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.{EmittedEvent, ScheduleTrigger}

  @due ~U[2026-08-10 12:00:00.000000Z]
  @now ~U[2026-08-10 12:00:01.000000Z]

  defmodule States do
    alias ClusterMurmur.Runtime.RecurringScheduleCycleTest, as: Test

    def list_due(now) do
      trace({:list_due, now})

      case Process.get({Test, :states}, {:ok, []}) do
        {:ok, states} -> {:ok, Enum.take(states, 100)}
        failure -> failure
      end
    end

    def list_due_after(_now, cursor) do
      trace({:list_due_after, elem(cursor, 1)})

      case Process.get({Test, :states}, {:ok, []}) do
        {:ok, states} ->
          {:ok, states |> Enum.filter(&after_cursor?(&1, cursor)) |> Enum.take(100)}

        failure ->
          failure
      end
    end

    def claim_due(trigger_id, next_run_at, claimed_at) do
      trace({:claim, trigger_id})

      case Map.get(Process.get({Test, :claim_failures}, %{}), trigger_id) do
        nil ->
          {:ok,
           %ScheduleStateClaim{
             trigger_id: trigger_id,
             expected_next_run_at: next_run_at,
             token: token(trigger_id),
             started_at: claimed_at,
             expires_at: DateTime.add(claimed_at, 60, :second)
           }}

        failure ->
          failure
      end
    end

    defp token(trigger_id),
      do: :sha256 |> :crypto.hash(trigger_id) |> Base.url_encode64(padding: false)

    defp after_cursor?(state, {next_run_at, trigger_id}) do
      case DateTime.compare(state.next_run_at, next_run_at) do
        :gt -> true
        :eq -> state.trigger_id > trigger_id
        :lt -> false
      end
    end

    defp trace(entry), do: Process.put({Test, :trace}, trace() ++ [entry])
    defp trace, do: Process.get({Test, :trace}, [])
  end

  defmodule Commits do
    alias ClusterMurmur.Runtime.RecurringScheduleCycleTest, as: Test

    def commit(plan, event, recorded_at) do
      trace({:commit, plan.claim.trigger_id, event.type, recorded_at})
      {:ok, Test.commit_result(plan, event)}
    end

    defp trace(entry), do: Process.put({Test, :trace}, trace() ++ [entry])
    defp trace, do: Process.get({Test, :trace}, [])
  end

  defmodule StaleClaims do
    alias ClusterMurmur.Runtime.RecurringScheduleCycleTest.States

    defdelegate list_due(now), to: States
    defdelegate list_due_after(now, cursor), to: States

    def claim_due(trigger_id, next_run_at, claimed_at) do
      with {:ok, claim} <- States.claim_due(trigger_id, next_run_at, claimed_at) do
        started_at = DateTime.add(claim.started_at, -1, :second)
        {:ok, %{claim | started_at: started_at, expires_at: DateTime.add(started_at, 60)}}
      end
    end
  end

  defmodule FalseCommits do
    def commit(_plan, _event, _recorded_at), do: {:ok, :committed}
  end

  defmodule WrongCommits do
    alias ClusterMurmur.Runtime.RecurringScheduleCycleTest, as: Test

    def commit(plan, event, _recorded_at) do
      result = Test.commit_result(plan, event)
      {:ok, %{result | state: %{result.state | trigger_id: "wrong-trigger"}}}
    end
  end

  defmodule PrivateCommitResult do
    alias ClusterMurmur.Runtime.RecurringScheduleCycleTest, as: Test

    def commit(plan, event, _recorded_at) do
      {:ok, plan |> Test.commit_result(event) |> Map.put(:private, true)}
    end
  end

  setup do
    Process.put({__MODULE__, :trace}, [])
    Process.put({__MODULE__, :claim_failures}, %{})
    :ok
  end

  test "claims, plans, and commits due states in durable order" do
    configuration = configuration([trigger("first"), trigger("second")])
    Process.put({__MODULE__, :states}, {:ok, [state("first"), state("second")]})

    assert {:ok, %Result{} = result} = RecurringScheduleCycle.run(configuration, @now, adapters())
    assert result == %Result{due_count: 2, executed_count: 2, failure_count: 0}

    assert Process.get({__MODULE__, :trace}) == [
             {:list_due, @now},
             {:claim, "first"},
             {:commit, "first", "schedule.fired", @now},
             {:claim, "second"},
             {:commit, "second", "schedule.fired", @now}
           ]

    refute inspect(result) =~ "first"
  end

  test "continues a prevalidated batch after one claim conflict" do
    configuration = configuration([trigger("first"), trigger("second")])
    Process.put({__MODULE__, :states}, {:ok, [state("first"), state("second")]})
    Process.put({__MODULE__, :claim_failures}, %{"first" => {:error, :schedule_conflict}})

    assert {:ok, result} = RecurringScheduleCycle.run(configuration, @now, adapters())
    assert result == %Result{due_count: 2, executed_count: 1, failure_count: 1}

    assert Process.get({__MODULE__, :trace}) == [
             {:list_due, @now},
             {:claim, "first"},
             {:claim, "second"},
             {:commit, "second", "schedule.fired", @now}
           ]
  end

  test "pages past one hundred states without starving later work" do
    triggers =
      Enum.map(0..100, fn index ->
        trigger("schedule-#{String.pad_leading(Integer.to_string(index), 3, "0")}")
      end)

    configuration = configuration(triggers)
    Process.put({__MODULE__, :states}, {:ok, Enum.map(triggers, &state(&1.id))})

    assert {:ok, result} = RecurringScheduleCycle.run(configuration, @now, adapters())
    assert result == %Result{due_count: 101, executed_count: 101, failure_count: 0}

    assert Enum.take(Process.get({__MODULE__, :trace}), 2) == [
             {:list_due, @now},
             {:list_due_after, "schedule-099"}
           ]
  end

  test "does not count stale claims or uncorrelated commit success" do
    configuration = configuration([trigger("known")])
    Process.put({__MODULE__, :states}, {:ok, [state("known")]})

    for adapters <- [
          %Adapters{states: StaleClaims, commits: Commits},
          %Adapters{states: States, commits: FalseCommits},
          %Adapters{states: States, commits: WrongCommits},
          %Adapters{states: States, commits: PrivateCommitResult}
        ] do
      Process.put({__MODULE__, :trace}, [])

      assert {:ok, result} = RecurringScheduleCycle.run(configuration, @now, adapters)
      assert result == %Result{due_count: 1, executed_count: 0, failure_count: 1}
    end
  end

  test "rejects stale, unsorted, future, claimed, and oversized loads before claiming" do
    configuration = configuration([trigger("known"), trigger("other")])

    claimed =
      state("known",
        claim_token: Base.url_encode64(<<1::256>>, padding: false),
        claim_started_at: @due,
        claim_expires_at: DateTime.add(@due, 60, :second)
      )

    invalid_loads = [
      [state("missing")],
      [state("other"), state("known")],
      [state("known", next_run_at: DateTime.add(@now, 1, :second))],
      [claimed],
      List.duplicate(state("known"), 101)
    ]

    for states <- invalid_loads do
      Process.put({__MODULE__, :trace}, [])
      Process.put({__MODULE__, :states}, {:ok, states})

      assert RecurringScheduleCycle.run(configuration, @now, adapters()) ==
               {:error, :invalid_recurring_schedule_cycle}

      assert Process.get({__MODULE__, :trace}) == [{:list_due, @now}]
    end
  end

  test "rejects malformed runtime dependencies before listing storage" do
    valid = configuration([trigger("known")])

    invalid = [
      {%{valid | version: 1.0}, @now, adapters()},
      {valid, %{@now | hour: 24}, adapters()},
      {valid, @now, Map.put(adapters(), :private, true)}
    ]

    for {configuration, now, adapters} <- invalid do
      assert RecurringScheduleCycle.run(configuration, now, adapters) ==
               {:error, :invalid_recurring_schedule_cycle}
    end

    assert Process.get({__MODULE__, :trace}) == []
  end

  test "accepts canonical second-precision execution instants" do
    now = ~U[2026-08-10 12:00:01Z]
    configuration = configuration([trigger("known")])
    Process.put({__MODULE__, :states}, {:ok, [state("known")]})

    assert {:ok, %Result{executed_count: 1}} =
             RecurringScheduleCycle.run(configuration, now, adapters())
  end

  test "validates only exact bounded and correlated aggregate results" do
    valid = %Result{due_count: 2, executed_count: 1, failure_count: 1}
    assert RecurringScheduleCycle.validate_result(valid) == :ok

    invalid = [
      %{valid | due_count: 1},
      %{valid | executed_count: -1},
      %{valid | failure_count: 257},
      %{valid | failure_count: "private"},
      Map.put(valid, :private, "private")
    ]

    for result <- invalid do
      assert RecurringScheduleCycle.validate_result(result) ==
               {:error, :invalid_recurring_schedule_cycle_result}
    end
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

  defp state(trigger_id, overrides \\ []) do
    ScheduleState
    |> struct!(
      Keyword.merge(
        [
          trigger_id: trigger_id,
          next_run_at: @due,
          last_run_at: nil,
          claim_token: nil,
          claim_started_at: nil,
          claim_expires_at: nil
        ],
        overrides
      )
    )
    |> Ecto.put_meta(state: :loaded)
  end

  defp adapters, do: %Adapters{states: States, commits: Commits}

  @doc false
  def commit_result(plan, event) do
    event_record =
      %EventRecord{}
      |> EventRecord.changeset(event)
      |> Ecto.Changeset.apply_changes()

    dispatch = %EventDispatchReceipt{
      event_id: event.id,
      status: :pending,
      enqueued_at: plan.executed_at
    }

    state =
      state(plan.claim.trigger_id,
        next_run_at: plan.next_run_at,
        last_run_at: plan.executed_at
      )

    %CommitResult{event: event_record, dispatch: dispatch, state: state}
  end
end
