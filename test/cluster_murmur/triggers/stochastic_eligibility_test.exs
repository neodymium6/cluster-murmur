defmodule ClusterMurmur.Triggers.StochasticEligibilityTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Triggers.ActiveHours
  alias ClusterMurmur.Triggers.{EmittedEvent, StochasticEligibility, StochasticTrigger}
  alias ClusterMurmur.Triggers.StochasticEligibility.Decision

  test "allows an unconstrained trigger without a daily count" do
    assert StochasticEligibility.evaluate(trigger(nil, nil), ~U[2026-08-04 00:00:00Z], nil) ==
             {:ok, %Decision{eligible: true, reason: :eligible, local_date: nil}}
  end

  test "returns no date bucket for an active-hours-only trigger" do
    trigger = trigger(window(8 * 60, 23 * 60, "Asia/Tokyo"), nil)

    assert StochasticEligibility.evaluate(trigger, ~U[2026-08-04 00:00:00Z], nil) ==
             {:ok, %Decision{eligible: true, reason: :eligible, local_date: nil}}
  end

  test "checks active hours before the daily limit" do
    trigger = trigger(window(8 * 60, 23 * 60, "Asia/Tokyo"), 3)

    assert StochasticEligibility.evaluate(trigger, ~U[2026-08-04 00:00:00Z], {~D[2026-08-04], 3}) ==
             {:ok,
              %Decision{
                eligible: false,
                reason: :daily_limit_reached,
                local_date: ~D[2026-08-04]
              }}

    assert StochasticEligibility.evaluate(trigger, ~U[2026-08-04 15:00:00Z], {~D[2026-08-05], 3}) ==
             {:ok,
              %Decision{
                eligible: false,
                reason: :outside_active_hours,
                local_date: ~D[2026-08-05]
              }}
  end

  test "allows execution below the daily limit" do
    trigger = trigger(window(8 * 60, 23 * 60, "Asia/Tokyo"), 3)

    assert StochasticEligibility.evaluate(trigger, ~U[2026-08-04 00:00:00Z], {~D[2026-08-04], 2}) ==
             {:ok, %Decision{eligible: true, reason: :eligible, local_date: ~D[2026-08-04]}}
  end

  test "attributes the post-midnight side of a crossing window to its calendar date" do
    trigger = trigger(window(23 * 60, 8 * 60, "Asia/Tokyo"), 3)

    assert StochasticEligibility.evaluate(trigger, ~U[2026-08-04 16:00:00Z], {~D[2026-08-05], 0}) ==
             {:ok, %Decision{eligible: true, reason: :eligible, local_date: ~D[2026-08-05]}}
  end

  test "rejects invalid count contracts and forged trigger values" do
    constrained = trigger(window(8 * 60, 23 * 60, "Etc/UTC"), 3)

    for count <- [nil, -1, {~D[2026-08-04], -1}, {~D[2026-08-04], 10_001}, {~D[2026-08-04], 1.0}] do
      assert StochasticEligibility.evaluate(constrained, ~U[2026-08-04 12:00:00Z], count) ==
               {:error, :invalid_execution_count}
    end

    assert StochasticEligibility.evaluate(
             constrained,
             ~U[2026-08-04 12:00:00Z],
             {~D[2026-08-03], 0}
           ) == {:error, :invalid_execution_count}

    assert StochasticEligibility.evaluate(trigger(nil, nil), ~U[2026-08-04 12:00:00Z], 0) ==
             {:error, :invalid_execution_count}

    invalid = [
      %{constrained | daily_limit: 0},
      %{constrained | active_hours: nil},
      %{constrained | distribution: :uniform},
      %{constrained | mean_interval_ms: constrained.minimum_interval_ms}
    ]

    for trigger <- invalid do
      assert StochasticEligibility.evaluate(
               trigger,
               ~U[2026-08-04 12:00:00Z],
               {~D[2026-08-04], 0}
             ) ==
               {:error, :invalid_trigger}
    end
  end

  test "preserves datetime errors and redacts the local bucket from inspection" do
    trigger = trigger(window(8 * 60, 23 * 60, "Etc/UTC"), 3)
    forged = %{~U[2026-08-04 12:00:00Z] | hour: 24}

    assert StochasticEligibility.evaluate(trigger, forged, {~D[2026-08-04], 0}) ==
             {:error, :invalid_datetime}

    assert StochasticEligibility.evaluate(trigger, nil, {~D[2026-08-04], 0}) ==
             {:error, :invalid_datetime}

    assert {:ok, decision} =
             StochasticEligibility.evaluate(
               trigger,
               ~U[2026-08-04 12:00:00Z],
               {~D[2026-08-04], 0}
             )

    refute inspect(decision) =~ "2026"
    assert inspect(decision) =~ "eligible: true"
  end

  defp trigger(active_hours, daily_limit) do
    %StochasticTrigger{
      id: "ambient",
      distribution: :shifted_exponential,
      mean_interval_ms: 8_000,
      minimum_interval_ms: 2_000,
      active_hours: active_hours,
      daily_limit: daily_limit,
      action: :emit_event,
      event: %EmittedEvent{type: "stochastic.fired", group: "social", subject: "ambient"}
    }
  end

  defp window(start_minute, end_minute, timezone) do
    %ActiveHours{start_minute: start_minute, end_minute: end_minute, timezone: timezone}
  end
end
