defmodule ClusterMurmur.Observations.DebounceEvaluatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Observations.{
    DebounceEvaluator,
    DebouncePolicy,
    EntityState,
    Observation
  }

  test "tracks initial progress and commits only at the configured threshold" do
    assert {:ok, first} = DebounceEvaluator.evaluate(nil, observation(:unhealthy, 0), policy())
    assert first.current_state == :unknown
    assert first.pending_state == :unhealthy
    assert first.consecutive_count == 1
    assert first.last_changed_at == nil

    assert {:ok, second} = DebounceEvaluator.evaluate(first, observation(:unhealthy, 1), policy())
    assert second.current_state == :unhealthy
    assert second.pending_state == nil
    assert second.consecutive_count == 0
    assert second.last_changed_at == second.last_observed_at
  end

  test "clears contrary progress when the committed state is observed" do
    previous = state(pending_state: :unhealthy, consecutive_count: 1)
    assert {:ok, next} = DebounceEvaluator.evaluate(previous, observation(:healthy, 1), policy())
    assert next.current_state == :healthy
    assert next.pending_state == nil
    assert next.consecutive_count == 0
    assert next.last_changed_at == previous.last_changed_at
    assert next.facts == %{"sample" => 1}
  end

  test "resets pending progress when the contrary candidate changes" do
    previous =
      state(
        current_state: :unknown,
        pending_state: :unhealthy,
        consecutive_count: 1,
        last_changed_at: nil
      )

    assert {:ok, next} = DebounceEvaluator.evaluate(previous, observation(:healthy, 1), policy())
    assert next.current_state == :unknown
    assert next.pending_state == :healthy
    assert next.consecutive_count == 1
  end

  test "supports explicit one-observation thresholds" do
    policy = %DebouncePolicy{healthy_threshold: 1, unhealthy_threshold: 1}
    assert {:ok, initial} = DebounceEvaluator.evaluate(nil, observation(:healthy, 0), policy)
    assert initial.current_state == :healthy
    assert initial.last_changed_at == initial.last_observed_at

    assert {:ok, failed} =
             DebounceEvaluator.evaluate(initial, observation(:unhealthy, 1), policy)

    assert failed.current_state == :unhealthy
  end

  test "rejects invalid inputs, mismatched identity, and non-new observations" do
    previous = state([])

    assert DebounceEvaluator.evaluate(
             previous,
             observation(:healthy, 1, subject: "other"),
             policy()
           ) ==
             {:error, :observation_identity_mismatch}

    for offset <- [-1, 0] do
      assert DebounceEvaluator.evaluate(previous, observation(:healthy, offset), policy()) ==
               {:error, :stale_observation}
    end

    for invalid <- [
          nil,
          %DebouncePolicy{healthy_threshold: 0, unhealthy_threshold: 2},
          Map.put(policy(), :extra, 1)
        ] do
      assert DebounceEvaluator.evaluate(previous, observation(:healthy, 1), invalid) ==
               {:error, :invalid_debounce_policy}
    end

    assert DebounceEvaluator.evaluate(previous, %{observation(:healthy, 1) | facts: []}, policy()) ==
             {:error, :invalid_observation}

    assert DebounceEvaluator.evaluate(
             %{previous | consecutive_count: -1},
             observation(:healthy, 1),
             policy()
           ) ==
             {:error, :invalid_entity_state}
  end

  defp policy, do: %DebouncePolicy{healthy_threshold: 2, unhealthy_threshold: 2}

  defp observation(state, offset, overrides \\ []) do
    struct!(
      Observation,
      Keyword.merge(
        [
          source: "example-observer",
          subject: "example-target",
          state: state,
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
