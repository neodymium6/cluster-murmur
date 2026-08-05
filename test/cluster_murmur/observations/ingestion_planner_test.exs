defmodule ClusterMurmur.Observations.IngestionPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observations.{
    DebouncePolicy,
    EntityState,
    IngestionPlanner,
    Observation
  }

  test "plans pending state without an event before the threshold" do
    assert {:ok, plan} = IngestionPlanner.plan(nil, observation(:unhealthy, 0), policy())
    assert plan.entity_state.current_state == :unknown
    assert plan.entity_state.pending_state == :unhealthy
    assert plan.entity_state.consecutive_count == 1
    assert plan.event == nil
    assert inspect(plan) == "#ClusterMurmur.Observations.IngestionPlanner.Plan<...>"
  end

  test "plans one factual event when debounce commits a failure" do
    assert {:ok, pending} = IngestionPlanner.plan(nil, observation(:unhealthy, 0), policy())

    assert {:ok, plan} =
             IngestionPlanner.plan(
               pending.entity_state,
               observation(:unhealthy, 1),
               policy()
             )

    assert plan.entity_state.current_state == :unhealthy
    assert plan.entity_state.pending_state == nil
    assert plan.event.type == "observation.failed"
    assert plan.event.facts == %{"sample" => 1}
  end

  test "plans recovery and silent steady-state updates" do
    failed = state(current_state: :unhealthy)

    assert {:ok, pending} =
             IngestionPlanner.plan(failed, observation(:healthy, 1), policy())

    assert pending.event == nil

    assert {:ok, recovered} =
             IngestionPlanner.plan(
               pending.entity_state,
               observation(:healthy, 2),
               policy()
             )

    assert recovered.event.type == "observation.recovered"

    assert {:ok, steady} =
             IngestionPlanner.plan(
               recovered.entity_state,
               observation(:healthy, 3),
               policy()
             )

    assert steady.entity_state.current_state == :healthy
    assert steady.event == nil
  end

  test "preserves factual validation errors without side effects" do
    previous = state([])

    assert IngestionPlanner.plan(previous, observation(:healthy, 0), policy()) ==
             {:error, :stale_observation}

    assert IngestionPlanner.plan(previous, observation(:healthy, 1, subject: "other"), policy()) ==
             {:error, :observation_identity_mismatch}

    assert IngestionPlanner.plan(previous, observation(:healthy, 1), nil) ==
             {:error, :invalid_debounce_policy}
  end

  defp policy, do: %DebouncePolicy{healthy_threshold: 2, unhealthy_threshold: 2}

  defp observation(health, offset, overrides \\ []) do
    struct!(
      Observation,
      Keyword.merge(
        [
          source: "example-observer",
          subject: "example-target",
          state: health,
          observed_at: DateTime.add(~U[2026-08-05 12:00:00.000000Z], offset, :second),
          facts: %{"sample" => offset},
          labels: %{"category" => "monitoring"}
        ],
        overrides
      )
    )
  end

  defp state(overrides) do
    struct!(
      EntityState,
      Keyword.merge(
        [
          source: "example-observer",
          subject: "example-target",
          current_state: :healthy,
          pending_state: nil,
          consecutive_count: 0,
          last_observed_at: ~U[2026-08-05 12:00:00.000000Z],
          last_changed_at: ~U[2026-08-05 11:00:00.000000Z],
          facts: %{},
          labels: %{}
        ],
        overrides
      )
    )
  end
end
