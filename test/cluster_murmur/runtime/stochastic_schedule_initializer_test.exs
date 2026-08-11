defmodule ClusterMurmur.Runtime.StochasticScheduleInitializerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{EventGroups, Triggers}

  alias ClusterMurmur.Persistence.{
    StochasticSchedule,
    StochasticScheduleRetirement
  }

  alias ClusterMurmur.Runtime.StochasticScheduleInitializer
  alias ClusterMurmur.Runtime.StochasticScheduleInitializer.{Adapters, Result}
  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.{EmittedEvent, StochasticTrigger}

  @initialized_at ~U[2026-08-11 12:30:00.000000Z]

  defmodule SequenceRandom do
    def uniform do
      key = {ClusterMurmur.Runtime.StochasticScheduleInitializerTest, :random}
      [next | remaining] = Process.get(key, [0.0])
      Process.put(key, remaining)
      next
    end
  end

  defmodule Schedules do
    alias ClusterMurmur.Persistence.StochasticScheduleRetirement
    alias ClusterMurmur.Runtime.StochasticScheduleInitializerTest, as: Test

    def retire_unconfigured(trigger_ids) do
      trace({:retire, trigger_ids})

      Process.get(
        {Test, :retirement},
        {:ok, %StochasticScheduleRetirement{retired_count: 0, saturated?: false}}
      )
    end

    def restore_or_initialize(trigger_id, next_run_at) do
      trace({:restore, trigger_id, next_run_at})

      case Map.get(Process.get({Test, :responses}, %{}), trigger_id) do
        nil -> {:ok, Test.schedule(trigger_id, next_run_at)}
        response -> response
      end
    end

    defp trace(entry), do: Process.put({Test, :trace}, trace() ++ [entry])
    defp trace, do: Process.get({Test, :trace}, [])
  end

  setup do
    Process.put({__MODULE__, :trace}, [])
    Process.put({__MODULE__, :responses}, %{})
    Process.put({__MODULE__, :random}, [0.0, 0.0])

    Process.put(
      {__MODULE__, :retirement},
      {:ok, %StochasticScheduleRetirement{retired_count: 0, saturated?: false}}
    )

    :ok
  end

  test "samples every initial version before restoring in trigger order" do
    configuration = configuration([trigger("second"), trigger("first")])

    assert {:ok, %Result{schedule_count: 2} = result} =
             StochasticScheduleInitializer.run(
               configuration,
               @initialized_at,
               SequenceRandom,
               adapters()
             )

    assert Process.get({__MODULE__, :trace}) == [
             {:retire, ["first", "second"]},
             {:restore, "first", ~U[2026-08-11 12:30:02.000000Z]},
             {:restore, "second", ~U[2026-08-11 12:30:02.000000Z]}
           ]

    assert Process.get({__MODULE__, :random}) == []
    refute inspect(result) =~ "first"
    refute inspect(result) =~ "2026"
  end

  test "accepts existing durable state without replacing its version" do
    existing = schedule("ambient", ~U[2026-08-01 01:00:00.000000Z])
    Process.put({__MODULE__, :responses}, %{"ambient" => {:ok, existing}})

    assert {:ok, %Result{schedule_count: 1}} =
             StochasticScheduleInitializer.run(
               configuration([trigger("ambient")]),
               @initialized_at,
               SequenceRandom,
               adapters()
             )

    assert Process.get({__MODULE__, :trace}) == [
             {:retire, ["ambient"]},
             {:restore, "ambient", ~U[2026-08-11 12:30:02.000000Z]}
           ]
  end

  test "samples the complete set before the first storage mutation" do
    Process.put({__MODULE__, :random}, [0.0, 1.0])

    assert StochasticScheduleInitializer.run(
             configuration([trigger("a-valid"), trigger("z-invalid")]),
             @initialized_at,
             SequenceRandom,
             adapters()
           ) == {:error, :invalid_stochastic_schedule_initialization}

    assert Process.get({__MODULE__, :trace}) == []
  end

  test "rejects malformed restored schedules and saturated retirement" do
    configuration = configuration([trigger("ambient")])

    malformed_schedules = [
      schedule("wrong", ~U[2026-08-11 12:30:02.000000Z]),
      %{schedule("ambient", ~U[2026-08-11 12:30:02.000000Z]) | next_run_at: "private"},
      %{
        schedule("ambient", ~U[2026-08-11 12:30:02.000000Z])
        | daily_count: 1,
          daily_count_date: nil
      }
    ]

    for malformed <- malformed_schedules do
      Process.put({__MODULE__, :trace}, [])
      Process.put({__MODULE__, :responses}, %{"ambient" => {:ok, malformed}})
      Process.put({__MODULE__, :random}, [0.0])

      assert StochasticScheduleInitializer.run(
               configuration,
               @initialized_at,
               SequenceRandom,
               adapters()
             ) == {:error, :invalid_stochastic_schedule_initialization}
    end

    Process.put({__MODULE__, :trace}, [])
    Process.put({__MODULE__, :responses}, %{})
    Process.put({__MODULE__, :random}, [0.0])

    Process.put(
      {__MODULE__, :retirement},
      {:ok, %StochasticScheduleRetirement{retired_count: 100, saturated?: true}}
    )

    assert StochasticScheduleInitializer.run(
             configuration,
             @initialized_at,
             SequenceRandom,
             adapters()
           ) == {:error, :invalid_stochastic_schedule_initialization}

    assert Process.get({__MODULE__, :trace}) == [{:retire, ["ambient"]}]
  end

  test "retires stale state even when no stochastic triggers remain" do
    assert {:ok, %Result{schedule_count: 0}} =
             StochasticScheduleInitializer.run(
               RuntimeFixture.configuration(),
               @initialized_at,
               SequenceRandom,
               adapters()
             )

    assert Process.get({__MODULE__, :trace}) == [{:retire, []}]
    assert Process.get({__MODULE__, :random}) == [0.0, 0.0]
  end

  test "rejects malformed dependencies before sampling or storing" do
    valid = configuration([trigger("ambient")])

    invalid = [
      {%{valid | version: 1.0}, @initialized_at, SequenceRandom, adapters()},
      {valid, %{@initialized_at | hour: 24}, SequenceRandom, adapters()},
      {valid, @initialized_at, String, adapters()},
      {valid, @initialized_at, SequenceRandom, %Adapters{schedules: String}},
      {valid, @initialized_at, SequenceRandom, Map.put(adapters(), :private, true)},
      {nil, @initialized_at, SequenceRandom, adapters()}
    ]

    for arguments <- invalid do
      assert apply(StochasticScheduleInitializer, :run, Tuple.to_list(arguments)) ==
               {:error, :invalid_stochastic_schedule_initialization}
    end

    assert Process.get({__MODULE__, :trace}) == []
    assert Process.get({__MODULE__, :random}) == [0.0, 0.0]
  end

  test "validates only exact bounded aggregate results" do
    valid = %Result{schedule_count: 2}
    assert StochasticScheduleInitializer.validate_result(valid) == :ok

    for result <- [
          %{valid | schedule_count: -1},
          %{valid | schedule_count: 257},
          %{valid | schedule_count: "private"},
          Map.put(valid, :private, true),
          nil
        ] do
      assert StochasticScheduleInitializer.validate_result(result) ==
               {:error, :invalid_stochastic_schedule_initialization_result}
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

  defp trigger(id) do
    %StochasticTrigger{
      id: id,
      distribution: :shifted_exponential,
      mean_interval_ms: 8_000,
      minimum_interval_ms: 2_000,
      active_hours: nil,
      daily_limit: nil,
      action: :emit_event,
      event: %EmittedEvent{type: "stochastic.fired", group: "social", subject: id}
    }
  end

  defp adapters, do: %Adapters{schedules: Schedules}

  @doc false
  def schedule(trigger_id, next_run_at) do
    %StochasticSchedule{
      trigger_id: trigger_id,
      next_run_at: next_run_at,
      last_run_at: nil,
      daily_count: 0,
      daily_count_date: nil,
      claim_token: nil,
      claim_started_at: nil,
      claim_expires_at: nil
    }
    |> Ecto.put_meta(state: :loaded)
  end
end
