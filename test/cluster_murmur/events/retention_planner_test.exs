defmodule ClusterMurmur.Events.RetentionPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.EventPolicy
  alias ClusterMurmur.Events.RetentionPlanner
  alias ClusterMurmur.Events.RetentionPlanner.Plan

  @planned_at ~U[2026-08-09 04:00:00.000000Z]

  test "derives the exact configured retention cutoff without effects" do
    assert {:ok, %Plan{} = plan} = RetentionPlanner.plan(policy(), @planned_at)

    assert plan == %Plan{
             policy: policy(),
             planned_at: @planned_at,
             cutoff: ~U[2026-05-11 04:00:00.000000Z]
           }

    assert RetentionPlanner.validate(plan) == :ok
  end

  test "supports the bounded maximum retention interval" do
    policy = %EventPolicy{
      dedupe_window_ms: 1,
      retention_ms: 365 * 86_400_000
    }

    assert {:ok, %Plan{cutoff: ~U[2025-08-09 04:00:00.000000Z]}} =
             RetentionPlanner.plan(policy, @planned_at)
  end

  test "rejects invalid policy and time facts before calculation" do
    assert RetentionPlanner.plan(%{policy() | retention_ms: 0}, @planned_at) ==
             {:error, :invalid_event_policy}

    assert RetentionPlanner.plan(policy(), nil) == {:error, :invalid_datetime}
    assert RetentionPlanner.plan(nil, nil) == {:error, :invalid_event_policy}
  end

  test "fails closed when retention would leave the storage year range" do
    beginning = DateTime.new!(~D[0000-01-01], ~T[00:00:00.000000], "Etc/UTC")

    assert RetentionPlanner.plan(policy(), beginning) == {:error, :no_retention_cutoff}
  end

  test "rejects forged or uncorrelated plans without retaining added values" do
    assert {:ok, plan} = RetentionPlanner.plan(policy(), @planned_at)

    invalid = [
      %{plan | cutoff: DateTime.add(plan.cutoff, 1, :microsecond)},
      %{plan | cutoff: %{plan.cutoff | microsecond: {0, 0}}},
      %{plan | policy: %{plan.policy | retention_ms: 1}},
      %{plan | planned_at: %{plan.planned_at | hour: 24}},
      Map.put(plan, :private, "private-value")
    ]

    for candidate <- invalid do
      result = RetentionPlanner.validate(candidate)
      assert result == {:error, :invalid_retention_plan}
      refute inspect(result) =~ "private"
    end

    assert RetentionPlanner.validate(nil) == {:error, :invalid_retention_plan}
  end

  defp policy do
    %EventPolicy{dedupe_window_ms: 300_000, retention_ms: 90 * 86_400_000}
  end
end
