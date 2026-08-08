defmodule ClusterMurmur.Runtime.StochasticCycleTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{EventGroups, Triggers}

  alias ClusterMurmur.Persistence.{
    EventDispatchReceipt,
    EventRecord,
    StochasticSchedule,
    StochasticScheduleClaim
  }

  alias ClusterMurmur.Persistence.StochasticEventCommitStore.Result, as: CommitResult
  alias ClusterMurmur.Runtime.StochasticCycle
  alias ClusterMurmur.Runtime.StochasticCycle.{Adapters, Result}
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.{ActiveHours, EmittedEvent, StochasticTrigger}

  @now ~U[2026-08-08 12:00:01.000000Z]

  defmodule ZeroRandom do
    def uniform, do: 0.0
  end

  defmodule Schedules do
    alias ClusterMurmur.Runtime.StochasticCycleTest, as: Test

    def list_due(now) do
      trace({:list_due, now})

      case Process.get({Test, :schedules}, {:ok, []}) do
        {:ok, schedules} -> {:ok, Enum.take(schedules, 100)}
        failure -> failure
      end
    end

    def list_due_after(_now, cursor) do
      trace({:list_due_after, elem(cursor, 1)})

      case Process.get({Test, :schedules}, {:ok, []}) do
        {:ok, schedules} ->
          {:ok, schedules |> Enum.filter(&after_cursor?(&1, cursor)) |> Enum.take(100)}

        failure ->
          failure
      end
    end

    def claim_due(trigger_id, next_run_at, claimed_at) do
      trace({:claim, trigger_id})

      case Map.get(Process.get({Test, :claim_failures}, %{}), trigger_id) do
        nil ->
          {:ok,
           %StochasticScheduleClaim{
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

    defp after_cursor?(schedule, {next_run_at, trigger_id}) do
      case DateTime.compare(schedule.next_run_at, next_run_at) do
        :gt -> true
        :eq -> schedule.trigger_id > trigger_id
        :lt -> false
      end
    end

    defp trace(entry), do: Process.put({Test, :trace}, trace() ++ [entry])
    defp trace, do: Process.get({Test, :trace}, [])
  end

  defmodule Commits do
    alias ClusterMurmur.Runtime.StochasticCycleTest, as: Test

    def commit(plan, event, recorded_at) do
      trace({:commit, plan.claim.trigger_id, event.type, recorded_at})
      {:ok, Test.commit_result(plan, event)}
    end

    defp trace(entry), do: Process.put({Test, :trace}, trace() ++ [entry])
    defp trace, do: Process.get({Test, :trace}, [])
  end

  defmodule StaleClaims do
    alias ClusterMurmur.Runtime.StochasticCycleTest.Schedules

    defdelegate list_due(now), to: Schedules
    defdelegate list_due_after(now, cursor), to: Schedules

    def claim_due(trigger_id, next_run_at, claimed_at) do
      with {:ok, claim} <- Schedules.claim_due(trigger_id, next_run_at, claimed_at) do
        started_at = DateTime.add(claim.started_at, -1, :second)
        {:ok, %{claim | started_at: started_at, expires_at: DateTime.add(started_at, 60)}}
      end
    end
  end

  defmodule FalseCommits do
    def commit(_plan, _event, _recorded_at), do: {:ok, :committed}
  end

  defmodule WrongCommits do
    alias ClusterMurmur.Runtime.StochasticCycleTest, as: Test

    def commit(plan, event, _recorded_at) do
      result = Test.commit_result(plan, event)
      {:ok, %{result | event: %{result.event | id: "wrong-event"}}}
    end
  end

  defmodule WrongDispatchCommits do
    alias ClusterMurmur.Runtime.StochasticCycleTest, as: Test

    def commit(plan, event, _recorded_at) do
      result = Test.commit_result(plan, event)
      {:ok, %{result | dispatch: %{result.dispatch | event_id: "wrong-event"}}}
    end
  end

  defmodule PrivateCommitResult do
    alias ClusterMurmur.Runtime.StochasticCycleTest, as: Test

    def commit(plan, event, _recorded_at) do
      {:ok, plan |> Test.commit_result(event) |> Map.put(:private, true)}
    end
  end

  setup do
    Process.put({__MODULE__, :trace}, [])
    Process.put({__MODULE__, :claim_failures}, %{})
    :ok
  end

  test "claims and commits eligible schedules while leaving ineligible work unclaimed" do
    configuration = configuration([trigger("active", nil), trigger("inactive", inactive_hours())])
    Process.put({__MODULE__, :schedules}, {:ok, [schedule("active"), schedule("inactive")]})

    assert {:ok, %Result{} = result} =
             StochasticCycle.run(configuration, @now, ZeroRandom, adapters())

    assert result.due_count == 2
    assert result.executed_count == 1
    assert result.skipped_count == 1
    assert result.failure_count == 0

    assert Process.get({__MODULE__, :trace}) == [
             {:list_due, @now},
             {:claim, "active"},
             {:commit, "active", "stochastic.fired", @now}
           ]

    refute inspect(result) =~ "active"
  end

  test "continues a prevalidated batch after one claim conflict" do
    configuration = configuration([trigger("first", nil), trigger("second", nil)])
    Process.put({__MODULE__, :schedules}, {:ok, [schedule("first"), schedule("second")]})
    Process.put({__MODULE__, :claim_failures}, %{"first" => {:error, :schedule_conflict}})

    assert {:ok, result} = StochasticCycle.run(configuration, @now, ZeroRandom, adapters())
    assert result.executed_count == 1
    assert result.failure_count == 1

    assert Process.get({__MODULE__, :trace}) == [
             {:list_due, @now},
             {:claim, "first"},
             {:claim, "second"},
             {:commit, "second", "stochastic.fired", @now}
           ]
  end

  test "pages past one hundred ineligible schedules without starving later work" do
    inactive_triggers =
      Enum.map(0..99, fn index ->
        trigger(
          "inactive-#{String.pad_leading(Integer.to_string(index), 3, "0")}",
          inactive_hours()
        )
      end)

    active = trigger("z-active", nil)
    configuration = configuration(inactive_triggers ++ [active])
    schedules = Enum.map(inactive_triggers ++ [active], &schedule(&1.id))
    Process.put({__MODULE__, :schedules}, {:ok, schedules})

    assert {:ok, result} = StochasticCycle.run(configuration, @now, ZeroRandom, adapters())
    assert result.due_count == 101
    assert result.executed_count == 1
    assert result.skipped_count == 100
    assert result.failure_count == 0

    assert Enum.take(Process.get({__MODULE__, :trace}), 2) == [
             {:list_due, @now},
             {:list_due_after, "inactive-099"}
           ]

    assert List.last(Process.get({__MODULE__, :trace})) ==
             {:commit, "z-active", "stochastic.fired", @now}
  end

  test "does not count stale claims or uncorrelated commit success as executions" do
    configuration = configuration([trigger("known", nil)])
    Process.put({__MODULE__, :schedules}, {:ok, [schedule("known")]})

    for adapters <- [
          %Adapters{schedules: StaleClaims, commits: Commits},
          %Adapters{schedules: Schedules, commits: FalseCommits},
          %Adapters{schedules: Schedules, commits: WrongCommits},
          %Adapters{schedules: Schedules, commits: WrongDispatchCommits},
          %Adapters{schedules: Schedules, commits: PrivateCommitResult}
        ] do
      Process.put({__MODULE__, :trace}, [])

      assert {:ok, result} =
               StochasticCycle.run(configuration, @now, ZeroRandom, adapters)

      assert result.executed_count == 0
      assert result.failure_count == 1
    end
  end

  test "rejects stale, unsorted, and oversized loads before the first claim" do
    configuration = configuration([trigger("known", nil), trigger("other", nil)])

    invalid_loads = [
      [schedule("missing")],
      [schedule("other"), schedule("known")],
      List.duplicate(schedule("known"), 101)
    ]

    for schedules <- invalid_loads do
      Process.put({__MODULE__, :trace}, [])
      Process.put({__MODULE__, :schedules}, {:ok, schedules})

      assert StochasticCycle.run(configuration, @now, ZeroRandom, adapters()) ==
               {:error, :invalid_stochastic_cycle}

      assert Process.get({__MODULE__, :trace}) == [{:list_due, @now}]
    end
  end

  test "rejects malformed runtime dependencies before listing storage" do
    valid = configuration([trigger("known", nil)])

    invalid = [
      {%{valid | version: 1.0}, ZeroRandom, adapters()},
      {valid, String, adapters()},
      {valid, ZeroRandom, Map.put(adapters(), :private, true)}
    ]

    for {configuration, random, adapters} <- invalid do
      assert StochasticCycle.run(configuration, @now, random, adapters) ==
               {:error, :invalid_stochastic_cycle}
    end

    assert Process.get({__MODULE__, :trace}) == []
  end

  test "validates only exact bounded and correlated aggregate results" do
    valid = %Result{due_count: 3, executed_count: 1, skipped_count: 1, failure_count: 1}
    assert StochasticCycle.validate_result(valid) == :ok

    invalid = [
      %{valid | due_count: 2},
      %{valid | executed_count: -1},
      %{valid | failure_count: 257},
      %{valid | skipped_count: "private"},
      Map.put(valid, :private, "private")
    ]

    for result <- invalid do
      assert StochasticCycle.validate_result(result) ==
               {:error, :invalid_stochastic_cycle_result}
    end
  end

  defp configuration(stochastic_triggers) do
    base = RuntimeFixture.configuration()

    triggers =
      stochastic_triggers
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

  defp trigger(id, active_hours) do
    %StochasticTrigger{
      id: id,
      distribution: :shifted_exponential,
      mean_interval_ms: 8_000,
      minimum_interval_ms: 2_000,
      active_hours: active_hours,
      daily_limit: nil,
      action: :emit_event,
      event: %EmittedEvent{type: "stochastic.fired", group: "social", subject: id}
    }
  end

  defp inactive_hours do
    %ActiveHours{start_minute: 13 * 60, end_minute: 14 * 60, timezone: "Etc/UTC"}
  end

  defp schedule(trigger_id) do
    %StochasticSchedule{
      trigger_id: trigger_id,
      next_run_at: ~U[2026-08-08 12:00:00.000000Z],
      last_run_at: nil,
      daily_count: 0,
      daily_count_date: nil,
      claim_token: nil,
      claim_started_at: nil,
      claim_expires_at: nil
    }
  end

  defp adapters, do: %Adapters{schedules: Schedules, commits: Commits}

  @doc false
  def commit_result(plan, event) do
    event_record =
      %EventRecord{}
      |> EventRecord.changeset(event)
      |> Ecto.Changeset.apply_changes()

    {daily_count, daily_count_date} =
      case plan.local_date do
        nil -> {0, nil}
        local_date -> {1, local_date}
      end

    schedule = %StochasticSchedule{
      trigger_id: plan.claim.trigger_id,
      next_run_at: plan.next_run_at,
      last_run_at: plan.executed_at,
      daily_count: daily_count,
      daily_count_date: daily_count_date,
      claim_token: nil,
      claim_started_at: nil,
      claim_expires_at: nil
    }

    dispatch = %EventDispatchReceipt{
      event_id: event.id,
      status: :pending,
      enqueued_at: plan.executed_at
    }

    %CommitResult{event: event_record, dispatch: dispatch, schedule: schedule}
  end
end
