defmodule ClusterMurmur.Runtime.EventRetentionCycleTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.RetentionPlanner.Plan
  alias ClusterMurmur.Runtime.EventRetentionCycle
  alias ClusterMurmur.Runtime.EventRetentionCycle.{Adapters, Result}
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @now ~U[2026-08-09 05:00:00.000000Z]

  defmodule MarkerStore do
    def prune(%Plan{} = plan) do
      send(self(), {:pruned, plan})
      {:ok, 37}
    end
  end

  defmodule EmptyMarkerStore do
    def prune(%Plan{}), do: {:ok, 0}
  end

  defmodule UnavailableMarkerStore do
    def prune(%Plan{}), do: {:error, :storage_unavailable}
  end

  defmodule InvalidPlanMarkerStore do
    def prune(%Plan{}), do: {:error, :invalid_retention_plan}
  end

  defmodule MalformedMarkerStore do
    def prune(%Plan{}), do: {:ok, 101}
  end

  defmodule RaisingMarkerStore do
    def prune(%Plan{}), do: raise("private-value")
  end

  defmodule ExitingMarkerStore do
    def prune(%Plan{}), do: exit("private-value")
  end

  test "plans and executes exactly one bounded marker cleanup batch" do
    configuration = RuntimeFixture.configuration()

    assert EventRetentionCycle.run(configuration, @now, adapters(MarkerStore)) ==
             {:ok, %Result{pruned_marker_count: 37}}

    assert_received {:pruned,
                     %Plan{
                       policy: policy,
                       planned_at: @now,
                       cutoff: ~U[2026-05-11 05:00:00.000000Z]
                     }}

    assert policy === configuration.event_policy
    refute_received {:pruned, _plan}
  end

  test "accepts an empty aggregate result" do
    assert EventRetentionCycle.run(
             RuntimeFixture.configuration(),
             @now,
             adapters(EmptyMarkerStore)
           ) == {:ok, %Result{pruned_marker_count: 0}}
  end

  test "maps only the stable store outage to a cleanup failure" do
    assert EventRetentionCycle.run(
             RuntimeFixture.configuration(),
             @now,
             adapters(UnavailableMarkerStore)
           ) == {:error, :event_retention_failed}
  end

  test "fails closed on invalid inputs and adapters before cleanup" do
    configuration = RuntimeFixture.configuration()

    invalid = [
      {nil, @now, adapters(MarkerStore)},
      {%{configuration | version: 2}, @now, adapters(MarkerStore)},
      {configuration, nil, adapters(MarkerStore)},
      {configuration, %{@now | time_zone: "example.invalid"}, adapters(MarkerStore)},
      {configuration, @now, %Adapters{dedupe_markers: String}},
      {configuration, @now, Map.put(adapters(MarkerStore), :private, "private-value")},
      {configuration, @now, nil}
    ]

    for {candidate_configuration, now, candidate_adapters} <- invalid do
      result = EventRetentionCycle.run(candidate_configuration, now, candidate_adapters)
      assert result == {:error, :invalid_event_retention_cycle}
      refute inspect(result) =~ "private"
    end

    refute_received {:pruned, _plan}
  end

  test "fails closed on rejected, malformed, or raising store behavior" do
    configuration = RuntimeFixture.configuration()

    for store <- [
          InvalidPlanMarkerStore,
          MalformedMarkerStore,
          RaisingMarkerStore,
          ExitingMarkerStore
        ] do
      result = EventRetentionCycle.run(configuration, @now, adapters(store))
      assert result == {:error, :invalid_event_retention_cycle}
      refute inspect(result) =~ "private"
    end
  end

  test "validates only exact bounded aggregate results" do
    valid = %Result{pruned_marker_count: 100}
    assert EventRetentionCycle.validate_result(valid) == :ok

    invalid = [
      %{valid | pruned_marker_count: -1},
      %{valid | pruned_marker_count: 101},
      %{valid | pruned_marker_count: "private"},
      Map.put(valid, :private, "private-value"),
      nil
    ]

    for result <- invalid do
      assert EventRetentionCycle.validate_result(result) ==
               {:error, :invalid_event_retention_cycle_result}
    end
  end

  defp adapters(store), do: %Adapters{dedupe_markers: store}
end
